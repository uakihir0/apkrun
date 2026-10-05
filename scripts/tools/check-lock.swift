import CoreFoundation
import CryptoKit
import Darwin
import Foundation

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

struct LockPackage {
    let identity: String
    let location: String
    let version: String
    let revision: String
}

struct PackageDeclaration {
    let repository: String
    let exactVersion: String?
    let source: URL
}

func childProcessEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
    environment["GIT_NO_REPLACE_OBJECTS"] = "1"
    return environment
}

func readJSON(_ data: Data, from path: URL) throws -> Any {
    do {
        return try JSONSerialization.jsonObject(with: data)
    } catch {
        throw CheckFailure(description: "\(path.path): invalid JSON: \(error)")
    }
}

struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

struct OpenRegularFile {
    let descriptor: Int32
    let directoryIdentities: [FileIdentity]
}

struct OpenDirectory {
    let descriptor: Int32
    let identities: [FileIdentity]
}

func openDirectoryChain(
    root: URL,
    components: [String],
    role: String
) throws -> (descriptor: Int32, identities: [FileIdentity]) {
    let path = components.reduce(root) { $0.appending(path: $1) }
    guard
        components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0")
        })
    else {
        throw CheckFailure(description: "\(path.path): unsafe path for \(role)")
    }

    var directoryDescriptor = open(
        root.path,
        O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
    )
    guard directoryDescriptor >= 0 else {
        throw CheckFailure(
            description: "\(root.path): couldn't open the root for \(role): "
                + String(cString: strerror(errno))
        )
    }
    var identities: [FileIdentity] = []
    var rootMetadata = stat()
    guard fstat(directoryDescriptor, &rootMetadata) == 0 else {
        let details = String(cString: strerror(errno))
        close(directoryDescriptor)
        throw CheckFailure(description: "\(root.path): couldn't inspect \(role) root: \(details)")
    }
    identities.append(FileIdentity(device: rootMetadata.st_dev, inode: rootMetadata.st_ino))

    for component in components {
        let nextDescriptor = openat(
            directoryDescriptor,
            component,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard nextDescriptor >= 0 else {
            let details = String(cString: strerror(errno))
            close(directoryDescriptor)
            throw CheckFailure(
                description: "\(path.path): couldn't safely open \(role) directory: \(details)"
            )
        }
        var metadata = stat()
        guard fstat(nextDescriptor, &metadata) == 0 else {
            let details = String(cString: strerror(errno))
            close(nextDescriptor)
            close(directoryDescriptor)
            throw CheckFailure(description: "\(path.path): couldn't inspect \(role) directory: \(details)")
        }
        close(directoryDescriptor)
        directoryDescriptor = nextDescriptor
        identities.append(FileIdentity(device: metadata.st_dev, inode: metadata.st_ino))
    }
    return (directoryDescriptor, identities)
}

func openOrCreateDirectoryBeneath(
    root: URL,
    components: [String],
    role: String
) throws -> OpenDirectory {
    let path = components.reduce(root) { $0.appending(path: $1) }
    guard !components.isEmpty,
        components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0")
        })
    else {
        throw CheckFailure(description: "\(path.path): unsafe path for \(role)")
    }

    var directoryDescriptor = open(
        root.path,
        O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
    )
    guard directoryDescriptor >= 0 else {
        throw CheckFailure(
            description: "\(root.path): couldn't open the root for \(role): "
                + String(cString: strerror(errno))
        )
    }
    var identities: [FileIdentity] = []
    var rootMetadata = stat()
    guard fstat(directoryDescriptor, &rootMetadata) == 0 else {
        let details = String(cString: strerror(errno))
        close(directoryDescriptor)
        throw CheckFailure(description: "\(root.path): couldn't inspect \(role) root: \(details)")
    }
    identities.append(FileIdentity(device: rootMetadata.st_dev, inode: rootMetadata.st_ino))

    for component in components {
        var nextDescriptor = openat(
            directoryDescriptor,
            component,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        if nextDescriptor < 0, errno == ENOENT {
            if mkdirat(directoryDescriptor, component, mode_t(S_IRWXU)) != 0, errno != EEXIST {
                let details = String(cString: strerror(errno))
                close(directoryDescriptor)
                throw CheckFailure(
                    description: "\(path.path): couldn't create \(role) directory: \(details)"
                )
            }
            nextDescriptor = openat(
                directoryDescriptor,
                component,
                O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
            )
        }
        guard nextDescriptor >= 0 else {
            let details = String(cString: strerror(errno))
            close(directoryDescriptor)
            throw CheckFailure(
                description: "\(path.path): couldn't safely open \(role) directory: \(details)"
            )
        }
        var metadata = stat()
        guard fstat(nextDescriptor, &metadata) == 0 else {
            let details = String(cString: strerror(errno))
            close(nextDescriptor)
            close(directoryDescriptor)
            throw CheckFailure(description: "\(path.path): couldn't inspect \(role) directory: \(details)")
        }
        close(directoryDescriptor)
        directoryDescriptor = nextDescriptor
        identities.append(FileIdentity(device: metadata.st_dev, inode: metadata.st_ino))
    }
    return OpenDirectory(descriptor: directoryDescriptor, identities: identities)
}

func openRegularFileBeneath(
    root: URL,
    components: [String],
    role: String,
    maximumBytes: Int? = nil
) throws -> OpenRegularFile {
    let path = components.reduce(root) { $0.appending(path: $1) }
    guard !components.isEmpty,
        components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0")
        })
    else {
        throw CheckFailure(description: "\(path.path): unsafe path for \(role)")
    }
    let (directoryDescriptor, identities) = try openDirectoryChain(
        root: root,
        components: Array(components.dropLast()),
        role: role
    )
    defer {
        close(directoryDescriptor)
    }
    let descriptor = openat(
        directoryDescriptor,
        components[components.count - 1],
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
    )
    guard descriptor >= 0 else {
        throw CheckFailure(
            description: "\(path.path): couldn't safely open \(role): "
                + String(cString: strerror(errno))
        )
    }
    var before = stat()
    guard fstat(descriptor, &before) == 0 else {
        let details = String(cString: strerror(errno))
        close(descriptor)
        throw CheckFailure(description: "\(path.path): couldn't inspect \(role): \(details)")
    }
    guard (before.st_mode & S_IFMT) == S_IFREG else {
        close(descriptor)
        throw CheckFailure(description: "\(path.path): \(role) is not a regular file")
    }
    if let maximumBytes {
        guard before.st_size >= 0, before.st_size <= Int64(maximumBytes) else {
            close(descriptor)
            throw CheckFailure(description: "\(path.path): \(role) exceeds the size limit")
        }
    }
    return OpenRegularFile(
        descriptor: descriptor,
        directoryIdentities: identities
    )
}

func sameFileVersion(_ first: stat, _ second: stat) -> Bool {
    first.st_dev == second.st_dev
        && first.st_ino == second.st_ino
        && first.st_size == second.st_size
        && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
        && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
        && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
        && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
}

