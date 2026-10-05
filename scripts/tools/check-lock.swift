import CoreFoundation
import CryptoKit
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

func readJSON(_ path: URL) throws -> Any {
    do {
        let data = try Data(contentsOf: path)
        return try JSONSerialization.jsonObject(with: data)
    } catch {
        throw CheckFailure(description: "\(path.path): invalid JSON: \(error)")
    }
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
    var isDirectory = ObjCBool(false)
    return FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory)
        && !isDirectory.boolValue
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

func check(root: URL) throws -> [String] {
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

    guard let lock = try readJSON(lockURL) as? [String: Any],
        let schemaVersion = lock["schemaVersion"] as? NSNumber,
        CFGetTypeID(schemaVersion) != CFBooleanGetTypeID(),
        ["c", "s", "i", "l", "q"].contains(String(cString: schemaVersion.objCType)),
        schemaVersion.intValue == 1,
        let components = lock["components"] as? [[String: Any]]
    else {
        throw CheckFailure(description: "\(lockURL.path): expected schemaVersion 1 and components")
    }

    let resolvedPackages = try decodePackages(try readJSON(resolvedURL), path: resolvedURL)
    var packageDeclarations = try swiftPackageDeclarations(root: root, manifest: manifestURL)
    if FileManager.default.fileExists(atPath: projectURL.path) {
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

func rootURL(from arguments: [String]) throws -> URL {
    var rootPath = FileManager.default.currentDirectoryPath
    var index = 1
    while index < arguments.count {
        guard arguments[index] == "--root", arguments.indices.contains(index + 1) else {
            throw CheckFailure(description: "usage: check-lock.swift [--root <directory>]")
        }
        rootPath = arguments[index + 1]
        index += 2
    }
    return URL(fileURLWithPath: rootPath).standardizedFileURL
}

do {
    let root = try rootURL(from: CommandLine.arguments)
    let failures = try check(root: root)
    if failures.isEmpty {
        print("check-lock: passed")
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
