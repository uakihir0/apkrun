import Foundation

/// A command-line exit rule attached to a catalog entry.
public enum CatalogCLIExit: Equatable, Sendable {
    case code(Int)
    case cause
}

/// A data-driven rule for errors whose exit status depends on their contents.
public enum CatalogCLIExitRule: String, Equatable, Sendable {
    case allConfigurationItemsInternalOrFailure
}

/// Localized text and an optional action for a reason-specific catalog variant.
public struct ErrorCatalogVariant: Equatable, Sendable {
    /// Localized message templates selected for a specific reason.
    public let message: [String: String]?

    /// Localized remediation templates selected for a specific reason.
    public let remediation: [String: String]?

    /// An optional action associated with this reason.
    public let action: RemediationAction?

    /// Creates localized presentation overrides for one reason.
    public init(
        message: [String: String]? = nil,
        remediation: [String: String]? = nil,
        action: RemediationAction? = nil
    ) {
        self.message = message
        self.remediation = remediation
        self.action = action
    }
}

/// One generated entry from `ErrorCatalog/errors.json`.
public struct ErrorCatalogEntry: Equatable, Sendable {
    /// The stable qualified error code.
    public let code: String

    /// The parameter names accepted by the message templates.
    public let parameters: Set<String>

    /// Localized message templates.
    public let message: [String: String]?

    /// Localized remediation templates.
    public let remediation: [String: String]?

    /// The suggested user action.
    public let action: RemediationAction?

    /// The fixed exit code or cause-based behavior.
    public let cliExit: CatalogCLIExit

    /// An optional rule that computes the CLI exit status.
    public let cliExitRule: CatalogCLIExitRule?

    /// Reason-specific message, remediation, and action overrides.
    public let variants: [String: ErrorCatalogVariant]

    /// Whether presentation and exit status pass through to the underlying cause.
    public let transparent: Bool

    /// Whether the catalog entry is retained only for compatibility.
    public let retired: Bool

    /// Creates one typed error catalog entry.
    public init(
        code: String,
        parameters: Set<String>,
        message: [String: String]?,
        remediation: [String: String]?,
        action: RemediationAction?,
        cliExit: CatalogCLIExit,
        cliExitRule: CatalogCLIExitRule? = nil,
        variants: [String: ErrorCatalogVariant] = [:],
        transparent: Bool = false,
        retired: Bool = false
    ) {
        self.code = code
        self.parameters = parameters
        self.message = message
        self.remediation = remediation
        self.action = action
        self.cliExit = cliExit
        self.cliExitRule = cliExitRule
        self.variants = variants
        self.transparent = transparent
        self.retired = retired
    }
}

/// Runtime access to the checked-in catalog generated from `errors.json`.
public enum ErrorCatalog {
    /// The generic entry shown when no code in an error chain is known.
    public static let unknownEntry = ErrorCatalogEntry(
        code: "unknown",
        parameters: [],
        message: ["en": "APKRun couldn't complete the operation."],
        remediation: ["en": "Update APKRun. If it happens again, create a diagnostics report."],
        action: .updateAPKRun,
        cliExit: .code(1)
    )

    /// All active and retired entries, keyed by their stable qualified code.
    public static let entries = GeneratedErrorCatalog.entries

    /// Returns the catalog entry for a qualified error code, if known.
    public static func entry(for code: String) -> ErrorCatalogEntry? {
        entries[code]
    }

    /// Returns the fixed exit code for a catalog entry, or its dynamic rule's fallback.
    public static func cliExit(for code: String) -> Int? {
        guard let entry = entries[code] else {
            return nil
        }
        guard case .code(let code) = entry.cliExit else {
            return nil
        }
        return code
    }

    /// Returns the CLI exit code for a typed error, resolving transparent and unknown codes.
    public static func cliExit(for error: any APKRunError) -> Int {
        cliExit(for: error, entries: entries)
    }

    static func cliExit(
        for error: any APKRunError,
        entries: [String: ErrorCatalogEntry]
    ) -> Int {
        cliExit(for: error, visited: [], entries: entries)
    }

    /// Resolves an error to the first known error and entry that supply user-facing text.
    static func presentationSource(
        for error: any APKRunError,
        entries: [String: ErrorCatalogEntry] = ErrorCatalog.entries
    ) -> (error: any APKRunError, entry: ErrorCatalogEntry) {
        presentationSource(for: error, visited: [], entries: entries)
    }

    private static func cliExit(
        for error: any APKRunError,
        visited: Set<String>,
        entries: [String: ErrorCatalogEntry]
    ) -> Int {
        guard !visited.contains(error.qualifiedCode) else {
            return 1
        }
        var visited = visited
        visited.insert(error.qualifiedCode)
        guard let entry = entries[error.qualifiedCode] else {
            return error.cause.map { cliExit(for: $0, visited: visited, entries: entries) } ?? 1
        }

        if entry.transparent || entry.cliExit == .cause {
            return error.cause.map { cliExit(for: $0, visited: visited, entries: entries) } ?? 1
        }

        if entry.cliExitRule == .allConfigurationItemsInternalOrFailure {
            guard case .text(let rawItems)? = error.parameters["items"] else {
                return 1
            }
            let items =
                rawItems
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !items.isEmpty else {
                return 1
            }
            let allInternal = items.allSatisfy { item in
                guard let itemEntry = entries["vm.\(item)"],
                    case .code(let code) = itemEntry.cliExit
                else {
                    return false
                }
                return code == 70
            }
            return allInternal ? 70 : 1
        }

        if case .code(let code) = entry.cliExit {
            return code
        }
        return error.cause.map { cliExit(for: $0, visited: visited, entries: entries) } ?? 1
    }

    private static func presentationSource(
        for error: any APKRunError,
        visited: Set<String>,
        entries: [String: ErrorCatalogEntry]
    ) -> (error: any APKRunError, entry: ErrorCatalogEntry) {
        guard !visited.contains(error.qualifiedCode) else {
            return (error, unknownEntry)
        }
        if let entry = entries[error.qualifiedCode], !entry.transparent {
            return (error, entry)
        }
        if let cause = error.cause {
            var visited = visited
            visited.insert(error.qualifiedCode)
            return presentationSource(for: cause, visited: visited, entries: entries)
        }
        return (error, unknownEntry)
    }
}
