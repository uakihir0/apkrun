import Foundation
import RuntimeAPI
import RuntimeCore
import Testing

@testable import RuntimeHost

@Test(.timeLimit(.minutes(1)))
func eventHubDeliversSequencedOperationEventsToSubscribedConnections() async throws {
    let hub = RuntimeEventHub()
    let sink = RecordingRuntimeEventSink()
    let connectionID = ObjectIdentifier(sink)
    let operationID = RuntimeAPI.OperationID()
    let outputQueue = DispatchQueue(label: "RuntimeEventHubTests.output")
    let isOpen: @Sendable () -> Bool = { true }

    let firstTopics = try hub.subscribe(
        connectionID: connectionID,
        clientKind: .cli,
        topics: [.operations],
        sink: RuntimeEventSinkReference(value: sink),
        outputQueue: outputQueue,
        isConnectionOpen: isOpen
    )
    let repeatedTopics = try hub.subscribe(
        connectionID: connectionID,
        clientKind: .cli,
        topics: [.operations],
        sink: RuntimeEventSinkReference(value: sink),
        outputQueue: outputQueue,
        isConnectionOpen: isOpen
    )
    let packageID = try #require(
        RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext")
    )
    let snapshot = OperationSnapshot(
        operationID: operationID,
        kind: .install,
        clientKind: .cli,
        startedAt: Date(),
        progress: OperationProgress(stage: "startingRuntime")
    )

    #expect(firstTopics == [.operations])
    #expect(repeatedTopics == [.operations])
    hub.publishOperationEvent(.started(snapshot), operationID: operationID)
    hub.publishOperationEvent(
        .finished(
            operationID,
            .succeeded(
                .package(
                    RuntimePackageSummary(
                        packageID: packageID,
                        displayName: "HelloText",
                        versionCode: nil
                    )
                ))),
        operationID: operationID
    )
    try await Task.sleep(for: .milliseconds(60))

    let delivered = try sink.envelopes()
    #expect(delivered.map(\.seq) == [1, 2])
    #expect(delivered.allSatisfy { $0.topic == .operations })
    #expect(delivered.map(\.operationID) == [operationID, operationID])
    guard case .operations(.started(let started)) = delivered.first?.payload else {
        Issue.record("Expected the operation-start event to arrive first.")
        return
    }
    #expect(started.operationID == operationID)
    guard case .operations(.finished(let finishedID, _)) = delivered.last?.payload else {
        Issue.record("Expected the operation-finished event to arrive last.")
        return
    }
    #expect(finishedID == operationID)

    try hub.unsubscribe(connectionID: connectionID, clientKind: .cli, topics: [.operations])
    hub.publishOperationEvent(.started(snapshot), operationID: operationID)
    try await Task.sleep(for: .milliseconds(40))
    #expect(try sink.envelopes().count == 2)
    hub.remove(connectionID: connectionID)
}

@Test(.timeLimit(.minutes(1)))
func eventHubCoalescesRuntimeProgressButPreservesStateTransitions() async throws {
    let hub = RuntimeEventHub()
    let sink = RecordingRuntimeEventSink()
    let connectionID = ObjectIdentifier(sink)
    let outputQueue = DispatchQueue(label: "RuntimeEventHubTests.runtime")
    _ = try hub.subscribe(
        connectionID: connectionID,
        clientKind: .cli,
        topics: [.runtime],
        sink: RuntimeEventSinkReference(value: sink),
        outputQueue: outputQueue,
        isConnectionOpen: { true }
    )
    hub.beginSnapshotBarrier(connectionID: connectionID)
    hub.publishRuntimeChange(.stateChanged(.booting(.kernel)))
    hub.publishRuntimeChange(
        .bootProgress(BootProgress(phase: .kernel, fraction: 0.1, elapsedMs: 100, purpose: .normal))
    )
    hub.publishRuntimeChange(
        .bootProgress(BootProgress(phase: .kernel, fraction: 0.4, elapsedMs: 400, purpose: .normal))
    )
    hub.publishRuntimeChange(.stateChanged(.ready))
    hub.endSnapshotBarrier(connectionID: connectionID, outputQueue: outputQueue) {}
    try await Task.sleep(for: .milliseconds(60))

    let envelopes = try sink.envelopes()
    #expect(envelopes.map(\.seq) == [1, 2, 3])
    #expect(envelopes.map(\.topic) == [.runtime, .runtime, .runtime])
    guard case .runtime(.stateChanged(.booting(.kernel))) = envelopes[0].payload else {
        Issue.record("Expected the booting state transition to be preserved.")
        return
    }
    guard case .runtime(.bootProgress(let progress)) = envelopes[1].payload else {
        Issue.record("Expected one coalesced runtime progress event.")
        return
    }
    #expect(progress.fraction == 0.4)
    guard case .runtime(.stateChanged(.ready)) = envelopes[2].payload else {
        Issue.record("Expected the ready state transition to be preserved.")
        return
    }
    try hub.unsubscribe(connectionID: connectionID, clientKind: .cli, topics: [.runtime])
    hub.remove(connectionID: connectionID)
}

