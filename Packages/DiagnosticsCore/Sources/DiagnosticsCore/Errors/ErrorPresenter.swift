import Foundation

private struct RemediationPresentation {
    let text: String?
    let action: RemediationAction?
}

/// The alert content a GUI surface can show without understanding catalog internals.
public struct PresentedErrorHint: Equatable, Sendable {
    /// The stable code associated with the hint.
    public let code: String

    /// The rendered hint text.
    public let message: String

    /// Creates one user-facing hint.
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// A complete GUI-ready presentation of a typed error.
public struct PresentedError: Equatable, Sendable {
    /// The stable qualified error code.
    public let code: String

    /// The short title shown in the alert.
    public let title: String

    /// The main remediation text shown in the alert.
    public let body: String

    /// Additional cause or item-specific hints.
    public let hints: [PresentedErrorHint]

    /// The action offered by the error catalog.
    public let action: RemediationAction

    /// Path-free diagnostic details suitable for copying.
    public let copyDetails: String

    /// Creates GUI-ready error content.
    public init(
        code: String,
        title: String,
        body: String,
        hints: [PresentedErrorHint] = [],
        action: RemediationAction,
        copyDetails: String
    ) {
        self.code = code
        self.title = title
        self.body = body
        self.hints = hints
        self.action = action
        self.copyDetails = copyDetails
    }
}

/// Renders typed errors consistently for CLI, JSON, GUI, and Copy Details surfaces.
public struct ErrorPresenter {
    private let locale: Locale
    private let operationID: OperationID?
    private let buildInfo: BuildInfo
    private let imageVersion: String
    private let timestamp: Date

    /// Creates a presenter using the current build and operation context.
    public init(
        locale: Locale = Locale(identifier: Locale.preferredLanguages.first ?? "en"),
        operationID: OperationID? = OperationContext.current?.operationID,
        buildInfo: BuildInfo = .current,
        imageVersion: String = "unknown",
        timestamp: Date = Date()
    ) {
        self.locale = locale
        self.operationID = operationID
        self.buildInfo = buildInfo
        self.imageVersion = imageVersion
        self.timestamp = timestamp
    }

    /// Renders an error as `error:`, `hint:`, and `code:` lines for stderr.
    public func cli(_ error: any APKRunError) -> String {
        let source = ErrorCatalog.presentationSource(for: error)
        let entry = source.entry
        let contentError = source.error
        let variant = selectedVariant(for: contentError, in: entry)
        let message = render(
            template: localized(variant?.message, fallback: entry.message) ?? "",
            error: contentError,
            visited: []
        )
        let heading = ErrorCatalog.cliExit(for: error) == 0 ? "warning" : "error"
        var lines = ["\(heading): \(message)"]

        let listItems = listItems(for: contentError)
        if !listItems.isEmpty {
            lines.append(
                contentsOf: listItems.map { item in
                    "hint: \(item.code): \(item.message)"
                })
        }

        let remediation = remediation(for: error, visited: [])
        if let text = remediation.text, !text.isEmpty {
            lines.append("hint: \(text)")
        }

        let operation = operationID.map { " (operation \($0.short))" } ?? ""
        lines.append("code: \(safeDisplayText(error.qualifiedCode))\(operation)")
        return lines.joined(separator: "\n")
    }

