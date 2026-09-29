import Foundation

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

struct DependencyGraph {
    let moduleTargets: Set<String>
    let internalTargets: Set<String>
    let moduleDependencies: [String: Set<String>]
    let moduleProducts: [String: Set<String>]
    let executableDependencies: [String: Set<String>]
    let executableProducts: [String: Set<String>]
    let executableTraitDependencies: [String: Set<String>]
    let executableTraitProducts: [String: Set<String>]
    let thirdPartyProducts: Set<String>
}

struct RawGraphRow {
    let name: String
    var body: String
    var traitBody: String
}

struct PackageDependency {
    let name: String
    let product: Bool
    let traitNames: Set<String>
    let platformNames: Set<String>
    let isConditional: Bool
}

struct PackageTarget {
    let name: String
    let type: String
    let path: String
    let excludes: Set<String>
    let dependencies: [PackageDependency]
}

struct SourceToken {
    let value: String
    let line: Int
    let isString: Bool
}

struct ImportReference {
    let name: String
    let line: Int
}

enum TargetRole {
    case module(String)
    case executable(String)
    case test(String)
    case testSupport(String)
    case integration
    case unlisted(String)
}

struct SourceRoot {
    let url: URL
    let role: TargetRole
    let production: Bool
    let excludedRelativePaths: Set<String>
}

func readText(_ url: URL) throws -> String {
    do {
        return try String(contentsOf: url, encoding: .utf8)
    } catch {
        throw CheckFailure(description: "\(url.path): couldn't read file: \(error)")
    }
}

func readJSON(_ url: URL) throws -> Any {
    do {
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    } catch {
        throw CheckFailure(description: "\(url.path): invalid JSON: \(error)")
    }
}

func runJSONCommand(
    executable: URL,
    arguments: [String],
    workingDirectory: URL,
    source: URL
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
        throw CheckFailure(description: "\(source.path): couldn't run \(executable.path): \(error)")
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let details = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw CheckFailure(
            description: "\(source.path): command failed (\(process.terminationStatus)): \(details)"
        )
    }
    do {
        return try JSONSerialization.jsonObject(with: data)
    } catch {
        throw CheckFailure(description: "\(source.path): command returned invalid JSON: \(error)")
    }
}

func executableVersion(from text: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: #"(?m)^XCODEGEN_VERSION=([0-9.]+)$"#),
        let match = expression.firstMatch(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        ),
        let range = Range(match.range(at: 1), in: text)
    else {
        return nil
    }
    return String(text[range])
}

func xcodegenExecutable(root: URL) -> URL? {
    if let configuredPath = ProcessInfo.processInfo.environment["APKRUN_XCODEGEN"] {
        let executable = URL(fileURLWithPath: configuredPath)
        return FileManager.default.isExecutableFile(atPath: executable.path) ? executable : nil
    }

    let versionsFile = root.appending(path: "scripts/tool-versions.env")
    guard let versions = try? String(contentsOf: versionsFile, encoding: .utf8),
        let version = executableVersion(from: versions)
    else {
        return nil
    }
    let executable = root.appending(path: "build/tools/xcodegen-\(version)/bin/xcodegen")
    return FileManager.default.isExecutableFile(atPath: executable.path) ? executable : nil
}

func fencedBlocks(in section: String) -> [String] {
    guard let expression = try? NSRegularExpression(pattern: #"```[^\n]*\n([\s\S]*?)```"#) else {
        return []
    }
    let range = NSRange(section.startIndex..<section.endIndex, in: section)
    return expression.matches(in: section, range: range).compactMap { match in
        guard let contents = Range(match.range(at: 1), in: section) else {
            return nil
        }
        return String(section[contents])
    }
}

func graphBlocks(from markdownURL: URL) throws -> [String] {
    let markdown = try readText(markdownURL)
    guard let start = markdown.range(of: "## 3. Dependency graph"),
        let end = markdown[start.upperBound...].range(of: "## 4.")
    else {
        throw CheckFailure(description: "\(markdownURL.path): missing dependency graph section §3")
    }
    let blocks = fencedBlocks(in: String(markdown[start.lowerBound..<end.lowerBound]))
    guard blocks.count == 2 else {
        throw CheckFailure(
            description: "\(markdownURL.path): dependency graph §3 must contain exactly two code blocks"
        )
    }
    return blocks
}

func rawRows(in block: String, includeTraitRows: Bool) -> [RawGraphRow] {
    var rows: [RawGraphRow] = []
    var current: RawGraphRow?

    func flush() {
        if let current {
            rows.append(current)
        }
    }

    for rawLine in block.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            continue
        }

        if includeTraitRows, trimmed.hasPrefix("+"), var row = current {
            var traitBody = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            if let condition = traitBody.range(of: " only when") {
                traitBody = String(traitBody[..<condition.lowerBound])
            }
            row.traitBody += " " + traitBody
            current = row
            continue
        }

        if let arrow = line.range(of: "→") {
            flush()
            let name =
                String(line[..<arrow.lowerBound])
                .trimmingCharacters(in: .whitespaces)
                .split(whereSeparator: \.isWhitespace)
                .first
                .map(String.init) ?? ""
            current = RawGraphRow(
                name: name,
                body: String(line[arrow.upperBound...]).trimmingCharacters(in: .whitespaces),
                traitBody: ""
            )
            continue
        }

        if let leaf = try? NSRegularExpression(pattern: #"^([A-Za-z][A-Za-z0-9]*)\s+\(leaf\)\s*$"#),
            let match = leaf.firstMatch(
                in: trimmed,
                range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            ),
            let nameRange = Range(match.range(at: 1), in: trimmed)
        {
            flush()
            current = RawGraphRow(name: String(trimmed[nameRange]), body: "", traitBody: "")
            continue
        }

        if var row = current {
            row.body += " " + trimmed
            current = row
        }
    }
    flush()
    return rows.filter { !$0.name.isEmpty }
}