func readRegularFileBeneath(
    root: URL,
    components: [String],
    role: String,
    maximumBytes: Int
) throws -> Data {
    let path = components.reduce(root) { $0.appending(path: $1) }
    let openedFile = try openRegularFileBeneath(
        root: root,
        components: components,
        role: role,
        maximumBytes: maximumBytes
    )
    let descriptor = openedFile.descriptor
    defer {
        close(descriptor)
    }

    var before = stat()
    guard fstat(descriptor, &before) == 0 else {
        throw CheckFailure(
            description: "\(path.path): couldn't inspect \(role): \(String(cString: strerror(errno)))"
        )
    }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    var data = Data()
    do {
        while let chunk = try file.read(upToCount: min(65_536, maximumBytes + 1 - data.count)),
            !chunk.isEmpty
        {
            data.append(chunk)
            guard data.count <= maximumBytes else {
                throw CheckFailure(description: "\(path.path): \(role) exceeds the size limit")
            }
        }
    } catch {
        throw CheckFailure(description: "\(path.path): couldn't read \(role): \(error)")
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0, sameFileVersion(before, after) else {
        throw CheckFailure(description: "\(path.path): \(role) changed while it was being read")
    }
    let (verifiedDirectoryDescriptor, directoryIdentities) = try openDirectoryChain(
        root: root,
        components: Array(components.dropLast()),
        role: role
    )
    close(verifiedDirectoryDescriptor)
    guard directoryIdentities == openedFile.directoryIdentities else {
        throw CheckFailure(description: "\(path.path): \(role) directory path changed while it was being read")
    }
    return data
}

func readRegularFileAt(
    directoryDescriptor: Int32,
    name: String,
    role: String,
    maximumBytes: Int
) throws -> Data {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
        throw CheckFailure(description: "unsafe path for \(role)")
    }
    let descriptor = openat(
        directoryDescriptor,
        name,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
    )
    guard descriptor >= 0 else {
        throw CheckFailure(
            description: "couldn't safely open \(role): \(String(cString: strerror(errno)))"
        )
    }
    defer {
        close(descriptor)
    }
    var before = stat()
    guard fstat(descriptor, &before) == 0 else {
        throw CheckFailure(
            description: "couldn't inspect \(role): \(String(cString: strerror(errno)))"
        )
    }
    guard (before.st_mode & S_IFMT) == S_IFREG else {
        throw CheckFailure(description: "\(role) is not a regular file")
    }
    guard before.st_size >= 0, before.st_size <= Int64(maximumBytes) else {
        throw CheckFailure(description: "\(role) exceeds the size limit")
    }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    var data = Data()
    do {
        while let chunk = try file.read(upToCount: min(65_536, maximumBytes + 1 - data.count)),
            !chunk.isEmpty
        {
            data.append(chunk)
            guard data.count <= maximumBytes else {
                throw CheckFailure(description: "\(role) exceeds the size limit")
            }
        }
    } catch {
        throw CheckFailure(description: "couldn't read \(role): \(error)")
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0, sameFileVersion(before, after) else {
        throw CheckFailure(description: "\(role) changed while it was being read")
    }
    return data
}

func readLockSnapshot(at root: URL) throws -> Data {
    try readRegularFileBeneath(
        root: root,
        components: ["ThirdParty", "ThirdParty.lock.json"],
        role: "lock file",
        maximumBytes: 16 * 1_024 * 1_024
    )
}

func string(_ value: Any?) -> String? {
    value as? String
}

func arrayOfStrings(_ value: Any?) -> [String]? {
    value as? [String]
}

func repositoryPort(in value: String) -> (present: Bool, port: Int?)? {
    guard let schemeEnd = value.range(of: "://")?.upperBound else { return nil }
    let remainder = value[schemeEnd...]
    let authorityEnd = remainder.firstIndex(where: { "/?#".contains($0) }) ?? remainder.endIndex
    let authority = remainder[..<authorityEnd]
    guard !authority.isEmpty, !authority.contains("@") else { return nil }

    let portText: Substring
    if authority.first == "[" {
        guard let closingBracket = authority.firstIndex(of: "]") else { return nil }
        let suffix = authority[authority.index(after: closingBracket)...]
        if suffix.isEmpty { return (false, nil) }
        guard suffix.first == ":" else { return nil }
        portText = suffix.dropFirst()
    } else if let colon = authority.lastIndex(of: ":") {
        guard !authority[..<colon].contains(":") else { return nil }
        portText = authority[authority.index(after: colon)...]
    } else {
        return (false, nil)
    }

    guard !portText.isEmpty,
        portText.allSatisfy({ $0 >= "0" && $0 <= "9" }),
        let port = Int(portText),
        (1...65_535).contains(port)
    else {
        return nil
    }
    return (true, port)
}

func normalizedRepositoryURL(_ value: String) -> String? {
    guard let explicitPort = repositoryPort(in: value) else { return nil }
    guard var components = URLComponents(string: value),
        let scheme = components.scheme,
        let host = components.host,
        !host.isEmpty,
        components.url != nil,
        !components.percentEncodedPath.isEmpty,
        components.user == nil,
        components.password == nil,
        components.query == nil,
        components.fragment == nil,
        scheme.caseInsensitiveCompare("https") == .orderedSame
    else {
        return nil
    }
    guard components.port == explicitPort.port else { return nil }

    components.scheme = "https"
    components.host = host.lowercased()
    if explicitPort.port == 443 {
        components.port = nil
    }
    var path = components.percentEncodedPath
    while path.hasSuffix("/") {
        path.removeLast()
    }
    guard !path.isEmpty else { return nil }
    if path.hasSuffix(".git") {
        path = String(path.dropLast(4))
    }
    guard !path.isEmpty else { return nil }
    components.percentEncodedPath = path
    return components.string
}

func identityKey(_ value: String) -> String {
    value.lowercased()
}

func safeRelativePath(_ value: String) -> Bool {
    guard !value.isEmpty, !value.hasPrefix("/") else { return false }
    return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
        !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\")
    }
}

func runJSONCommand(
    executable: URL,
    arguments: [String],
    workingDirectory: URL,
    inputFile: URL
) throws -> Any {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = workingDirectory
    process.environment = childProcessEnvironment()
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output

    do {
        try process.run()
    } catch {
        throw CheckFailure(
            description: "\(inputFile.path): couldn't run \(executable.path): \(error)"
        )
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let details = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw CheckFailure(
            description: "\(inputFile.path): command failed (\(process.terminationStatus)): \(details)"
        )
    }
    do {
        return try JSONSerialization.jsonObject(with: data)
    } catch {
        throw CheckFailure(description: "\(inputFile.path): command returned invalid JSON: \(error)")
    }
}

func swiftPackageDeclarations(root: URL, manifest: URL) throws -> [PackageDeclaration] {
    let dump = try runJSONCommand(
        executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
        arguments: ["swift", "package", "dump-package", "--package-path", root.path],
        workingDirectory: root,
        inputFile: manifest
    )
    guard let package = dump as? [String: Any],
        let dependencies = package["dependencies"] as? [[String: Any]]
    else {
        throw CheckFailure(description: "\(manifest.path): swift package dump-package omitted dependencies")
    }

    var declarations: [PackageDeclaration] = []
    for dependency in dependencies {
        guard let sourceControl = dependency["sourceControl"] as? [[String: Any]] else {
            continue
        }
        for package in sourceControl {
            guard let location = package["location"] as? [String: Any],
                let remote = location["remote"] as? [[String: Any]],
                let repository = remote.first?["urlString"] as? String,
                let requirement = package["requirement"] as? [String: Any]
            else {
                throw CheckFailure(
                    description: "\(manifest.path): malformed source-control package in SwiftPM dump"
                )
            }
            let exactVersions = requirement["exact"] as? [String]
            declarations.append(
                PackageDeclaration(
                    repository: repository,
                    exactVersion: exactVersions?.count == 1 ? exactVersions?.first : nil,
                    source: manifest
                )
            )
        }
    }
    return declarations
}

func capturedVersion(from versions: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: #"(?m)^XCODEGEN_VERSION=([0-9.]+)$"#),
        let match = expression.firstMatch(
            in: versions,
            range: NSRange(versions.startIndex..<versions.endIndex, in: versions)
        ),
        let range = Range(match.range(at: 1), in: versions)
    else {
        return nil
    }
    return String(versions[range])
}

func xcodegenExecutable(root: URL) -> URL? {
    if let configuredPath = ProcessInfo.processInfo.environment["APKRUN_XCODEGEN"] {
        let configured = URL(fileURLWithPath: configuredPath)
        return FileManager.default.isExecutableFile(atPath: configured.path) ? configured : nil
    }
    let versionsURL = root.appending(path: "scripts/tool-versions.env")
    guard let versions = try? String(contentsOf: versionsURL, encoding: .utf8),
        let version = capturedVersion(from: versions)
    else {
        return nil
    }
    let path = root.appending(path: "build/tools/xcodegen-\(version)/bin/xcodegen")
    return FileManager.default.isExecutableFile(atPath: path.path) ? path : nil
}

func projectPackageDeclarations(
    root: URL,
    project: URL,
    executable: URL
) throws -> [PackageDeclaration] {
    let dump = try runJSONCommand(
        executable: executable,
        arguments: [
            "dump", "--type", "parsed-json", "--spec", project.path, "--project-root", root.path,
        ],
        workingDirectory: root,
        inputFile: project
    )
    guard let projectSpec = dump as? [String: Any],
        let packages = projectSpec["packages"] as? [String: Any]
    else {
        throw CheckFailure(description: "\(project.path): parsed XcodeGen spec omitted packages")
    }

    return packages.compactMap { _, value in
        guard let package = value as? [String: Any] else {
            return nil
        }
        let repository =
            string(package["url"])
            ?? string(package["git"])
            ?? string(package["github"]).map { "https://github.com/\($0)" }
        guard let repository else { return nil }
        return PackageDeclaration(
            repository: repository,
            exactVersion: string(package["exactVersion"]) ?? string(package["version"]),
            source: project
        )
    }
}

func isDescendant(_ candidate: URL, of directory: URL) -> Bool {
    let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
    let directoryPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
    let prefix = directoryPath.hasSuffix("/") ? directoryPath : "\(directoryPath)/"
    return candidatePath.hasPrefix(prefix)
}

func pathComponents(_ path: URL, beneath root: URL) -> [String]? {
    let rootPath = root.standardizedFileURL.path
    let pathValue = path.standardizedFileURL.path
    let prefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
    guard pathValue.hasPrefix(prefix) else {
        return nil
    }
    return pathValue.dropFirst(prefix.count).split(separator: "/").map(String.init)
}

func hasSymlinkComponent(_ path: URL, within root: URL) -> Bool {
    let rootPath = root.standardizedFileURL.path
    let pathValue = path.standardizedFileURL.path
    let prefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
    guard pathValue.hasPrefix(prefix) else { return true }

    var current = root
    for component in pathValue.dropFirst(prefix.count).split(separator: "/") {
        current.appendPathComponent(String(component))
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil {
            return true
        }
    }
    return false
}

