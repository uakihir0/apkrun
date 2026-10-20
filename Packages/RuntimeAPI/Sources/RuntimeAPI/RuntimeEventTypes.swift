import Foundation

/// A control-endpoint event stream category.
///
/// Topics are request values, so an unrecognized topic is rejected rather than silently ignored.
public enum EventTopic: String, Codable, Equatable, Hashable, Sendable {
    /// Runtime state and boot progress.
    case runtime
    /// Session list changes.
    case sessions
    /// Package state and store operation changes.
    case packages
    /// Package update events.
    case updates
    /// Long-running operation events.
    case operations
    /// Health check changes.
    case health
    /// Runtime maintenance events.
    case maintenance
    /// Wrapper status changes.
    case wrappers
    /// Desktop integration state changes.
    case integrations
}

/// Requests event delivery for one or more topics on the authenticated connection.
public struct RuntimeSubscribeControlRequest: Codable, Equatable, Sendable {
    /// The authenticated request metadata.
    public let header: APIRequestHeader
    /// Topics to add to this connection's subscriptions.
    public let topics: [EventTopic]

    /// Creates a subscription request.
    public init(header: APIRequestHeader, topics: [EventTopic]) {
        self.header = header
        self.topics = topics
    }
}

/// The result or structured failure for a subscription request.
public struct RuntimeSubscribeControlReply: Codable, Equatable, Sendable {
    /// Every topic this connection is subscribed to after success.
    public let result: [EventTopic]?
    /// The structured failure, present when the request was rejected.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: [EventTopic]) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// Requests removal of one or more topics from the authenticated connection.
public struct RuntimeUnsubscribeControlRequest: Codable, Equatable, Sendable {
    /// The authenticated request metadata.
    public let header: APIRequestHeader
    /// Topics to remove from this connection's subscriptions.
    public let topics: [EventTopic]

    /// Creates an unsubscription request.
    public init(header: APIRequestHeader, topics: [EventTopic]) {
        self.header = header
        self.topics = topics
    }
}

/// An empty successful control-operation result.
public struct RuntimeEmpty: Codable, Equatable, Sendable {
    /// Creates an empty result.
    public init() {}
}

/// The result or structured failure for an unsubscription request.
public struct RuntimeUnsubscribeControlReply: Codable, Equatable, Sendable {
    /// The empty success result, present when the request completed.
    public let result: RuntimeEmpty?
    /// The structured failure, present when the request was rejected.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: RuntimeEmpty = RuntimeEmpty()) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// One sequenced event delivered to a subscribed connection.
public struct EventEnvelope: Codable, Equatable, Sendable {
    /// The topic carrying the event.
    public let topic: EventTopic
    /// The per-connection sequence number, assigned from 1 when sent.
    public let seq: UInt64
    /// The time the event was produced.
    public let time: Date
    /// The operation that caused the event, when there is one.
    public let operationID: OperationID?
    /// The event data.
    public let payload: EventPayload

    /// Creates an event envelope.
    public init(
        topic: EventTopic,
        seq: UInt64,
        time: Date,
        operationID: OperationID? = nil,
        payload: EventPayload
    ) {
        self.topic = topic
        self.seq = seq
        self.time = time
        self.operationID = operationID
        self.payload = payload
    }
}

/// The payload carried by an event envelope.
///
/// API 1.9 implements operation events and queue-resynchronization notices. Payloads added by a
/// newer API version decode as ``unknown`` so an older client can keep processing the batch.
public enum EventPayload: Codable, Equatable, Sendable {
    /// Runtime state and boot progress.
    case runtime(RuntimeChange)
    /// An operation started, progressed, or finished.
    case operations(OperationEvent)
    /// Events for the topic were dropped; fetch a fresh snapshot.
    case resyncRequired(EventTopic)
    /// The daemon reported an event kind added by a newer API version.
    case unknown

    private enum CaseKey: String, CodingKey {
        case runtime
        case operations
        case resyncRequired
    }

    private enum AssociatedKey: String, CodingKey {
        case first = "_0"
    }

