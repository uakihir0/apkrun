import Foundation
import RuntimeAPI

struct RuntimeEventSinkReference: @unchecked Sendable {
    let value: any RuntimeEventSink
}

/// Serializes event delivery for each authenticated XPC connection.
///
/// Control replies use the same outbound queue as event batches, preserving the server's
/// subscribe-then-snapshot ordering contract.
final class RuntimeEventHub: @unchecked Sendable {
    private static let maximumQueuedEvents = 1024
    private static let maximumBatchSize = 64
    private static let maximumInFlightBatches = 4
    private static let batchDelay: DispatchTimeInterval = .milliseconds(16)
    private static let progressIntervalNanoseconds: UInt64 = 100_000_000

    private let queue = DispatchQueue(label: "io.apkrun.RuntimeHost.eventHub")
    private var subscribers: [ObjectIdentifier: Subscriber] = [:]
    private var replyBarriers: [ObjectIdentifier: Int] = [:]

    func subscribe(
        connectionID: ObjectIdentifier,
        clientKind: RuntimeClientKind,
        topics: [EventTopic],
        sink: RuntimeEventSinkReference?,
        outputQueue: DispatchQueue,
        isConnectionOpen: @escaping @Sendable () -> Bool
    ) throws(RuntimeWireError) -> [EventTopic] {
        var result: Result<[EventTopic], RuntimeWireError> = .failure(Self.connectionClosedError)
        queue.sync {
            guard isConnectionOpen() else {
                result = .failure(Self.connectionClosedError)
                return
            }
            let requestedTopics = Set(topics)
            guard requestedTopics.isSubset(of: Self.allowedTopics(for: clientKind)) else {
                result = .failure(Self.notAuthorizedError)
                return
            }
            guard let sink else {
                result = .failure(Self.malformedSinkError)
                return
            }

            var subscriber =
                subscribers[connectionID]
                ?? Subscriber(
                    clientKind: clientKind,
                    sink: sink,
                    outputQueue: outputQueue,
                    isConnectionOpen: isConnectionOpen
                )
            subscriber.topics.formUnion(requestedTopics)
            subscribers[connectionID] = subscriber
            result = .success(subscriber.topics.sorted { $0.rawValue < $1.rawValue })
        }
        switch result {
        case .success(let topics):
            return topics
        case .failure(let error):
            throw error
        }
    }

    func unsubscribe(
        connectionID: ObjectIdentifier,
        clientKind: RuntimeClientKind,
        topics: [EventTopic]
    ) throws(RuntimeWireError) {
        var failure: RuntimeWireError?
        queue.sync {
            guard Set(topics).isSubset(of: Self.allowedTopics(for: clientKind)) else {
                failure = Self.notAuthorizedError
                return
            }
            guard var subscriber = subscribers[connectionID] else {
                return
            }
            let removedTopics = Set(topics)
            subscriber.topics.subtract(removedTopics)
            subscriber.pending.removeAll { removedTopics.contains($0.topic) }
            for topic in removedTopics {
                Self.clearProgressDelivery(for: topic, from: &subscriber)
            }
            if subscriber.topics.isEmpty {
                subscribers[connectionID] = nil
            } else {
                subscribers[connectionID] = subscriber
            }
        }
        if let failure {
            throw failure
        }
    }

    func remove(connectionID: ObjectIdentifier) {
        queue.sync {
            subscribers[connectionID] = nil
            replyBarriers[connectionID] = nil
        }
    }

    func removeAll(connectionIDs: [ObjectIdentifier]) {
        queue.sync {
            for connectionID in connectionIDs {
                subscribers[connectionID] = nil
                replyBarriers[connectionID] = nil
            }
        }
    }

    func flush(connectionID: ObjectIdentifier) {
        queue.sync {
            flushPendingEvents(for: connectionID, discardUndeliverable: false)
        }
    }

    /// Flushes queued events before a snapshot request begins, then holds newer events until its
    /// reply has been placed on the connection's output queue.
    func beginSnapshotBarrier(connectionID: ObjectIdentifier) {
        queue.sync {
            flushPendingEvents(for: connectionID, discardUndeliverable: true)
            replyBarriers[connectionID, default: 0] += 1
        }
    }

    /// Places the snapshot reply before events produced while the snapshot was being read.
    func endSnapshotBarrier(
        connectionID: ObjectIdentifier,
        outputQueue: DispatchQueue,
        reply: @escaping @Sendable () -> Void
    ) {
        queue.sync {
            outputQueue.async(execute: reply)
            let outstandingBarriers = replyBarriers[connectionID, default: 0]
            if outstandingBarriers <= 1 {
                replyBarriers[connectionID] = nil
                if var subscriber = subscribers[connectionID] {
                    scheduleDelivery(for: connectionID, subscriber: &subscriber)
                    subscribers[connectionID] = subscriber
                }
            } else {
                replyBarriers[connectionID] = outstandingBarriers - 1
            }
        }
    }