func destinations(from raw: String) -> [String] {
    var value = raw
    if let condition = value.range(of: " only when") {
        value = String(value[..<condition.lowerBound])
    }
    value = value.replacingOccurrences(
        of: #"\(([A-Za-z][A-Za-z0-9]*)\)\s*(?=,|$)"#,
        with: "",
        options: .regularExpression
    )
    value = value.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
    return
        value
        .split(separator: ",")
        .compactMap { part in
            let token = part.trimmingCharacters(in: .whitespaces)
            guard let expression = try? NSRegularExpression(pattern: #"^([A-Za-z][A-Za-z0-9.]*)"#),
                let match = expression.firstMatch(
                    in: token,
                    range: NSRange(token.startIndex..<token.endIndex, in: token)
                ),
                let range = Range(match.range(at: 1), in: token)
            else {
                return nil
            }
            return String(token[range])
        }
}

func makeGraph(from blocks: [String], source: URL) throws -> DependencyGraph {
    guard let moduleBlock = blocks.first, let executableBlock = blocks.last else {
        throw CheckFailure(description: "\(source.path): dependency graph §3 is empty")
    }
    let moduleRows = rawRows(in: moduleBlock, includeTraitRows: false)
    let executableRows = rawRows(in: executableBlock, includeTraitRows: true)
    let moduleTargets = Set(moduleRows.map(\.name))
    guard moduleRows.count >= 16, executableRows.count >= 5 else {
        throw CheckFailure(
            description: "\(source.path): dependency graph §3 did not yield all module and executable rows"
        )
    }

    var internalTargets = moduleTargets
    let cTargetExpression = try? NSRegularExpression(pattern: #"([A-Za-z][A-Za-z0-9]*)\(C\)"#)
    for row in moduleRows {
        guard let cTargetExpression else { continue }
        let range = NSRange(row.body.startIndex..<row.body.endIndex, in: row.body)
        for match in cTargetExpression.matches(in: row.body, range: range) {
            guard let targetRange = Range(match.range(at: 1), in: row.body) else { continue }
            internalTargets.insert(String(row.body[targetRange]))
        }
    }

    let sdkProducts: Set<String> = ["Foundation", "IOSurface"]
    var moduleDependencies: [String: Set<String>] = [:]
    var moduleProducts: [String: Set<String>] = [:]
    var executableDependencies: [String: Set<String>] = [:]
    var executableProducts: [String: Set<String>] = [:]
    var executableTraitDependencies: [String: Set<String>] = [:]
    var executableTraitProducts: [String: Set<String>] = [:]

    for row in moduleRows {
        var targets: Set<String> = []
        var products: Set<String> = []
        for destination in destinations(from: row.body) {
            if internalTargets.contains(destination) {
                targets.insert(destination)
            } else if !sdkProducts.contains(destination) {
                products.insert(destination)
            }
        }
        moduleDependencies[row.name] = targets
        moduleProducts[row.name] = products
    }

    for row in executableRows {
        let name = row.name == "APKRun.app" ? "APKRun" : row.name
        var targets: Set<String> = []
        var products: Set<String> = []
        for destination in destinations(from: row.body) {
            if internalTargets.contains(destination) {
                targets.insert(destination)
            } else if !sdkProducts.contains(destination) {
                products.insert(destination)
            }
        }
        var traitTargets: Set<String> = []
        var traitProducts: Set<String> = []
        for destination in destinations(from: row.traitBody) {
            if internalTargets.contains(destination) {
                traitTargets.insert(destination)
            } else if !sdkProducts.contains(destination) {
                traitProducts.insert(destination)
            }
        }
        executableDependencies[name] = targets
        executableProducts[name] = products
        executableTraitDependencies[name] = traitTargets
        executableTraitProducts[name] = traitProducts
    }

    let allProducts = Set(moduleProducts.values.flatMap { $0 })
        .union(executableProducts.values.flatMap { $0 })
        .union(executableTraitProducts.values.flatMap { $0 })
    return DependencyGraph(
        moduleTargets: moduleTargets,
        internalTargets: internalTargets,
        moduleDependencies: moduleDependencies,
        moduleProducts: moduleProducts,
        executableDependencies: executableDependencies,
        executableProducts: executableProducts,
        executableTraitDependencies: executableTraitDependencies,
        executableTraitProducts: executableTraitProducts,
        thirdPartyProducts: allProducts
    )
}

func packageTargets(from object: Any, source: URL) throws -> [PackageTarget] {
    guard let package = object as? [String: Any],
        let rawTargets = package["targets"] as? [[String: Any]]
    else {
        throw CheckFailure(description: "\(source.path): swift package dump-package omitted targets")
    }
    return try rawTargets.map { target in
        guard let name = target["name"] as? String,
            let type = target["type"] as? String,
            let path = target["path"] as? String
        else {
            throw CheckFailure(description: "\(source.path): malformed target in SwiftPM dump")
        }
        let dependencies = try (target["dependencies"] as? [[String: Any]] ?? []).map {
            rawDependency -> PackageDependency in
            func condition(from value: Any?) -> (Set<String>, Set<String>, Bool) {
                guard let condition = value as? [String: Any] else {
                    return ([], [], false)
                }
                return (
                    Set(condition["traits"] as? [String] ?? []),
                    Set(condition["platformNames"] as? [String] ?? []),
                    true
                )
            }
            if let values = rawDependency["byName"] as? [Any],
                let name = values.first as? String
            {
                let (traits, platforms, isConditional) = condition(from: rawDependency["condition"])
                return PackageDependency(
                    name: name,
                    product: false,
                    traitNames: traits,
                    platformNames: platforms,
                    isConditional: isConditional
                )
            }
            if let values = rawDependency["product"] as? [Any],
                let name = values.first as? String
            {
                let (traits, platforms, isConditional) = condition(from: rawDependency["condition"])
                return PackageDependency(
                    name: name,
                    product: true,
                    traitNames: traits,
                    platformNames: platforms,
                    isConditional: isConditional
                )
            }
            if let values = rawDependency["target"] as? [Any],
                let name = values.first as? String
            {
                let condition = values.count > 1 ? values[1] as? [String: Any] : nil
                let traits = Set(condition?["traits"] as? [String] ?? [])
                let platforms = Set(condition?["platformNames"] as? [String] ?? [])
                return PackageDependency(
                    name: name,
                    product: false,
                    traitNames: traits,
                    platformNames: platforms,
                    isConditional: condition != nil
                )
            }
            throw CheckFailure(
                description: "\(source.path): \(name) has an unrecognized dependency in SwiftPM dump"
            )
        }
        return PackageTarget(
            name: name,
            type: type,
            path: path,
            excludes: Set(target["exclude"] as? [String] ?? []),
            dependencies: dependencies
        )
    }
}

func targetRoles(
    for target: PackageTarget,
    knownModules: Set<String>,
    knownInternalTargets: Set<String>
) -> TargetRole {
    let normalizedPath = target.path
    if normalizedPath.hasPrefix("Packages/") {
        let components = normalizedPath.split(separator: "/").map(String.init)
        guard components.count >= 2, knownModules.contains(components[1]) else {
            return .unlisted(target.name)
        }
        let module = components[1]
        if target.name == module {
            return .module(module)
        }
        if target.name == "\(module)TestSupport" {
            return .testSupport(module)
        }
        if target.name == "\(module)Tests" || target.name == "\(module)SystemTests" {
            return .test(module)
        }
        if components.contains("Sources"), knownInternalTargets.contains(target.name) {
            return .module(module)
        }
        return .unlisted(target.name)
    }
    if target.name == "apkrun" {
        return .executable("apkrun")
    }
    if target.name == "apkrunTests" {
        return .test("apkrun")
    }
    if normalizedPath.hasPrefix("Tests/IntegrationTests/")
        || normalizedPath.hasPrefix("Tests/AcceptanceTests/")
    {
        return .integration
    }
    return .unlisted(target.name)
}

func sourceExtension(_ url: URL) -> Bool {
    [
        "swift", "h", "hh", "hpp", "c", "cc", "cpp", "m", "mm", "metal",
    ].contains(url.pathExtension.lowercased())
}

func sourceFiles(under root: URL, excluding excludedPaths: Set<String> = []) -> [URL] {
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
        return []
    }
    if !isDirectory.boolValue {
        return sourceExtension(root) ? [root] : []
    }
    guard
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
    else {
        return []
    }
    var files: [URL] = []
    for case let url as URL in enumerator {
        let relative = String(url.path.dropFirst(root.path.count + 1))
        if excludedPaths.contains(relative) {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                enumerator.skipDescendants()
            }
            continue
        }
        if excludedPaths.contains(where: { relative.hasPrefix($0 + "/") }) {
            continue
        }
        if sourceExtension(url) {
            files.append(url)
        }
    }
    return files
}

