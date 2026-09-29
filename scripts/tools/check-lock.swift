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

func readJSON(_ path: URL) throws -> Any {
    let data = try Data(contentsOf: path)
    return try JSONSerialization.jsonObject(with: data)
}

func string(_ value: Any?) -> String? {
    value as? String
}

func arrayOfStrings(_ value: Any?) -> [String]? {
    value as? [String]
}

func identityKey(_ value: String) -> String {
    value.lowercased().replacingOccurrences(of: ".git", with: "")
}

func safeRelativePath(_ value: String) -> Bool {
    guard !value.isEmpty, !value.hasPrefix("/") else { return false }
    return value.split(separator: "/").allSatisfy { $0 != "." && $0 != ".." }
}

func exactManifestVersion(
    repository: String,
    manifest: String
) -> String? {
    let packageBlocks = manifest.components(separatedBy: ".package(").dropFirst()
    for block in packageBlocks where block.localizedCaseInsensitiveContains(repository) {
        guard
            let exactRange = block.range(
                of: #"exact\s*:\s*"([^"]+)""#,
                options: .regularExpression
            )
        else {
            continue
        }
        let exactClause = String(block[exactRange])
        guard let quote = exactClause.firstIndex(of: "\""),
            let endQuote = exactClause[exactClause.index(after: quote)...].firstIndex(of: "\"")
        else {
            continue
        }
        return String(exactClause[exactClause.index(after: quote)..<endQuote])
    }
    return nil
}

func decodePackages(_ object: Any, path: URL) throws -> [LockPackage] {
    guard let root = object as? [String: Any],
        let pins = root["pins"] as? [[String: Any]]
    else {
        throw CheckFailure(description: "\(path.path): expected a pins array")
    }

    return try pins.map { pin in
        guard let identity = string(pin["identity"]),
            let location = string(pin["location"]),
            let state = pin["state"] as? [String: Any],
            let version = string(state["version"]),
            let revision = string(state["revision"])
        else {
            throw CheckFailure(description: "\(path.path): malformed Swift package pin")
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
        let schemaVersion = lock["schemaVersion"] as? Int,
        schemaVersion == 1,
        let components = lock["components"] as? [[String: Any]]
    else {
        throw CheckFailure(description: "\(lockURL.path): expected schemaVersion 1 and components")
    }

    let resolvedPackages = try decodePackages(try readJSON(resolvedURL), path: resolvedURL)
    let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
    var failures: [String] = []
    var names: Set<String> = []
    var swiftPMNames: Set<String> = []
    let allowedKinds: Set<String> = [
        "source", "prebuilt", "vendored", "swiftpm", "gradle", "cargo",
    ]
    let allowedShips: Set<String> = ["app", "image", "tooling", "derived"]
    let lowerHex40 = try NSRegularExpression(pattern: "^[0-9a-f]{40}$")
    let hex64 = try NSRegularExpression(pattern: "^[0-9a-fA-F]{64}$")

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

        let licenseFiles = arrayOfStrings(component["licenseFiles"]) ?? []
        if licenseFiles.isEmpty {
            failures.append("\(lockURL.path): \(label) is missing 'licenseFiles'")
        }
        for licenseFile in licenseFiles {
            guard safeRelativePath(licenseFile) else {
                failures.append("\(lockURL.path): \(label) has unsafe license path '\(licenseFile)'")
                continue
            }
            let licenseURL = root.appending(path: "ThirdParty/licenses/\(name)/\(licenseFile)")
            var isDirectory = ObjCBool(false)
            if !FileManager.default.fileExists(atPath: licenseURL.path, isDirectory: &isDirectory)
                || isDirectory.boolValue
            {
                failures.append("\(lockURL.path): \(label) license file is missing: \(licenseURL.path)")
            }
        }

        if arrayOfStrings(component["buildFlags"]) == nil {
            failures.append("\(lockURL.path): \(label) is missing a 'buildFlags' array")
        }
        let patches = arrayOfStrings(component["patches"]) ?? []
        if component["patches"] == nil {
            failures.append("\(lockURL.path): \(label) is missing a 'patches' array")
        }
        for patch in patches {
            guard safeRelativePath(patch), patch.hasPrefix("\(name)/") else {
                failures.append("\(lockURL.path): \(label) has invalid patch path '\(patch)'")
                continue
            }
            let patchURL = root.appending(path: "ThirdParty/patches/\(patch)")
            var isDirectory = ObjCBool(false)
            if !FileManager.default.fileExists(atPath: patchURL.path, isDirectory: &isDirectory)
                || isDirectory.boolValue
            {
                failures.append("\(lockURL.path): \(label) patch is missing: \(patchURL.path)")
            }
        }

        let repository = string(component["repository"])
        let commit = string(component["commit"])
        if ["source", "vendored", "swiftpm"].contains(kind),
            repository?.hasPrefix("https://") != true
        {
            failures.append("\(lockURL.path): \(label) requires an HTTPS repository")
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
            if string(component["url"])?.hasPrefix("https://") != true {
                failures.append("\(lockURL.path): \(label) requires an HTTPS download URL")
            }
            if string(component["sha256"]) == nil {
                failures.append("\(lockURL.path): \(label) is missing its sha256")
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
        if identityKey(resolved.location) != identityKey(repository) {
            failures.append(
                "\(resolvedURL.path): \(name) repository \(resolved.location) does not match lock repository \(repository)"
            )
        }
        if resolved.version != string(component["version"]) {
            failures.append(
                "\(resolvedURL.path): \(name) version \(resolved.version) does not match lock version \(string(component["version"]) ?? "<missing>")"
            )
        }
        if let manifestVersion = exactManifestVersion(
            repository: repository,
            manifest: manifest
        ) {
            if manifestVersion != string(component["version"]) {
                failures.append(
                    "\(manifestURL.path): \(name) exact version \(manifestVersion) does not match lock version \(string(component["version"]) ?? "<missing>")"
                )
            }
        } else {
            failures.append(
                "\(manifestURL.path): \(name) must use an exact version requirement"
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