    /// Decodes a known event payload or preserves a future payload as ``unknown``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RuntimeEventCodingKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected one event payload case.")
            )
        }
        switch key.stringValue {
        case "runtime":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .runtime(try payload.decode(RuntimeChange.self, forKey: .first))
        case "operations":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .operations(try payload.decode(OperationEvent.self, forKey: .first))
        case "resyncRequired":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .resyncRequired(try payload.decode(EventTopic.self, forKey: .first))
        default:
            self = .unknown
        }
    }

    /// Encodes a known event payload.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CaseKey.self)
        switch self {
        case .runtime(let event):
            var payload = container.nestedContainer(keyedBy: AssociatedKey.self, forKey: .runtime)
            try payload.encode(event, forKey: .first)
        case .operations(let event):
            var payload = container.nestedContainer(keyedBy: AssociatedKey.self, forKey: .operations)
            try payload.encode(event, forKey: .first)
        case .resyncRequired(let topic):
            var payload = container.nestedContainer(keyedBy: AssociatedKey.self, forKey: .resyncRequired)
            try payload.encode(topic, forKey: .first)
        case .unknown:
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Unknown event payloads cannot be encoded.")
            )
        }
    }
}

/// Identifies one leased Android display slot.
public struct DisplayID: Codable, Equatable, Hashable, Sendable {
    /// The canonical lowercase UUID string.
    public let rawValue: String

    /// Creates an ID from a canonical lowercase UUID string.
    public init?(rawValue: String) {
        guard let value = UUID(uuidString: rawValue),
            value.uuidString.lowercased() == rawValue
        else {
            return nil
        }
        self.rawValue = rawValue
    }

    /// Decodes a canonical lowercase UUID string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let displayID = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid display ID.")
        }
        self = displayID
    }

    /// Encodes the display ID as its canonical string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A typed, public-safe value used in a diagnostic error message.
public enum WireErrorParameter: Codable, Equatable, Sendable {
    /// Plain public text.
    case text(String)
    /// A byte count.
    case bytes(Int64)
    /// An item count.
    case count(Int)
    /// A duration in milliseconds.
    case durationMs(Int64)
    /// A file's last path component.
    case fileName(String)
    /// A parameter kind added by a newer API version.
    case unknown

    private enum AssociatedKey: String, CodingKey {
        case first = "_0"
    }

    /// Decodes a known parameter, preserving a future kind as ``unknown``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RuntimeEventCodingKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected one wire error parameter case.")
            )
        }
        switch key.stringValue {
        case "text":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .text(try payload.decode(String.self, forKey: .first))
        case "bytes":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .bytes(try payload.decode(Int64.self, forKey: .first))
        case "count":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .count(try payload.decode(Int.self, forKey: .first))
        case "durationMs":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .durationMs(try payload.decode(Int64.self, forKey: .first))
        case "fileName":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            let value = try payload.decode(String.self, forKey: .first)
            self = .fileName(Self.lastPathComponent(value))
        default:
            self = .unknown
        }
    }

    /// Encodes a stable parameter, reducing file names to their last path component.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: RuntimeEventCodingKey.self)
        switch self {
        case .text(let value):
            try Self.encode(value, as: "text", into: &container)
        case .bytes(let value):
            try Self.encode(value, as: "bytes", into: &container)
        case .count(let value):
            try Self.encode(value, as: "count", into: &container)
        case .durationMs(let value):
            try Self.encode(value, as: "durationMs", into: &container)
        case .fileName(let value):
            try Self.encode(Self.lastPathComponent(value), as: "fileName", into: &container)
        case .unknown:
            _ = container.nestedContainer(
                keyedBy: RuntimeEventCodingKey.self,
                forKey: RuntimeEventCodingKey("unknown")
            )
        }
    }

    private static func encode<Value: Encodable>(
        _ value: Value,
        as caseName: String,
        into container: inout KeyedEncodingContainer<RuntimeEventCodingKey>
    ) throws {
        var payload = container.nestedContainer(
            keyedBy: AssociatedKey.self,
            forKey: RuntimeEventCodingKey(caseName)
        )
        try payload.encode(value, forKey: .first)
    }

    private static func lastPathComponent(_ value: String) -> String {
        value.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
    }
}

/// Selects the catalog text used to render one item in a list error.
public enum WireErrorListItemSelector: Codable, Equatable, Sendable {
    /// A fully qualified error code.
    case errorCode(String)
    /// A catalog variant.
    case variant(code: String, key: String)
    /// A selector added by a newer API version.
    case unknown