func tokenize(_ source: String) -> [SourceToken] {
    let bytes = Array(source.utf8)
    var tokens: [SourceToken] = []
    var index = 0
    var line = 1

    func byte(at position: Int) -> UInt8? {
        bytes.indices.contains(position) ? bytes[position] : nil
    }

    func isIdentifierStart(_ value: UInt8) -> Bool {
        (65...90).contains(value) || (97...122).contains(value) || value == 95
    }

    func isIdentifierByte(_ value: UInt8) -> Bool {
        isIdentifierStart(value) || (48...57).contains(value)
    }

    func advanceLine(from start: Int, to end: Int) {
        for value in bytes[start..<end] where value == 10 {
            line += 1
        }
    }

    while index < bytes.count {
        guard let current = byte(at: index) else { break }
        if current == 10 {
            line += 1
            index += 1
            continue
        }
        if current == 32 || current == 9 || current == 13 {
            index += 1
            continue
        }

        if current == 47, byte(at: index + 1) == 47 {
            index += 2
            while index < bytes.count, byte(at: index) != 10 {
                index += 1
            }
            continue
        }

        if current == 47, byte(at: index + 1) == 42 {
            let start = index
            index += 2
            var depth = 1
            while index < bytes.count, depth > 0 {
                if byte(at: index) == 47, byte(at: index + 1) == 42 {
                    depth += 1
                    index += 2
                } else if byte(at: index) == 42, byte(at: index + 1) == 47 {
                    depth -= 1
                    index += 2
                } else {
                    index += 1
                }
            }
            advanceLine(from: start, to: index)
            continue
        }

        if current == 35 || current == 34 {
            let start = index
            var cursor = index
            while byte(at: cursor) == 35 {
                cursor += 1
            }
            if byte(at: cursor) == 34 {
                let hashCount = cursor - start
                let isTripleQuote =
                    byte(at: cursor + 1) == 34 && byte(at: cursor + 2) == 34
                let quoteCount = isTripleQuote ? 3 : 1
                cursor += quoteCount
                let contentStart = cursor
                var contentEnd = cursor
                while cursor < bytes.count {
                    if hashCount == 0, byte(at: cursor) == 92 {
                        cursor = min(bytes.count, cursor + 2)
                        continue
                    }
                    var matchesQuote = true
                    for offset in 0..<quoteCount where byte(at: cursor + offset) != 34 {
                        matchesQuote = false
                    }
                    let closingHashStart = cursor + quoteCount
                    let closingHashes = (0..<hashCount).allSatisfy {
                        byte(at: closingHashStart + $0) == 35
                    }
                    if matchesQuote && closingHashes {
                        contentEnd = cursor
                        cursor += quoteCount + hashCount
                        break
                    }
                    cursor += 1
                }
                if cursor > contentStart {
                    let tokenLine = line
                    let literal = String(decoding: bytes[contentStart..<contentEnd], as: UTF8.self)
                    advanceLine(from: start, to: cursor)
                    tokens.append(SourceToken(value: literal, line: tokenLine, isString: true))
                    index = cursor
                    continue
                }
            }
        }

        if current == 39 {
            let start = index
            index += 1
            while index < bytes.count {
                if byte(at: index) == 92 {
                    index = min(bytes.count, index + 2)
                } else if byte(at: index) == 39 {
                    index += 1
                    break
                } else {
                    index += 1
                }
            }
            advanceLine(from: start, to: index)
            continue
        }

        if isIdentifierStart(current) {
            let start = index
            let tokenLine = line
            index += 1
            while let value = byte(at: index), isIdentifierByte(value) {
                index += 1
            }
            tokens.append(
                SourceToken(
                    value: String(decoding: bytes[start..<index], as: UTF8.self),
                    line: tokenLine,
                    isString: false
                )
            )
            continue
        }

        tokens.append(
            SourceToken(
                value: String(decoding: [current], as: UTF8.self),
                line: line,
                isString: false
            )
        )
        index += 1
    }
    return tokens
}