func readRegularTextFile(at path: URL, role: String, maximumBytes: Int = 1_048_576) throws -> String? {
    let descriptor = open(path.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    if descriptor < 0 {
        if errno == ENOENT {
            return nil
        }
        throw CheckFailure(
            description: "\(path.path): couldn't open \(role) safely: \(String(cString: strerror(errno)))"
        )
    }
    var before = stat()
    guard fstat(descriptor, &before) == 0 else {
        let details = String(cString: strerror(errno))
        close(descriptor)
        throw CheckFailure(description: "\(path.path): couldn't inspect \(role): \(details)")
    }
    guard (before.st_mode & S_IFMT) == S_IFREG else {
        close(descriptor)
        throw CheckFailure(description: "\(path.path): \(role) is not a regular file")
    }
    guard before.st_size >= 0, before.st_size <= Int64(maximumBytes) else {
        close(descriptor)
        throw CheckFailure(description: "\(path.path): \(role) exceeds the size limit")
    }
    defer {
        close(descriptor)
    }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    var data = Data()
    do {
        while let chunk = try file.read(upToCount: min(65_536, maximumBytes + 1 - data.count)),
            !chunk.isEmpty
        {
            data.append(chunk)
            guard data.count <= maximumBytes else {
                throw CheckFailure(description: "\(path.path): \(role) exceeds the size limit")
            }
        }
    } catch {
        throw CheckFailure(description: "\(path.path): couldn't read \(role): \(error)")
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0, sameFileVersion(before, after) else {
        throw CheckFailure(description: "\(path.path): \(role) changed while it was being read")
    }
    guard let text = String(data: data, encoding: .utf8) else {
        throw CheckFailure(description: "\(path.path): \(role) is not valid UTF-8")
    }
    return text
}

func containsGitConfigInclude(_ text: String) -> Bool {
    var inIncludeSection = false
    for rawLine in text.split(whereSeparator: \.isNewline) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else {
            continue
        }
        if line.hasPrefix("[") {
            let section = line.dropFirst()
                .prefix { !$0.isWhitespace && $0 != "]" }
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                .lowercased()
            inIncludeSection = section == "include" || section == "includeif"
        } else if inIncludeSection {
            let key = line.prefix { !$0.isWhitespace && $0 != "=" }.lowercased()
            if key == "path" {
                return true
            }
        }
    }
    return false
}

func isSafeFile(_ file: URL, under directory: URL, within root: URL) -> Bool {
    guard !hasSymlinkComponent(directory, within: root),
        !hasSymlinkComponent(file, within: root)
    else {
        return false
    }
    let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
    guard isDescendant(directory, of: resolvedRoot),
        isDescendant(file, of: directory)
    else {
        return false
    }
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
        let fileType = attributes[.type] as? FileAttributeType
    else {
        return false
    }
    return fileType == .typeRegular
}

struct GitMetadataPaths {
    let gitDirectory: URL
    let commonDirectory: URL
    let detachedHead: String
}

struct GitExecutionContext {
    let gitDirectory: String
    let workingTree: String
}

func inspectGitMetadata(at source: URL) throws -> GitMetadataPaths {
    let gitEntry = source.appending(path: ".git")
    guard !hasSymlinkComponent(gitEntry, within: source),
        let attributes = try? FileManager.default.attributesOfItem(atPath: gitEntry.path),
        let fileType = attributes[.type] as? FileAttributeType
    else {
        throw CheckFailure(
            description: "\(gitEntry.path): Git metadata entry is missing or symlinked"
        )
    }

    let gitDirectory: URL
    if fileType == .typeDirectory {
        gitDirectory = gitEntry.resolvingSymlinksInPath().standardizedFileURL
    } else if fileType == .typeRegular {
        guard let contents = try readRegularTextFile(at: gitEntry, role: "Git metadata pointer"),
            let line = contents.split(whereSeparator: \.isNewline).first,
            line.hasPrefix("gitdir: ")
        else {
            throw CheckFailure(description: "\(gitEntry.path): invalid Git metadata pointer")
        }
        let target = String(line.dropFirst("gitdir: ".count))
        let targetURL =
            target.hasPrefix("/")
            ? URL(fileURLWithPath: target)
            : source.appending(path: target)
        gitDirectory = targetURL.resolvingSymlinksInPath().standardizedFileURL
    } else {
        throw CheckFailure(
            description: "\(gitEntry.path): Git metadata entry is not a file or directory"
        )
    }
    guard !hasSymlinkComponent(gitDirectory, within: source),
        isDescendant(gitDirectory, of: source)
    else {
        throw CheckFailure(
            description: "\(gitEntry.path): Git metadata must be inside the pinned checkout and not symlinked"
        )
    }

    let commonPointer = gitDirectory.appending(path: "commondir")
    let commonDirectory: URL
    if let commonPath = try readRegularTextFile(
        at: commonPointer,
        role: "Git common-directory pointer"
    ) {
        let trimmedPath = commonPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetURL =
            trimmedPath.hasPrefix("/")
            ? URL(fileURLWithPath: trimmedPath)
            : gitDirectory.appending(path: trimmedPath)
        commonDirectory = targetURL.resolvingSymlinksInPath().standardizedFileURL
    } else {
        commonDirectory = gitDirectory
    }
    guard !hasSymlinkComponent(commonDirectory, within: source),
        isDescendant(commonDirectory, of: source)
    else {
        throw CheckFailure(
            description: "\(commonPointer.path): shared Git metadata must be inside the pinned checkout"
        )
    }

    guard let gitDirectoryComponents = pathComponents(gitDirectory, beneath: source) else {
        throw CheckFailure(
            description: "\(gitEntry.path): Git metadata must be beneath the pinned checkout"
        )
    }
    let headData = try readRegularFileBeneath(
        root: source,
        components: gitDirectoryComponents + ["HEAD"],
        role: "Git HEAD",
        maximumBytes: 1_024
    )
    guard let headContents = String(data: headData, encoding: .utf8) else {
        throw CheckFailure(description: "\(gitEntry.path): Git HEAD is not valid UTF-8")
    }
    let detachedHead = headContents.trimmingCharacters(in: .whitespacesAndNewlines)
    guard detachedHead.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
        throw CheckFailure(
            description: "\(gitEntry.path): pinned source checkout must have a detached full-commit HEAD"
        )
    }
    let indexDescriptor = try openRegularFileBeneath(
        root: source,
        components: gitDirectoryComponents + ["index"],
        role: "Git index"
    )
    close(indexDescriptor.descriptor)

    var configPaths: Set<String> = []
    for directory in [commonDirectory, gitDirectory] {
        for name in ["config", "config.worktree"] {
            let config = directory.appending(path: name)
            guard configPaths.insert(config.path).inserted else { continue }
            guard !hasSymlinkComponent(config, within: source) else {
                throw CheckFailure(description: "\(config.path): Git config must not be symlinked")
            }
            if let contents = try readRegularTextFile(at: config, role: "Git config"),
                containsGitConfigInclude(contents)
            {
                throw CheckFailure(
                    description: "\(config.path): Git config includes are not allowed for patch application"
                )
            }
        }
    }
    return GitMetadataPaths(
        gitDirectory: gitDirectory,
        commonDirectory: commonDirectory,
        detachedHead: detachedHead
    )
}

func decodePackages(_ object: Any, path: URL) throws -> [LockPackage] {
    guard let root = object as? [String: Any],
        let pins = root["pins"] as? [[String: Any]]
    else {
        throw CheckFailure(description: "\(path.path): expected a pins array")
    }

    var identities: Set<String> = []
    return try pins.map { pin in
        guard let identity = string(pin["identity"]),
            let location = string(pin["location"]),
            let state = pin["state"] as? [String: Any],
            let version = string(state["version"]),
            let revision = string(state["revision"])
        else {
            throw CheckFailure(description: "\(path.path): malformed Swift package pin")
        }
        guard identities.insert(identityKey(identity)).inserted else {
            throw CheckFailure(description: "\(path.path): duplicate Swift package pin '\(identity)'")
        }
        return LockPackage(
            identity: identity,
            location: location,
            version: version,
            revision: revision
        )
    }
}