    private enum AssociatedKey: String, CodingKey {
        case first = "_0"
        case code
        case key
    }

    /// Decodes a known selector, preserving a future selector as ``unknown``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RuntimeEventCodingKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected one list-item selector case.")
            )
        }
        switch key.stringValue {
        case "errorCode":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .errorCode(try payload.decode(String.self, forKey: .first))
        case "variant":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .variant(
                code: try payload.decode(String.self, forKey: .code),
                key: try payload.decode(String.self, forKey: .key)
            )
        default:
            self = .unknown
        }
    }

    /// Encodes a known selector.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: RuntimeEventCodingKey.self)
        switch self {
        case .errorCode(let code):
            var payload = container.nestedContainer(
                keyedBy: AssociatedKey.self,
                forKey: RuntimeEventCodingKey("errorCode")
            )
            try payload.encode(code, forKey: .first)
        case .variant(let code, let key):
            var payload = container.nestedContainer(
                keyedBy: AssociatedKey.self,
                forKey: RuntimeEventCodingKey("variant")
            )
            try payload.encode(code, forKey: .code)
            try payload.encode(key, forKey: .key)
        case .unknown:
            _ = container.nestedContainer(
                keyedBy: RuntimeEventCodingKey.self,
                forKey: RuntimeEventCodingKey("unknown")
            )
        }
    }
}

/// One ordered, parameterized item carried by a list error.
public struct WireErrorListItem: Codable, Equatable, Sendable {
    /// The catalog entry or variant used to select this item's text.
    public var selector: WireErrorListItemSelector
    /// Public-safe values used by this item's message template.
    public var parameters: [String: WireErrorParameter]

    /// Creates a list item.
    public init(selector: WireErrorListItemSelector, parameters: [String: WireErrorParameter] = [:]) {
        self.selector = selector
        self.parameters = parameters
    }
}

/// A safe system-error domain and numeric code, without arbitrary user information.
public struct WireUnderlyingError: Codable, Equatable, Sendable {
    /// The system error namespace.
    public var domain: String
    /// The numeric system error code.
    public var code: Int

    /// Creates a path-free underlying error value.
    public init(domain: String, code: Int) {
        self.domain = domain
        self.code = code
    }
}

/// Public identifiers attached to a failure for diagnostics and support.
public struct ErrorContext: Codable, Equatable, Sendable {
    /// The operation that produced the error, when available.
    public var operationID: OperationID?
    /// The affected Android package, when available.
    public var packageID: RuntimePackageID?
    /// The affected leased display, when available.
    public var displayID: DisplayID?

    /// Creates diagnostic context.
    public init(
        operationID: OperationID? = nil,
        packageID: RuntimePackageID? = nil,
        displayID: DisplayID? = nil
    ) {
        self.operationID = operationID
        self.packageID = packageID
        self.displayID = displayID
    }
}

/// A structured error safe to pass over the RuntimeAPI wire.
public struct WireError: Error, Codable, Equatable, Sendable {
    /// The error domain, such as `runtime` or `store`.
    public var domain: String
    /// The stable qualified catalog code.
    public var code: String
    /// Public-safe typed values for the error message.
    public var parameters: [String: WireErrorParameter]
    /// Ordered, typed details for per-item errors; absent on older peers.
    public var listItems: [WireErrorListItem]?
    /// A nested failure with the same wire shape.
    public var cause: WireErrorBox?
    /// A system error without user information.
    public var underlying: WireUnderlyingError?
    /// Public identifiers associated with the failure.
    public var context: ErrorContext?

    /// Creates a structured wire error.
    public init(
        domain: String,
        code: String,
        parameters: [String: WireErrorParameter] = [:],
        listItems: [WireErrorListItem]? = nil,
        cause: WireErrorBox? = nil,
        underlying: WireUnderlyingError? = nil,
        context: ErrorContext? = nil
    ) {
        self.domain = domain
        self.code = code
        self.parameters = parameters
        self.listItems = listItems
        self.cause = cause
        self.underlying = underlying
        self.context = context
    }
}