@Test(.timeLimit(.minutes(1)))
func runtimeHostStateBridgeKeepsSnapshotAndEventStateConsistent() async throws {
    let host = RuntimeHost()
    let sink = RecordingRuntimeEventSink()
    let connectionID = ObjectIdentifier(sink)
    _ = try host.eventHub.subscribe(
        connectionID: connectionID,
        clientKind: .cli,
        topics: [.runtime],
        sink: RuntimeEventSinkReference(value: sink),
        outputQueue: DispatchQueue(label: "RuntimeEventHubTests.hostBridge"),
        isConnectionOpen: { true }
    )

    await host.consumeSupervisorState(RuntimeStateSnapshot(revision: 1, state: .stopping(.reset)))
    #expect(await host.status().runtimeState == "stopping")
    try await Task.sleep(for: .milliseconds(40))

    let envelopes = try sink.envelopes()
    #expect(envelopes.count == 1)
    guard case .runtime(.stateChanged(.stopping(.reset))) = envelopes.first?.payload else {
        Issue.record("Expected the reset stop reason in the runtime topic.")
        return
    }
    host.eventHub.remove(connectionID: connectionID)
}

@Test(.timeLimit(.minutes(1)))
func runtimeHostPreservesDelayedStateEventsAfterNewerStatusSnapshot() async throws {
    let host = RuntimeHost()
    let sink = RecordingRuntimeEventSink()
    let connectionID = ObjectIdentifier(sink)
    _ = try host.eventHub.subscribe(
        connectionID: connectionID,
        clientKind: .cli,
        topics: [.runtime],
        sink: RuntimeEventSinkReference(value: sink),
        outputQueue: DispatchQueue(label: "RuntimeEventHubTests.stateRevision"),
        isConnectionOpen: { true }
    )

    await host.synchronizeRuntimeStateSnapshot(RuntimeStateSnapshot(revision: 2, state: .ready))
    await host.consumeSupervisorState(
        RuntimeStateSnapshot(revision: 1, state: .booting(.kernel))
    )
    await host.consumeSupervisorState(RuntimeStateSnapshot(revision: 2, state: .ready))
    #expect(await host.status().runtimeState == "ready")
    try await Task.sleep(for: .milliseconds(40))

    let envelopes = try sink.envelopes()
    #expect(envelopes.count == 2)
    guard case .runtime(.stateChanged(.booting(.kernel))) = envelopes.first?.payload else {
        Issue.record("A delayed booting transition must still be delivered.")
        return
    }
    guard case .runtime(.stateChanged(.ready)) = envelopes.last?.payload else {
        Issue.record("The latest state transition must follow the earlier transition.")
        return
    }
    host.eventHub.remove(connectionID: connectionID)
}

@Test
func runtimeFailureEventsOmitUntrustedGuestDetails() {
    let state = RuntimeHost.wireRuntimeState(
        for: .failed(.androidBootFailed(detail: "untrusted guest console text"))
    )
    guard case .failed(let error) = state else {
        Issue.record("Expected a failed runtime state.")
        return
    }
    #expect(error.domain == "runtime")
    #expect(error.code == "runtime.androidBootFailed")
    #expect(error.parameters["detail"] == nil)
}

@Test
func eventHubRejectsUnauthorizedMultiTopicSubscriptionsAtomically() throws {
    let hub = RuntimeEventHub()
    let sink = RecordingRuntimeEventSink()
    let connectionID = ObjectIdentifier(sink)
    let outputQueue = DispatchQueue(label: "RuntimeEventHubTests.authorization")

    do {
        _ = try hub.subscribe(
            connectionID: connectionID,
            clientKind: .launcher,
            topics: [.runtime, .operations],
            sink: RuntimeEventSinkReference(value: sink),
            outputQueue: outputQueue,
            isConnectionOpen: { true }
        )
        Issue.record("A launcher must not receive operation events.")
    } catch let error as RuntimeWireError {
        #expect(error.code == "runtime.notAuthorized")
    }

    #expect(
        try hub.subscribe(
            connectionID: connectionID,
            clientKind: .launcher,
            topics: [.runtime],
            sink: RuntimeEventSinkReference(value: sink),
            outputQueue: outputQueue,
            isConnectionOpen: { true }
        ) == [.runtime])
    do {
        try hub.unsubscribe(connectionID: connectionID, clientKind: .launcher, topics: [.operations])
        Issue.record("A launcher must not unsubscribe from a topic it cannot access.")
    } catch let error as RuntimeWireError {
        #expect(error.code == "runtime.notAuthorized")
    }
    #expect(
        try hub.subscribe(
            connectionID: connectionID,
            clientKind: .launcher,
            topics: [],
            sink: RuntimeEventSinkReference(value: sink),
            outputQueue: outputQueue,
            isConnectionOpen: { true }
        ) == [.runtime])
    try hub.unsubscribe(connectionID: connectionID, clientKind: .launcher, topics: [.runtime])
    hub.remove(connectionID: connectionID)
}

