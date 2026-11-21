import Foundation
import RuntimeAPI

/// Routes event batches received from the authenticated XPC endpoint to topic-specific streams.
final class RuntimeEventStreamHub: @unchecked Sendable {
    private struct Subscriber {
        let topic: EventTopic
        let continuation: AsyncStream<EventEnvelope>.Continuation
        var needsResync: Bool
    }

    private let lock = NSLock()
    private var subscribers: [UUID: Subscriber] = [:]

    func makeStream(
        for topic: EventTopic,
        onTermination: @escaping @Sendable (UUID) -> Void
    ) -> (id: UUID, stream: AsyncStream<EventEnvelope>) {
        let id = UUID()
        let pair = AsyncStream<EventEnvelope>.makeStream(bufferingPolicy: .bufferingNewest(1024))
        pair.continuation.onTermination = { _ in onTermination(id) }
        lock.withLock {
            subscribers[id] = Subscriber(
                topic: topic,
                continuation: pair.continuation,
                needsResync: false
            )
        }
        return (id, pair.stream)
    }

    /// Removes a subscriber and returns whether it was the last subscriber to its topic.
    func removeSubscriber(_ id: UUID) -> (topic: EventTopic, lastForTopic: Bool)? {
        let removed = lock.withLock { () -> Subscriber? in
            subscribers.removeValue(forKey: id)
        }
        guard let removed else { return nil }
        removed.continuation.finish()
        let lastForTopic = lock.withLock {
            !subscribers.values.contains { $0.topic == removed.topic }
        }
        return (removed.topic, lastForTopic)
    }

    func activeTopics() -> [EventTopic] {
        lock.withLock {
            var topics: [EventTopic] = []
            for subscriber in subscribers.values where !topics.contains(subscriber.topic) {
                topics.append(subscriber.topic)
            }
            return topics
        }
    }

    func hasSubscribers() -> Bool {
        lock.withLock { !subscribers.isEmpty }
    }

    func deliver(_ envelopes: [EventEnvelope]) {
        lock.withLock {
            for envelope in envelopes {
                for id in Array(subscribers.keys) {
                    guard var subscriber = subscribers[id], subscriber.topic == envelope.topic else {
                        continue
                    }
                    if subscriber.needsResync {
                        let marker = Self.resyncEnvelope(for: subscriber.topic)
                        if case .terminated = subscriber.continuation.yield(marker) {
                            subscribers[id] = nil
                            continue
                        }
                        subscriber.needsResync = false
                    }
                    switch subscriber.continuation.yield(envelope) {
                    case .enqueued:
                        break
                    case .dropped:
                        // bufferingNewest keeps the newest value and reports the evicted one.
                        let marker = Self.resyncEnvelope(for: subscriber.topic)
                        if case .terminated = subscriber.continuation.yield(marker) {
                            subscribers[id] = nil
                            continue
                        }
                        subscriber.needsResync = false
                    case .terminated:
                        subscribers[id] = nil
                        continue
                    @unknown default:
                        subscriber.needsResync = true
                    }
                    subscribers[id] = subscriber
                }
            }
        }
    }

    func markResyncRequired(for topics: [EventTopic]) {
        let requestedTopics = Set(topics)
        lock.withLock {
            for id in Array(subscribers.keys) {
                guard var subscriber = subscribers[id],
                    requestedTopics.contains(subscriber.topic)
                else {
                    continue
                }
                let marker = Self.resyncEnvelope(for: subscriber.topic)
                if case .terminated = subscriber.continuation.yield(marker) {
                    subscribers[id] = nil
                    continue
                }
                subscriber.needsResync = false
                subscribers[id] = subscriber
            }
        }
    }

    private static func resyncEnvelope(for topic: EventTopic) -> EventEnvelope {
        EventEnvelope(
            topic: topic,
            seq: 0,
            time: Date(),
            payload: .resyncRequired(topic)
        )
    }
}

/// Routes §16.4 stream envelopes (delivered inside event batches as
/// `.stream` payloads) to the stream the client opened.
final class RuntimeNotificationStreamHub: @unchecked Sendable {
    /// Envelopes held for a stream the client has not registered yet (the
    /// open reply arrives after the daemon already queued posts).
    private static let pendingEnvelopeLimit = 256

