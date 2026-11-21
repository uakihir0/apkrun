import Dispatch
import Foundation
import RuntimeAPI

/// Server-side registry of open streams (runtime-api.md §16.4).
///
/// Streams ride the connection's exported `RuntimeEventSink`: each stream
/// event is delivered as an `EventEnvelope` whose payload is `.stream`. At
/// most four unacknowledged events are in flight per stream, four streams per
/// connection, and `closeStream` is idempotent. A stream that loses its
/// connection ends without a final `ended` event.
final class RuntimeStreamCenter: @unchecked Sendable {
    /// The kind of stream, used for deduplication and scoping rules.
    enum StreamKind: Equatable {
        /// A wrapper's `notificationRelay` for one package (§11.3).
        case notificationRelay(packageID: RuntimePackageID)
        /// APKRun.app's `hostNotifications` stream; only one exists at a time.
        case hostNotifications
    }

    private struct ConnectionState {
        let sink: RuntimeEventSinkReference
        let outputQueue: DispatchQueue
        let isOpen: @Sendable () -> Bool
    }

    private struct StreamState {
        let kind: StreamKind
        let connectionID: ObjectIdentifier
        var nextSequence: UInt64 = 1
        var pending: [StreamEvent] = []
        var inFlight = 0
        var ended = false
    }

    private let lock = NSLock()
    private var connections: [ObjectIdentifier: ConnectionState] = [:]
    private var streams: [StreamID: StreamState] = [:]
    /// One notification relay per connection (§11.3).
    private var relayByConnection: [ObjectIdentifier: StreamID] = [:]
    /// The single live `hostNotifications` stream (§11.3).
    private var hostNotificationsStream: StreamID?
    /// Streams per connection, for the four-stream limit and invalidation.
    private var streamsByConnection: [ObjectIdentifier: Set<StreamID>] = [:]
    /// Invoked when a wrapper answers a notification relay (§11.3).
    var onRelayResponse: (@Sendable (StreamID, RelayResponse) -> Void)?
    /// Invoked when APKRun.app answers a host notification (§11.3).
    var onHostNotificationResponse: (@Sendable (StreamID, HostNotificationResponse) -> Void)?
    /// Invoked when a `notificationRelay` stream opens or is reused (§11.3).
    var onRelayStreamOpened: (@Sendable (RuntimePackageID, StreamID) -> Void)?

    /// Records a `notificationRelayResponse`. Returns false for an unknown,
    /// ended, or foreign stream.
    func recordRelayResponse(_ streamID: StreamID, _ response: RelayResponse, from connectionID: ObjectIdentifier)
        -> Bool
    {
        lock.lock()
        let stream = streams[streamID]
        let valid =
            stream?.connectionID == connectionID && stream?.ended == false
            && stream.map { if case .notificationRelay = $0.kind { return true }; return false } == true
        let handler = onRelayResponse
        lock.unlock()
        guard valid else { return false }
        handler?(streamID, response)
        return true
    }

    /// Records a `hostNotificationResponse`. Returns false for an unknown,
    /// ended, or foreign stream.
    func recordHostNotificationResponse(
        _ streamID: StreamID,
        _ response: HostNotificationResponse,
        from connectionID: ObjectIdentifier
    ) -> Bool {
        lock.lock()
        let stream = streams[streamID]
        let valid =
            stream?.connectionID == connectionID && stream?.ended == false
            && stream.map { if case .hostNotifications = $0.kind { return true }; return false } == true
        let handler = onHostNotificationResponse
        lock.unlock()
        guard valid else { return false }
        handler?(streamID, response)
        return true
    }

