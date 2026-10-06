import DiagnosticsCore
import DiagnosticsCoreTestSupport
import Foundation
import Testing
import VirtualMachineCoreTestSupport

@testable import VirtualMachineCore

@Test(.timeLimit(.minutes(1)))
func vmControllerPublishesOrderedStartAndForcedStopStatesWithOperationIDs() async throws {
    let sink = RecordingLogSink()
    let diagnostics = DiagnosticsContext.testing(logSink: sink)
    let driver = FakeVirtualMachineDriver()
    let factory = FakeVirtualMachineDriverFactory(drivers: [driver])
    let controller = makeController(factory: factory, diagnostics: diagnostics)
    let stateStream = controller.stateUpdates
    let collectedStates = Task {
        await collectStates(stateStream, count: 5)
    }

    try await controller.start()
    try await controller.stop()

    #expect(
        await collectedStates.value == [
            .stopped,
            .starting,
            .running,
            .stopping,
            .stopped,
        ]
    )
    #expect(driver.operations == [.start, .stop, .release])

    let stateEntries = sink.entries.filter {
        $0.subsystem == .vm && $0.category == VMLogCategory.lifecycle.rawValue
            && $0.publicMessage.hasPrefix("VM state changed")
    }
    #expect(stateEntries.count == 4)
    #expect(stateEntries.allSatisfy { $0.operationID != nil })
    #expect(
        diagnostics.perfTimeline.snapshot().map(\.marker).contains(.vmStart)
    )
}

@Test(.timeLimit(.minutes(1)))
func vmControllerMapsDriverStartFailureAndReset() async throws {
    let underlying = VZErrorInfo(
        domain: "VZErrorDomain",
        code: 2,
        description: "private kernel path"
    )
    let driver = FakeVirtualMachineDriver(
        script: FakeVirtualMachineDriverScript(start: .failure(underlying))
    )
    let factory = FakeVirtualMachineDriverFactory(drivers: [driver])
    let controller = makeController(factory: factory)
    let stateStream = controller.stateUpdates
    let failure = VMFailure.startFailed(underlying: underlying)

    await #expect(throws: failure) {
        try await controller.start()
    }
    #expect(await collectUntil(stateStream, reaches: .failed(failure)))
    #expect(await controller.state == .failed(failure))

    try await controller.reset()
    #expect(await controller.state == .stopped)
    #expect(driver.operations == [.start, .release])
}

@Test(.timeLimit(.minutes(1)))
func vmControllerMapsDriverCreationValidationFailure() async throws {
    let underlying = VZErrorInfo(
        domain: "VZErrorDomain",
        code: 3,
        description: "framework rejected configuration"
    )
    let factory = FakeVirtualMachineDriverFactory(drivers: [], failure: underlying)
    let controller = makeController(factory: factory)
    let failure = VMFailure.startFailed(underlying: underlying)

    await #expect(throws: failure) {
        try await controller.start()
    }
    #expect(await controller.state == .failed(failure))
    try await controller.reset()
    #expect(await controller.state == .stopped)
}

@Test(.timeLimit(.minutes(1)))
func vmControllerMapsGuestStopFromRunningAndStopping() async throws {
    let spontaneousReleaseGate = FakeVirtualMachineDriverGate()
    let spontaneousDriver = FakeVirtualMachineDriver(
        script: FakeVirtualMachineDriverScript(releaseGate: spontaneousReleaseGate)
    )
    let spontaneousController = makeController(
        factory: FakeVirtualMachineDriverFactory(drivers: [spontaneousDriver])
    )
    let spontaneousStates = spontaneousController.stateUpdates

    try await spontaneousController.start()
    spontaneousDriver.emit(.guestDidStop)
    await spontaneousReleaseGate.waitUntilEntered()
    #expect(await collectUntil(spontaneousStates, reaches: .stopped))
    #expect(spontaneousDriver.operations == [.start, .release])
    await spontaneousReleaseGate.open()

    let requestedReleaseGate = FakeVirtualMachineDriverGate()
    let requestedDriver = FakeVirtualMachineDriver(
        script: FakeVirtualMachineDriverScript(releaseGate: requestedReleaseGate)
    )
    let requestedController = makeController(
        factory: FakeVirtualMachineDriverFactory(drivers: [requestedDriver])
    )
    let requestedStates = requestedController.stateUpdates

    try await requestedController.start()
    try await requestedController.requestGuestStop()
    #expect(await requestedController.state == .stopping)
    requestedDriver.emit(.guestDidStop)
    await requestedReleaseGate.waitUntilEntered()
    #expect(await collectUntil(requestedStates, reaches: .stopped))
    #expect(requestedDriver.operations == [.start, .requestStop, .release])
    await requestedReleaseGate.open()
}