func importReferences(in source: String) -> [ImportReference] {
    let tokens = tokenize(source)
    var imports: [ImportReference] = []
    let importableKinds: Set<String> = [
        "class", "enum", "func", "let", "protocol", "struct", "typealias", "var",
    ]
    for index in tokens.indices where tokens[index].value == "import" && !tokens[index].isString {
        let isPreprocessor = index > 0 && tokens[index - 1].value == "#"
        let isAtImport = index > 0 && tokens[index - 1].value == "@"
        var candidate = index + 1
        if !isPreprocessor && !isAtImport,
            candidate < tokens.count,
            importableKinds.contains(tokens[candidate].value)
        {
            candidate += 1
        }
        guard tokens.indices.contains(candidate) else { continue }
        let token = tokens[candidate]
        let moduleName: String?
        if isPreprocessor, token.value == "<" {
            moduleName =
                tokens.dropFirst(candidate + 1).first(where: {
                    !$0.isString && isIdentifierStartByte($0.value)
                })?.value
        } else if isPreprocessor, token.isString {
            moduleName = token.value.split(separator: "/").first.map {
                String($0).split(separator: ".").first.map(String.init) ?? String($0)
            }
        } else if isIdentifierStartByte(token.value) {
            moduleName = token.value
        } else {
            moduleName = nil
        }
        if let moduleName {
            imports.append(ImportReference(name: moduleName, line: tokens[index].line))
        }
    }

    for index in tokens.indices where tokens[index].value == "include" && !tokens[index].isString {
        guard index > 0, tokens[index - 1].value == "#" else { continue }
        let candidate = index + 1
        guard tokens.indices.contains(candidate) else { continue }
        let token = tokens[candidate]
        let name: String?
        if token.value == "<" {
            name =
                tokens.dropFirst(candidate + 1).first(where: {
                    !$0.isString && isIdentifierStartByte($0.value)
                })?.value
        } else if token.isString {
            name = token.value.split(separator: "/").first.map {
                String($0).split(separator: ".").first.map(String.init) ?? String($0)
            }
        } else {
            name = nil
        }
        if let name {
            imports.append(ImportReference(name: name, line: tokens[index].line))
        }
    }
    return imports
}

func isIdentifierStartByte(_ value: String) -> Bool {
    guard let first = value.utf8.first else { return false }
    return (65...90).contains(first) || (97...122).contains(first) || first == 95
}

func importsAllowed(for role: TargetRole, graph: DependencyGraph) -> (Set<String>, Set<String>) {
    switch role {
    case .module(let module):
        return (graph.moduleDependencies[module] ?? [], graph.moduleProducts[module] ?? [])
    case .executable(let executable):
        return (
            (graph.executableDependencies[executable] ?? [])
                .union(graph.executableTraitDependencies[executable] ?? []),
            (graph.executableProducts[executable] ?? [])
                .union(graph.executableTraitProducts[executable] ?? [])
        )
    case .test(let module):
        if module == "apkrun" {
            return (
                (graph.executableDependencies[module] ?? [])
                    .union(graph.executableTraitDependencies[module] ?? [])
                    .union([module]),
                (graph.executableProducts[module] ?? [])
                    .union(graph.executableTraitProducts[module] ?? [])
            )
        }
        var modules: Set<String> = [module]
        var products: Set<String> = []
        var pending = [module]
        while let current = pending.popLast() {
            for dependency in graph.moduleDependencies[current] ?? [] where modules.insert(dependency).inserted {
                pending.append(dependency)
            }
            products.formUnion(graph.moduleProducts[current] ?? [])
        }
        return (modules, products)
    case .testSupport(let module):
        var modules: Set<String> = [module]
        var products: Set<String> = []
        var pending = [module]
        while let current = pending.popLast() {
            for dependency in graph.moduleDependencies[current] ?? [] where modules.insert(dependency).inserted {
                pending.append(dependency)
            }
            products.formUnion(graph.moduleProducts[current] ?? [])
        }
        return (modules, products)
    case .integration:
        return (graph.internalTargets, graph.thirdPartyProducts)
    case .unlisted:
        return ([], [])
    }
}

func forbiddenDirectories(root: URL) -> [String] {
    let names: Set<String> = ["Common", "Helpers", "Misc", "Utils"]
    var failures: [String] = []
    for base in ["Apps", "Daemon", "CLI", "Packages"] {
        let directory = root.appending(path: base)
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else {
            continue
        }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                values.isDirectory == true,
                names.contains(url.lastPathComponent)
            else {
                continue
            }
            failures.append(
                "\(url.path): forbidden dumping-ground directory '\(url.lastPathComponent)' " + "(modules.md §1)"
            )
        }
    }
    return failures
}