    /// Opens a `notificationRelay` stream; a second request returns the
    /// existing handle (§11.3).
    func openNotificationRelay(
        connectionID: ObjectIdentifier,
        packageID: RuntimePackageID,
        sink: RuntimeEventSinkReference?,
        outputQueue: DispatchQueue,
        isOpen: @escaping @Sendable () -> Bool
    ) throws(RuntimeWireError) -> StreamHandle {
        lock.lock()
        defer { lock.unlock() }
        if let existing = relayByConnection[connectionID],
            streams[existing]?.ended == false
        {
            let opened = onRelayStreamOpened
            lock.unlock()
            opened?(packageID, existing)
            lock.lock()
            return StreamHandle(streamID: existing)
        }
        let streamID = try openStreamLocked(
            connectionID: connectionID,
            kind: .notificationRelay(packageID: packageID),
            sink: sink,
            outputQueue: outputQueue,
            isOpen: isOpen
        )
        relayByConnection[connectionID] = streamID
        let opened = onRelayStreamOpened
        lock.unlock()
        opened?(packageID, streamID)
        lock.lock()
        return StreamHandle(streamID: streamID)
    }

    /// Opens the `hostNotifications` stream, ending any previous one with
    /// `replaced` (§11.3).
    func openHostNotifications(
        connectionID: ObjectIdentifier,
        sink: RuntimeEventSinkReference?,
        outputQueue: DispatchQueue,
        isOpen: @escaping @Sendable () -> Bool
    ) throws(RuntimeWireError) -> StreamHandle {
        lock.lock()
        defer { lock.unlock() }
        if let previous = hostNotificationsStream {
            endLocked(previous, reason: .replaced)
        }
        let streamID = try openStreamLocked(
            connectionID: connectionID,
            kind: .hostNotifications,
            sink: sink,
            outputQueue: outputQueue,
            isOpen: isOpen
        )
        hostNotificationsStream = streamID
        return StreamHandle(streamID: streamID)
    }

    /// Whether `connectionID` currently holds a `notificationRelay` stream.
    func hasNotificationRelay(connectionID: ObjectIdentifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let streamID = relayByConnection[connectionID] else { return false }
        return streams[streamID]?.ended == false
    }

    /// Sends a relay message to the package's wrapper stream. Returns false
    /// when no live relay exists for the package.
    @discardableResult
    func sendRelay(_ message: RelayMessage, to packageID: RuntimePackageID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let streamID = streams.first(where: {
            if case .notificationRelay(let id) = $0.value.kind { return id == packageID && !$0.value.ended }
            return false
        })?.key else {
            return false
        }
        enqueueLocked(.relay(message), on: streamID)
        return true
    }