func check(root: URL, lockSnapshot: Data) throws -> [String] {
    let lockURL = root.appending(path: "ThirdParty/ThirdParty.lock.json")
    let resolvedURL = root.appending(path: "Package.resolved")
    let manifestURL = root.appending(path: "Package.swift")
    let projectURL = root.appending(path: "project.yml")
    guard FileManager.default.fileExists(atPath: lockURL.path) else {
        throw CheckFailure(description: "\(lockURL.path): file is missing")
    }
    guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
        throw CheckFailure(description: "\(resolvedURL.path): file is missing")
    }
    guard FileManager.default.fileExists(atPath: manifestURL.path) else {
        throw CheckFailure(description: "\(manifestURL.path): file is missing")
    }

    guard let lock = try readJSON(lockSnapshot, from: lockURL) as? [String: Any],
        let schemaVersion = lock["schemaVersion"] as? NSNumber,
        CFGetTypeID(schemaVersion) != CFBooleanGetTypeID(),
        ["c", "s", "i", "l", "q"].contains(String(cString: schemaVersion.objCType)),
        schemaVersion.intValue == 1,
        let components = lock["components"] as? [[String: Any]]
    else {
        throw CheckFailure(description: "\(lockURL.path): expected schemaVersion 1 and components")
    }

    let manifestDescriptor = try openRegularFileBeneath(
        root: root,
        components: ["Package.swift"],
        role: "Swift package manifest",
        maximumBytes: 16 * 1_024 * 1_024
    )
    close(manifestDescriptor.descriptor)
    let resolvedSnapshot = try readRegularFileBeneath(
        root: root,
        components: ["Package.resolved"],
        role: "Swift package lock file",
        maximumBytes: 16 * 1_024 * 1_024
    )
    let resolvedPackages = try decodePackages(
        try readJSON(resolvedSnapshot, from: resolvedURL),
        path: resolvedURL
    )
    var packageDeclarations = try swiftPackageDeclarations(root: root, manifest: manifestURL)
    if FileManager.default.fileExists(atPath: projectURL.path) {
        let projectDescriptor = try openRegularFileBeneath(
            root: root,
            components: ["project.yml"],
            role: "XcodeGen project file",
            maximumBytes: 16 * 1_024 * 1_024
        )
        close(projectDescriptor.descriptor)
        guard let xcodegen = xcodegenExecutable(root: root) else {
            throw CheckFailure(
                description: "\(projectURL.path): pinned XcodeGen is missing; run scripts/bootstrap"
            )
        }
        packageDeclarations += try projectPackageDeclarations(
            root: root,
            project: projectURL,
            executable: xcodegen
        )
    }
    var failures: [String] = []
    var names: Set<String> = []
    var swiftPMNames: Set<String> = []
    let allowedKinds: Set<String> = [
        "source", "prebuilt", "vendored", "swiftpm", "gradle", "cargo",
    ]
    let allowedShips: Set<String> = ["app", "image", "tooling", "derived", "reference"]
    let lowerHex40 = try NSRegularExpression(pattern: "^[0-9a-f]{40}\\z")
    let hex64 = try NSRegularExpression(pattern: "^[0-9a-fA-F]{64}\\z")

    func matches(_ expression: NSRegularExpression, _ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: range) != nil
    }

    for (index, component) in components.enumerated() {
        let label = string(component["name"]) ?? "components[\(index)]"
        let requiredFields = ["name", "group", "kind", "version", "license"]
        for field in requiredFields where string(component[field])?.isEmpty != false {
            failures.append("\(lockURL.path): \(label) is missing required field '\(field)'")
        }

        guard let name = string(component["name"]), !name.isEmpty else { continue }
        if !names.insert(identityKey(name)).inserted {
            failures.append("\(lockURL.path): duplicate component name '\(name)'")
        }
        if name.range(
            of: #"^[a-z0-9][a-z0-9._-]*$"#,
            options: .regularExpression
        ) == nil {
            failures.append("\(lockURL.path): component name '\(name)' is not a safe directory name")
        }

        guard let kind = string(component["kind"]), allowedKinds.contains(kind) else {
            failures.append("\(lockURL.path): \(label) has an unsupported kind")
            continue
        }

        let ships: [String]
        if let singleShip = string(component["ships"]) {
            ships = [singleShip]
        } else if let multipleShips = arrayOfStrings(component["ships"]) {
            ships = multipleShips
        } else {
            ships = []
            failures.append("\(lockURL.path): \(label) is missing a valid 'ships' field")
        }
        if ships.isEmpty || ships.contains(where: { !allowedShips.contains($0) }) {
            failures.append("\(lockURL.path): \(label) has an unsupported 'ships' value")
        }
        if ships.contains("reference") && (kind != "source" || ships != ["reference"]) {
            failures.append(
                "\(lockURL.path): \(label) requires reference to be the sole ships value for a source component"
            )
        }

        let licenseFiles = arrayOfStrings(component["licenseFiles"]) ?? []
        if component["licenseFiles"] == nil || arrayOfStrings(component["licenseFiles"]) == nil {
            failures.append("\(lockURL.path): \(label) requires a 'licenseFiles' string array")
        } else if licenseFiles.isEmpty {
            failures.append("\(lockURL.path): \(label) is missing 'licenseFiles'")
        }
        for licenseFile in licenseFiles {
            guard safeRelativePath(licenseFile) else {
                failures.append("\(lockURL.path): \(label) has unsafe license path '\(licenseFile)'")
                continue
            }
            let licenseURL = root.appending(path: "ThirdParty/licenses/\(name)/\(licenseFile)")
            if !FileManager.default.fileExists(atPath: licenseURL.path) {
                failures.append("\(lockURL.path): \(label) license file is missing: \(licenseURL.path)")
            } else if !isSafeFile(
                licenseURL,
                under: root.appending(path: "ThirdParty/licenses/\(name)"),
                within: root
            ) {
                failures.append(
                    "\(lockURL.path): \(label) license path is not a regular file within its allowed directory: \(licenseURL.path)"
                )
            }
        }

        let buildFlags = arrayOfStrings(component["buildFlags"]) ?? []
        if component["buildFlags"] == nil || arrayOfStrings(component["buildFlags"]) == nil {
            failures.append("\(lockURL.path): \(label) requires a 'buildFlags' string array")
        }
        let patches = arrayOfStrings(component["patches"]) ?? []
        if component["patches"] == nil || arrayOfStrings(component["patches"]) == nil {
            failures.append("\(lockURL.path): \(label) requires a 'patches' string array")
        }
        if ships == ["reference"] && (!buildFlags.isEmpty || !patches.isEmpty) {
            failures.append(
                "\(lockURL.path): \(label) reference entries must not declare build flags or patches"
            )
        }
        if kind != "source" && !patches.isEmpty {
            failures.append(
                "\(lockURL.path): \(label) may declare patches only for source components"
            )
        }
        for patch in patches {
            guard safeRelativePath(patch), patch.hasPrefix("\(name)/") else {
                failures.append("\(lockURL.path): \(label) has invalid patch path '\(patch)'")
                continue
            }
            let patchURL = root.appending(path: "ThirdParty/patches/\(patch)")
            if !FileManager.default.fileExists(atPath: patchURL.path) {
                failures.append("\(lockURL.path): \(label) patch is missing: \(patchURL.path)")
            } else if !isSafeFile(
                patchURL,
                under: root.appending(path: "ThirdParty/patches/\(name)"),
                within: root
            ) {
                failures.append(
                    "\(lockURL.path): \(label) patch is not a regular file within its allowed directory: \(patchURL.path)"
                )
            }
        }

        let repository = string(component["repository"])
        let commit = string(component["commit"])
        if ["source", "vendored", "swiftpm"].contains(kind),
            repository.flatMap(normalizedRepositoryURL) == nil
        {
            failures.append("\(lockURL.path): \(label) requires a valid HTTPS repository URL")
        }
        if let commit, !matches(lowerHex40, commit) {
            failures.append("\(lockURL.path): \(label) commit must be 40 lowercase hexadecimal characters")
        }
        if ["source", "vendored", "swiftpm"].contains(kind),
            commit == nil
        {
            failures.append("\(lockURL.path): \(label) is missing its full commit")
        }
        if let hash = string(component["sha256"]), !matches(hex64, hash) {
            failures.append("\(lockURL.path): \(label) sha256 must be 64 hexadecimal characters")
        }
        if kind == "prebuilt" {
            if string(component["url"]).flatMap(normalizedRepositoryURL) == nil {
                failures.append("\(lockURL.path): \(label) requires a valid HTTPS download URL")
            }
            if string(component["sha256"]) == nil {
                failures.append("\(lockURL.path): \(label) is missing its sha256")
            }
        }
        if kind == "vendored" {
            guard let vendoredFiles = component["files"] as? [[String: Any]],
                !vendoredFiles.isEmpty
            else {
                failures.append("\(lockURL.path): \(label) requires a non-empty 'files' array")
                continue
            }
            var vendoredPaths: Set<String> = []
            for file in vendoredFiles {
                guard let relativePath = string(file["path"]),
                    let expectedHash = string(file["sha256"])
                else {
                    failures.append("\(lockURL.path): \(label) has a malformed vendored file entry")
                    continue
                }
                guard safeRelativePath(relativePath) else {
                    failures.append(
                        "\(lockURL.path): \(label) has unsafe vendored file path '\(relativePath)'"
                    )
                    continue
                }
                if !matches(hex64, expectedHash) {
                    failures.append(
                        "\(lockURL.path): \(label) has an invalid SHA-256 for '\(relativePath)'"
                    )
                    continue
                }
                if !vendoredPaths.insert(relativePath).inserted {
                    failures.append(
                        "\(lockURL.path): \(label) lists vendored file '\(relativePath)' more than once"
                    )
                    continue
                }

                let fileURL = root.appending(path: relativePath)
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    failures.append(
                        "\(lockURL.path): \(label) vendored file is missing: \(relativePath)"
                    )
                    continue
                }
                guard !hasSymlinkComponent(fileURL, within: root),
                    isDescendant(fileURL, of: root),
                    let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                    attributes[.type] as? FileAttributeType == .typeRegular
                else {
                    failures.append(
                        "\(lockURL.path): \(label) vendored path is not a regular file within the repository: \(relativePath)"
                    )
                    continue
                }
                guard let data = try? Data(contentsOf: fileURL) else {
                    failures.append(
                        "\(lockURL.path): \(label) vendored file cannot be read: \(relativePath)"
                    )
                    continue
                }
                let actualHash = SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }
                    .joined()
                if actualHash != expectedHash.lowercased() {
                    failures.append(
                        "\(lockURL.path): \(label) vendored file SHA-256 mismatch: \(relativePath)"
                    )
                }
            }
        }

        guard kind == "swiftpm" else { continue }
        swiftPMNames.insert(identityKey(name))
        guard let repository else { continue }
        let resolved = resolvedPackages.first {
            identityKey($0.identity) == identityKey(name)
        }
        guard let resolved else {
            failures.append("\(resolvedURL.path): Swift package '\(name)' is not pinned")
            continue
        }
        if resolved.revision != commit {
            failures.append(
                "\(resolvedURL.path): \(name) revision \(resolved.revision) does not match lock commit \(commit ?? "<missing>")"
            )
        }
        if normalizedRepositoryURL(resolved.location) != normalizedRepositoryURL(repository) {
            failures.append(
                "\(resolvedURL.path): \(name) repository \(resolved.location) does not match lock repository \(repository)"
            )
        }
        if resolved.version != string(component["version"]) {
            failures.append(
                "\(resolvedURL.path): \(name) version \(resolved.version) does not match lock version \(string(component["version"]) ?? "<missing>")"
            )
        }
    }

    let swiftPMComponents = components.filter { string($0["kind"]) == "swiftpm" }
    for declaration in packageDeclarations {
        let component = swiftPMComponents.first {
            normalizedRepositoryURL(string($0["repository"]) ?? "")
                == normalizedRepositoryURL(declaration.repository)
                && normalizedRepositoryURL(declaration.repository) != nil
        }
        guard let component else {
            failures.append(
                "\(declaration.source.path): Swift package '\(declaration.repository)' has no ThirdParty lock entry"
            )
            continue
        }
        let name = string(component["name"]) ?? declaration.repository
        guard let exactVersion = declaration.exactVersion else {
            failures.append(
                "\(declaration.source.path): \(name) must use an exact version requirement"
            )
            continue
        }
        if exactVersion != string(component["version"]) {
            failures.append(
                "\(declaration.source.path): \(name) exact version \(exactVersion) does not match lock version \(string(component["version"]) ?? "<missing>")"
            )
        }
    }

    for component in swiftPMComponents {
        guard let name = string(component["name"]),
            let repository = string(component["repository"])
        else {
            continue
        }
        if !packageDeclarations.contains(where: {
            normalizedRepositoryURL($0.repository) == normalizedRepositoryURL(repository)
                && normalizedRepositoryURL($0.repository) != nil
        }) {
            failures.append(
                "\(manifestURL.path): Swift package '\(name)' must be declared in Package.swift or project.yml"
            )
        }
    }

    for package in resolvedPackages where !swiftPMNames.contains(identityKey(package.identity)) {
        failures.append(
            "\(resolvedURL.path): Swift package pin '\(package.identity)' has no ThirdParty lock entry"
        )
    }
    return failures
}