@Test(.timeLimit(.minutes(1)))
func vmControllerWaitsForForcedStopCallbackBeforeReleasingOnGuestStop() async throws {
    let stopGate = FakeVirtualMachineDriverGate(ignoresCancellation: true)
    let driver = FakeVirtualMachineDriver(
        script: FakeVirtualMachineDriverScript(stopGate: stopGate)
    )
    let controller = makeController(
        factory: FakeVirtualMachineDriverFactory(drivers: [driver])
    )

    try await controller.start()
    let stopTask = Task {
        try await controller.stop()
    }
    await stopGate.waitUntilEntered()
    driver.emit(.guestDidStop)
    await Task.yield()

    #expect(await controller.state == .stopping)
    #expect(driver.operations == [.start, .stop])

    await stopGate.open()
    try await stopTask.value
    #expect(await controller.state == .stopped)
    #expect(driver.operations == [.start, .stop, .release])
}

@Test(.timeLimit(.minutes(1)))
func vmControllerMapsStopErrorsAndIgnoresDuplicateDelegateFailure() async throws {
    let underlying = VZErrorInfo(
        domain: "VZErrorDomain",
        code: 4,
        description: "guest exited unexpectedly"
    )
    let driver = FakeVirtualMachineDriver()
    let controller = makeController(
        factory: FakeVirtualMachineDriverFactory(drivers: [driver])
    )
    let states = controller.stateUpdates
    let failure = VMFailure.stoppedWithError(underlying: underlying)

    try await controller.start()
    driver.emit(.didStopWithError(underlying))
    #expect(await collectUntil(states, reaches: .failed(failure)))
    driver.emit(.didStopWithError(underlying))
    await Task.yield()
    #expect(await controller.state == .failed(failure))
}

@Test(.timeLimit(.minutes(1)))
func vmControllerKeepsRunningWhenNetworkAttachmentDisconnects() async throws {
    let underlying = VZErrorInfo(
        domain: "VZErrorDomain",
        code: 5,
        description: "network disconnected"
    )
    let sink = RecordingLogSink()
    let driver = FakeVirtualMachineDriver()
    let restartDriver = FakeVirtualMachineDriver()
    let controller = makeController(
        factory: FakeVirtualMachineDriverFactory(drivers: [driver, restartDriver]),
        diagnostics: .testing(logSink: sink),
        networkEnabled: true
    )
    var networkUpdates = controller.networkHealthUpdates.makeAsyncIterator()
    #expect(await networkUpdates.next() == .available)

    try await controller.start()
    let startOperationID = sink.entries.first {
        $0.subsystem == .vm && $0.category == VMLogCategory.lifecycle.rawValue
            && $0.publicMessage == "VM state changed from stopped to starting"
    }?.operationID
    driver.emit(.networkAttachmentDisconnected(underlying))
    #expect(
        await networkUpdates.next()
            == .disconnected(domain: "VZErrorDomain", code: 5)
    )
    #expect(await waitForNetworkError(underlying, on: controller))
    #expect(await controller.state == .running)
    #expect(await controller.networkAttachmentError == underlying)

    let eventEntry = sink.entries.first {
        $0.subsystem == .vm
            && $0.category == VMLogCategory.network.rawValue
            && $0.publicMessage.hasPrefix("Network attachment disconnected (")
    }
    #expect(startOperationID != nil)
    #expect(eventEntry?.operationID != nil)
    #expect(eventEntry?.operationID != startOperationID)
    #expect(eventEntry?.level == .warning)
    #expect(eventEntry?.errorCode == VMFailure.networkAttachmentLost.qualifiedCode)
    #expect(eventEntry?.publicMessage.contains("VZErrorDomain, code 5") == true)

    try await controller.stop()
    try await controller.start()
    #expect(await networkUpdates.next() == .available)
    try await controller.stop()
}