/// Boxes a nested wire error while encoding the same object shape as `WireError`.
///
/// The reference boundary allows `WireError` to carry a nested cause without making the Swift
/// value layout recursively contain itself.
public final class WireErrorBox: Codable, Equatable, Sendable {
    /// The nested error.
    public let value: WireError

    /// Creates a box around a nested error.
    public init(_ value: WireError) {
        self.value = value
    }

    /// Decodes the nested wire error without adding a wrapper object.
    public required init(from decoder: any Decoder) throws {
        value = try WireError(from: decoder)
    }

    /// Encodes the nested wire error directly.
    public func encode(to encoder: any Encoder) throws {
        try value.encode(to: encoder)
    }

    /// Compares the boxed errors by their wire values.
    public static func == (lhs: WireErrorBox, rhs: WireErrorBox) -> Bool {
        lhs.value == rhs.value
    }
}

/// The Android runtime's lifecycle state carried by the control API.
public enum WireRuntimeState: Codable, Equatable, Sendable {
    /// Android is stopped.
    case stopped
    /// Android is booting in the given phase.
    case booting(BootPhase)
    /// Android is ready.
    case ready
    /// Android is suspended.
    case suspended
    /// Android is stopping for the given reason.
    case stopping(WireStopReason)
    /// Android failed with a structured error.
    case failed(WireError)
    /// The daemon returned a state added by a newer API version.
    case unknown

    private enum AssociatedKey: String, CodingKey {
        case first = "_0"
    }

    /// Decodes known states and preserves a future state as ``unknown``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RuntimeEventCodingKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected one runtime state case.")
            )
        }
        switch key.stringValue {
        case "stopped":
            self = .stopped
        case "booting":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .booting(try payload.decode(BootPhase.self, forKey: .first))
        case "ready":
            self = .ready
        case "suspended":
            self = .suspended
        case "stopping":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .stopping(try payload.decode(WireStopReason.self, forKey: .first))
        case "failed":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .failed(try payload.decode(WireError.self, forKey: .first))
        case "unknown":
            self = .unknown
        default:
            self = .unknown
        }
    }

    /// Encodes a known runtime state.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: RuntimeEventCodingKey.self)
        switch self {
        case .stopped:
            _ = container.nestedContainer(
                keyedBy: RuntimeEventCodingKey.self,
                forKey: RuntimeEventCodingKey("stopped")
            )
        case .booting(let phase):
            var payload = container.nestedContainer(
                keyedBy: AssociatedKey.self,
                forKey: RuntimeEventCodingKey("booting")
            )
            try payload.encode(phase, forKey: .first)
        case .ready:
            _ = container.nestedContainer(
                keyedBy: RuntimeEventCodingKey.self,
                forKey: RuntimeEventCodingKey("ready")
            )
        case .suspended:
            _ = container.nestedContainer(
                keyedBy: RuntimeEventCodingKey.self,
                forKey: RuntimeEventCodingKey("suspended")
            )
        case .stopping(let reason):
            var payload = container.nestedContainer(
                keyedBy: AssociatedKey.self,
                forKey: RuntimeEventCodingKey("stopping")
            )
            try payload.encode(reason, forKey: .first)
        case .failed(let error):
            var payload = container.nestedContainer(
                keyedBy: AssociatedKey.self,
                forKey: RuntimeEventCodingKey("failed")
            )
            try payload.encode(error, forKey: .first)
        case .unknown:
            _ = container.nestedContainer(
                keyedBy: RuntimeEventCodingKey.self,
                forKey: RuntimeEventCodingKey("unknown")
            )
        }
    }
}

/// A boot phase exposed on the control API.
public enum BootPhase: String, Codable, Equatable, Sendable {
    case kernel
    case `init`
    case systemServer
    case bootCompleted
    case agentsConnecting
    case unknown

    /// Decodes a known boot phase, preserving an unrecognized future phase.
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }

    /// Encodes the stable boot-phase wire value.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Why the runtime stopped.
public enum WireStopReason: String, Codable, Equatable, Sendable {
    case user
    case idle
    case hostShutdown
    case hostUpdate
    case migration
    case reset
    case failure
    case unknown

    /// Decodes a known stop reason, preserving an unrecognized future reason.
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }

    /// Encodes the stable stop-reason wire value.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The version of an Android runtime image on the RuntimeAPI boundary.