func experimentModules(root: URL, packageTargets: [PackageTarget]) -> Set<String> {
    let experiments = root.appending(path: "Experiments")
    var modules = Set(
        packageTargets
            .filter { pathIsInsideExperiments(root.appending(path: $0.path), root: root) }
            .map(\.name)
    )
    guard
        let enumerator = FileManager.default.enumerator(
            at: experiments,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
    else {
        return modules
    }
    for case let url as URL in enumerator {
        let components = url.pathComponents
        if let sourceIndex = components.lastIndex(of: "Sources"),
            components.indices.contains(sourceIndex + 1)
        {
            modules.insert(components[sourceIndex + 1])
        }
    }
    return modules
}

func pathIsInsideExperiments(_ url: URL, root: URL) -> Bool {
    let experimentsPath = root.appending(path: "Experiments").standardizedFileURL.path
    let candidatePath = url.standardizedFileURL.path
    return candidatePath == experimentsPath || candidatePath.hasPrefix(experimentsPath + "/")
}

func reportImports(
    in file: URL,
    owner: TargetRole,
    root: URL,
    graph: DependencyGraph,
    experimentModuleNames: Set<String>,
    testSupportNames: Set<String>
) -> [String] {
    guard let source = try? String(contentsOf: file, encoding: .utf8) else {
        return ["\(file.path): couldn't read source for dependency scan"]
    }
    let (allowedTargets, allowedProducts) = importsAllowed(for: owner, graph: graph)
    let allowedSupports: Set<String>
    switch owner {
    case .test(let module):
        if module == "apkrun" {
            allowedSupports = testSupportNames
        } else {
            allowedSupports = Set(([module] + Array(allowedTargets)).map { "\($0)TestSupport" })
                .intersection(testSupportNames)
        }
    case .integration:
        allowedSupports = testSupportNames
    default:
        allowedSupports = []
    }

    var failures: [String] = []
    for imported in importReferences(in: source) {
        if experimentModuleNames.contains(imported.name) {
            failures.append(
                "\(file.path):\(imported.line): production/test source imports Experiments module "
                    + "'\(imported.name)' (modules.md §1 and §3)"
            )
            continue
        }
        if graph.internalTargets.contains(imported.name) {
            var permitted = allowedTargets.contains(imported.name)
            if case .test(let module) = owner, imported.name == module {
                permitted = true
            }
            if case .testSupport(let module) = owner, imported.name == module {
                permitted = true
            }
            if !permitted {
                let ownerName = roleName(owner)
                failures.append(
                    "\(file.path):\(imported.line): forbidden import edge '\(ownerName) -> "
                        + "\(imported.name)'; modules.md §3 does not allow it"
                )
            }
        } else if graph.thirdPartyProducts.contains(imported.name),
            !allowedProducts.contains(imported.name)
        {
            failures.append(
                "\(file.path):\(imported.line): third-party import '\(imported.name)' is not allowed "
                    + "for '\(roleName(owner))' by modules.md §3"
            )
        } else if testSupportNames.contains(imported.name),
            !allowedSupports.contains(imported.name)
        {
            failures.append(
                "\(file.path):\(imported.line): test support import '\(imported.name)' is not allowed "
                    + "for '\(roleName(owner))' by build-system.md §2.1"
            )
        }
    }
    _ = root
    return failures
}

func roleName(_ role: TargetRole) -> String {
    switch role {
    case .module(let value):
        value
    case .executable(let value):
        value
    case .test(let value):
        "\(value)Tests"
    case .testSupport(let value):
        "\(value)TestSupport"
    case .integration:
        "integration/acceptance tests"
    case .unlisted(let value):
        value
    }
}

func allowedTestDependencies(
    for role: TargetRole,
    graph: DependencyGraph,
    testSupportNames: Set<String>
) -> Set<String>? {
    switch role {
    case .test(let module):
        if module == "apkrun" {
            let modules =
                (graph.executableDependencies[module] ?? [])
                .union(graph.executableTraitDependencies[module] ?? [])
                .union([module])
            return modules.union(testSupportNames)
        }
        let (modules, _) = importsAllowed(for: role, graph: graph)
        let supports = Set(([module] + Array(modules)).map { "\($0)TestSupport" })
            .intersection(testSupportNames)
        return modules.union(supports)
    case .testSupport:
        let (modules, _) = importsAllowed(for: role, graph: graph)
        return modules
    case .integration:
        return graph.internalTargets.union(testSupportNames)
    default:
        return nil
    }
}

func checkPackageDependencies(
    targets: [PackageTarget],
    graph: DependencyGraph,
    packageURL: URL
) -> [String] {
    var failures: [String] = []
    let byName = Dictionary(uniqueKeysWithValues: targets.map { ($0.name, $0) })
    let testSupportNames = Set(targets.filter { $0.name.hasSuffix("TestSupport") }.map(\.name))

    for module in graph.moduleTargets where byName[module] == nil {
        failures.append(
            "\(packageURL.path): missing SwiftPM target '\(module)' listed by modules.md §3"
        )
    }

    for target in targets {
        let role = targetRoles(
            for: target,
            knownModules: graph.moduleTargets,
            knownInternalTargets: graph.internalTargets
        )
        let targetFile = "\(packageURL.path) (\(target.name))"
        let internalDependencies = Set(
            target.dependencies.filter {
                !$0.product && graph.internalTargets.contains($0.name)
            }.map(\.name))
        let productDependencies = Set(target.dependencies.filter(\.product).map(\.name))

        if case .unlisted(let targetName) = role {
            failures.append(
                "\(targetFile): unclassified SwiftPM target at '\(target.path)' has no rule in modules.md §3"
            )
            for dependency in target.dependencies {
                if dependency.product {
                    failures.append(
                        "\(targetFile): third-party product '\(dependency.name)' is not allowed for "
                            + "unclassified target '\(targetName)' by modules.md §3"
                    )
                } else {
                    failures.append(
                        "\(targetFile): forbidden dependency edge '\(targetName) -> \(dependency.name)'; "
                            + "modules.md §3 does not allow it"
                    )
                }
            }
        } else if case .module(let module) = role, graph.moduleTargets.contains(module) {
            let allowedModules = graph.moduleDependencies[module] ?? []
            let allTargetDependencies = Set(target.dependencies.filter { !$0.product }.map(\.name))
            for dependency in allTargetDependencies.subtracting(allowedModules) {
                failures.append(
                    "\(targetFile): forbidden dependency edge '\(module) -> \(dependency)'; "
                        + "modules.md §3 does not allow it"
                )
            }
            let allowedProducts = graph.moduleProducts[module] ?? []
            for dependency in productDependencies.subtracting(allowedProducts) {
                failures.append(
                    "\(targetFile): third-party product '\(dependency)' is not allowed for "
                        + "'\(module)' by modules.md §3"
                )
            }
            for dependency in allowedProducts.subtracting(productDependencies) {
                failures.append(
                    "\(targetFile): missing third-party product edge '\(module) -> \(dependency)' "
                        + "required by modules.md §3"
                )
            }
            for dependency in target.dependencies where dependency.isConditional {
                failures.append(
                    "\(targetFile): trait-conditioned edge '\(module) -> \(dependency.name)' is forbidden; "
                        + "only apkrun may use EmbeddedRuntime (modules.md §3)"
                )
            }
        } else if case .executable(let executable) = role, executable == "apkrun" {
            let expectedModules = graph.executableDependencies[executable] ?? []
            let expectedProducts = graph.executableProducts[executable] ?? []
            let expectedTraitModules = graph.executableTraitDependencies[executable] ?? []
            let expectedTraitProducts = graph.executableTraitProducts[executable] ?? []
            let baseModules = Set(
                target.dependencies.filter {
                    !$0.product && !$0.isConditional
                }.map(\.name))
            let conditional = target.dependencies.filter(\.isConditional)
            let conditionalModules = Set(conditional.filter { !$0.product }.map(\.name))
            let baseProducts = Set(
                target.dependencies.filter {
                    $0.product && !$0.isConditional
                }.map(\.name))
            for dependency in baseModules.subtracting(expectedModules) {
                failures.append(
                    "\(targetFile): forbidden dependency edge 'apkrun -> \(dependency)'; "
                        + "modules.md §3 does not allow it"
                )
            }
            for dependency in baseProducts.subtracting(expectedProducts) {
                failures.append(
                    "\(targetFile): third-party product '\(dependency)' is not allowed for "
                        + "'apkrun' by modules.md §3"
                )
            }
            if baseModules != expectedModules {
                for dependency in expectedModules.subtracting(baseModules) {
                    failures.append(
                        "\(targetFile): missing dependency edge 'apkrun -> \(dependency)' from " + "modules.md §3"
                    )
                }
            }
            if baseProducts != expectedProducts {
                for dependency in expectedProducts.subtracting(baseProducts) {
                    failures.append(
                        "\(targetFile): missing third-party product edge 'apkrun -> \(dependency)' "
                            + "from modules.md §3"
                    )
                }
            }
            if conditionalModules != expectedTraitModules {
                for dependency in conditionalModules.subtracting(expectedTraitModules) {
                    failures.append(
                        "\(targetFile): forbidden trait-conditioned edge 'apkrun -> \(dependency)'; "
                            + "modules.md §3 permits only EmbeddedRuntime edges"
                    )
                }
                for dependency in expectedTraitModules.subtracting(conditionalModules) {
                    failures.append(
                        "\(targetFile): missing trait-conditioned edge 'apkrun -> \(dependency)' "
                            + "for EmbeddedRuntime (modules.md §3)"
                    )
                }
            }
            for dependency in conditional {
                if dependency.product
                    || dependency.traitNames != ["EmbeddedRuntime"]
                    || !dependency.platformNames.isEmpty
                    || !expectedTraitModules.contains(dependency.name)
                {
                    failures.append(
                        "\(targetFile): trait-conditioned edge '\(dependency.name)' must use only "
                            + "EmbeddedRuntime on apkrun (modules.md §3)"
                    )
                }
            }
            if Set(conditional.filter(\.product).map(\.name)) != expectedTraitProducts {
                failures.append(
                    "\(targetFile): trait-conditioned third-party products do not match " + "modules.md §3"
                )
            }
        } else if let allowed = allowedTestDependencies(
            for: role,
            graph: graph,
            testSupportNames: testSupportNames
        ) {
            for dependency in target.dependencies {
                if !dependency.product && !allowed.contains(dependency.name) {
                    failures.append(
                        "\(targetFile): test target has forbidden dependency '\(dependency.name)'; "
                            + "build-system.md §2.1 limits test dependencies"
                    )
                }
                if dependency.isConditional {
                    failures.append(
                        "\(targetFile): trait-conditioned dependency '\(dependency.name)' is not allowed "
                            + "for tests (modules.md §3)"
                    )
                }
            }
        } else if case .module(let module) = role {
            let allowedModules = graph.moduleDependencies[module] ?? []
            for dependency in internalDependencies.subtracting(allowedModules) {
                failures.append(
                    "\(targetFile): forbidden dependency edge '\(module) -> \(dependency)'; "
                        + "modules.md §3 does not allow it"
                )
            }
        }

        for dependency in target.dependencies where dependency.product {
            let allowedProducts: Set<String>
            switch role {
            case .module(let module):
                allowedProducts = graph.moduleProducts[module] ?? []
            case .executable(let executable):
                allowedProducts =
                    (graph.executableProducts[executable] ?? [])
                    .union(graph.executableTraitProducts[executable] ?? [])
            case .test, .testSupport:
                allowedProducts = importsAllowed(for: role, graph: graph).1
            case .integration:
                allowedProducts = graph.thirdPartyProducts
            case .unlisted:
                allowedProducts = []
            }
            if !allowedProducts.contains(dependency.name) {
                failures.append(
                    "\(targetFile): third-party product '\(dependency.name)' is outside the "
                        + "allowed dependency graph in modules.md §3"
                )
            }
        }
    }
    return failures
}

func xcodeTargets(from object: Any, source: URL) throws -> [String: [String: Any]] {
    guard let project = object as? [String: Any],
        let targets = project["targets"] as? [String: [String: Any]]
    else {
        throw CheckFailure(description: "\(source.path): XcodeGen dump omitted targets")
    }
    return targets
}

func xcodePackageNames(from object: Any, source: URL) throws -> Set<String> {
    guard let project = object as? [String: Any],
        let packages = project["packages"] as? [String: Any]
    else {
        throw CheckFailure(description: "\(source.path): XcodeGen dump omitted packages")
    }
    return Set(packages.keys)
}

func checkXcodeTargets(
    targets: [String: [String: Any]],
    packages: Set<String>,
    graph: DependencyGraph,
    source: URL
) -> [String] {
    var failures: [String] = []
    let executableTargets = ["APKRun", "APKRunMenuBar", "APKRunLauncher", "apkrund"]
    for targetName in executableTargets where targets[targetName] == nil {
        failures.append(
            "\(source.path): missing XcodeGen target '\(targetName)' listed by modules.md §3"
        )
    }

    for targetName in executableTargets {
        guard let target = targets[targetName],
            let role = executableRole(for: targetName),
            let dependencies = target["dependencies"] as? [[String: Any]]
        else {
            failures.append("\(source.path): XcodeGen target '\(targetName)' has no dependency list")
            continue
        }
        let expectedModules = graph.executableDependencies[role] ?? []
        let expectedProducts = graph.executableProducts[role] ?? []
        var actualModules: Set<String> = []
        var actualProducts: Set<String> = []
        let targetDependencies: [String: Set<String>] = [
            "APKRun": ["BuildStamp", "apkrund", "APKRunLauncher", "APKRunMenuBar"],
            "APKRunMenuBar": ["BuildStamp"],
            "APKRunLauncher": ["BuildStamp"],
            "apkrund": ["BuildStamp"],
        ]

        for dependency in dependencies {
            if let product = dependency["product"] as? String {
                let allowedKeys: Set<String> = ["product", "package", "link", "embed"]
                if !Set(dependency.keys).isSubset(of: allowedKeys) {
                    failures.append(
                        "\(source.path): Xcode target '\(role)' has an unrecognized product dependency "
                            + "shape in modules.md §3"
                    )
                }
                guard let package = dependency["package"] as? String,
                    packages.contains(package)
                else {
                    failures.append(
                        "\(source.path): Xcode target '\(role)' product '\(product)' names an "
                            + "undeclared package (modules.md §3)"
                    )
                    continue
                }
                if dependency["link"] as? Bool == false {
                    failures.append(
                        "\(source.path): Xcode target '\(role)' product '\(product)' must be linked "
                            + "as listed in modules.md §3"
                    )
                }
                if graph.internalTargets.contains(product) {
                    if package != "APKRun" {
                        failures.append(
                            "\(source.path): Xcode target '\(role)' module product '\(product)' "
                                + "must come from package 'APKRun' (modules.md §3)"
                        )
                    }
                    actualModules.insert(product)
                } else {
                    actualProducts.insert(product)
                }
                continue
            }
            if let targetName = dependency["target"] as? String {
                if !Set(dependency.keys).isSubset(of: ["target", "link", "embed"]) {
                    failures.append(
                        "\(source.path): Xcode target '\(role)' has an unrecognized target dependency "
                            + "shape in modules.md §3"
                    )
                }
                let shouldBeUnlinked = targetDependencies[role]?.contains(targetName) == true
                if shouldBeUnlinked,
                    dependency["link"] as? Bool == false,
                    dependency["embed"] as? Bool == false
                {
                    continue
                }
                let explanation =
                    graph.internalTargets.contains(targetName)
                    ? "must be linked as a package product"
                    : "is not an allowed helper target"
                failures.append(
                    "\(source.path): forbidden Xcode target dependency edge '\(role) -> \(targetName)'; "
                        + "\(explanation) (modules.md §3)"
                )
                continue
            }
            let dependencyKinds: Set<String> = ["framework", "sdk", "carthage", "bundle"]
            if let kind = dependencyKinds.first(where: { dependency[$0] != nil }) {
                failures.append(
                    "\(source.path): Xcode target '\(role)' has undeclared \(kind) dependency; "
                        + "modules.md §3 lists only module and approved third-party products"
                )
                continue
            }
            failures.append(
                "\(source.path): Xcode target '\(role)' has an unrecognized dependency in "
                    + "XcodeGen dump (modules.md §3)"
            )
        }

        for dependency in actualModules.subtracting(expectedModules) {
            failures.append(
                "\(source.path): forbidden Xcode target dependency edge '\(role) -> \(dependency)'; "
                    + "modules.md §3 does not allow it"
            )
        }
        for dependency in expectedModules.subtracting(actualModules) {
            failures.append(
                "\(source.path): missing Xcode target dependency edge '\(role) -> \(dependency)' "
                    + "from modules.md §3"
            )
        }
        for dependency in actualProducts.subtracting(expectedProducts) {
            failures.append(
                "\(source.path): third-party product '\(dependency)' is not allowed for "
                    + "Xcode target '\(role)' by modules.md §3"
            )
        }
        let declaredGraphProducts = expectedProducts.intersection(packages)
        for dependency in declaredGraphProducts.subtracting(actualProducts) {
            failures.append(
                "\(source.path): missing third-party product edge '\(role) -> \(dependency)' "
                    + "from modules.md §3"
            )
        }
    }
    return failures
}

func executableRole(for targetName: String) -> String? {
    targetName == "APKRun"
        ? "APKRun"
        : targetName == "APKRunMenuBar"
            ? "APKRunMenuBar"
            : targetName == "APKRunLauncher" ? "APKRunLauncher" : targetName == "apkrund" ? "apkrund" : nil
}

func packageSourceRoots(
    targets: [PackageTarget],
    graph: DependencyGraph,
    root: URL
) -> [SourceRoot] {
    targets.compactMap { target in
        let role = targetRoles(
            for: target,
            knownModules: graph.moduleTargets,
            knownInternalTargets: graph.internalTargets
        )
        return SourceRoot(
            url: root.appending(path: target.path),
            role: role,
            production: {
                switch role {
                case .module, .executable:
                    true
                case .test, .testSupport, .integration, .unlisted:
                    false
                }
            }(),
            excludedRelativePaths: target.excludes
        )
    }
}

func xcodeSourceRoots(
    targets: [String: [String: Any]],
    root: URL
) -> [SourceRoot] {
    var roots: [SourceRoot] = []
    for name in ["APKRun", "APKRunMenuBar", "APKRunLauncher", "apkrund"] {
        guard let target = targets[name],
            let roleName = executableRole(for: name),
            let sources = target["sources"] as? [[String: Any]]
        else {
            continue
        }
        for source in sources {
            guard let path = source["path"] as? String else { continue }
            roots.append(
                SourceRoot(
                    url: root.appending(path: path),
                    role: .executable(roleName),
                    production: true,
                    excludedRelativePaths: []
                )
            )
        }
    }
    return roots
}

func check(
    root: URL,
    graph: DependencyGraph,
    packageTargets: [PackageTarget],
    xcodeTargets: [String: [String: Any]],
    xcodePackages: Set<String>,
    packageURL: URL,
    projectURL: URL
) -> [String] {
    var failures = forbiddenDirectories(root: root)
    failures += checkPackageDependencies(targets: packageTargets, graph: graph, packageURL: packageURL)
    failures += checkXcodeTargets(
        targets: xcodeTargets,
        packages: xcodePackages,
        graph: graph,
        source: projectURL
    )

    let experimentModuleNames = experimentModules(root: root, packageTargets: packageTargets)
    let testSupportNames = Set(packageTargets.filter { $0.name.hasSuffix("TestSupport") }.map(\.name))
    var sourceRoots = packageSourceRoots(targets: packageTargets, graph: graph, root: root)
    sourceRoots += xcodeSourceRoots(targets: xcodeTargets, root: root)

    for sourceRoot in sourceRoots {
        if sourceRoot.production, pathIsInsideExperiments(sourceRoot.url, root: root) {
            failures.append(
                "\(sourceRoot.url.path): production target has sources under Experiments/ " + "(modules.md §1 and §3)"
            )
        }
        for file in sourceFiles(
            under: sourceRoot.url,
            excluding: sourceRoot.excludedRelativePaths
        )
        where !sourceRoot.production
            || !file.pathComponents.contains(where: { $0 == "Tests" || $0 == "UITests" })
        {
            failures += reportImports(
                in: file,
                owner: sourceRoot.role,
                root: root,
                graph: graph,
                experimentModuleNames: experimentModuleNames,
                testSupportNames: testSupportNames
            )
        }
    }
    return failures
}

func rootURL(from arguments: [String]) throws -> URL {
    var rootPath = FileManager.default.currentDirectoryPath
    var index = 1
    while index < arguments.count {
        guard arguments[index] == "--root", arguments.indices.contains(index + 1) else {
            throw CheckFailure(description: "usage: check-module-deps.swift [--root <directory>]")
        }
        rootPath = arguments[index + 1]
        index += 2
    }
    return URL(fileURLWithPath: rootPath).standardizedFileURL
}

do {
    let root = try rootURL(from: CommandLine.arguments)
    let graphURL = root.appending(path: "docs/01-architecture/modules.md")
    let packageURL = root.appending(path: "Package.swift")
    let projectURL = root.appending(path: "project.yml")
    guard FileManager.default.fileExists(atPath: packageURL.path) else {
        throw CheckFailure(description: "\(packageURL.path): file is missing")
    }
    guard FileManager.default.fileExists(atPath: projectURL.path) else {
        throw CheckFailure(description: "\(projectURL.path): file is missing")
    }

    let graph = try makeGraph(from: graphBlocks(from: graphURL), source: graphURL)
    let packageDump = try runJSONCommand(
        executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
        arguments: ["swift", "package", "dump-package", "--package-path", root.path],
        workingDirectory: root,
        source: packageURL
    )
    let packageTargets = try packageTargets(from: packageDump, source: packageURL)

    guard let xcodegen = xcodegenExecutable(root: root) else {
        throw CheckFailure(
            description: "\(projectURL.path): pinned XcodeGen is missing; run scripts/bootstrap"
        )
    }
    let projectDump = try runJSONCommand(
        executable: xcodegen,
        arguments: ["dump", "--type", "json", "--spec", projectURL.path, "--project-root", root.path],
        workingDirectory: root,
        source: projectURL
    )
    let targets = try xcodeTargets(from: projectDump, source: projectURL)
    let xcodePackages = try xcodePackageNames(from: projectDump, source: projectURL)
    let failures = check(
        root: root,
        graph: graph,
        packageTargets: packageTargets,
        xcodeTargets: targets,
        xcodePackages: xcodePackages,
        packageURL: packageURL,
        projectURL: projectURL
    )
    if failures.isEmpty {
        print("check-module-deps: passed")
    } else {
        for failure in failures {
            fputs("check-module-deps: \(failure)\n", stderr)
        }
        exit(1)
    }
} catch let failure as CheckFailure {
    fputs("check-module-deps: \(failure.description)\n", stderr)
    exit(1)
} catch {
    fputs("check-module-deps: unexpected error: \(error)\n", stderr)
    exit(1)
}
