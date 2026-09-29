import Foundation

/// Structured fields automatically appended to each log entry.
public struct LogContext: Equatable, Sendable {
    /// The full UUID of the current operation.
    public var operationID: String?

    /// The Android package identifier, when one applies.
    public var packageID: String?

    /// The Android display identifier, when one applies.
    public var displayID: String?

    /// The Android session identifier, when one applies.
    public var sessionID: String?

    /// Creates a set of public-safe identifiers to append to a log entry.
    public init(
        operationID: String? = nil,
        packageID: String? = nil,
        displayID: String? = nil,
        sessionID: String? = nil
    ) {
        self.operationID = operationID
        self.packageID = packageID
        self.displayID = displayID
        self.sessionID = sessionID
    }
}

/// One structured entry passed from `APKLogger` to a `LogSink`.
public struct LogEntry: CustomReflectable, CustomStringConvertible, Sendable {
    /// The time at which the entry was created.
    public let timestamp: Date

    /// The severity of the entry.
    public let level: LogLevel

    /// The fixed subsystem name.
    public let subsystem: LogSubsystem

    /// The statically declared category name.
    public let category: String

    /// The message with private values replaced by `<private>`.
    public let publicMessage: String

    /// The full message when private values were interpolated.
    let privateMessage: String?

    /// The full operation identifier, if present.
    public let operationID: String?

    /// The package identifier, if present.
    public let packageID: String?

    /// The display identifier, if present.
    public let displayID: String?

    /// The session identifier, if present.
    public let sessionID: String?

    /// The qualified error code, if this entry records a failure.
    public let errorCode: String?

    /// A safe description that excludes the private message representation.
    public var description: String {
        "<log entry \(subsystem.rawValue)/\(category) \(level.rawValue)>"
    }

    /// Exposes public fields only, even when a caller uses reflection.
    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                ("timestamp", timestamp),
                ("level", level),
                ("subsystem", subsystem),
                ("category", category),
                ("publicMessage", publicMessage),
                ("operationID", operationID as Any),
                ("packageID", packageID as Any),
                ("displayID", displayID as Any),
                ("sessionID", sessionID as Any),
                ("errorCode", errorCode as Any),
            ],
            displayStyle: .struct,
            ancestorRepresentation: .suppressed
        )
    }

    /// Creates a log entry with public-safe structured fields.
    init(
        timestamp: Date = .now,
        level: LogLevel,
        subsystem: LogSubsystem,
        category: String,
        publicMessage: String,
        privateMessage: String? = nil,
        context: LogContext = LogContext(),
        errorCode: String? = nil
    ) {
        self.timestamp = timestamp
        self.level = level
        self.subsystem = subsystem
        self.category = category
        self.publicMessage = Self.escapedSeparator(in: publicMessage)
        self.privateMessage = privateMessage.map(Self.escapedSeparator(in:))
        operationID = context.operationID
        packageID = context.packageID
        displayID = context.displayID
        sessionID = context.sessionID
        self.errorCode = errorCode
    }

    /// The exact U+001F-delimited string used when a private representation exists.
    var encodedMessage: String {
        guard let privateMessage else { return formattedPublicMessage }
        return "\(formattedPublicMessage)\u{1F}\(formattedPrivateMessage ?? privateMessage)"
    }

    /// The public message followed by its structured fields.
    public var formattedPublicMessage: String {
        publicMessage + structuredSuffix
    }

    /// The private message followed by the same structured fields.
    var formattedPrivateMessage: String? {
        privateMessage.map { $0 + structuredSuffix }
    }

    /// The structured fields formatted for public logs and file mirrors.
    public var structuredSuffix: String {
        var fields: [String] = []
        if let operationID {
            fields.append("op=\(String(operationID.prefix(8)))")
        }
        if let packageID {
            fields.append("pkg=\(Self.escapedSeparator(in: packageID))")
        }
        if let displayID {
            fields.append("disp=\(Self.escapedSeparator(in: displayID))")
        }
        if let sessionID {
            fields.append("sess=\(Self.escapedSeparator(in: sessionID))")
        }
        if let errorCode {
            fields.append("err=\(Self.escapedSeparator(in: errorCode))")
        }
        guard !fields.isEmpty else { return "" }
        return " " + fields.joined(separator: " ")
    }

    private static func escapedSeparator(in value: String) -> String {
        value.replacingOccurrences(of: "\u{1F}", with: "\\u{001F}")
    }
}