public struct ImageVersion: Comparable, Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    /// The release year.
    public var year: Int
    /// The release month.
    public var month: Int
    /// The sequence within the month.
    public var sequence: Int
    /// The Android build identifier.
    public var base: String
    /// The guest architecture.
    public var architecture: String

    private static let pattern =
        #"^([0-9]{4})\.(0[1-9]|1[0-2])\.(0|[1-9][0-9]{0,2})-(cf[0-9]{1,20}|ar[0-9]{6})-(arm64)$"#

    /// Parses the canonical full version form.
    public init?(_ text: String) {
        guard text.range(of: Self.pattern, options: .regularExpression) != nil else {
            return nil
        }
        let parts = text.split(separator: "-", maxSplits: 2).map(String.init)
        let numbers = parts[0].split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3, numbers.count == 3 else {
            return nil
        }
        year = numbers[0]
        month = numbers[1]
        sequence = numbers[2]
        base = parts[1]
        architecture = parts[2]
    }

    /// Creates a version from its components.
    public init(year: Int, month: Int, sequence: Int, base: String, architecture: String) {
        self.year = year
        self.month = month
        self.sequence = sequence
        self.base = base
        self.architecture = architecture
    }

    /// The canonical version string.
    public var description: String {
        String(format: "%04d.%02d.%d-%@-%@", year, month, sequence, base, architecture)
    }

    /// Orders versions by their year, month, and sequence.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.sequence) < (rhs.year, rhs.month, rhs.sequence)
    }

    /// Decodes a canonical version string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let version = Self(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid image version.")
        }
        self = version
    }

    /// Encodes the version as its canonical string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// The purpose of a runtime boot.
public enum BootPurpose: Codable, Equatable, Sendable {
    /// A normal boot.
    case normal
    /// The first boot while provisioning.
    case firstBoot
    /// Booting an updated image.
    case imageUpdate(from: ImageVersion, to: ImageVersion)
    /// A boot purpose added by a newer API version.
    case unknown

    private enum AssociatedKey: String, CodingKey {
        case from
        case to
    }

    /// Decodes a known purpose, preserving a future purpose as ``unknown``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RuntimeEventCodingKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected one boot purpose case.")
            )
        }
        switch key.stringValue {
        case "normal":
            self = .normal
        case "firstBoot":
            self = .firstBoot
        case "imageUpdate":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .imageUpdate(
                from: try payload.decode(ImageVersion.self, forKey: .from),
                to: try payload.decode(ImageVersion.self, forKey: .to)
            )
        case "unknown":
            self = .unknown
        default:
            self = .unknown
        }
    }

    /// Encodes a known purpose.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: RuntimeEventCodingKey.self)
        switch self {
        case .normal:
            _ = container.nestedContainer(
                keyedBy: RuntimeEventCodingKey.self,
                forKey: RuntimeEventCodingKey("normal")
            )
        case .firstBoot:
            _ = container.nestedContainer(
                keyedBy: RuntimeEventCodingKey.self,
                forKey: RuntimeEventCodingKey("firstBoot")
            )
        case .imageUpdate(let from, let to):
            var payload = container.nestedContainer(
                keyedBy: AssociatedKey.self,
                forKey: RuntimeEventCodingKey("imageUpdate")
            )
            try payload.encode(from, forKey: .from)
            try payload.encode(to, forKey: .to)
        case .unknown:
            _ = container.nestedContainer(
                keyedBy: RuntimeEventCodingKey.self,
                forKey: RuntimeEventCodingKey("unknown")
            )
        }
    }
}

/// Estimated progress for the current Android boot.
public struct BootProgress: Codable, Equatable, Sendable {
    /// The current boot phase.
    public var phase: BootPhase
    /// Estimated completion fraction, when available.
    public var fraction: Double?
    /// Time spent booting in milliseconds.
    public var elapsedMs: Int64
    /// Why Android is booting.
    public var purpose: BootPurpose

    /// Creates a boot progress value.
    public init(phase: BootPhase, fraction: Double? = nil, elapsedMs: Int64, purpose: BootPurpose) {
        self.phase = phase
        self.fraction = fraction
        self.elapsedMs = elapsedMs
        self.purpose = purpose
    }
}

