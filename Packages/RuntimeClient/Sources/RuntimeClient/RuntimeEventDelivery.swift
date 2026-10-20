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

/// The client-exported XPC object that decodes event batches and acknowledges receipt.
final class RuntimeEventSinkReceiver: NSObject, RuntimeEventSink, @unchecked Sendable {
    private let streamHub: RuntimeEventStreamHub

    init(streamHub: RuntimeEventStreamHub) {
        self.streamHub = streamHub
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
        streamHub.deliver(envelopes)
        reply()
    }
}
