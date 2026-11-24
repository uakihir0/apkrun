import Foundation

/// The lifecycle state of an app session on the wire (host-ui.md §5.2).
///
/// `starting` covers every pre-running registry state; sessions that ended
/// are reported through ``SessionChange/ended`` and never appear in
/// `listSessions`.
public enum WireSessionPhase: String, Codable, Sendable, Equatable {
    /// The session exists but the app is not on screen yet.
    case starting
    /// The app is on screen and takes input.
    case running
    /// The window is hidden or minimized; the app still takes input.
    case backgrounded
    /// The session is closing.
    case closing
}

/// One app session on the wire.
public struct WireSessionSummary: Codable, Equatable, Sendable {
    /// The runtime's session identity.
    public var sessionID: UUID
    /// The Android package the session belongs to.
    public var packageID: RuntimePackageID
    /// The current lifecycle phase.
    public var phase: WireSessionPhase

    /// Creates a session summary.
    public init(sessionID: UUID, packageID: RuntimePackageID, phase: WireSessionPhase) {
        self.sessionID = sessionID
        self.packageID = packageID
        self.phase = phase
    }
}

/// A `listSessions` control request; has no parameters (host-ui.md §5.2).
public struct RuntimeListSessionsControlRequest: Codable, Equatable, Sendable {
    /// The authenticated request metadata.
    public let header: APIRequestHeader

    /// Creates the request.
    public init(header: APIRequestHeader) {
        self.header = header
    }
}

/// The `listSessions` reply.
public struct RuntimeListSessionsControlReply: Codable, Equatable, Sendable {
    /// The live sessions, when the request succeeded.
    public var sessions: [WireSessionSummary]?
    /// The typed failure, when the request failed.
    public var error: RuntimeWireError?

    /// Creates the reply.
    public init(sessions: [WireSessionSummary]? = nil, error: RuntimeWireError? = nil) {
        self.sessions = sessions
        self.error = error
    }
}

/// A session change published on the `sessions` event topic (API 1.23).
public enum SessionChange: Codable, Equatable, Sendable {
    /// A session appeared or changed phase.
    case changed(WireSessionSummary)
    /// A session ended; `reason` is the `SessionEndReason` case name.
    case ended(sessionID: UUID, packageID: RuntimePackageID, reason: String)
    /// The daemon reported a session change added by a newer API version.
    case unknown

    private enum CaseKey: String, CodingKey {
        case changed
        case ended
    }

    private enum AssociatedKey: String, CodingKey {
        case first = "_0"
        case package
        case reason
    }

    /// Decodes a session change or preserves one added by a newer API version.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RuntimeEventCodingKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected one session change case.")
            )
        }
        switch key.stringValue {
        case "changed":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .changed(try payload.decode(WireSessionSummary.self, forKey: .first))
        case "ended":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .ended(
                sessionID: try payload.decode(UUID.self, forKey: .first),
                packageID: try payload.decode(RuntimePackageID.self, forKey: .package),
                reason: try payload.decode(String.self, forKey: .reason)
            )
        default:
            self = .unknown
        }
    }

    /// Encodes the session change as a single-keyed object.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CaseKey.self)
        switch self {
        case .changed(let summary):
            var payload = container.nestedContainer(
                keyedBy: AssociatedKey.self, forKey: .changed)
            try payload.encode(summary, forKey: .first)
        case .ended(let sessionID, let packageID, let reason):
            var payload = container.nestedContainer(
                keyedBy: AssociatedKey.self, forKey: .ended)
            try payload.encode(sessionID, forKey: .first)
            try payload.encode(packageID, forKey: .package)
            try payload.encode(reason, forKey: .reason)
        case .unknown:
            throw EncodingError.invalidValue(
                self,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Unknown session changes cannot be encoded.")
            )
        }
    }
}

/// The close policy a `closeSession` request applies to a package session
/// (display-and-windowing.md §7.6).
public enum WireClosePolicy: String, Codable, Sendable, Equatable {
    /// The Guest Agent finishes the session's tasks; Android may keep the
    /// process cached.
    case stop
    /// The root task moves to display 0 behind the launcher and the daemon
    /// holds a background-task activity until the task ends.
    case keepRunning
}

/// A `closeSession` control request (runtime-api.md §6.1, API 1.39).
public struct RuntimeCloseSessionControlRequest: Codable, Equatable, Sendable {
    /// The authenticated request metadata.
    public let header: APIRequestHeader
    /// The package whose session should close.
    public let packageID: RuntimePackageID
    /// The policy to apply; `nil` reads the package's saved
    /// `window.closeBehavior`.
    public let policy: WireClosePolicy?

    /// Creates the request.
    public init(header: APIRequestHeader, packageID: RuntimePackageID, policy: WireClosePolicy? = nil) {
        self.header = header
        self.packageID = packageID
        self.policy = policy
    }
}

/// The `closeSession` reply.
public struct RuntimeCloseSessionControlReply: Codable, Equatable, Sendable {
    /// Whether a session existed and was closed, when the request succeeded.
    public var hadSession: Bool?
    /// The typed failure, when the request failed.
    public var error: RuntimeWireError?

    /// Creates the reply.
    public init(hadSession: Bool? = nil, error: RuntimeWireError? = nil) {
        self.hadSession = hadSession
        self.error = error
    }
}
