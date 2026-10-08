#!/usr/bin/env swift
import CoreFoundation
import Foundation

struct CatalogVariant {
    let name: String
    let message: [String: String]?
    let remediation: [String: String]?
    let action: String?
    let doc: [String: Any]
}

struct CatalogEntry {
    let code: String
    let parameters: [String]
    let message: [String: String]?
    let remediation: [String: String]?
    let action: String?
    let cliExit: Any
    let cliExitRule: String?
    let variants: [CatalogVariant]
    let transparent: Bool
    let retired: Bool
    let doc: [String: Any]
}

let rootURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let jsonURL = rootURL.appendingPathComponent("Packages/DiagnosticsCore/ErrorCatalog/errors.json")
let generatedURL = rootURL.appendingPathComponent(
    "Packages/DiagnosticsCore/Sources/DiagnosticsCore/Errors/ErrorCatalog.generated.swift"
)
let markdownURL = rootURL.appendingPathComponent("docs/03-reference/error-catalog.md")
let remediationActions: Set<String> = [
    "none", "retry", "openTroubleshooting", "restartAndroid", "startGraphicsSafeMode",
    "openRuntimeSettings", "openStorageSettings", "openPrivacySettings",
    "openLoginItemsSettings", "openNotificationSettings", "openDownloadsPage",
    "updateAPKRun", "updateAndroid", "updateMacApp", "createMacApp", "reinstallApp",
    "reportProblem",
]

func fail(_ message: String) -> Never {
    fputs("errorgen: \(message)\n", stderr)
    exit(1)
}

func requireString(_ value: Any?, _ key: String, _ context: String) -> String {
    guard let string = value as? String, !string.isEmpty else {
        fail("\(context).\(key) must be a non-empty string")
    }
    return string
}

func optionalStrings(_ value: Any?, _ key: String, _ context: String) -> [String: String]? {
    guard let value else { return nil }
    guard let dictionary = value as? [String: Any] else {
        fail("\(context).\(key) must be an object of language strings")
    }
    var result: [String: String] = [:]
    for (language, text) in dictionary {
        guard let text = text as? String else {
            fail("\(context).\(key).\(language) must be a string")
        }
        result[language] = text
    }
    return result
}

func validateNonemptyTexts(_ values: [String: String]?, _ context: String) {
    for (language, text) in values ?? [:] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail("\(context).\(language) must not be empty")
        }
    }
}

func nonemptyText(_ value: String?) -> String? {
    guard let value,
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
        return nil
    }
    return value
}