/// One runtime activity that prevents the Android VM from becoming idle.
public struct ActivityKind: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    /// The activity's wire value.
    public let rawValue: String

    /// Creates an activity kind from its wire value.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Decodes the activity kind as its string wire value.
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    /// Encodes the activity kind as its string wire value.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The runtime activity sources currently keeping Android active.
public struct IdleStatus: Codable, Equatable, Sendable {
    /// Active runtime holds; empty means the runtime is idle.
    public var activities: [ActivityKind]
    /// When the idle period began.
    public var idleSince: Date?
    /// The scheduled suspend time, if any.
    public var suspendAt: Date?
    /// The scheduled stop time, if any.
    public var stopAt: Date?

    /// Creates an idle-status value.
    public init(
        activities: [ActivityKind],
        idleSince: Date? = nil,
        suspendAt: Date? = nil,
        stopAt: Date? = nil
    ) {
        self.activities = activities
        self.idleSince = idleSince
        self.suspendAt = suspendAt
        self.stopAt = stopAt
    }
}

/// A guest-side component that can report a connection to the runtime.
public enum AgentKind: String, Codable, Equatable, Sendable {
    case guest
    case store
    case unknown

    /// Decodes a known agent kind, preserving an unrecognized value.
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }

    /// Encodes the stable agent-kind wire value.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The connection state of a runtime agent.
public enum AgentConnectionState: String, Codable, Equatable, Sendable {
    case notStarted
    case connecting
    case connected
    case reconnecting
    case unresponsive
    case unavailable
    case incompatible
    case unknown

    /// Decodes a known agent state, preserving an unrecognized value.
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }

    /// Encodes the stable agent-state wire value.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The observed state of one Android guest agent.
public struct AgentConnection: Codable, Equatable, Sendable {
    /// Which agent is connected.
    public var agent: AgentKind
    /// The latest connection state.
    public var state: AgentConnectionState
    /// The protocol version from the latest handshake.
    public var protocolVersion: String?
    /// Whether runtime operation depends on this agent.
    public var required: Bool

    /// Creates an agent connection value.
    public init(
        agent: AgentKind,
        state: AgentConnectionState,
        protocolVersion: String? = nil,
        required: Bool
    ) {
        self.agent = agent
        self.state = state
        self.protocolVersion = protocolVersion
        self.required = required
    }
}

/// The runtime's provisioning lifecycle.
public enum WireProvisioningState: Codable, Equatable, Sendable {
    case notStarted
    case checkingHost
    case installingImage(fraction: Double)
    case creatingInstance
    case firstBoot(BootPhase, fraction: Double)
    case installingAgents
    case verifying
    case complete
    case failed(step: ProvisioningStep, error: WireError)
    case unknown

    private enum AssociatedKey: String, CodingKey {
        case first = "_0"
        case fraction
        case step
        case error
    }