    /// Renders the schema-versioned JSON error envelope used by `--json`.
    public func json(_ error: any APKRunError) -> String {
        let object: [String: Any] = [
            "schemaVersion": 1,
            "error": jsonObject(for: error, includeOperationID: true, visited: []),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let output = String(data: data, encoding: .utf8)
        else {
            return
                #"{"schemaVersion":1,"error":{"code":"unknown","message":"APKRun couldn't complete the operation."}}"#
        }
        return output
    }

    /// Produces alert content for APKRun.app, the menu bar app, and the launcher.
    public func gui(_ error: any APKRunError) -> PresentedError {
        let source = ErrorCatalog.presentationSource(for: error)
        let entry = source.entry
        let contentError = source.error
        let variant = selectedVariant(for: contentError, in: entry)
        let title = render(
            template: localized(variant?.message, fallback: entry.message) ?? "",
            error: contentError,
            visited: []
        )
        let remediation = remediation(for: error, visited: [])
        let body = remediation.text ?? ""
        let hints = listItems(for: contentError).map {
            PresentedErrorHint(code: $0.code, message: $0.message)
        }
        return PresentedError(
            code: error.qualifiedCode,
            title: title,
            body: body,
            hints: hints,
            action: remediation.action ?? variant?.action ?? entry.action ?? .none,
            copyDetails: copyDetails(error)
        )
    }

    /// Produces the single-line, path-free diagnostic string copied by GUI surfaces.
    public func copyDetails(_ error: any APKRunError) -> String {
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        timestampFormatter.formatOptions = [.withInternetDateTime]
        let operation = operationID?.wireValue ?? "unknown"
        var line =
            "APKRun \(buildInfo.marketingVersion) (\(buildInfo.buildNumber))"
            + " · image \(safeToken(imageVersion))"
            + " · \(safeToken(error.qualifiedCode))"
            + " · op \(operation)"
            + " · \(timestampFormatter.string(from: timestamp))"
        if let underlying = underlyingError(in: error, visited: []) {
            line += " · underlying \(safeToken(underlying.domain)) \(underlying.code)"
        }
        return line
    }

    private func jsonObject(
        for error: any APKRunError,
        includeOperationID: Bool,
        visited: Set<String>
    ) -> [String: Any] {
        guard !visited.contains(error.qualifiedCode) else {
            return [
                "code": error.qualifiedCode,
                "message": localized(ErrorCatalog.unknownEntry.message) ?? "",
            ]
        }
        var visited = visited
        visited.insert(error.qualifiedCode)
        let source = ErrorCatalog.presentationSource(for: error)
        let entry = source.entry
        let contentError = source.error
        let variant = selectedVariant(for: contentError, in: entry)
        let message = render(
            template: localized(variant?.message, fallback: entry.message) ?? "",
            error: contentError,
            visited: []
        )
        let remediation = remediation(for: error, visited: [])
        var result: [String: Any] = [
            "code": error.qualifiedCode,
            "message": message,
        ]
        if let text = remediation.text {
            result["remediation"] = text
        }
        let hints = listItems(for: contentError)
        if !hints.isEmpty {
            result["hints"] = hints.map { ["code": $0.code, "message": $0.message] }
        }
        if includeOperationID {
            result["operationID"] = operationID?.wireValue ?? NSNull()
        }
        if let action = remediation.action ?? variant?.action ?? entry.action {
            result["action"] = action.rawValue
        }
        if let underlying = error.underlying {
            result["underlying"] = ["domain": safeToken(underlying.domain), "code": underlying.code]
        }
        if let cause = error.cause {
            result["cause"] = jsonObject(
                for: cause,
                includeOperationID: false,
                visited: visited
            )
        }
        return result
    }

    private func selectedVariant(
        for error: any APKRunError,
        in entry: ErrorCatalogEntry
    ) -> ErrorCatalogVariant? {
        guard case .text(let reason)? = error.parameters["reason"] else {
            return nil
        }
        return entry.variants[reason]
    }

    private func remediation(
        for error: any APKRunError,
        visited: Set<String>
    ) -> RemediationPresentation {
        guard !visited.contains(error.qualifiedCode) else {
            return RemediationPresentation(text: nil, action: nil)
        }
        var visited = visited
        visited.insert(error.qualifiedCode)
        let source = ErrorCatalog.presentationSource(for: error)
        if source.error.qualifiedCode != error.qualifiedCode {
            return remediation(for: source.error, visited: visited)
        }
        let variant = selectedVariant(for: source.error, in: source.entry)
        if let template = localized(variant?.remediation, fallback: source.entry.remediation) {
            return RemediationPresentation(
                text: render(template: template, error: source.error, visited: []),
                action: variant?.action ?? source.entry.action
            )
        }
        if let cause = source.error.cause {
            let inherited = remediation(for: cause, visited: visited)
            if inherited.text != nil {
                return inherited
            }
            return RemediationPresentation(
                text: nil,
                action: variant?.action ?? source.entry.action ?? inherited.action
            )
        }
        return RemediationPresentation(
            text: nil,
            action: variant?.action ?? source.entry.action
        )
    }

    private func listItems(for error: any APKRunError) -> [(code: String, message: String)] {
        guard case .text(let rawItems)? = error.parameters["items"] else {
            return []
        }
        let source = ErrorCatalog.presentationSource(for: error)
        let parentEntry = source.entry
        let contentError = source.error
        let domain =
            contentError.qualifiedCode
            .split(separator: ".", maxSplits: 1)
            .first
            .map(String.init) ?? "vm"
        return
            rawItems
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { item in
                let itemCode = item.contains(".") ? item : "\(domain).\(item)"
                if let variant = parentEntry.variants[item] {
                    let message = localized(variant.message, fallback: parentEntry.message) ?? ""
                    return (
                        "\(parentEntry.code) / \(safeDisplayText(item))",
                        render(template: message, error: contentError, visited: [])
                    )
                }
                guard let itemEntry = ErrorCatalog.entry(for: itemCode) else {
                    return (safeDisplayText(itemCode), localized(ErrorCatalog.unknownEntry.message) ?? "")
                }
                let variant = selectedVariant(for: contentError, in: itemEntry)
                let message = localized(variant?.message, fallback: itemEntry.message) ?? ""
                return (
                    safeDisplayText(itemCode),
                    render(template: message, error: contentError, visited: [])
                )
            }
    }

    private func render(
        template: String,
        error: any APKRunError,
        visited: Set<String>
    ) -> String {
        guard !visited.contains(error.qualifiedCode) else {
            return template
        }
        var visited = visited
        visited.insert(error.qualifiedCode)
        let pattern = #"\{([A-Za-z][A-Za-z0-9]*)\}"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return template
        }
        let source = template as NSString
        let matches = expression.matches(
            in: template,
            range: NSRange(location: 0, length: source.length)
        )
        var result = template
        for match in matches.reversed() {
            guard match.numberOfRanges == 2,
                let nameRange = Range(match.range(at: 1), in: result),
                let wholeRange = Range(match.range(at: 0), in: result)
            else {
                continue
            }
            let name = String(result[nameRange])
            let replacement: String
            if name == "cause", let cause = error.cause {
                let causeSource = ErrorCatalog.presentationSource(for: cause)
                let causeVariant = selectedVariant(for: causeSource.error, in: causeSource.entry)
                replacement = render(
                    template: localized(
                        causeVariant?.message,
                        fallback: causeSource.entry.message
                    ) ?? "",
                    error: causeSource.error,
                    visited: visited
                )
            } else if let parameter = error.parameters[name] {
                replacement = format(parameter)
            } else {
                replacement = ""
            }
            result.replaceSubrange(wholeRange, with: replacement)
        }
        return result
    }