@Test(.timeLimit(.minutes(1)))
func eventHubDropsQueuedTopicEventsWhenUnsubscribed() async throws {
    let hub = RuntimeEventHub()
    let sink = RecordingRuntimeEventSink()
    let connectionID = ObjectIdentifier(sink)
    let outputQueue = DispatchQueue(label: "RuntimeEventHubTests.unsubscribe")
    let operationID = OperationID()
    let snapshot = OperationSnapshot(
        operationID: operationID,
        kind: .install,
        clientKind: .cli,
        startedAt: Date()
    )
    _ = try hub.subscribe(
        connectionID: connectionID,
        clientKind: .cli,
        topics: [.operations],
        sink: RuntimeEventSinkReference(value: sink),
        outputQueue: outputQueue,
        isConnectionOpen: { true }
    )
    hub.publishOperationEvent(.started(snapshot), operationID: operationID)
    try hub.unsubscribe(connectionID: connectionID, clientKind: .cli, topics: [.operations])
    try await Task.sleep(for: .milliseconds(40))

    #expect(try sink.envelopes().isEmpty)
    hub.remove(connectionID: connectionID)
}

@Test(.timeLimit(.minutes(1)))
func eventHubPreservesEventsAcrossAcknowledgementBackpressure() async throws {
    let hub = RuntimeEventHub()
    let sink = RecordingRuntimeEventSink(acknowledgesImmediately: false)
    let connectionID = ObjectIdentifier(sink)
    let outputQueue = DispatchQueue(label: "RuntimeEventHubTests.flowControl")
    _ = try hub.subscribe(
        connectionID: connectionID,
        clientKind: .cli,
        topics: [.operations],
        sink: RuntimeEventSinkReference(value: sink),
        outputQueue: outputQueue,
        isConnectionOpen: { true }
    )
    for _ in 0..<300 {
        let operationID = OperationID()
        let snapshot = OperationSnapshot(
            operationID: operationID,
            kind: .install,
            clientKind: .cli,
            startedAt: Date()
        )
        hub.publishOperationEvent(.started(snapshot), operationID: operationID)
    }

    hub.flush(connectionID: connectionID)
    try await Task.sleep(for: .milliseconds(40))
    #expect(try sink.envelopes().count == 256)

    sink.acknowledgeAll()
    try await Task.sleep(for: .milliseconds(40))
    let delivered = try sink.envelopes()
    #expect(delivered.count == 300)
    #expect(delivered.map(\.seq) == Array(1...300).map(UInt64.init))
    #expect(delivered.allSatisfy { $0.payload != .resyncRequired(.operations) })
    hub.remove(connectionID: connectionID)
}

@Test(.timeLimit(.minutes(1)))
func eventHubKeepsSnapshotReplyAheadOfResyncForBackpressuredEvents() async throws {
    let hub = RuntimeEventHub()
    let sink = RecordingRuntimeEventSink(acknowledgesImmediately: false)
    let replyRecorder = SnapshotReplyRecorder()
    let connectionID = ObjectIdentifier(sink)
    let outputQueue = DispatchQueue(label: "RuntimeEventHubTests.snapshotBackpressure")
    _ = try hub.subscribe(
        connectionID: connectionID,
        clientKind: .cli,
        topics: [.operations],
        sink: RuntimeEventSinkReference(value: sink),
        outputQueue: outputQueue,
        isConnectionOpen: { true }
    )
    for _ in 0..<300 {
        let operationID = OperationID()
        let snapshot = OperationSnapshot(
            operationID: operationID,
            kind: .install,
            clientKind: .cli,
            startedAt: Date()
        )
        hub.publishOperationEvent(.started(snapshot), operationID: operationID)
    }
    hub.flush(connectionID: connectionID)
    try await Task.sleep(for: .milliseconds(40))
    #expect(try sink.envelopes().count == 256)

    hub.beginSnapshotBarrier(connectionID: connectionID)
    hub.endSnapshotBarrier(connectionID: connectionID, outputQueue: outputQueue) {
        replyRecorder.record(envelopeCount: (try? sink.envelopes().count) ?? -1)
    }
    try await Task.sleep(for: .milliseconds(40))
    #expect(replyRecorder.envelopeCount == 256)

    sink.acknowledgeAll()
    try await Task.sleep(for: .milliseconds(40))
    let delivered = try sink.envelopes()
    #expect(delivered.count == 257)
    #expect(delivered.last?.payload == .resyncRequired(.operations))
    hub.remove(connectionID: connectionID)
}