    /// Decodes a known provisioning state, preserving a future state as ``unknown``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RuntimeEventCodingKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected one provisioning state case.")
            )
        }
        switch key.stringValue {
        case "notStarted":
            self = .notStarted
        case "checkingHost":
            self = .checkingHost
        case "installingImage":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .installingImage(fraction: try payload.decode(Double.self, forKey: .fraction))
        case "creatingInstance":
            self = .creatingInstance
        case "firstBoot":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .firstBoot(
                try payload.decode(BootPhase.self, forKey: .first),
                fraction: try payload.decode(Double.self, forKey: .fraction)
            )
        case "installingAgents":
            self = .installingAgents
        case "verifying":
            self = .verifying
        case "complete":
            self = .complete
        case "failed":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .failed(
                step: try payload.decode(ProvisioningStep.self, forKey: .step),
                error: try payload.decode(WireError.self, forKey: .error)
            )
        case "unknown":
            self = .unknown
        default:
            self = .unknown
        }
    }

    /// Encodes a known provisioning state.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: RuntimeEventCodingKey.self)
        switch self {
        case .notStarted:
            Self.encodeEmpty("notStarted", into: &container)
        case .checkingHost:
            Self.encodeEmpty("checkingHost", into: &container)
        case .installingImage(let fraction):
            var payload = container.nestedContainer(
                keyedBy: AssociatedKey.self,
                forKey: RuntimeEventCodingKey("installingImage")
            )
            try payload.encode(fraction, forKey: .fraction)
        case .creatingInstance:
            Self.encodeEmpty("creatingInstance", into: &container)
        case .firstBoot(let phase, let fraction):
            var payload = container.nestedContainer(
                keyedBy: AssociatedKey.self,
                forKey: RuntimeEventCodingKey("firstBoot")
            )
            try payload.encode(phase, forKey: .first)
            try payload.encode(fraction, forKey: .fraction)
        case .installingAgents:
            Self.encodeEmpty("installingAgents", into: &container)
        case .verifying:
            Self.encodeEmpty("verifying", into: &container)
        case .complete:
            Self.encodeEmpty("complete", into: &container)
        case .failed(let step, let error):
            var payload = container.nestedContainer(
                keyedBy: AssociatedKey.self,
                forKey: RuntimeEventCodingKey("failed")
            )
            try payload.encode(step, forKey: .step)
            try payload.encode(error, forKey: .error)
        case .unknown:
            Self.encodeEmpty("unknown", into: &container)
        }
    }

    private static func encodeEmpty(
        _ caseName: String,
        into container: inout KeyedEncodingContainer<RuntimeEventCodingKey>
    ) {
        _ = container.nestedContainer(
            keyedBy: RuntimeEventCodingKey.self,
            forKey: RuntimeEventCodingKey(caseName)
        )
    }
}

/// A provisioning step with a stable wire value.
public enum ProvisioningStep: String, Codable, Equatable, Sendable {
    case checkingHost
    case installingImage
    case creatingInstance
    case firstBoot
    case installingAgents
    case verifying
    case unknown

    /// Decodes a known provisioning step, preserving an unrecognized future value.
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }

    /// Encodes the stable provisioning-step wire value.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A change in the runtime state or boot process.
public enum RuntimeChange: Codable, Equatable, Sendable {
    /// Android changed lifecycle state.
    case stateChanged(WireRuntimeState)
    /// Boot progress changed; intermediate values may be coalesced.
    case bootProgress(BootProgress)
    /// The boot-loop guard changed.
    case bootLoopGuardChanged(BootLoopGuardStatus?)
    /// Runtime image provisioning changed.
    case provisioningChanged(WireProvisioningState)
    /// Configuration values with these dotted keys changed.
    case configurationChanged(keys: [String])
    /// Runtime idle state changed.
    case idleChanged(IdleStatus)
    /// Guest agent connectivity changed.
    case agentsChanged([AgentConnection])
    /// Developer mode changed.
    case developerModeChanged(Bool)
    /// The daemon reported a runtime event added by a newer API version.
    case unknown

    private enum AssociatedKey: String, CodingKey {
        case first = "_0"
        case keys
    }