func loadEntries(release: Bool) throws -> [CatalogEntry] {
    let data = try Data(contentsOf: jsonURL)
    guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        document["version"] as? Int == 1,
        let rawEntries = document["errors"] as? [[String: Any]]
    else {
        fail("errors.json must have version 1 and an errors array")
    }

    // Keep this set aligned with the user-facing CLI contract in cli.md §3.3.
    let knownExits: Set<Int> = [0, 1, 2, 3, 4, 5, 64, 69, 70, 75, 130]
    var entries: [CatalogEntry] = []
    var codes = Set<String>()
    for raw in rawEntries {
        let code = requireString(raw["code"], "code", "entry")
        guard
            code.range(
                of: #"^[A-Za-z][A-Za-z0-9]*\.[a-z][A-Za-z0-9]*$"#,
                options: .regularExpression
            ) != nil
        else {
            fail("\(code) is not a valid qualified error code")
        }
        guard
            code.hasPrefix("vm.") || code.hasPrefix("graphics.") || code.hasPrefix("runtime.")
                || code.hasPrefix("image.") || code.hasPrefix("cli.")
        else {
            fail("\(code) is outside the vm/graphics/runtime/image/cli catalog scope")
        }
        guard codes.insert(code).inserted else {
            fail("duplicate code \(code)")
        }
        guard let parameters = raw["parameters"] as? [String],
            Set(parameters).count == parameters.count
        else {
            fail("\(code).parameters must be a unique string array")
        }
        let message = optionalStrings(raw["message"], "message", code)
        let remediation = optionalStrings(raw["remediation"], "remediation", code)
        validateNonemptyTexts(message, "\(code).message")
        validateNonemptyTexts(remediation, "\(code).remediation")
        let action = raw["action"] as? String
        if let action, !remediationActions.contains(action) {
            fail("\(code).action is not a RemediationAction")
        }
        let transparent = raw["transparent"] as? Bool ?? false
        let retired = raw["retired"] as? Bool ?? false
        let cliExit = raw["cliExit"] as Any
        let cliExitRule = raw["cliExitRule"] as? String
        let doc = raw["doc"] as? [String: Any] ?? [:]
        if code.hasPrefix("vm.") {
            let table = doc["table"] as? String
            guard table == "vmFailure" || table == "vmConfiguration" else {
                fail("\(code).doc.table must be vmFailure or vmConfiguration")
            }
            let requiredFields =
                table == "vmFailure"
                ? ["case", "when", "raisedBy", "ref"]
                : ["case", "cause", "exitDisplay"]
            for field in requiredFields {
                guard nonemptyText(doc[field] as? String) != nil else {
                    fail("\(code).doc.\(field) must be a non-empty string")
                }
            }
        } else {
            for field in ["case", "when", "raisedBy", "ref"] {
                guard nonemptyText(doc[field] as? String) != nil else {
                    fail("\(code).doc.\(field) must be a non-empty string")
                }
            }
        }

        if transparent {
            guard message == nil, action == nil else {
                fail("\(code): transparent entries cannot define message or action")
            }
        } else {
            guard message?["en"] != nil, action != nil else {
                fail("\(code): non-transparent entries need English message and action")
            }
        }
        if release {
            guard message?["ja"] != nil || transparent,
                remediation == nil || remediation?["ja"] != nil
            else {
                fail("\(code): release entries need Japanese message and remediation")
            }
        }

        if let fixedExit = cliExit as? Int,
            let number = cliExit as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        {
            guard knownExits.contains(fixedExit) else {
                fail("\(code): unsupported cliExit \(fixedExit)")
            }
        } else if let symbolicExit = cliExit as? String {
            guard symbolicExit == "cause", transparent else {
                fail("\(code): cliExit \"cause\" is only valid on transparent entries")
            }
        } else {
            fail("\(code).cliExit must be an integer or \"cause\"")
        }
        if let cliExitRule {
            guard cliExitRule == "allConfigurationItemsInternalOrFailure",
                code == "vm.configurationInvalid",
                (cliExit as? Int) == 1
            else {
                fail("\(code): unsupported cliExitRule \(cliExitRule)")
            }
        }

        let variants = (raw["variants"] as? [String: Any] ?? [:]).map { name, value in
            guard let value = value as? [String: Any] else {
                fail("\(code).variants.\(name) must be an object")
            }
            let variantDoc = value["doc"] as? [String: Any] ?? [:]
            let variantMessage = optionalStrings(
                value["message"],
                "message",
                "\(code).variants.\(name)"
            )
            let variantRemediation = optionalStrings(
                value["remediation"],
                "remediation",
                "\(code).variants.\(name)"
            )
            validateNonemptyTexts(
                variantMessage,
                "\(code).variants.\(name).message"
            )
            validateNonemptyTexts(
                variantRemediation,
                "\(code).variants.\(name).remediation"
            )
            let variantAction = value["action"] as? String
            if let variantAction, !remediationActions.contains(variantAction) {
                fail("\(code).variants.\(name).action is not a RemediationAction")
            }
            if let variantMessage, variantMessage["en"] == nil {
                fail("\(code).variants.\(name).message needs English text")
            }
            if let variantRemediation, variantRemediation["en"] == nil {
                fail("\(code).variants.\(name).remediation needs English text")
            }
            if release {
                guard variantMessage == nil || variantMessage?["ja"] != nil,
                    variantRemediation == nil || variantRemediation?["ja"] != nil
                else {
                    fail("\(code).variants.\(name) needs Japanese text for release")
                }
            }
            return CatalogVariant(
                name: name,
                message: variantMessage,
                remediation: variantRemediation,
                action: variantAction,
                doc: variantDoc
            )
        }.sorted { $0.name < $1.name }

        for (textName, texts) in [("message", message), ("remediation", remediation)] {
            guard let texts else { continue }
            for (language, text) in texts {
                for placeholder in placeholders(in: text) where !parameters.contains(placeholder) {
                    fail("\(code).\(textName).\(language) uses undeclared {\(placeholder)}")
                }
            }
        }
        for variant in variants {
            for (textName, texts) in [("message", variant.message), ("remediation", variant.remediation)] {
                guard let texts else { continue }
                for (language, text) in texts {
                    for placeholder in placeholders(in: text) where !parameters.contains(placeholder) {
                        fail(
                            "\(code).variants.\(variant.name).\(textName).\(language) uses undeclared {\(placeholder)}")
                    }
                }
            }
        }

        entries.append(
            CatalogEntry(
                code: code,
                parameters: parameters,
                message: message,
                remediation: remediation,
                action: action,
                cliExit: cliExit,
                cliExitRule: cliExitRule,
                variants: variants,
                transparent: transparent,
                retired: retired,
                doc: doc
            )
        )
    }
    return entries
}

func placeholders(in text: String) -> [String] {
    guard let expression = try? NSRegularExpression(pattern: #"\{([A-Za-z][A-Za-z0-9]*)\}"#) else {
        return []
    }
    let nsText = text as NSString
    return expression.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        .compactMap { match in
            guard match.numberOfRanges == 2 else { return nil }
            return nsText.substring(with: match.range(at: 1))
        }
}