@Test(.timeLimit(.minutes(1)))
func vmControllerIgnoresEventsFromPreviousGenerationDuringRestart() async throws {
    let firstDriver = FakeVirtualMachineDriver()
    let startGate = FakeVirtualMachineDriverGate()
    let secondDriver = FakeVirtualMachineDriver(
        script: FakeVirtualMachineDriverScript(startGate: startGate)
    )
    let controller = makeController(
        factory: FakeVirtualMachineDriverFactory(drivers: [firstDriver, secondDriver])
    )

    try await controller.start()
    let previousGeneration = await controller.vmGeneration
    try await controller.stop()

    let startTask = Task {
        try await controller.start()
    }
    await startGate.waitUntilEntered()
    #expect(await controller.state == .starting)

    await controller.receive(
        .didStopWithError(
            VZErrorInfo(domain: "VZErrorDomain", code: 6, description: "stale stop")
        ),
        generation: previousGeneration
    )
    #expect(await controller.state == .starting)

    await startGate.open()
    try await startTask.value
    #expect(await controller.state == .running)
    #expect(secondDriver.operations == [.start])
}

@Test(.timeLimit(.minutes(1)))
func vmControllerLogsConfiguredNetworkMACAsPublicConfigurationData() async throws {
    let sink = RecordingLogSink()
    let controller = VMController(
        definition: try makeValidatedDefinition(networkEnabled: true),
        diagnostics: .testing(logSink: sink),
        queue: VMQueue(label: "io.apkrun.vm.network-config.test"),
        driverFactory: FakeVirtualMachineDriverFactory(
            drivers: [FakeVirtualMachineDriver()]
        )
    )

    try await controller.start()

    let entry = try #require(
        sink.entries.first {
            $0.subsystem == .vm && $0.category == VMLogCategory.config.rawValue
                && $0.publicMessage.contains("Configured VM NAT network")
        }
    )
    #expect(entry.publicMessage.contains("MAC 02:00:00:00:00:01"))
    #expect(entry.operationID != nil)
    try await controller.stop()
}

@Test(.timeLimit(.minutes(1)))
func vmControllerRejectsOperationsWhileGuestStopReleasesResources() async throws {
    let releaseGate = FakeVirtualMachineDriverGate()
    let firstDriver = FakeVirtualMachineDriver(
        script: FakeVirtualMachineDriverScript(releaseGate: releaseGate)
    )
    let secondDriver = FakeVirtualMachineDriver()
    let controller = makeController(
        factory: FakeVirtualMachineDriverFactory(drivers: [firstDriver, secondDriver])
    )

    try await controller.start()
    firstDriver.emit(.guestDidStop)
    await releaseGate.waitUntilEntered()
    #expect(await controller.state == .stopped)

    await #expect(throws: VMFailure.invalidTransition(from: .stopped, to: .stopping)) {
        try await controller.stop()
    }
    await releaseGate.open()

    try await controller.start()
    try await controller.pause()
    #expect(secondDriver.operations == [.start, .pause])
    #expect(firstDriver.operations == [.start, .release])
    #expect(firstDriver.operationsAfterRelease.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func vmControllerPauseAndResumeUseTheExplicitStateMachine() async throws {
    let driver = FakeVirtualMachineDriver()
    let controller = makeController(
        factory: FakeVirtualMachineDriverFactory(drivers: [driver])
    )
    let states = controller.stateUpdates
    let collectedStates = Task {
        await collectStates(states, count: 5)
    }

    try await controller.start()
    try await controller.pause()
    try await controller.resume()

    #expect(
        await collectedStates.value == [
            .stopped,
            .starting,
            .running,
            .paused,
            .running,
        ]
    )
    #expect(driver.operations == [.start, .pause, .resume])
}

@Test(.timeLimit(.minutes(1)))
func vmControllerRejectsPublicCallsInTheWrongState() async throws {
    let controller = makeController(
        factory: FakeVirtualMachineDriverFactory(drivers: [FakeVirtualMachineDriver()])
    )

    await #expect(throws: VMFailure.invalidTransition(from: .stopped, to: .paused)) {
        try await controller.pause()
    }
    await #expect(throws: VMFailure.invalidTransition(from: .stopped, to: .stopped)) {
        try await controller.reset()
    }
    #expect(await controller.state == .stopped)
}

