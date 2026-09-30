import DiagnosticsCore
import Dispatch
import Foundation

/// Owns one VM lifecycle and publishes every explicit state transition.
public actor VMController {
    /// The definition is used by each driver created for this controller.
    private let validatedDefinition: ValidatedVMDefinition
    private let diagnostics: DiagnosticsContext
    private let queue: VMQueue
    private let driverFactory: any VirtualMachineDriverFactory
    private let forcedStopTimeout: Duration
    private let logger: APKLogger
    private let consoleStore: ConsoleChannelStore
    private let stateContinuation: AsyncStream<VMState>.Continuation

    /// The current explicit state of the VM.
    public private(set) var state: VMState

    /// All states, including the initial `.stopped`, in transition order.
    public nonisolated let stateUpdates: AsyncStream<VMState>

    private var consoleChannels: [ConsoleChannel]
    private var hasAttemptedStart = false
    package private(set) var vmGeneration: UInt64 = 0
    private var activePublicOperation: UUID?
    private var driver: (any VirtualMachineDriver)?
    private var eventTask: Task<Void, Never>?
    private var eventsDuringStart: [VirtualMachineEvent] = []
    package private(set) var networkAttachmentError: VZErrorInfo?
    private var stopCompletion: (id: UUID, gate: VMStopCompletionGate)?
    private var stopTimeoutTask: Task<Void, Never>?
    private var stopOperationTasks: [UUID: Task<Void, Never>] = [:]
    private var stopOperationsDrain: (id: UUID, gate: VMStopOperationsDrainGate)?
    private var resourceRelease: (id: UUID, task: Task<Void, Never>)?

    /// Creates a controller backed by Virtualization.framework.
    public init(
        definition: ValidatedVMDefinition,
        diagnostics: DiagnosticsContext
    ) {
        let queue = VMQueue()
        self.init(
            definition: definition,
            diagnostics: diagnostics,
            queue: queue,
            driverFactory: VZVirtualMachineDriverFactory(queue: queue),
            forcedStopTimeout: .seconds(10)
        )
    }

    package init(
        definition: ValidatedVMDefinition,
        diagnostics: DiagnosticsContext,
        queue: VMQueue,
        driverFactory: any VirtualMachineDriverFactory,
        forcedStopTimeout: Duration = .seconds(10)
    ) {
        precondition(forcedStopTimeout > .zero)
        validatedDefinition = definition
        self.diagnostics = diagnostics
        self.queue = queue
        self.driverFactory = driverFactory
        self.forcedStopTimeout = forcedStopTimeout
        logger = APKLogger(category: VMLogCategory.lifecycle, sink: diagnostics.logSink)

        let stateStream = AsyncStream.makeStream(
            of: VMState.self,
            bufferingPolicy: .unbounded
        )
        stateUpdates = stateStream.stream
        stateContinuation = stateStream.continuation
        state = .stopped
        stateContinuation.yield(.stopped)

        let channels = Self.makeConsoleChannels(
            for: definition.definition.consolePorts,
            queue: queue
        )
        consoleChannels = channels
        consoleStore = ConsoleChannelStore(channels: channels)
    }

    /// Starts the validated Linux VM.
    public func start() async throws {
        try await OperationContext.withNew { @Sendable in
            try await self.startWithinOperation()
        }
    }

    /// Pauses a running VM.
    public func pause() async throws {
        try await OperationContext.withNew { @Sendable in
            try await self.pauseWithinOperation()
        }
    }

    /// Resumes a paused VM.
    public func resume() async throws {
        try await OperationContext.withNew { @Sendable in
            try await self.resumeWithinOperation()
        }
    }

    /// Force-stops a running, paused, or already-stopping VM.
    public func stop() async throws {
        try await OperationContext.withNew { @Sendable in
            try await self.stopWithinOperation()
        }
    }

    /// Sends a power-button request; shutdown is reported through state updates.
    public func requestGuestStop() async throws {
        try await OperationContext.withNew { @Sendable in
            try await self.requestGuestStopWithinOperation()
        }
    }

    /// Releases framework objects and clears a failed state.
    public func reset() async throws {
        try await OperationContext.withNew { @Sendable in
            try await self.resetWithinOperation()
        }
    }

    /// Returns the channel assigned to a console role.
    public nonisolated func console(_ role: ConsoleRole) -> ConsoleChannel {
        guard let channel = consoleStore.channel(for: role) else {
            preconditionFailure("No console channel exists for the requested role.")
        }
        return channel
    }

    private func startWithinOperation() async throws(VMFailure) {
        await waitForResourceReleaseIfNeeded()
        let operationID = try beginPublicOperation(
            target: .starting,
            allows: { $0 == .stopped }
        )
        defer { endPublicOperation(operationID) }

        vmGeneration &+= 1
        let generation = vmGeneration
        try transition(to: .starting, source: .publicRequest)
        Perf.mark(.vmStart, timeline: diagnostics.perfTimeline)

        if hasAttemptedStart {
            for channel in consoleChannels {
                channel.close()
            }
            consoleChannels = Self.makeConsoleChannels(
                for: validatedDefinition.definition.consolePorts,
                queue: queue
            )
            consoleStore.replace(with: consoleChannels)
        }
        hasAttemptedStart = true
        eventsDuringStart.removeAll()
        networkAttachmentError = nil

        let newDriver: any VirtualMachineDriver
        do {
            newDriver = try await driverFactory.makeDriver(
                for: validatedDefinition.definition,
                consoleChannels: consoleChannels
            )
        } catch let error {
            let failure = VMFailure.startFailed(underlying: error)
            try transition(to: .failed(failure), source: .internalEvent)
            logFailure(failure, description: error.description)
            throw failure
        }

        driver = newDriver
        observe(newDriver, generation: generation)
        do {
            try await newDriver.start()
        } catch let error {
            let failure = VMFailure.startFailed(underlying: error)
            if state == .starting {
                try transition(to: .failed(failure), source: .internalEvent)
            }
            logFailure(failure, description: error.description)
            throw failure
        }

        if case .failed(let failure) = state {
            throw failure
        }
        if state == .starting {
            try transition(to: .running, source: .internalEvent)
        }

        let pendingEvents = eventsDuringStart
        eventsDuringStart.removeAll()
        for event in pendingEvents {
            await receive(event, generation: generation)
        }
        if case .failed(let failure) = state {
            throw failure
        }
    }

    private func pauseWithinOperation() async throws(VMFailure) {
        let operationID = try beginPublicOperation(
            target: .paused,
            allows: { $0 == .running }
        )
        defer { endPublicOperation(operationID) }
        guard let driver else {
            assertionFailure("A running VM must have a driver.")
            throw VMFailure.invalidTransition(from: state, to: .paused)
        }

        do {
            try await driver.pause()
        } catch let error {
            let failure = VMFailure.pauseFailed(underlying: error)
            if state == .running {
                try transition(to: .failed(failure), source: .internalEvent)
            }
            logFailure(failure, description: error.description)
            throw failure
        }

        guard state == .running else {
            if case .failed(let failure) = state {
                throw failure
            }
            throw VMFailure.invalidTransition(from: state, to: .paused)
        }
        try transition(to: .paused, source: .internalEvent)
    }

    private func resumeWithinOperation() async throws(VMFailure) {
        let operationID = try beginPublicOperation(
            target: .running,
            allows: { $0 == .paused }
        )
        defer { endPublicOperation(operationID) }
        guard let driver else {
            assertionFailure("A paused VM must have a driver.")
            throw VMFailure.invalidTransition(from: state, to: .running)
        }

        do {
            try await driver.resume()
        } catch let error {
            let failure = VMFailure.resumeFailed(underlying: error)
            if state == .paused {
                try transition(to: .failed(failure), source: .internalEvent)
            }
            logFailure(failure, description: error.description)
            throw failure
        }

        guard state == .paused else {
            if case .failed(let failure) = state {
                throw failure
            }
            throw VMFailure.invalidTransition(from: state, to: .running)
        }
        try transition(to: .running, source: .internalEvent)
    }

    private func stopWithinOperation() async throws(VMFailure) {
        let operationID = try beginPublicOperation(
            target: .stopping,
            allows: { $0 == .running || $0 == .paused || $0 == .stopping }
        )
        defer { endPublicOperation(operationID) }

        if state != .stopping {
            try transition(to: .stopping, source: .publicRequest)
        }
        guard let driver else {
            assertionFailure("A stopping VM must have a driver.")
            throw VMFailure.invalidTransition(from: state, to: .stopped)
        }

        logger.info("Starting forced VM stop")
        let stopID = UUID()
        let gate = VMStopCompletionGate()
        stopCompletion = (stopID, gate)

        stopOperationTasks[stopID] = Task { [weak self, driver, gate] in
            let result: VMStopDriverResult
            do {
                try await driver.stop()
                result = .succeeded
            } catch {
                result = .failed(VZErrorInfo(error as NSError))
            }
            await gate.complete(.completed(result))
            await self?.stopOperationDidFinish(stopID)
        }
        stopTimeoutTask = Task { [gate, forcedStopTimeout] in
            try? await Task.sleep(for: forcedStopTimeout)
            guard !Task.isCancelled else { return }
            await gate.complete(.timedOut)
        }

        let outcome = await gate.wait()
        stopTimeoutTask?.cancel()
        stopTimeoutTask = nil
        if stopCompletion?.id == stopID {
            stopCompletion = nil
        }

        switch outcome {
        case .timedOut:
            if state == .stopping {
                let failure = VMFailure.stopTimedOut
                try transition(to: .failed(failure), source: .internalEvent)
                throw failure
            }
            if case .failed(let failure) = state {
                throw failure
            }
        case .completed(.succeeded):
            if state == .stopping {
                if !stopOperationTasks.isEmpty, !(await waitForStopOperationsToDrain()) {
                    let failure = VMFailure.stopTimedOut
                    if state == .stopping {
                        try transition(to: .failed(failure), source: .internalEvent)
                    }
                    logFailure(
                        failure,
                        description: "Virtualization.framework did not complete the stop operation"
                    )
                    throw failure
                }
            }
            if state == .stopping {
                await releaseResources()
                if state == .stopping {
                    try transition(to: .stopped, source: .internalEvent)
                }
            }
            if case .failed(let failure) = state {
                throw failure
            }
        case .completed(.failed(let error)):
            if state == .stopping {
                let failure = VMFailure.stoppedWithError(underlying: error)
                try transition(to: .failed(failure), source: .internalEvent)
                logFailure(failure, description: error.description)
                throw failure
            }
            if case .failed(let failure) = state {
                throw failure
            }
        }
    }

    private func requestGuestStopWithinOperation() async throws(VMFailure) {
        let operationID = try beginPublicOperation(
            target: .stopping,
            allows: { $0 == .running || $0 == .paused }
        )
        defer { endPublicOperation(operationID) }
        try transition(to: .stopping, source: .publicRequest)
        guard let driver else {
            assertionFailure("A running VM must have a driver.")
            throw VMFailure.invalidTransition(from: state, to: .stopped)
        }

        do {
            try await driver.requestStop()
        } catch let error {
            let failure = VMFailure.stoppedWithError(underlying: error)
            if state == .stopping {
                try transition(to: .failed(failure), source: .internalEvent)
            }
            logFailure(failure, description: error.description)
            throw failure
        }
    }

    private func resetWithinOperation() async throws(VMFailure) {
        let operationID = try beginPublicOperation(
            target: .stopped,
            allows: {
                if case .failed = $0 { return true }
                return false
            }
        )
        defer { endPublicOperation(operationID) }

        stopTimeoutTask?.cancel()
        stopTimeoutTask = nil
        let stopTasks = Array(stopOperationTasks.values)
        for task in stopTasks {
            task.cancel()
        }
        if !stopTasks.isEmpty, !(await waitForStopOperationsToDrain()) {
            let failure = VMFailure.stopTimedOut
            logFailure(failure, description: "A framework stop operation is still in progress")
            throw failure
        }
        stopOperationTasks.removeAll()
        stopCompletion = nil
        await releaseResources()
        try transition(to: .stopped, source: .internalEvent)
    }

    package func receive(_ event: VirtualMachineEvent, generation: UInt64) async {
        guard generation == vmGeneration else { return }
        await OperationContext.withNew { @Sendable in
            await self.receiveWithinOperation(event)
        }
    }

    private func receiveWithinOperation(_ event: VirtualMachineEvent) async {
        if state == .starting {
            eventsDuringStart.append(event)
            return
        }

        switch event {
        case .guestDidStop:
            guard state == .running || state == .paused || state == .stopping else {
                return
            }
            if state == .stopping, let completion = stopCompletion {
                await completion.gate.complete(.completed(.succeeded))
                return
            }
            try? transition(to: .stopped, source: .internalEvent)
            await releaseResources()

        case .didStopWithError(let error):
            guard state == .running || state == .paused || state == .stopping else {
                return
            }
            if state == .stopping, let completion = stopCompletion {
                await completion.gate.complete(.completed(.failed(error)))
            }
            let failure = VMFailure.stoppedWithError(underlying: error)
            try? transition(to: .failed(failure), source: .internalEvent)
            logFailure(failure, description: error.description)

        case .networkAttachmentDisconnected(let error):
            guard state == .running || state == .paused else { return }
            networkAttachmentError = error
            logger.error(
                "VM network attachment disconnected: \(error.description, .private)",
                errorCode: VMFailure.networkAttachmentLost.qualifiedCode
            )
        }
    }

    private func observe(
        _ driver: any VirtualMachineDriver,
        generation: UInt64
    ) {
        eventTask?.cancel()
        let events = driver.events
        eventTask = Task.detached { [weak self, events] in
            for await event in events {
                guard !Task.isCancelled, let self else { return }
                await self.receive(event, generation: generation)
            }
        }
    }

    private func releaseResources() async {
        let releaseID: UUID
        if let resourceRelease {
            releaseID = resourceRelease.id
            await resourceRelease.task.value
            finishResourceRelease(id: releaseID)
            return
        }

        releaseID = UUID()
        let driver = self.driver
        let channels = consoleChannels
        let task = Task {
            await driver?.release()
            for channel in channels {
                channel.close()
            }
        }
        resourceRelease = (releaseID, task)
        await task.value
        finishResourceRelease(id: releaseID)
    }

    private func finishResourceRelease(id releaseID: UUID) {
        guard resourceRelease?.id == releaseID else { return }
        self.driver = nil
        eventTask?.cancel()
        eventTask = nil
        resourceRelease = nil
    }

    private func waitForResourceReleaseIfNeeded() async {
        guard let resourceRelease else { return }
        await resourceRelease.task.value
        finishResourceRelease(id: resourceRelease.id)
    }

    private func stopOperationDidFinish(_ identifier: UUID) async {
        stopOperationTasks.removeValue(forKey: identifier)
        if stopOperationTasks.isEmpty, let stopOperationsDrain {
            await stopOperationsDrain.gate.complete()
        }
    }

    private func waitForStopOperationsToDrain() async -> Bool {
        guard !stopOperationTasks.isEmpty else { return true }
        let identifier = UUID()
        let gate = VMStopOperationsDrainGate()
        stopOperationsDrain = (identifier, gate)
        let timeoutTask = Task { [forcedStopTimeout] in
            try? await Task.sleep(for: forcedStopTimeout)
            guard !Task.isCancelled else { return }
            await gate.complete(timedOut: true)
        }

        let drained = await gate.wait()
        timeoutTask.cancel()
        if stopOperationsDrain?.id == identifier {
            stopOperationsDrain = nil
        }
        return drained
    }

    private func beginPublicOperation(
        target: VMState,
        allows: (VMState) -> Bool
    ) throws(VMFailure) -> UUID {
        guard activePublicOperation == nil, allows(state) else {
            let failure = VMFailure.invalidTransition(from: state, to: target)
            logger.fault(
                "Rejected VM lifecycle operation from \(state.logLabel, .public) to \(target.logLabel, .public)",
                errorCode: failure.qualifiedCode
            )
            throw failure
        }
        let identifier = UUID()
        activePublicOperation = identifier
        return identifier
    }

    private func endPublicOperation(_ identifier: UUID) {
        guard activePublicOperation == identifier else { return }
        activePublicOperation = nil
    }

    private func transition(
        to nextState: VMState,
        source: TransitionSource
    ) throws(VMFailure) {
        guard VMStateTransitions.isAllowed(from: state, to: nextState) else {
            let failure = VMFailure.invalidTransition(from: state, to: nextState)
            logger.fault(
                "Rejected VM state transition from \(state.logLabel, .public) to \(nextState.logLabel, .public)",
                errorCode: failure.qualifiedCode
            )
            if source == .internalEvent {
                assertionFailure("Internal VM state transition violated the documented state machine.")
            }
            throw failure
        }

        let oldState = state
        state = nextState
        stateContinuation.yield(nextState)
        logger.info(
            "VM state changed from \(oldState.logLabel, .public) to \(nextState.logLabel, .public)"
        )
    }

    private func logFailure(_ failure: VMFailure, description: String) {
        logger.error(
            "VM lifecycle failed: \(description, .private)",
            errorCode: failure.qualifiedCode
        )
    }

    private static func makeConsoleChannels(
        for ports: [ConsolePortDefinition],
        queue: VMQueue
    ) -> [ConsoleChannel] {
        ports.map { ConsoleChannel(role: $0.role, vmQueue: queue) }
    }
}