func swiftLiteral(_ string: String) -> String {
    String(reflecting: string)
}

func swiftStrings(_ values: [String: String]?) -> String {
    guard let values else { return "nil" }
    let contents = values.sorted(by: { $0.key < $1.key }).map {
        "\(swiftLiteral($0.key)): \(swiftLiteral($0.value))"
    }
    return "[" + contents.joined(separator: ", ") + "]"
}

func swiftAction(_ action: String?) -> String {
    guard let action else { return "nil" }
    return "RemediationAction.\(action)"
}

func swiftExit(_ value: Any) -> String {
    if let code = value as? Int {
        return ".code(\(code))"
    }
    return ".cause"
}

func renderSwift(_ entries: [CatalogEntry]) -> String {
    var lines = [
        "// Generated by scripts/errorgen.swift. Do not edit by hand.",
        "import Foundation",
        "",
        "public enum GeneratedErrorCatalog {",
        "    public static let entries: [String: ErrorCatalogEntry] = [",
    ]
    for entry in entries {
        let variants: String
        if entry.variants.isEmpty {
            variants = "[:]"
        } else {
            let values = entry.variants.map { variant in
                let fields = [
                    "message: \(swiftStrings(variant.message))",
                    "remediation: \(swiftStrings(variant.remediation))",
                    "action: \(swiftAction(variant.action))",
                ].joined(separator: ", ")
                return "\(swiftLiteral(variant.name)): ErrorCatalogVariant(\(fields))"
            }
            variants = "[" + values.joined(separator: ", ") + "]"
        }
        let parameters = "[" + entry.parameters.sorted().map(swiftLiteral).joined(separator: ", ") + "]"
        let action = swiftAction(entry.action)
        let rule = entry.cliExitRule.map { ".\($0)" } ?? "nil"
        lines.append(
            "        \(swiftLiteral(entry.code)): ErrorCatalogEntry("
                + "code: \(swiftLiteral(entry.code)), "
                + "parameters: Set(\(parameters)), "
                + "message: \(swiftStrings(entry.message)), "
                + "remediation: \(swiftStrings(entry.remediation)), "
                + "action: \(action), "
                + "cliExit: \(swiftExit(entry.cliExit)), "
                + "cliExitRule: \(rule), "
                + "variants: \(variants), "
                + "transparent: \(entry.transparent), "
                + "retired: \(entry.retired)"
                + "),"
        )
    }
    lines += ["    ]", "}", ""]
    return lines.joined(separator: "\n")
}

func markdownText(_ entry: CatalogEntry, key: String, language: String = "en") -> String {
    if let value = entry.doc[key] as? String {
        return value
    }
    let texts = entry.doc[key] as? [String: String] ?? [:]
    return texts[language] ?? ""
}