    /// Decodes a known runtime change or preserves a future change as ``unknown``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RuntimeEventCodingKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected one runtime change case.")
            )
        }
        switch key.stringValue {
        case "stateChanged":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .stateChanged(try payload.decode(WireRuntimeState.self, forKey: .first))
        case "bootProgress":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .bootProgress(try payload.decode(BootProgress.self, forKey: .first))
        case "bootLoopGuardChanged":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .bootLoopGuardChanged(try payload.decodeIfPresent(BootLoopGuardStatus.self, forKey: .first))
        case "provisioningChanged":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .provisioningChanged(try payload.decode(WireProvisioningState.self, forKey: .first))
        case "configurationChanged":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .configurationChanged(keys: try payload.decode([String].self, forKey: .keys))
        case "idleChanged":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .idleChanged(try payload.decode(IdleStatus.self, forKey: .first))
        case "agentsChanged":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .agentsChanged(try payload.decode([AgentConnection].self, forKey: .first))
        case "developerModeChanged":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .developerModeChanged(try payload.decode(Bool.self, forKey: .first))
        default:
            self = .unknown
        }
    }

    /// Encodes a known runtime change.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: RuntimeEventCodingKey.self)
        switch self {
        case .stateChanged(let state):
            try Self.encode(state, for: "stateChanged", key: .first, into: &container)
        case .bootProgress(let progress):
            try Self.encode(progress, for: "bootProgress", key: .first, into: &container)
        case .bootLoopGuardChanged(let status):
            var payload = container.nestedContainer(
                keyedBy: AssociatedKey.self,
                forKey: RuntimeEventCodingKey("bootLoopGuardChanged")
            )
            try payload.encode(status, forKey: .first)
        case .provisioningChanged(let state):
            try Self.encode(state, for: "provisioningChanged", key: .first, into: &container)
        case .configurationChanged(let keys):
            var payload = container.nestedContainer(
                keyedBy: AssociatedKey.self,
                forKey: RuntimeEventCodingKey("configurationChanged")
            )
            try payload.encode(keys, forKey: .keys)
        case .idleChanged(let status):
            try Self.encode(status, for: "idleChanged", key: .first, into: &container)
        case .agentsChanged(let agents):
            try Self.encode(agents, for: "agentsChanged", key: .first, into: &container)
        case .developerModeChanged(let enabled):
            try Self.encode(enabled, for: "developerModeChanged", key: .first, into: &container)
        case .unknown:
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Unknown runtime changes cannot be encoded.")
            )
        }
    }

    private static func encode<Value: Encodable>(
        _ value: Value,
        for caseName: String,
        key: AssociatedKey,
        into container: inout KeyedEncodingContainer<RuntimeEventCodingKey>
    ) throws {
        var payload = container.nestedContainer(
            keyedBy: AssociatedKey.self,
            forKey: RuntimeEventCodingKey(caseName)
        )
        try payload.encode(value, forKey: key)
    }
}

/// The number of failed boots recorded by the runtime boot-loop guard.
public struct BootLoopGuardStatus: Codable, Equatable, Sendable {
    /// Number of failures in the rolling window.
    public var failures: Int
    /// When that window began.
    public var windowStartedAt: Date
    /// Whether the guard is currently tripped.
    public var tripped: Bool

    /// Creates a guard status.
    public init(failures: Int, windowStartedAt: Date, tripped: Bool) {
        self.failures = failures
        self.windowStartedAt = windowStartedAt
        self.tripped = tripped
    }
}

/// A lifecycle or progress change for a long-running operation.
public enum OperationEvent: Codable, Equatable, Sendable {
    /// The operation was registered and has started.
    case started(OperationSnapshot)
    /// The latest progress for an operation; intermediate values may be coalesced.
    case progress(OperationID, OperationProgress)
    /// The operation reached a terminal result.
    case finished(OperationID, OperationResult)
    /// The daemon reported an operation event added by a newer API version.
    case unknown

    private enum CaseKey: String, CodingKey {
        case started
        case progress
        case finished
    }

    private enum AssociatedKey: String, CodingKey {
        case first = "_0"
        case second = "_1"
    }

    /// Decodes a known operation event or preserves a future event as ``unknown``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RuntimeEventCodingKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected one operation event case.")
            )
        }
        switch key.stringValue {
        case "started":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .started(try payload.decode(OperationSnapshot.self, forKey: .first))
        case "progress":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .progress(
                try payload.decode(OperationID.self, forKey: .first),
                try payload.decode(OperationProgress.self, forKey: .second)
            )
        case "finished":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .finished(
                try payload.decode(OperationID.self, forKey: .first),
                try payload.decode(OperationResult.self, forKey: .second)
            )
        default:
            self = .unknown
        }
    }

    /// Encodes a known operation event.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CaseKey.self)
        switch self {
        case .started(let snapshot):
            var payload = container.nestedContainer(keyedBy: AssociatedKey.self, forKey: .started)
            try payload.encode(snapshot, forKey: .first)
        case .progress(let operationID, let progress):
            var payload = container.nestedContainer(keyedBy: AssociatedKey.self, forKey: .progress)
            try payload.encode(operationID, forKey: .first)
            try payload.encode(progress, forKey: .second)
        case .finished(let operationID, let result):
            var payload = container.nestedContainer(keyedBy: AssociatedKey.self, forKey: .finished)
            try payload.encode(operationID, forKey: .first)
            try payload.encode(result, forKey: .second)
        case .unknown:
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Unknown operation events cannot be encoded.")
            )
        }
    }
}

private struct RuntimeEventCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) {
        guard !stringValue.isEmpty else {
            return nil
        }
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