private enum TransitionSource {
    case publicRequest
    case internalEvent
}

extension VMState {
    fileprivate var logLabel: String {
        switch self {
        case .stopped:
            "stopped"
        case .starting:
            "starting"
        case .running:
            "running"
        case .paused:
            "paused"
        case .stopping:
            "stopping"
        case .failed:
            "failed"
        }
    }
}

// UNCHECKED-SENDABLE: lock protects the current role-to-channel snapshot.
private final class ConsoleChannelStore: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ConsoleChannel]

    init(channels: [ConsoleChannel]) {
        self.channels = channels
    }

    func replace(with channels: [ConsoleChannel]) {
        lock.withLock {
            self.channels = channels
        }
    }

    func channel(for role: ConsoleRole) -> ConsoleChannel? {
        lock.withLock {
            channels.first { $0.role == role }
        }
    }
}

private enum VMStopDriverResult: Sendable {
    case succeeded
    case failed(VZErrorInfo)
}

private enum VMStopCompletionResult: Sendable {
    case timedOut
    case completed(VMStopDriverResult)
}

private actor VMStopCompletionGate {
    private var result: VMStopCompletionResult?
    private var waiter: CheckedContinuation<VMStopCompletionResult, Never>?

    func wait() async -> VMStopCompletionResult {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func complete(_ result: VMStopCompletionResult) {
        guard self.result == nil else { return }
        self.result = result
        waiter?.resume(returning: result)
        waiter = nil
    }
}

private actor VMStopOperationsDrainGate {
    private var result: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?

    func wait() async -> Bool {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func complete(timedOut: Bool = false) {
        guard result == nil else { return }
        result = !timedOut
        waiter?.resume(returning: !timedOut)
        waiter = nil
    }
}