@Test(.timeLimit(.minutes(1)))
func vmControllerTimesOutForcedStopAndCanResetTheFailure() async throws {
    let gate = FakeVirtualMachineDriverGate()
    let driver = FakeVirtualMachineDriver(
        script: FakeVirtualMachineDriverScript(stopGate: gate)
    )
    let controller = makeController(
        factory: FakeVirtualMachineDriverFactory(drivers: [driver]),
        forcedStopTimeout: .milliseconds(100)
    )

    try await controller.start()
    let stopTask = Task {
        try await controller.stop()
    }
    await gate.waitUntilEntered()

    var stopFailure: VMFailure?
    do {
        try await stopTask.value
    } catch let failure as VMFailure {
        stopFailure = failure
    }
    #expect(stopFailure == .stopTimedOut)
    #expect(await controller.state == .failed(.stopTimedOut))

    try await controller.reset()
    #expect(await controller.state == .stopped)
    #expect(!(await gate.isOperationPending))
    #expect(driver.operations == [.start, .stop, .release])
}

@Test(.timeLimit(.minutes(1)))
func vmControllerBoundsResetWhileVZStopCallbackIsPending() async throws {
    let gate = FakeVirtualMachineDriverGate(ignoresCancellation: true)
    let driver = FakeVirtualMachineDriver(
        script: FakeVirtualMachineDriverScript(stopGate: gate)
    )
    let controller = makeController(
        factory: FakeVirtualMachineDriverFactory(drivers: [driver]),
        forcedStopTimeout: .milliseconds(50)
    )

    try await controller.start()
    let stopTask = Task {
        try await controller.stop()
    }
    await gate.waitUntilEntered()
    await #expect(throws: VMFailure.stopTimedOut) {
        try await stopTask.value
    }

    await #expect(throws: VMFailure.stopTimedOut) {
        try await controller.reset()
    }
    #expect(await controller.state == .failed(.stopTimedOut))
    #expect(driver.operations == [.start, .stop])

    await gate.open()
    try await controller.reset()
    #expect(await controller.state == .stopped)
    #expect(driver.operations == [.start, .stop, .release])
}

private func makeController(
    factory: any VirtualMachineDriverFactory,
    diagnostics: DiagnosticsContext = .testing(),
    forcedStopTimeout: Duration = .seconds(10),
    networkEnabled: Bool = false
) -> VMController {
    let definition = try! makeValidatedDefinition(networkEnabled: networkEnabled)
    return VMController(
        definition: definition,
        diagnostics: diagnostics,
        queue: VMQueue(label: "io.apkrun.vm.controller.test"),
        driverFactory: factory,
        forcedStopTimeout: forcedStopTimeout
    )
}

private func makeValidatedDefinition(networkEnabled: Bool = false) throws -> ValidatedVMDefinition {
    var builder = VMDefinitionBuilder()
    if networkEnabled {
        builder.network = .nat(macAddress: "02:00:00:00:00:01")
    }
    var header = Data(repeating: 0, count: 64)
    header.replaceSubrange(0x38..<0x3C, with: [0x41, 0x52, 0x4D, 0x64])
    let host = FakeVMHostEnvironment(
        fileProbes: [
            builder.kernelURL: VMFileProbeFixture(
                sizeBytes: 64,
                first64Bytes: header
            )
        ]
    )
    builder.machineIdentifier = MachineIdentity.newMachineIdentifier()
    let validator = VMDefinitionValidator(
        host: host,
        frameworkValidator: FakeFrameworkConfigurationValidator()
    )
    return try validator.validate(builder.build())
}

private func collectStates(
    _ updates: AsyncStream<VMState>,
    count: Int
) async -> [VMState] {
    var result: [VMState] = []
    for await state in updates {
        result.append(state)
        if result.count == count {
            return result
        }
    }
    return result
}

private func collectUntil(
    _ updates: AsyncStream<VMState>,
    reaches expected: VMState
) async -> Bool {
    var isInitialState = true
    for await state in updates {
        if isInitialState {
            isInitialState = false
            continue
        }
        if state == expected { return true }
    }
    return false
}

private func waitForNetworkError(
    _ expected: VZErrorInfo,
    on controller: VMController
) async -> Bool {
    for _ in 0..<1_000 {
        if await controller.networkAttachmentError == expected { return true }
        await Task.yield()
    }
    return false
}

private func waitForState(_ expected: VMState, on controller: VMController) async -> Bool {
    for _ in 0..<1_000 {
        if await controller.state == expected { return true }
        await Task.yield()
    }
    return await controller.state == expected
}