func escapeCell(_ text: String) -> String {
    text.replacingOccurrences(of: "|", with: #"&#124;"#)
        .replacingOccurrences(of: "\n", with: " ")
}

func exitDisplay(_ entry: CatalogEntry) -> String {
    if let display = entry.doc["exitDisplay"] as? String {
        return display
    }
    if let value = entry.cliExit as? Int {
        return String(value)
    }
    return "cause"
}

func actionDisplay(_ action: String?, remediation: String?) -> String {
    guard let remediation, !remediation.isEmpty else {
        return "— `\(action ?? "none")`"
    }
    return "\"\(escapeCell(remediation))\" `\(action ?? "none")`"
}

func renderVMMarkdown(_ entries: [CatalogEntry]) -> String {
    let failures = entries.filter { $0.doc["table"] as? String == "vmFailure" }
    let configurations = entries.filter { $0.doc["table"] as? String == "vmConfiguration" }
    var lines = [
        "### 5.1 `VMFailure`",
        "",
        "| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for entry in failures {
        let row = [
            "`\(markdownText(entry, key: "case"))`",
            "`\(entry.code)`",
            markdownText(entry, key: "when"),
            markdownText(entry, key: "raisedBy"),
            "\"\(escapeCell(entry.message?["en"] ?? ""))\"",
            actionDisplay(entry.action, remediation: entry.remediation?["en"]),
            exitDisplay(entry),
            markdownText(entry, key: "ref"),
        ]
        lines.append("| " + row.map(escapeCell).joined(separator: " | ") + " |")
    }
    lines += [
        "",
        "### 5.2 `VMConfigurationFailure`",
        "",
        "| Case | Code | Cause | Exit |",
        "|---|---|---|---|",
    ]
    for entry in configurations {
        let row = [
            "`\(markdownText(entry, key: "case"))`",
            "`\(entry.code)`",
            markdownText(entry, key: "cause"),
            exitDisplay(entry),
        ]
        lines.append("| " + row.map(escapeCell).joined(separator: " | ") + " |")
    }

    let groups = Dictionary(grouping: configurations) { entry in
        [
            entry.message?["en"] ?? "",
            entry.remediation?["en"] ?? "",
            entry.action ?? "none",
        ].joined(separator: "\u{1f}")
    }
    lines += [
        "",
        "Texts:",
        "",
        "| Entries | Message | Remediation · action |",
        "|---|---|---|",
    ]
    for key in groups.keys.sorted() {
        guard let group = groups[key], let first = group.first else { continue }
        let codes = group.map(\.code).sorted().map { "`\($0)`" }.joined(separator: ", ")
        let row = [
            codes,
            "\"\(escapeCell(first.message?["en"] ?? ""))\"",
            actionDisplay(first.action, remediation: first.remediation?["en"]),
        ]
        lines.append("| " + row.map(escapeCell).joined(separator: " | ") + " |")
    }
    return lines.joined(separator: "\n")
}

func renderCLIMarkdown(_ entries: [CatalogEntry]) -> String {
    var lines = [
        "| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for entry in entries {
        let row = [
            "`\(markdownText(entry, key: "case"))`",
            "`\(entry.code)`",
            markdownText(entry, key: "when"),
            markdownText(entry, key: "raisedBy"),
            "\"\(escapeCell(entry.message?["en"] ?? ""))\"",
            actionDisplay(entry.action, remediation: entry.remediation?["en"]),
            exitDisplay(entry),
            markdownText(entry, key: "ref"),
        ]
        lines.append("| " + row.map(escapeCell).joined(separator: " | ") + " |")

        for variant in entry.variants {
            let variantRow = [
                "—",
                "`\(entry.code) / \(variant.name)`",
                variant.doc["when"] as? String
                    ?? markdownText(entry, key: "when"),
                variant.doc["raisedBy"] as? String
                    ?? markdownText(entry, key: "raisedBy"),
                "\"\(escapeCell(nonemptyText(variant.message?["en"]) ?? entry.message?["en"] ?? ""))\"",
                actionDisplay(
                    variant.action ?? entry.action,
                    remediation: variant.remediation?["en"] ?? entry.remediation?["en"]
                ),
                exitDisplay(entry),
                variant.doc["ref"] as? String ?? markdownText(entry, key: "ref"),
            ]
            lines.append("| " + variantRow.map(escapeCell).joined(separator: " | ") + " |")
        }
    }
    return lines.joined(separator: "\n")
}

func renderMarkdown(_ entries: [CatalogEntry], source: String) -> String {
    var result = source
    for domain in ["vm", "graphics", "runtime", "image", "cli"] {
        let begin = "<!-- errorgen:begin \(domain) -->"
        let end = "<!-- errorgen:end \(domain) -->"
        guard let beginRange = result.range(of: begin),
            let endRange = result.range(of: end),
            beginRange.upperBound <= endRange.lowerBound
        else {
            fail("error-catalog.md is missing ordered markers for \(domain)")
        }
        let domainEntries = entries.filter { $0.code.hasPrefix("\(domain).") }
        let body: String
        switch domain {
        case "vm":
            body = renderVMMarkdown(domainEntries)
        default:
            body = renderCLIMarkdown(domainEntries)
        }
        result.replaceSubrange(beginRange.upperBound..<endRange.lowerBound, with: "\n\(body)\n")
    }
    return result
}

func writeOrCheck(_ contents: String, at url: URL, check: Bool) throws {
    if check {
        let existing = try String(contentsOf: url, encoding: .utf8)
        guard existing == contents else {
            fail("\(url.path) is stale; run swift scripts/errorgen.swift")
        }
    } else {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}

do {
    let arguments = Set(CommandLine.arguments.dropFirst())
    let check = arguments.contains("--check")
    let release = arguments.contains("--release")
    let markdownOnly = arguments.contains("--markdown")
    let knownFlags: Set<String> = ["--check", "--release", "--markdown"]
    guard arguments.isSubset(of: knownFlags) else {
        fail("usage: swift scripts/errorgen.swift [--markdown] [--check] [--release]")
    }
    let entries = try loadEntries(release: release)
    if !markdownOnly {
        try writeOrCheck(renderSwift(entries), at: generatedURL, check: check)
    }
    if markdownOnly || check {
        let source = try String(contentsOf: markdownURL, encoding: .utf8)
        let output = renderMarkdown(entries, source: source)
        if check {
            guard output == source else {
                fail("error-catalog.md generated regions are stale; run swift scripts/errorgen.swift --markdown")
            }
        } else {
            try output.write(to: markdownURL, atomically: true, encoding: .utf8)
        }
    }
    if !check {
        print(markdownOnly ? "Updated error-catalog.md." : "Updated ErrorCatalog.generated.swift.")
    }
} catch {
    fail(String(describing: error))
}