    private let lock = NSLock()
    private var continuations: [StreamID: AsyncStream<StreamEnvelope>.Continuation] = [:]
    private var pending: [StreamID: [StreamEnvelope]] = [:]

    /// Registers a stream and returns its event stream. Envelopes delivered
    /// before the registration are replayed first.
    func register(_ streamID: StreamID) -> AsyncStream<StreamEnvelope> {
        let pair = AsyncStream<StreamEnvelope>.makeStream(bufferingPolicy: .unbounded)
        let buffered = lock.withLock { () -> [StreamEnvelope] in
            continuations[streamID] = pair.continuation
            return pending.removeValue(forKey: streamID) ?? []
        }
        pair.continuation.onTermination = { [weak self] _ in
            self?.remove(streamID)
        }
        for envelope in buffered {
            pair.continuation.yield(envelope)
            if case .ended = envelope.event {
                remove(streamID)
                break
            }
        }
        return pair.stream
    }

    /// Finishes a stream locally, e.g. after `closeStream`.
    func remove(_ streamID: StreamID) {
        let continuation = lock.withLock { () -> AsyncStream<StreamEnvelope>.Continuation? in
            pending[streamID] = nil
            return continuations.removeValue(forKey: streamID)
        }
        // finish() runs onTermination synchronously; it must run outside the
        // lock because the handler calls back into remove().
        continuation?.finish()
    }

    /// Finishes every open stream, e.g. when the XPC connection drops.
    func finishAll() {
        let all = lock.withLock { () -> [AsyncStream<StreamEnvelope>.Continuation] in
            defer {
                continuations.removeAll()
                pending.removeAll()
            }
            return Array(continuations.values)
        }
        for continuation in all {
            continuation.finish()
        }
    }

    /// Yields each `.stream` envelope to its stream; an `.ended` event
    /// finishes the stream afterwards.
    func deliver(_ envelopes: [EventEnvelope]) {
        var targets: [(AsyncStream<StreamEnvelope>.Continuation, StreamEnvelope)] = []
        lock.withLock {
            for envelope in envelopes {
                guard case .stream(let streamEnvelope) = envelope.payload else { continue }
                if let continuation = continuations[streamEnvelope.streamID] {
                    targets.append((continuation, streamEnvelope))
                } else {
                    var queue = pending[streamEnvelope.streamID] ?? []
                    if queue.count < Self.pendingEnvelopeLimit {
                        queue.append(streamEnvelope)
                        pending[streamEnvelope.streamID] = queue
                    }
                }
            }
        }
        for (continuation, streamEnvelope) in targets {
            continuation.yield(streamEnvelope)
            if case .ended = streamEnvelope.event {
                remove(streamEnvelope.streamID)
            }
        }
    }
}

/// The client-exported XPC object that decodes event batches and acknowledges receipt.
final class RuntimeEventSinkReceiver: NSObject, RuntimeEventSink, @unchecked Sendable {
    private let streamHub: RuntimeEventStreamHub
    private let notificationStreamHub: RuntimeNotificationStreamHub

    init(
        streamHub: RuntimeEventStreamHub,
        notificationStreamHub: RuntimeNotificationStreamHub
    ) {
        self.streamHub = streamHub
        self.notificationStreamHub = notificationStreamHub
    }

    func handshake(reply: @escaping (Bool) -> Void) {
        reply(true)
    }

    func deliver(_ batch: Data, reply: @escaping () -> Void) {
        guard let envelopes = try? JSONDecoder().decode([EventEnvelope].self, from: batch) else {
            streamHub.markResyncRequired(for: streamHub.activeTopics())
            reply()
            return
        }
        var topicEnvelopes: [EventEnvelope] = []
        var streamEnvelopes: [EventEnvelope] = []
        for envelope in envelopes {
            if case .stream = envelope.payload {
                streamEnvelopes.append(envelope)
            } else {
                topicEnvelopes.append(envelope)
            }
        }
        notificationStreamHub.deliver(streamEnvelopes)
        streamHub.deliver(topicEnvelopes)
        reply()
    }
}