struct CommandOptions {
    let root: URL
    let applyPatches: Bool
}

func commandOptions(from arguments: [String]) throws -> CommandOptions {
    var rootPath = FileManager.default.currentDirectoryPath
    var applyPatches = false
    var index = 1
    while index < arguments.count {
        switch arguments[index] {
        case "--root":
            guard arguments.indices.contains(index + 1),
                !arguments[index + 1].isEmpty,
                !arguments[index + 1].hasPrefix("--")
            else {
                throw CheckFailure(
                    description: "usage: check-lock.swift [--root <directory>] [--apply]"
                )
            }
            rootPath = arguments[index + 1]
            index += 2
        case "--apply":
            guard !applyPatches else {
                throw CheckFailure(description: "check-lock.swift: --apply may be specified once")
            }
            applyPatches = true
            index += 1
        default:
            throw CheckFailure(
                description: "usage: check-lock.swift [--root <directory>] [--apply]"
            )
        }
    }
    return CommandOptions(
        root: URL(fileURLWithPath: rootPath).standardizedFileURL,
        applyPatches: applyPatches
    )
}

func anonymousInputFile(for data: Data) throws -> FileHandle {
    var template = Array(
        FileManager.default.temporaryDirectory.appending(path: "apkrun-patch-input.XXXXXX")
            .path.utf8CString
    )
    let descriptor = template.withUnsafeMutableBufferPointer { buffer -> Int32 in
        guard let baseAddress = buffer.baseAddress else {
            return -1
        }
        return mkstemp(baseAddress)
    }
    guard descriptor >= 0 else {
        throw CheckFailure(
            description: "couldn't create anonymous patch input: \(String(cString: strerror(errno)))"
        )
    }
    guard
        let path = template.withUnsafeBufferPointer({ buffer in
            buffer.baseAddress.map(String.init(cString:))
        })
    else {
        close(descriptor)
        throw CheckFailure(description: "couldn't resolve anonymous patch input path")
    }
    guard unlink(path) == 0 else {
        let details = String(cString: strerror(errno))
        close(descriptor)
        unlink(path)
        throw CheckFailure(description: "couldn't unlink temporary patch input: \(details)")
    }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
        try file.write(contentsOf: data)
        try file.seek(toOffset: 0)
        return file
    } catch {
        try? file.close()
        throw CheckFailure(description: "couldn't prepare anonymous patch input: \(error)")
    }
}