@Test(.timeLimit(.minutes(1)))
func eventHubPlacesSnapshotReplyBetweenOlderAndNewerEvents() async throws {
    let hub = RuntimeEventHub()
    let recorder = RuntimeEventOrderRecorder()
    let connectionID = ObjectIdentifier(recorder)
    let outputQueue = DispatchQueue(label: "RuntimeEventHubTests.snapshotBarrier")
    let operationID = OperationID()
    _ = try hub.subscribe(
        connectionID: connectionID,
        clientKind: .cli,
        topics: [.operations],
        sink: RuntimeEventSinkReference(value: recorder),
        outputQueue: outputQueue,
        isConnectionOpen: { true }
    )

    func snapshot(_ stage: String) -> OperationSnapshot {
        OperationSnapshot(
            operationID: operationID,
            kind: .install,
            clientKind: .cli,
            startedAt: Date(),
            progress: OperationProgress(stage: stage)
        )
    }

    hub.publishOperationEvent(.started(snapshot("older")), operationID: operationID)
    hub.beginSnapshotBarrier(connectionID: connectionID)
    hub.publishOperationEvent(.progress(operationID, OperationProgress(stage: "newer")), operationID: operationID)
    hub.endSnapshotBarrier(
        connectionID: connectionID,
        outputQueue: outputQueue
    ) {
        recorder.append("reply")
    }
    try await Task.sleep(for: .milliseconds(60))

    #expect(recorder.values() == ["event-1", "reply", "event-2"])
    hub.remove(connectionID: connectionID)
}

@Test
func eventHubRejectsSubscriptionsWithoutAnExportedSink() {
    let hub = RuntimeEventHub()
    let sink = RecordingRuntimeEventSink()
    do {
        _ = try hub.subscribe(
            connectionID: ObjectIdentifier(sink),
            clientKind: .cli,
            topics: [.operations],
            sink: nil,
            outputQueue: DispatchQueue(label: "RuntimeEventHubTests.missingSink"),
            isConnectionOpen: { true }
        )
        Issue.record("A subscription without a client event sink must fail.")
    } catch let error as RuntimeWireError {
        #expect(error.code == "runtime.malformedRequest")
    }
}

private final class RuntimeEventOrderRecorder: NSObject, RuntimeEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [String] = []

    func handshake(reply: @escaping (Bool) -> Void) {
        reply(true)
    }

    func deliver(_ batch: Data, reply: @escaping () -> Void) {
        let envelopes = (try? JSONDecoder().decode([EventEnvelope].self, from: batch)) ?? []
        lock.lock()
        for envelope in envelopes {
            recordedValues.append("event-\(envelope.seq)")
        }
        lock.unlock()
        reply()
    }

    func append(_ value: String) {
        lock.withLock {
            recordedValues.append(value)
        }
    }

    func values() -> [String] {
        lock.withLock { recordedValues }
    }
}

private final class SnapshotReplyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEnvelopeCount: Int?

    var envelopeCount: Int? {
        lock.withLock { recordedEnvelopeCount }
    }

    func record(envelopeCount: Int) {
        lock.withLock {
            recordedEnvelopeCount = envelopeCount
        }
    }
}

private final class RecordingRuntimeEventSink: NSObject, RuntimeEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [Data] = []
    private var acknowledgementHandlers: [() -> Void] = []
    private let acknowledgesImmediately: Bool

    init(acknowledgesImmediately: Bool = true) {
        self.acknowledgesImmediately = acknowledgesImmediately
    }

    func handshake(reply: @escaping (Bool) -> Void) {
        reply(true)
    }

    func deliver(_ batch: Data, reply: @escaping () -> Void) {
        lock.lock()
        batches.append(batch)
        if !acknowledgesImmediately {
            acknowledgementHandlers.append(reply)
        }
        lock.unlock()
        if acknowledgesImmediately {
            reply()
        }
    }

    func acknowledgeAll() {
        lock.lock()
        let handlers = acknowledgementHandlers
        acknowledgementHandlers.removeAll()
        lock.unlock()
        for handler in handlers {
            handler()
        }
    }

    func envelopes() throws -> [EventEnvelope] {
        lock.lock()
        let captured = batches
        lock.unlock()
        return
            try captured
            .flatMap { try JSONDecoder().decode([EventEnvelope].self, from: $0) }
    }
}