    private func format(_ parameter: ErrorParameter) -> String {
        switch parameter {
        case .text(let value):
            return safeDisplayText(value)
        case .bytes(let value):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            formatter.includesUnit = true
            formatter.isAdaptive = true
            formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
            return formatter.string(fromByteCount: value)
        case .count(let value):
            return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
        case .duration(let value):
            return formatDuration(value)
        case .fileName(let value):
            return safeDisplayText(URL(fileURLWithPath: value).lastPathComponent)
        }
    }

    private func localized(
        _ texts: [String: String]?,
        fallback: [String: String]? = nil
    ) -> String? {
        let preferred = Locale.preferredLanguages(for: locale)
        for language in preferred {
            if let text = nonemptyText(texts?[language]) {
                return text
            }
            if let text = nonemptyText(fallback?[language]) {
                return text
            }
        }
        return nonemptyText(texts?["en"])
            ?? nonemptyText(fallback?["en"])
            ?? texts?.values.compactMap(nonemptyText).sorted().first
            ?? fallback?.values.compactMap(nonemptyText).sorted().first
    }

    private func nonemptyText(_ value: String?) -> String? {
        guard let value,
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return value
    }

    private func underlyingError(
        in error: any APKRunError,
        visited: Set<String>
    ) -> UnderlyingError? {
        guard !visited.contains(error.qualifiedCode) else {
            return nil
        }
        if let underlying = error.underlying {
            return underlying
        }
        guard let cause = error.cause else {
            return nil
        }
        var visited = visited
        visited.insert(error.qualifiedCode)
        return underlyingError(in: cause, visited: visited)
    }

    private func safeToken(_ value: String) -> String {
        let token = value.unicodeScalars
            .filter { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0) }
            .map(String.init)
            .joined()
        return String(token.prefix(160))
    }

    private func safeDisplayText(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            let isControl = CharacterSet.controlCharacters.contains(scalar)
            let isLineSeparator = scalar.value == 0x2028 || scalar.value == 0x2029
            let isBidiControl =
                (0x202A...0x202E).contains(scalar.value)
                || (0x2066...0x2069).contains(scalar.value)
                || scalar.value == 0x200E
                || scalar.value == 0x200F
            if isControl || isLineSeparator || isBidiControl {
                result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private func formatDuration(_ duration: Duration) -> String {
        let components = duration.components
        let seconds =
            Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        if abs(seconds) < 1 {
            return "\(Int((seconds * 1_000).rounded())) ms"
        }
        if abs(seconds) < 60 {
            return "\(seconds.formatted(.number.locale(locale).precision(.fractionLength(0...2)))) s"
        }
        return "\(seconds.formatted(.number.locale(locale).precision(.fractionLength(0)))) s"
    }
}

extension Locale {
    fileprivate static func preferredLanguages(for locale: Locale) -> [String] {
        let identifier = locale.identifier.replacingOccurrences(of: "_", with: "-")
        let language = String(identifier.split(separator: "-").first ?? "en")
        return [identifier, language].uniqued()
    }
}

extension Array where Element: Hashable {
    fileprivate func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