func runGit(
    at directory: URL,
    arguments: [String],
    root: URL,
    standardInputData: Data? = nil,
    gitContext: GitExecutionContext? = nil,
    workingDirectoryDescriptor: Int32? = nil
) throws -> String {
    let previousDirectoryDescriptor: Int32?
    if let workingDirectoryDescriptor {
        let saved = open(".", O_RDONLY | O_CLOEXEC | O_DIRECTORY)
        guard saved >= 0 else {
            throw CheckFailure(
                description: "\(root.path): couldn't save the current directory: "
                    + String(cString: strerror(errno))
            )
        }
        guard fchdir(workingDirectoryDescriptor) == 0 else {
            let details = String(cString: strerror(errno))
            close(saved)
            throw CheckFailure(
                description: "\(root.path): couldn't enter the pinned working directory: \(details)"
            )
        }
        previousDirectoryDescriptor = saved
    } else {
        previousDirectoryDescriptor = nil
    }
    defer {
        if let previousDirectoryDescriptor {
            _ = fchdir(previousDirectoryDescriptor)
            close(previousDirectoryDescriptor)
        }
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments =
        [
            "-c", "core.fsmonitor=false",
            "-c", "core.hooksPath=/dev/null",
            "-c", "core.pager=cat",
            "-c", "diff.external=",
            "-c", "interactive.diffFilter=",
            "-c", "credential.helper=",
            "-c", "am.threeWay=false",
        ]
        + (workingDirectoryDescriptor == nil ? ["-C", directory.path] : [])
        + arguments
    process.currentDirectoryURL =
        workingDirectoryDescriptor == nil ? directory : nil
    var environment = childProcessEnvironment()
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_ATTR_NOSYSTEM"] = "1"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    if let gitContext {
        environment["GIT_DIR"] = gitContext.gitDirectory
        environment["GIT_WORK_TREE"] = gitContext.workingTree
    }
    process.environment = environment
    let inputFile: FileHandle?
    if let standardInputData {
        inputFile = try anonymousInputFile(for: standardInputData)
    } else {
        inputFile = nil
    }
    if let inputFile {
        process.standardInput = inputFile
    }
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    do {
        try process.run()
    } catch {
        throw CheckFailure(description: "\(root.path): couldn't run git: \(error)")
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let details = String(decoding: data, as: UTF8.self).trimmingCharacters(
        in: .whitespacesAndNewlines
    )
    guard process.terminationStatus == 0 else {
        throw CheckFailure(
            description: "\(root.path): git \(arguments.joined(separator: " ")) failed "
                + "(\(process.terminationStatus)): \(details)"
        )
    }
    return details
}

func gitOperationStates(
    at source: URL,
    root: URL,
    gitContext: GitExecutionContext? = nil,
    workingDirectoryDescriptor: Int32? = nil
) throws -> [String] {
    let stateNames = [
        "rebase-apply", "rebase-merge", "sequencer", "BISECT_LOG", "BISECT_START",
        "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD",
    ]
    var activeStates: [String] = []
    if let workingDirectoryDescriptor {
        let gitDirectoryDescriptor = openat(
            workingDirectoryDescriptor,
            ".git",
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard gitDirectoryDescriptor >= 0 else {
            throw CheckFailure(
                description: "\(source.path): couldn't safely open Git metadata: "
                    + String(cString: strerror(errno))
            )
        }
        defer {
            close(gitDirectoryDescriptor)
        }
        for stateName in stateNames {
            var metadata = stat()
            if fstatat(
                gitDirectoryDescriptor,
                stateName,
                &metadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0 {
                activeStates.append(stateName)
            } else if errno != ENOENT {
                throw CheckFailure(
                    description: "\(source.path): couldn't inspect Git operation state "
                        + "\(stateName): \(String(cString: strerror(errno)))"
                )
            }
        }
        return activeStates
    }
    for stateName in stateNames {
        let path = try runGit(
            at: source,
            arguments: ["rev-parse", "--git-path", stateName],
            root: root,
            gitContext: gitContext
        )
        let stateURL =
            path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : source.appending(path: path)
        if FileManager.default.fileExists(atPath: stateURL.path) {
            activeStates.append(stateName)
        }
    }
    return activeStates
}

func sourceWorkingTreeStatus(
    at source: URL,
    root: URL,
    gitContext: GitExecutionContext? = nil,
    workingDirectoryDescriptor: Int32? = nil
) throws -> String {
    let indexEntries = try runGit(
        at: source,
        arguments: ["ls-files", "-v", "-z"],
        root: root,
        gitContext: gitContext,
        workingDirectoryDescriptor: workingDirectoryDescriptor
    )
    let nonNormalIndexEntries = indexEntries.split(separator: "\0").filter {
        $0.first != "H"
    }
    guard nonNormalIndexEntries.isEmpty else {
        throw CheckFailure(
            description: "\(source.path): source index has assume-unchanged, skip-worktree, "
                + "or other non-normal flags; clear those flags before applying patches"
        )
    }
    return try runGit(
        at: source,
        arguments: [
            "status", "--porcelain=v1", "--untracked-files=all", "--ignored=matching",
        ],
        root: root,
        gitContext: gitContext,
        workingDirectoryDescriptor: workingDirectoryDescriptor
    )
}

func withPatchApplyLock(root: URL, operation: () throws -> Int) throws -> Int {
    let lockURL = root.appending(path: "ThirdParty/out/.check-lock-apply.lock")
    let descriptor = open(
        lockURL.path,
        O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
        mode_t(S_IRUSR | S_IWUSR)
    )
    guard descriptor >= 0 else {
        throw CheckFailure(
            description: "\(lockURL.path): couldn't open patch-application lock: "
                + String(cString: strerror(errno))
        )
    }
    var lockMetadata = stat()
    guard fstat(descriptor, &lockMetadata) == 0 else {
        let details = String(cString: strerror(errno))
        close(descriptor)
        throw CheckFailure(
            description: "\(lockURL.path): couldn't inspect patch-application lock: \(details)"
        )
    }
    guard (lockMetadata.st_mode & S_IFMT) == S_IFREG else {
        close(descriptor)
        throw CheckFailure(
            description: "\(lockURL.path): patch-application lock is not a regular file"
        )
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        let errorCode = errno
        close(descriptor)
        if errorCode == EWOULDBLOCK || errorCode == EAGAIN {
            throw CheckFailure(
                description: "\(root.path): another check-lock --apply operation is already running"
            )
        }
        throw CheckFailure(
            description: "\(lockURL.path): couldn't acquire patch-application lock: "
                + String(cString: strerror(errorCode))
        )
    }
    defer {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
    return try operation()
}

struct PatchPlan {
    let name: String
    let commit: String
    let patchSetDigest: String
    let source: URL
    let sourceGitDirectory: URL
    let patches: [PatchInput]
}

struct PatchInput {
    let path: URL
    let bytes: Data
}

func pinnedPatchPlans(root: URL, lockSnapshot: Data) throws -> [PatchPlan] {
    let lockURL = root.appending(path: "ThirdParty/ThirdParty.lock.json")
    guard let lock = try readJSON(lockSnapshot, from: lockURL) as? [String: Any],
        let components = lock["components"] as? [[String: Any]]
    else {
        throw CheckFailure(description: "\(lockURL.path): invalid component list")
    }

    var plans: [PatchPlan] = []
    for component in components {
        let ships: [String]
        if let singleShip = string(component["ships"]) {
            ships = [singleShip]
        } else {
            ships = arrayOfStrings(component["ships"]) ?? []
        }
        guard string(component["kind"]) == "source",
            !ships.contains("reference"),
            let name = string(component["name"]),
            let commit = string(component["commit"]),
            let patchPaths = arrayOfStrings(component["patches"]),
            !patchPaths.isEmpty
        else {
            continue
        }

        let sourceURL = root.appending(path: "ThirdParty/out/src/\(name)/\(commit)")
        guard !hasSymlinkComponent(sourceURL, within: root) else {
            throw CheckFailure(
                description: "\(sourceURL.path): source checkout path contains a symlink"
            )
        }
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: sourceURL.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue
        else {
            throw CheckFailure(
                description: "\(sourceURL.path): pinned source checkout is missing; "
                    + "prepare a clean checkout at \(commit) before applying patches"
            )
        }

        let metadataPaths = try inspectGitMetadata(at: sourceURL)
        let gitContext = GitExecutionContext(
            gitDirectory: metadataPaths.gitDirectory.path,
            workingTree: sourceURL.path
        )
        guard metadataPaths.detachedHead == commit else {
            throw CheckFailure(
                description: "\(sourceURL.path): expected pinned commit \(commit), found \(metadataPaths.detachedHead)"
            )
        }
        let topLevel = try runGit(
            at: sourceURL,
            arguments: ["rev-parse", "--show-toplevel"],
            root: root,
            gitContext: gitContext
        )
        guard
            URL(fileURLWithPath: topLevel).standardizedFileURL
                .resolvingSymlinksInPath().path
                == sourceURL.resolvingSymlinksInPath().path
        else {
            throw CheckFailure(
                description: "\(sourceURL.path): source path is not the Git checkout root"
            )
        }
        let gitDirectory = URL(
            fileURLWithPath: try runGit(
                at: sourceURL,
                arguments: ["rev-parse", "--absolute-git-dir"],
                root: root,
                gitContext: gitContext
            )
        ).resolvingSymlinksInPath().standardizedFileURL
        guard gitDirectory.path == metadataPaths.gitDirectory.path else {
            throw CheckFailure(
                description: "\(sourceURL.path): Git metadata path changed during validation"
            )
        }
        let commonDirectoryPath = try runGit(
            at: sourceURL,
            arguments: ["rev-parse", "--path-format=absolute", "--git-common-dir"],
            root: root,
            gitContext: gitContext
        )
        let commonDirectory = URL(fileURLWithPath: commonDirectoryPath)
            .resolvingSymlinksInPath().standardizedFileURL
        guard commonDirectory.path == metadataPaths.commonDirectory.path else {
            throw CheckFailure(
                description: "\(sourceURL.path): shared Git metadata path changed during validation"
            )
        }
        let gitConfigKeys = try runGit(
            at: sourceURL,
            arguments: ["config", "--null", "--name-only", "--list"],
            root: root,
            gitContext: gitContext
        )
        let customCommandKeys = gitConfigKeys.split(separator: "\0").filter {
            $0.hasPrefix("filter.")
                || ($0.hasPrefix("merge.") && $0.hasSuffix(".driver"))
        }
        guard customCommandKeys.isEmpty else {
            throw CheckFailure(
                description: "\(sourceURL.path): custom Git filters or merge drivers are configured; "
                    + "remove them before applying patches"
            )
        }

        let head = try runGit(
            at: sourceURL,
            arguments: ["rev-parse", "--verify", "HEAD^{commit}"],
            root: root,
            gitContext: gitContext
        )
        guard head == commit else {
            throw CheckFailure(
                description: "\(sourceURL.path): expected pinned commit \(commit), found \(head)"
            )
        }
        let activeStates = try gitOperationStates(
            at: sourceURL,
            root: root,
            gitContext: gitContext
        )
        guard activeStates.isEmpty else {
            throw CheckFailure(
                description: "\(sourceURL.path): Git operation is already in progress "
                    + "(\(activeStates.joined(separator: ", "))); finish or abort it before applying patches"
            )
        }
        let status = try sourceWorkingTreeStatus(
            at: sourceURL,
            root: root,
            gitContext: gitContext
        )
        guard status.isEmpty else {
            throw CheckFailure(
                description: "\(sourceURL.path): source checkout is not clean, including ignored files; "
                    + "restore a clean pinned checkout before applying patches"
            )
        }

        let patchInputs = try patchPaths.map { patchPath in
            guard safeRelativePath(patchPath), patchPath.hasPrefix("\(name)/") else {
                throw CheckFailure(
                    description: "\(lockURL.path): \(name) has unsafe patch path '\(patchPath)'"
                )
            }
            let patchURL = root.appending(path: "ThirdParty/patches/\(patchPath)")
            let pathComponents =
                ["ThirdParty", "patches"]
                + patchPath.split(separator: "/").map(String.init)
            let bytes = try readRegularFileBeneath(
                root: root,
                components: pathComponents,
                role: "patch",
                maximumBytes: 64 * 1_024 * 1_024
            )
            return PatchInput(path: patchURL, bytes: bytes)
        }
        plans.append(
            PatchPlan(
                name: name,
                commit: commit,
                patchSetDigest: patchSetDigest(patchInputs),
                source: sourceURL,
                sourceGitDirectory: metadataPaths.gitDirectory,
                patches: patchInputs
            )
        )
    }
    return plans
}

func patchSetDigest(_ patches: [PatchInput]) -> String {
    var hasher = SHA256()
    for patch in patches {
        var byteCount = UInt64(patch.bytes.count).bigEndian
        hasher.update(data: withUnsafeBytes(of: &byteCount) { Data($0) })
        hasher.update(data: patch.bytes)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func applyPinnedPatches(root: URL, lockSnapshot: Data) throws -> Int {
    let initialPlans = try pinnedPatchPlans(root: root, lockSnapshot: lockSnapshot)
    guard !initialPlans.isEmpty else {
        return 0
    }
    return try withPatchApplyLock(root: root) {
        let plans = try pinnedPatchPlans(root: root, lockSnapshot: lockSnapshot)
        let preparedPlans: [PreparedPatchPlan]
        do {
            preparedPlans = try preflightPatchPlans(plans, root: root)
        } catch {
            throw CheckFailure(
                description: "\(error); source checkouts were not changed"
            )
        }
        return try applyPatchPlans(preparedPlans, root: root)
    }
}

struct PreparedPatchPlan {
    let plan: PatchPlan
    let patchCommitHeads: [String]
}

func preflightPatchPlans(_ plans: [PatchPlan], root: URL) throws -> [PreparedPatchPlan] {
    var preparedPlans: [PreparedPatchPlan] = []
    let temporaryDirectory = FileManager.default.temporaryDirectory

    for plan in plans {
        let scratch = temporaryDirectory.appending(
            path: "apkrun-patch-preflight-\(UUID().uuidString)"
        )
        defer {
            try? FileManager.default.removeItem(at: scratch)
        }
        _ = try runGit(
            at: temporaryDirectory,
            arguments: [
                "clone", "--shared", "--no-checkout", plan.sourceGitDirectory.path, scratch.path,
            ],
            root: root
        )
        _ = try runGit(
            at: scratch,
            arguments: ["checkout", "--detach", plan.commit],
            root: root
        )

        var expectedParent = plan.commit
        var patchCommitHeads: [String] = []
        for patch in plan.patches {
            _ = try runGit(
                at: scratch,
                arguments: [
                    "-c", "user.name=APKRun Patch Application",
                    "-c", "user.email=build@localhost",
                    "-c", "user.useConfigOnly=true",
                    "-c", "commit.gpgsign=false",
                    "am", "--committer-date-is-author-date",
                ],
                root: root,
                standardInputData: patch.bytes
            )

            let head = try runGit(
                at: scratch,
                arguments: ["rev-parse", "--verify", "HEAD^{commit}"],
                root: root
            )
            let parent = try runGit(
                at: scratch,
                arguments: ["rev-parse", "--verify", "HEAD^"],
                root: root
            )
            guard parent == expectedParent else {
                throw CheckFailure(
                    description: "\(patch.path): applied commit does not extend the expected pinned history"
                )
            }
            let states = try gitOperationStates(at: scratch, root: root)
            let status = try sourceWorkingTreeStatus(at: scratch, root: root)
            guard states.isEmpty, status.isEmpty else {
                throw CheckFailure(
                    description: "\(scratch.path): patch preflight left an unfinished Git operation or dirty checkout"
                )
            }
            patchCommitHeads.append(head)
            expectedParent = head
        }
        preparedPlans.append(
            PreparedPatchPlan(
                plan: plan,
                patchCommitHeads: patchCommitHeads
            )
        )
    }
    return preparedPlans
}

func verifyPatchedCheckout(
    at checkout: URL,
    expectedHead: String,
    root: URL,
    workingDirectoryDescriptor: Int32
) throws {
    var checkoutMetadata = stat()
    guard fstat(workingDirectoryDescriptor, &checkoutMetadata) == 0,
        (checkoutMetadata.st_mode & S_IFMT) == S_IFDIR
    else {
        throw CheckFailure(description: "\(checkout.path): patched checkout is not a directory")
    }
    let gitDirectoryDescriptor = openat(
        workingDirectoryDescriptor,
        ".git",
        O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
    )
    guard gitDirectoryDescriptor >= 0 else {
        throw CheckFailure(
            description: "\(checkout.path): couldn't safely open patched Git metadata: "
                + String(cString: strerror(errno))
        )
    }
    defer {
        close(gitDirectoryDescriptor)
    }
    let headData = try readRegularFileAt(
        directoryDescriptor: gitDirectoryDescriptor,
        name: "HEAD",
        role: "patched Git HEAD",
        maximumBytes: 1_024
    )
    guard let headContents = String(data: headData, encoding: .utf8),
        headContents.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil
    else {
        throw CheckFailure(
            description: "\(checkout.path): patched checkout must have a detached full-commit HEAD"
        )
    }
    let gitContext = GitExecutionContext(
        gitDirectory: ".git",
        workingTree: "."
    )
    let configKeys = try runGit(
        at: checkout,
        arguments: ["config", "--null", "--name-only", "--list"],
        root: root,
        gitContext: gitContext,
        workingDirectoryDescriptor: workingDirectoryDescriptor
    )
    let customCommandKeys = configKeys.split(separator: "\0").filter {
        $0.hasPrefix("filter.")
            || ($0.hasPrefix("merge.") && $0.hasSuffix(".driver"))
    }
    guard customCommandKeys.isEmpty else {
        throw CheckFailure(
            description: "\(checkout.path): custom Git filters or merge drivers are configured"
        )
    }
    let head = try runGit(
        at: checkout,
        arguments: ["rev-parse", "--verify", "HEAD^{commit}"],
        root: root,
        gitContext: gitContext,
        workingDirectoryDescriptor: workingDirectoryDescriptor
    )
    guard head == expectedHead else {
        throw CheckFailure(
            description: "\(checkout.path): expected patched commit \(expectedHead), found \(head)"
        )
    }
    let activeStates = try gitOperationStates(
        at: checkout,
        root: root,
        gitContext: gitContext,
        workingDirectoryDescriptor: workingDirectoryDescriptor
    )
    guard activeStates.isEmpty else {
        throw CheckFailure(
            description: "\(checkout.path): patched checkout has unfinished Git state "
                + "(\(activeStates.joined(separator: ", ")))"
        )
    }
    let status = try sourceWorkingTreeStatus(
        at: checkout,
        root: root,
        gitContext: gitContext,
        workingDirectoryDescriptor: workingDirectoryDescriptor
    )
    guard status.isEmpty else {
        throw CheckFailure(description: "\(checkout.path): patched checkout is not clean")
    }
}

func rollbackPublishedCheckout(
    outputParentDescriptor: Int32,
    outputName: String,
    expectedIdentity: FileIdentity,
    rootDescriptor: Int32,
    stagingName: String
) -> Bool {
    var outputMetadata = stat()
    guard
        fstatat(
            outputParentDescriptor,
            outputName,
            &outputMetadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
        (outputMetadata.st_mode & S_IFMT) == S_IFDIR,
        outputMetadata.st_dev == expectedIdentity.device,
        outputMetadata.st_ino == expectedIdentity.inode
    else {
        return false
    }
    return renameatx_np(
        outputParentDescriptor,
        outputName,
        rootDescriptor,
        stagingName,
        UInt32(RENAME_EXCL)
    ) == 0
}

func verifyPublishedCheckoutLocation(
    root: URL,
    outputParentComponents: [String],
    expectedParentIdentities: [FileIdentity],
    outputParentDescriptor: Int32,
    outputParent: URL,
    outputName: String,
    outputPath: URL,
    stagingPath: URL,
    stagingName: String,
    stagingIdentity: FileIdentity,
    rootDescriptor: Int32
) -> (message: String, rolledBack: Bool)? {
    var outputMetadata = stat()
    let outputInspection = fstatat(
        outputParentDescriptor,
        outputName,
        &outputMetadata,
        AT_SYMLINK_NOFOLLOW
    )
    let outputInspectionDetails =
        outputInspection == 0
        ? "the directory entry does not identify the staged checkout"
        : String(cString: strerror(errno))
    guard outputInspection == 0,
        (outputMetadata.st_mode & S_IFMT) == S_IFDIR,
        outputMetadata.st_dev == stagingIdentity.device,
        outputMetadata.st_ino == stagingIdentity.inode
    else {
        let rolledBack = rollbackPublishedCheckout(
            outputParentDescriptor: outputParentDescriptor,
            outputName: outputName,
            expectedIdentity: stagingIdentity,
            rootDescriptor: rootDescriptor,
            stagingName: stagingName
        )
        let recovery =
            rolledBack
            ? "the checkout was returned to staging at \(stagingPath.path)"
            : "rollback could not confirm the checkout; last-known paths are "
                + "\(outputPath.path) and \(stagingPath.path)"
        return (
            "\(outputPath.path): published entry could not be verified "
                + "(\(outputInspectionDetails)); \(recovery)",
            rolledBack
        )
    }

    do {
        let (publishedParentDescriptor, publishedParentIdentities) = try openDirectoryChain(
            root: root,
            components: outputParentComponents,
            role: "patched-source output"
        )
        close(publishedParentDescriptor)
        guard publishedParentIdentities == expectedParentIdentities else {
            let rolledBack = rollbackPublishedCheckout(
                outputParentDescriptor: outputParentDescriptor,
                outputName: outputName,
                expectedIdentity: stagingIdentity,
                rootDescriptor: rootDescriptor,
                stagingName: stagingName
            )
            let recovery =
                rolledBack
                ? "the checkout was returned to staging at \(stagingPath.path)"
                : "rollback failed; last-known paths are \(outputPath.path) and \(stagingPath.path)"
            return (
                "\(outputParent.path): output directory moved during publication; \(recovery)",
                rolledBack
            )
        }
    } catch {
        let rolledBack = rollbackPublishedCheckout(
            outputParentDescriptor: outputParentDescriptor,
            outputName: outputName,
            expectedIdentity: stagingIdentity,
            rootDescriptor: rootDescriptor,
            stagingName: stagingName
        )
        let recovery =
            rolledBack
            ? "the checkout was returned to staging at \(stagingPath.path)"
            : "rollback failed; last-known paths are \(outputPath.path) and \(stagingPath.path)"
        return (
            "\(outputParent.path): output directory could not be reopened after publication: "
                + "\(error); \(recovery)",
            rolledBack
        )
    }
    return nil
}

func applyPatchPlans(_ preparedPlans: [PreparedPatchPlan], root: URL) throws -> Int {
    var stagingPaths: [URL] = []
    var publishedPaths: [URL] = []
    let (rootDescriptor, _) = try openDirectoryChain(
        root: root,
        components: [],
        role: "project root"
    )
    defer {
        close(rootDescriptor)
    }
    do {
        for prepared in preparedPlans {
            let plan = prepared.plan
            let componentOutput = root.appending(
                path: "ThirdParty/out/patched-src/\(plan.name)/\(plan.commit)"
            )
            guard let outputParentComponents = pathComponents(componentOutput, beneath: root) else {
                throw CheckFailure(
                    description: "\(componentOutput.path): patched-source output is outside the project"
                )
            }
            let openedOutputParent = try openOrCreateDirectoryBeneath(
                root: root,
                components: outputParentComponents,
                role: "patched-source output"
            )
            let outputParentDescriptor = openedOutputParent.descriptor
            defer {
                close(outputParentDescriptor)
            }
            let outputParent = componentOutput
            let output = outputParent.appending(path: plan.patchSetDigest)
            var outputMetadata = stat()
            if fstatat(
                outputParentDescriptor,
                plan.patchSetDigest,
                &outputMetadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0 {
                guard (outputMetadata.st_mode & S_IFMT) == S_IFDIR else {
                    throw CheckFailure(
                        description: "\(output.path): existing patched-source output is not a directory"
                    )
                }
                let existingOutputDescriptor = openat(
                    outputParentDescriptor,
                    plan.patchSetDigest,
                    O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
                )
                guard existingOutputDescriptor >= 0 else {
                    throw CheckFailure(
                        description: "\(output.path): couldn't safely open existing patched checkout: "
                            + String(cString: strerror(errno))
                    )
                }
                defer {
                    close(existingOutputDescriptor)
                }
                let expectedHead = prepared.patchCommitHeads.last ?? plan.commit
                try verifyPatchedCheckout(
                    at: output,
                    expectedHead: expectedHead,
                    root: root,
                    workingDirectoryDescriptor: existingOutputDescriptor
                )
                continue
            } else if errno != ENOENT {
                throw CheckFailure(
                    description: "\(output.path): couldn't inspect patched-source output: "
                        + String(cString: strerror(errno))
                )
            }

            let stagingName = ".apkrun-patch-staging-\(UUID().uuidString)"
            let staging = root.appending(path: stagingName)
            guard mkdirat(rootDescriptor, stagingName, mode_t(S_IRWXU)) == 0 else {
                throw CheckFailure(
                    description: "\(staging.path): couldn't create staging checkout: "
                        + String(cString: strerror(errno))
                )
            }
            stagingPaths.append(staging)
            let stagingDescriptor = openat(
                rootDescriptor,
                stagingName,
                O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
            )
            guard stagingDescriptor >= 0 else {
                throw CheckFailure(
                    description: "\(staging.path): couldn't safely open staging directory: "
                        + String(cString: strerror(errno))
                )
            }
            defer {
                close(stagingDescriptor)
            }
            var stagingMetadata = stat()
            guard fstat(stagingDescriptor, &stagingMetadata) == 0 else {
                throw CheckFailure(
                    description: "\(staging.path): couldn't inspect staging directory: "
                        + String(cString: strerror(errno))
                )
            }
            let stagingIdentity = FileIdentity(
                device: stagingMetadata.st_dev,
                inode: stagingMetadata.st_ino
            )
            _ = try runGit(
                at: staging,
                arguments: [
                    "clone", "--shared", "--no-checkout", plan.sourceGitDirectory.path, ".",
                ],
                root: root,
                workingDirectoryDescriptor: stagingDescriptor
            )
            let stagingGitContext = GitExecutionContext(
                gitDirectory: ".git",
                workingTree: "."
            )
            _ = try runGit(
                at: staging,
                arguments: ["checkout", "--detach", plan.commit],
                root: root,
                gitContext: stagingGitContext,
                workingDirectoryDescriptor: stagingDescriptor
            )

            let stagingConfig = try runGit(
                at: staging,
                arguments: ["config", "--null", "--name-only", "--list"],
                root: root,
                gitContext: stagingGitContext,
                workingDirectoryDescriptor: stagingDescriptor
            )
            let unsafeConfig = stagingConfig.split(separator: "\0").filter {
                $0.hasPrefix("filter.")
                    || ($0.hasPrefix("merge.") && $0.hasSuffix(".driver"))
            }
            guard unsafeConfig.isEmpty else {
                throw CheckFailure(
                    description: "\(staging.path): cloned checkout has custom Git filters or merge drivers"
                )
            }

            for (index, patch) in plan.patches.enumerated() {
                let activeStates = try gitOperationStates(
                    at: staging,
                    root: root,
                    gitContext: stagingGitContext,
                    workingDirectoryDescriptor: stagingDescriptor
                )
                guard activeStates.isEmpty else {
                    throw CheckFailure(
                        description: "\(staging.path): Git operation began before patch application "
                            + "(\(activeStates.joined(separator: ", ")))"
                    )
                }
                let expectedParent =
                    index == 0 ? plan.commit : prepared.patchCommitHeads[index - 1]
                let currentHead = try runGit(
                    at: staging,
                    arguments: ["rev-parse", "--verify", "HEAD^{commit}"],
                    root: root,
                    gitContext: stagingGitContext,
                    workingDirectoryDescriptor: stagingDescriptor
                )
                guard currentHead == expectedParent else {
                    throw CheckFailure(
                        description: "\(staging.path): checkout changed before patch application; "
                            + "expected \(expectedParent), found \(currentHead)"
                    )
                }
                _ = try runGit(
                    at: staging,
                    arguments: [
                        "-c", "user.name=APKRun Patch Application",
                        "-c", "user.email=build@localhost",
                        "-c", "user.useConfigOnly=true",
                        "-c", "commit.gpgsign=false",
                        "am", "--committer-date-is-author-date",
                    ],
                    root: root,
                    standardInputData: patch.bytes,
                    gitContext: stagingGitContext,
                    workingDirectoryDescriptor: stagingDescriptor
                )
                let head = try runGit(
                    at: staging,
                    arguments: ["rev-parse", "--verify", "HEAD^{commit}"],
                    root: root,
                    gitContext: stagingGitContext,
                    workingDirectoryDescriptor: stagingDescriptor
                )
                let parent = try runGit(
                    at: staging,
                    arguments: ["rev-parse", "--verify", "HEAD^"],
                    root: root,
                    gitContext: stagingGitContext,
                    workingDirectoryDescriptor: stagingDescriptor
                )
                guard parent == expectedParent,
                    head == prepared.patchCommitHeads[index]
                else {
                    throw CheckFailure(
                        description: "\(plan.source.path): applied commit does not extend the "
                            + "preflighted pinned history"
                    )
                }
                let status = try sourceWorkingTreeStatus(
                    at: staging,
                    root: root,
                    gitContext: stagingGitContext,
                    workingDirectoryDescriptor: stagingDescriptor
                )
                guard status.isEmpty else {
                    throw CheckFailure(
                        description: "\(staging.path): patch application left a dirty checkout"
                    )
                }
            }
            let expectedHead = prepared.patchCommitHeads.last ?? plan.commit
            try verifyPatchedCheckout(
                at: staging,
                expectedHead: expectedHead,
                root: root,
                workingDirectoryDescriptor: stagingDescriptor
            )
            var stagingEntryMetadata = stat()
            guard
                fstatat(
                    rootDescriptor,
                    stagingName,
                    &stagingEntryMetadata,
                    AT_SYMLINK_NOFOLLOW
                ) == 0,
                (stagingEntryMetadata.st_mode & S_IFMT) == S_IFDIR,
                stagingEntryMetadata.st_dev == stagingIdentity.device,
                stagingEntryMetadata.st_ino == stagingIdentity.inode
            else {
                throw CheckFailure(
                    description: "\(staging.path): staging directory name changed during patch application"
                )
            }
            let (currentParentDescriptor, currentParentIdentities) = try openDirectoryChain(
                root: root,
                components: outputParentComponents,
                role: "patched-source output"
            )
            close(currentParentDescriptor)
            guard currentParentIdentities == openedOutputParent.identities else {
                throw CheckFailure(
                    description: "\(outputParent.path): patched-source output directory changed during application"
                )
            }
            guard
                renameatx_np(
                    rootDescriptor,
                    stagingName,
                    outputParentDescriptor,
                    plan.patchSetDigest,
                    UInt32(RENAME_EXCL)
                ) == 0
            else {
                throw CheckFailure(
                    description:
                        "\(output.path): couldn't publish patched checkout without replacing an existing path: "
                        + String(cString: strerror(errno))
                )
            }
            if let publicationFailure = verifyPublishedCheckoutLocation(
                root: root,
                outputParentComponents: outputParentComponents,
                expectedParentIdentities: openedOutputParent.identities,
                outputParentDescriptor: outputParentDescriptor,
                outputParent: outputParent,
                outputName: plan.patchSetDigest,
                outputPath: output,
                stagingPath: staging,
                stagingName: stagingName,
                stagingIdentity: stagingIdentity,
                rootDescriptor: rootDescriptor
            ) {
                if !publicationFailure.rolledBack {
                    stagingPaths.removeLast()
                    publishedPaths.append(output)
                }
                throw CheckFailure(description: publicationFailure.message)
            }
            stagingPaths.removeLast()
            publishedPaths.append(output)
        }
    } catch {
        let preservedPaths = (stagingPaths + publishedPaths).map(\.path)
        let recovery =
            preservedPaths.isEmpty
            ? "no staging checkout is known to remain"
            : "staging or published checkout(s) may remain; last-known paths: "
                + preservedPaths.joined(separator: ", ")
        throw CheckFailure(
            description: "\(error); \(recovery)"
        )
    }

    return preparedPlans.reduce(0) { $0 + $1.plan.patches.count }
}

do {
    let options = try commandOptions(from: CommandLine.arguments)
    let lockSnapshot = try readLockSnapshot(at: options.root)
    let failures = try check(root: options.root, lockSnapshot: lockSnapshot)
    if failures.isEmpty {
        if options.applyPatches {
            let patchCount = try applyPinnedPatches(
                root: options.root,
                lockSnapshot: lockSnapshot
            )
            if patchCount == 0 {
                print("check-lock: passed; no patches to apply")
            } else {
                print("check-lock: passed; patches applied")
            }
        } else {
            print("check-lock: passed")
        }
    } else {
        for failure in failures {
            print("ERROR \(failure)")
        }
        exit(1)
    }
} catch {
    fputs("check-lock: \(error)\n", stderr)
    exit(1)
}