    func publishOperationEvent(_ event: OperationEvent, operationID: OperationID) {
        publish(
            QueuedEvent(
                topic: .operations,
                time: Date(),
                operationID: operationID,
                payload: .operations(event)
            )
        )
    }

    func publishRuntimeChange(_ change: RuntimeChange) {
        publish(
            QueuedEvent(
                topic: .runtime,
                time: Date(),
                operationID: nil,
                payload: .runtime(change)
            )
        )
    }

    func publishPackageChange(_ change: PackageChange, operationID: OperationID? = nil) {
        publish(
            QueuedEvent(
                topic: .packages,
                time: Date(),
                operationID: operationID,
                payload: .packages(change)
            )
        )
    }

    private func publish(_ event: QueuedEvent) {
        queue.sync {
            for connectionID in Array(subscribers.keys) {
                guard var subscriber = subscribers[connectionID],
                    subscriber.topics.contains(event.topic),
                    subscriber.isConnectionOpen()
                else {
                    subscribers[connectionID] = nil
                    continue
                }
                if case .operations(.finished(let finishedID, _)) = event.payload {
                    subscriber.lastProgressDelivery[Self.operationProgressKey(finishedID)] = nil
                }
                enqueue(event, for: &subscriber)
                subscribers[connectionID] = subscriber
                scheduleDelivery(for: connectionID, subscriber: &subscriber)
                subscribers[connectionID] = subscriber
            }
        }
    }

    private static let connectionClosedError = RuntimeWireError.runtime(
        "hostShuttingDown",
        message: "The client connection has closed."
    )
    private static let malformedSinkError = RuntimeWireError.runtime(
        "malformedRequest",
        message: "The client did not export an event receiver."
    )
    private static let notAuthorizedError = RuntimeWireError.runtime(
        "notAuthorized",
        message: "This client is not allowed to subscribe to one or more requested topics."
    )

    private static func allowedTopics(for clientKind: RuntimeClientKind) -> Set<EventTopic> {
        switch clientKind {
        case .app, .menuBar, .cli:
            [
                .runtime, .sessions, .packages, .updates, .operations, .health, .maintenance,
                .wrappers, .integrations,
            ]
        case .launcher:
            [.runtime]
        case .wrapper:
            []
        }
    }

    private func enqueue(_ event: QueuedEvent, for subscriber: inout Subscriber) {
        if let progressKey = event.coalescingKey,
            let index = subscriber.pending.firstIndex(where: { $0.coalescingKey == progressKey })
        {
            subscriber.pending[index] = event
            return
        }

        if subscriber.pending.count >= Self.maximumQueuedEvents {
            var counts: [EventTopic: Int] = [:]
            for pending in subscriber.pending {
                counts[pending.topic, default: 0] += 1
            }
            if let droppedTopic = counts.max(by: { $0.value < $1.value })?.key {
                subscriber.pending.removeAll { $0.topic == droppedTopic }
                Self.clearProgressDelivery(for: droppedTopic, from: &subscriber)
                subscriber.pending.append(
                    QueuedEvent(
                        topic: droppedTopic,
                        time: Date(),
                        operationID: nil,
                        payload: .resyncRequired(droppedTopic)
                    )
                )
            }
        }
        subscriber.pending.append(event)
    }

    private func flushPendingEvents(
        for connectionID: ObjectIdentifier,
        discardUndeliverable: Bool
    ) {
        while let subscriber = subscribers[connectionID],
            !subscriber.pending.isEmpty,
            subscriber.inFlightBatches.count < Self.maximumInFlightBatches
        {
            let previousPendingCount = subscriber.pending.count
            let previousInFlightCount = subscriber.inFlightBatches.count
            deliverNextBatch(for: connectionID)
            guard let updated = subscribers[connectionID],
                updated.pending.count < previousPendingCount
                    || updated.inFlightBatches.count > previousInFlightCount
            else {
                // A progress event may be waiting for its coalescing interval.
                // Leave the timer in charge instead of spinning the hub queue.
                break
            }
        }

        guard var subscriber = subscribers[connectionID] else {
            return
        }
        if discardUndeliverable, !subscriber.pending.isEmpty {
            replacePendingEventsWithResync(&subscriber)
            subscribers[connectionID] = subscriber
        }
    }

    private func replacePendingEventsWithResync(_ subscriber: inout Subscriber) {
        var seenTopics = Set<EventTopic>()
        let topics = subscriber.pending.compactMap { event -> EventTopic? in
            guard seenTopics.insert(event.topic).inserted else { return nil }
            return event.topic
        }
        subscriber.pending = topics.map { topic in
            QueuedEvent(
                topic: topic,
                time: Date(),
                operationID: nil,
                payload: .resyncRequired(topic)
            )
        }
        for topic in topics {
            Self.clearProgressDelivery(for: topic, from: &subscriber)
        }
    }

