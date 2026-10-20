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
    /// An operation started, progressed, or finished.
    case operations(OperationEvent)
    /// Events for the topic were dropped; fetch a fresh snapshot.
    case resyncRequired(EventTopic)
    /// The daemon reported an event kind added by a newer API version.
    case unknown

    private enum CaseKey: String, CodingKey {
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