    /// Sends a host notification to APKRun.app's stream. Returns false when
    /// no stream is open.
    @discardableResult
    func sendHostNotification(_ message: HostNotificationMessage) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let streamID = hostNotificationsStream, streams[streamID]?.ended == false else {
            return false
        }
        enqueueLocked(.hostNotification(message), on: streamID)
        return true
    }

    /// The package ID a `notificationRelay` stream serves.
    func relayPackageID(for streamID: StreamID) -> RuntimePackageID? {
        lock.lock()
        defer { lock.unlock() }
        guard let stream = streams[streamID],
            case .notificationRelay(let packageID) = stream.kind
        else {
            return nil
        }
        return packageID
    }

    /// Whether a stream belongs to the given connection (response routing).
    func stream(_ streamID: StreamID, belongsTo connectionID: ObjectIdentifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return streams[streamID]?.connectionID == connectionID
            && streams[streamID]?.ended == false
    }

    /// `closeStream`: idempotent; unknown, ended, or foreign streams are a
    /// no-op success (§16.4).
    func closeStream(_ streamID: StreamID, from connectionID: ObjectIdentifier) {
        lock.lock()
        defer { lock.unlock() }
        guard let stream = streams[streamID],
            stream.connectionID == connectionID,
            !stream.ended
        else {
            return
        }
        endLocked(streamID, reason: .closed)
    }

    /// Ends every stream of an invalidated connection without an `ended`
    /// event (§16.4).
    func connectionClosed(_ connectionID: ObjectIdentifier) {
        lock.lock()
        defer { lock.unlock() }
        connections[connectionID] = nil
        for streamID in streamsByConnection[connectionID] ?? [] {
            if var stream = streams[streamID] {
                stream.ended = true
                stream.pending.removeAll()
                streams[streamID] = stream
            }
        }
        streamsByConnection[connectionID] = nil
        relayByConnection[connectionID] = nil
        if let hostStream = hostNotificationsStream,
            streams[hostStream]?.connectionID == connectionID
        {
            hostNotificationsStream = nil
        }
    }

    // MARK: - Internals

    private func openStreamLocked(
        connectionID: ObjectIdentifier,
        kind: StreamKind,
        sink: RuntimeEventSinkReference?,
        outputQueue: DispatchQueue,
        isOpen: @escaping @Sendable () -> Bool
    ) throws(RuntimeWireError) -> StreamID {
        guard isOpen() else {
            throw .runtime("hostShuttingDown", message: "The client connection has closed.")
        }
        guard let sink else {
            throw .runtime(
                "malformedRequest",
                message: "The client did not export an event receiver.")
        }
        guard (streamsByConnection[connectionID] ?? []).count < 4 else {
            throw RuntimeWireError(
                domain: "runtime",
                code: "runtime.busy",
                message: "Too many open streams on this connection.")
        }
        connections[connectionID] = ConnectionState(
            sink: sink, outputQueue: outputQueue, isOpen: isOpen)
        let streamID = StreamID()
        streams[streamID] = StreamState(kind: kind, connectionID: connectionID)
        streamsByConnection[connectionID, default: []].insert(streamID)
        return streamID
    }

    private func enqueueLocked(_ event: StreamEvent, on streamID: StreamID) {
        guard var stream = streams[streamID], !stream.ended else { return }
        stream.pending.append(event)
        streams[streamID] = stream
        scheduleDeliveryLocked(for: streamID)
    }

    private func endLocked(_ streamID: StreamID, reason: StreamEndReason) {
        guard var stream = streams[streamID], !stream.ended else { return }
        stream.ended = true
        stream.pending = [.ended(reason)]
        streams[streamID] = stream
        if let connectionID = Optional(stream.connectionID),
            relayByConnection[connectionID] == streamID
        {
            relayByConnection[connectionID] = nil
        }
        if hostNotificationsStream == streamID {
            hostNotificationsStream = nil
        }
        scheduleDeliveryLocked(for: streamID)
    }

    private func scheduleDeliveryLocked(for streamID: StreamID) {
        guard let stream = streams[streamID],
            let connection = connections[stream.connectionID],
            connection.isOpen()
        else {
            return
        }
        connection.outputQueue.async { [weak self] in
            self?.deliverNext(for: streamID)
        }
    }

    private func deliverNext(for streamID: StreamID) {
        lock.lock()
        guard
            var stream = streams[streamID],
            let connection = connections[stream.connectionID],
            connection.isOpen(),
            !stream.pending.isEmpty,
            stream.inFlight < 4
        else {
            lock.unlock()
            return
        }
        var envelopes: [EventEnvelope] = []
        var seq = stream.nextSequence
        while envelopes.count < 4 - stream.inFlight, !stream.pending.isEmpty {
            let event = stream.pending.removeFirst()
            envelopes.append(
                EventEnvelope(
                    topic: .integrations,
                    seq: seq,
                    time: Date(),
                    operationID: nil,
                    payload: .stream(
                        StreamEnvelope(streamID: streamID, seq: seq, event: event))))
            seq &+= 1
        }
        stream.nextSequence = seq
        stream.inFlight += envelopes.count
        streams[streamID] = stream
        let sentCount = envelopes.count
        let wasTerminal = envelopes.contains {
            if case .stream(let envelope) = $0.payload,
                case .ended = envelope.event
            {
                return true
            }
            return false
        }
        lock.unlock()

        guard let batch = try? JSONEncoder().encode(envelopes) else { return }
        connection.outputQueue.async { [weak self] in
            connection.sink.value.deliver(batch) {
                self?.acknowledge(streamID, count: sentCount, terminal: wasTerminal)
            }
        }
    }

    private func acknowledge(_ streamID: StreamID, count: Int, terminal: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard var stream = streams[streamID] else { return }
        stream.inFlight = max(0, stream.inFlight - count)
        if terminal {
            stream.pending.removeAll()
        }
        streams[streamID] = stream
        if !terminal {
            scheduleDeliveryLocked(for: streamID)
        }
    }
}