    private static func clearProgressDelivery(for topic: EventTopic, from subscriber: inout Subscriber) {
        let prefix: String
        switch topic {
        case .runtime:
            prefix = "runtime:"
        case .operations:
            prefix = "operations:"
        default:
            return
        }
        subscriber.lastProgressDelivery = subscriber.lastProgressDelivery.filter {
            !$0.key.hasPrefix(prefix)
        }
    }

    private static func operationProgressKey(_ operationID: OperationID) -> String {
        "operations:\(operationID.wireValue)"
    }

    private func scheduleDelivery(for connectionID: ObjectIdentifier, subscriber: inout Subscriber) {
        guard !subscriber.pending.isEmpty,
            !subscriber.batchScheduled,
            subscriber.inFlightBatches.count < Self.maximumInFlightBatches
        else {
            return
        }
        subscriber.batchScheduled = true
        queue.asyncAfter(deadline: .now() + Self.batchDelay) { [weak self] in
            self?.deliverNextBatch(for: connectionID)
        }
    }

    private func deliverNextBatch(for connectionID: ObjectIdentifier) {
        guard var subscriber = subscribers[connectionID] else {
            return
        }
        subscriber.batchScheduled = false
        guard replyBarriers[connectionID, default: 0] == 0 else {
            subscribers[connectionID] = subscriber
            return
        }
        guard subscriber.isConnectionOpen() else {
            subscribers[connectionID] = nil
            return
        }
        guard !subscriber.pending.isEmpty,
            subscriber.inFlightBatches.count < Self.maximumInFlightBatches
        else {
            subscribers[connectionID] = subscriber
            return
        }

        let now = DispatchTime.now().uptimeNanoseconds
        if let progressKey = subscriber.pending.first?.coalescingKey,
            let lastSent = subscriber.lastProgressDelivery[progressKey],
            now - lastSent < Self.progressIntervalNanoseconds
        {
            let delay = Self.progressIntervalNanoseconds - (now - lastSent)
            subscriber.batchScheduled = true
            subscribers[connectionID] = subscriber
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) { [weak self] in
                self?.deliverNextBatch(for: connectionID)
            }
            return
        }

        var envelopes: [EventEnvelope] = []
        while envelopes.count < Self.maximumBatchSize, !subscriber.pending.isEmpty {
            if let progressKey = subscriber.pending[0].coalescingKey,
                let lastSent = subscriber.lastProgressDelivery[progressKey],
                now - lastSent < Self.progressIntervalNanoseconds
            {
                break
            }
            let event = subscriber.pending.removeFirst()
            if let progressKey = event.coalescingKey {
                subscriber.lastProgressDelivery[progressKey] = now
            }
            envelopes.append(
                EventEnvelope(
                    topic: event.topic,
                    seq: subscriber.nextSequence,
                    time: event.time,
                    operationID: event.operationID,
                    payload: event.payload
                )
            )
            subscriber.nextSequence &+= 1
        }
        guard !envelopes.isEmpty,
            let batch = try? JSONEncoder().encode(envelopes)
        else {
            subscribers[connectionID] = subscriber
            return
        }

        let acknowledgementID = UUID()
        subscriber.inFlightBatches.insert(acknowledgementID)
        let sink = subscriber.sink
        let outputQueue = subscriber.outputQueue
        subscribers[connectionID] = subscriber
        outputQueue.async { [weak self] in
            sink.value.deliver(batch) {
                self?.acknowledge(acknowledgementID, from: connectionID)
            }
        }
    }

    private func acknowledge(_ acknowledgementID: UUID, from connectionID: ObjectIdentifier) {
        queue.async { [weak self] in
            guard var subscriber = self?.subscribers[connectionID],
                subscriber.inFlightBatches.remove(acknowledgementID) != nil
            else {
                return
            }
            self?.scheduleDelivery(for: connectionID, subscriber: &subscriber)
            self?.subscribers[connectionID] = subscriber
        }
    }

    private struct QueuedEvent {
        let topic: EventTopic
        let time: Date
        let operationID: OperationID?
        let payload: EventPayload

        var coalescingKey: String? {
            switch payload {
            case .runtime(.bootProgress):
                "runtime:bootProgress"
            case .operations(.progress(let operationID, _)):
                RuntimeEventHub.operationProgressKey(operationID)
            default:
                nil
            }
        }
    }

    private struct Subscriber {
        let clientKind: RuntimeClientKind
        let sink: RuntimeEventSinkReference
        let outputQueue: DispatchQueue
        let isConnectionOpen: @Sendable () -> Bool
        var topics: Set<EventTopic> = []
        var pending: [QueuedEvent] = []
        var nextSequence: UInt64 = 1
        var inFlightBatches = Set<UUID>()
        var lastProgressDelivery: [String: UInt64] = [:]
        var batchScheduled = false
    }
}
