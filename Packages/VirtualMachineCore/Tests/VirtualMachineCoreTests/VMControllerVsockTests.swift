import Darwin
import DiagnosticsCore
import DiagnosticsCoreTestSupport
import Foundation
import Testing
import VirtualMachineCoreTestSupport

@testable import VirtualMachineCore

@Test(.timeLimit(.minutes(1)))
func vmControllerConnectsToGuestVsockAndClosesConnectionOnStop() async throws {
    let queue = VMQueue(label: "io.apkrun.vsock.connect.test")
    let (connection, closeProbe) = makeTestConnection(queue: queue)
    let driver = FakeVirtualMachineDriver(
        script: FakeVirtualMachineDriverScript(
            connectHandler: { port, completion in
                #expect(port == 7000)
                completion(.success(connection))
            }
        )
    )
    let sink = RecordingLogSink()
    let controller = makeVsockController(
        driver: driver,
        queue: queue,
        diagnostics: .testing(logSink: sink)
    )

    try await controller.start()
    let connected = try await controller.connect(
        vsockPort: 7000,
        timeout: .seconds(1)
    )

    #expect(connected === connection)
    #expect(driver.operations.contains(.connect(port: 7000)))
    let log = try #require(
        sink.entries.first {
            $0.subsystem == .vm
                && $0.category == VMLogCategory.vsock.rawValue
                && $0.publicMessage == "Connected to guest vsock port 7000"
        }
    )
    #expect(log.operationID != nil)

    try await controller.stop()
    await connection.closed.value
    #expect(closeProbe.closeCount == 1)
}

@Test(.timeLimit(.minutes(1)))
func vmControllerRejectsVsockWhenDeviceIsNotConfigured() async throws {
    let driver = FakeVirtualMachineDriver()
    let controller = makeVsockController(driver: driver, vsockEnabled: false)

    try await controller.start()
    await #expect(throws: VMFailure.vsockDeviceNotConfigured) {
        try await controller.connect(vsockPort: 7000, timeout: .seconds(1))
    }
    #expect(!driver.operations.contains(.connect(port: 7000)))
    try await controller.stop()
}

@Test(.timeLimit(.minutes(1)))
func vmControllerConnectRequiresRunningAndNoLifecycleOperation() async throws {
    let driver = FakeVirtualMachineDriver()
    let controller = makeVsockController(driver: driver)

    await #expect(
        throws: VMFailure.invalidTransition(from: .stopped, to: .running)
    ) {
        try await controller.connect(vsockPort: 7000, timeout: .seconds(1))
    }

    try await controller.start()
    try await controller.pause()
    await #expect(
        throws: VMFailure.invalidTransition(from: .paused, to: .running)
    ) {
        try await controller.connect(vsockPort: 7000, timeout: .seconds(1))
    }
    try await controller.resume()
    try await controller.stop()
    #expect(!driver.operations.contains(.connect(port: 7000)))
}

@Test(.timeLimit(.minutes(1)))
func vmControllerRejectsNewVsockConnectWhilePauseIsPending() async throws {
    let pauseGate = FakeVirtualMachineDriverGate()
    let driver = FakeVirtualMachineDriver(
        script: FakeVirtualMachineDriverScript(pauseGate: pauseGate)
    )
    let controller = makeVsockController(driver: driver)

    try await controller.start()
    let pauseTask = Task { try await controller.pause() }
    await pauseGate.waitUntilEntered()

    await #expect(
        throws: VMFailure.invalidTransition(from: .paused, to: .running)
    ) {
        try await controller.connect(vsockPort: 7000, timeout: .seconds(1))
    }
    #expect(!driver.operations.contains(.connect(port: 7000)))

    await pauseGate.open()
    try await pauseTask.value
    try await controller.stop()
}

@Test(.timeLimit(.minutes(1)))
func vmControllerClosesVsockConnectCompletedWhilePauseIsPending() async throws {
    let queue = VMQueue(label: "io.apkrun.vsock.pause-pending.test")
    let pauseGate = FakeVirtualMachineDriverGate()
    let connectGate = FakeVirtualMachineDriverGate()
    let (connection, closeProbe) = makeTestConnection(queue: queue)
    let driver = FakeVirtualMachineDriver(
        script: FakeVirtualMachineDriverScript(
            pauseGate: pauseGate,
            connectHandler: { _, completion in
                Task.detached {
                    await connectGate.waitUntilOpen()
                    completion(.success(connection))
                }
            }
        )
    )
    let controller = makeVsockController(driver: driver, queue: queue)

    try await controller.start()
    let connectTask = Task {
        try await controller.connect(vsockPort: 7000, timeout: .seconds(5))
    }
    let connectWasRequested = await waitForConnectRequest(from: driver)
    #expect(connectWasRequested)
    guard connectWasRequested else {
        connectTask.cancel()
        connection.close()
        await connectGate.open()
        try await controller.stop()
        _ = await connectTask.result
        await connection.closed.value
        return
    }

    let pauseTask = Task { try await controller.pause() }
    await pauseGate.waitUntilEntered()
    await #expect(
        throws: VMFailure.invalidTransition(from: .paused, to: .running)
    ) {
        try await connectTask.value
    }

    await connectGate.open()
    await connection.closed.value
    #expect(closeProbe.closeCount == 1)

    await pauseGate.open()
    try await pauseTask.value
    try await controller.stop()
}

@Test(.timeLimit(.minutes(1)))
func vmControllerProcessesStartupStopBeforeEnablingVsock() async throws {
    let startGate = FakeVirtualMachineDriverGate()
    let driver = FakeVirtualMachineDriver(
        script: FakeVirtualMachineDriverScript(startGate: startGate)
    )
    let controller = makeVsockController(driver: driver)

    let startTask = Task { try await controller.start() }
    await startGate.waitUntilEntered()
    let generation = await controller.vmGeneration
    await controller.receive(.guestDidStop, generation: generation)
    await startGate.open()
    try await startTask.value

    await #expect(
        throws: VMFailure.invalidTransition(from: .stopped, to: .running)
    ) {
        try await controller.connect(vsockPort: 7000, timeout: .seconds(1))
    }
    #expect(await controller.state == .stopped)
    #expect(driver.operations == [.start, .release])
}

@Test(.timeLimit(.minutes(1)))
func vmControllerMapsUnavailableVsockDeviceFromDriver() async throws {
    let driver = FakeVirtualMachineDriver(
        script: FakeVirtualMachineDriverScript(
            connectHandler: { _, completion in
                completion(.failure(.vsockDeviceUnavailable))
            }
        )
    )
    let controller = makeVsockController(driver: driver)

    try await controller.start()
    await #expect(throws: VMFailure.vsockDeviceUnavailable) {
        try await controller.connect(vsockPort: 7000, timeout: .seconds(1))
    }
    try await controller.stop()
}

@Test(.timeLimit(.minutes(1)))
func vmControllerMapsCallerCancellationAndClosesLateSuccess() async throws {
    let queue = VMQueue(label: "io.apkrun.vsock.cancellation.test")
    let connectGate = FakeVirtualMachineDriverGate()
    let (connection, closeProbe) = makeTestConnection(queue: queue)
    let driver = FakeVirtualMachineDriver(
        script: FakeVirtualMachineDriverScript(
            connectHandler: { _, completion in
                Task.detached {
                    await connectGate.waitUntilOpen()
                    completion(.success(connection))
                }
            }
        )
    )
    let controller = makeVsockController(driver: driver, queue: queue)

    try await controller.start()
    let connectTask = Task {
        try await controller.connect(vsockPort: 7000, timeout: .seconds(5))
    }
    let connectWasRequested = await waitForConnectRequest(from: driver)
    #expect(connectWasRequested)
    guard connectWasRequested else {
        connectTask.cancel()
        connection.close()
        await connectGate.open()
        try await controller.stop()
        _ = await connectTask.result
        await connection.closed.value
        return
    }
    connectTask.cancel()
    await #expect(throws: CancellationError.self) {
        try await connectTask.value
    }

    await connectGate.open()
    await connection.closed.value
    #expect(closeProbe.closeCount == 1)
    try await controller.stop()
}

@Test(.timeLimit(.minutes(1)))
func vmControllerDoesNotStartVsockConnectForZeroTimeout() async throws {
    let driver = FakeVirtualMachineDriver()
    let controller = makeVsockController(driver: driver)

    try await controller.start()
    await #expect(throws: VMFailure.vsockConnectTimedOut(port: 7000)) {
        try await controller.connect(vsockPort: 7000, timeout: .zero)
    }
    #expect(!driver.operations.contains(.connect(port: 7000)))
    try await controller.stop()
}

@Test(.timeLimit(.minutes(1)))
func vmControllerTimesOutVsockConnectAndClosesLateSuccess() async throws {
    let queue = VMQueue(label: "io.apkrun.vsock.late-success.test")
    let connectGate = FakeVirtualMachineDriverGate()
    let (connection, closeProbe) = makeTestConnection(queue: queue)
    let driver = FakeVirtualMachineDriver(
        script: FakeVirtualMachineDriverScript(
            connectHandler: { _, completion in
                Task.detached {
                    await connectGate.waitUntilOpen()
                    completion(.success(connection))
                }
            }
        )
    )
    let controller = makeVsockController(driver: driver, queue: queue)

    try await controller.start()
    let connectTask = Task {
        try await controller.connect(vsockPort: 7000, timeout: .seconds(1))
    }
    let connectWasRequested = await waitForConnectRequest(from: driver)
    #expect(connectWasRequested)
    guard connectWasRequested else {
        await #expect(throws: VMFailure.vsockConnectTimedOut(port: 7000)) {
            try await connectTask.value
        }
        connection.close()
        await connectGate.open()
        await connection.closed.value
        try await controller.stop()
        return
    }
    await #expect(throws: VMFailure.vsockConnectTimedOut(port: 7000)) {
        try await connectTask.value
    }

    await connectGate.open()
    await connection.closed.value
    #expect(closeProbe.closeCount == 1)
    try await controller.stop()
}

@Test(.timeLimit(.minutes(1)))
func vmControllerMapsRefusedAndOtherVsockErrors() async throws {
    let refused = VZErrorInfo(
        domain: NSPOSIXErrorDomain,
        code: Int(ECONNREFUSED),
        description: "connection refused"
    )
    let refusedDriver = FakeVirtualMachineDriver(
        script: FakeVirtualMachineDriverScript(
            connectHandler: { _, completion in
                completion(.failure(.virtualization(refused)))
            }
        )
    )
    let sink = RecordingLogSink()
    let refusedController = makeVsockController(
        driver: refusedDriver,
        diagnostics: .testing(logSink: sink)
    )

    try await refusedController.start()
    await #expect(throws: VMFailure.vsockPortNotListening(port: 7999)) {
        try await refusedController.connect(vsockPort: 7999, timeout: .seconds(1))
    }
    let refusedLog = try #require(
        sink.entries.first {
            $0.subsystem == .vm
                && $0.category == VMLogCategory.vsock.rawValue
                && $0.publicMessage.contains("Guest vsock port 7999 is not listening")
        }
    )
    #expect(refusedLog.level == .warning)
    #expect(refusedLog.errorCode == VMFailure.vsockPortNotListening(port: 7999).qualifiedCode)
    #expect(refusedLog.operationID != nil)
    try await refusedController.stop()

    let other = VZErrorInfo(
        domain: "VZErrorDomain",
        code: 17,
        description: "framework connection failure"
    )
    let otherDriver = FakeVirtualMachineDriver(
        script: FakeVirtualMachineDriverScript(
            connectHandler: { _, completion in
                completion(.failure(.virtualization(other)))
            }
        )
    )
    let otherController = makeVsockController(driver: otherDriver)

    try await otherController.start()
    await #expect(
        throws: VMFailure.vsockConnectFailed(port: 7000, underlying: other)
    ) {
        try await otherController.connect(vsockPort: 7000, timeout: .seconds(1))
    }
    try await otherController.stop()
}

@Test(.timeLimit(.minutes(1)))
func vmControllerCancelsPendingVsockAndClosesLateSuccessOnStop() async throws {
    let queue = VMQueue(label: "io.apkrun.vsock.stop-pending.test")
    let connectGate = FakeVirtualMachineDriverGate()
    let (connection, closeProbe) = makeTestConnection(queue: queue)
    let driver = FakeVirtualMachineDriver(
        script: FakeVirtualMachineDriverScript(
            connectHandler: { _, completion in
                Task.detached {
                    await connectGate.waitUntilOpen()
                    completion(.success(connection))
                }
            }
        )
    )
    let controller = makeVsockController(driver: driver, queue: queue)

    try await controller.start()
    let connectTask = Task {
        try await controller.connect(vsockPort: 7000, timeout: .seconds(5))
    }
    let connectWasRequested = await waitForConnectRequest(from: driver)
    #expect(connectWasRequested)
    guard connectWasRequested else {
        connectTask.cancel()
        connection.close()
        await connectGate.open()
        try await controller.stop()
        _ = await connectTask.result
        await connection.closed.value
        return
    }

    try await controller.stop()
    await #expect(
        throws: VMFailure.invalidTransition(from: .stopping, to: .running)
    ) {
        try await connectTask.value
    }

    await connectGate.open()
    await connection.closed.value
    #expect(closeProbe.closeCount == 1)
}

@Test(.timeLimit(.minutes(1)))
func vmControllerClosesVsockConnectionWhenGuestStops() async throws {
    let queue = VMQueue(label: "io.apkrun.vsock.guest-stop.test")
    let (connection, closeProbe) = makeTestConnection(queue: queue)
    let driver = FakeVirtualMachineDriver(
        script: FakeVirtualMachineDriverScript(
            connectHandler: { _, completion in completion(.success(connection)) }
        )
    )
    let controller = makeVsockController(driver: driver, queue: queue)

    try await controller.start()
    _ = try await controller.connect(vsockPort: 7000, timeout: .seconds(1))
    driver.emit(.guestDidStop)
    await connection.closed.value

    #expect(closeProbe.closeCount == 1)
    #expect(await controller.state == .stopped)
}

private func makeVsockController(
    driver: FakeVirtualMachineDriver,
    queue: VMQueue = VMQueue(label: "io.apkrun.vsock.controller.test"),
    diagnostics: DiagnosticsContext = .testing(),
    vsockEnabled: Bool = true
) -> VMController {
    VMController(
        definition: try! makeValidatedDefinition(vsockEnabled: vsockEnabled),
        diagnostics: diagnostics,
        queue: queue,
        driverFactory: FakeVirtualMachineDriverFactory(drivers: [driver])
    )
}

private func makeValidatedDefinition(vsockEnabled: Bool) throws -> ValidatedVMDefinition {
    var builder = VMDefinitionBuilder()
    builder.vsockEnabled = vsockEnabled
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

private func makeTestConnection(
    queue: VMQueue
) -> (VsockConnection, VsockConnectionCloseProbe) {
    var descriptors = [Int32](repeating: -1, count: 2)
    let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors)
    precondition(result == 0)

    let hostDescriptor = descriptors[0]
    let peerDescriptor = descriptors[1]
    let closeProbe = VsockConnectionCloseProbe()
    let connection = VsockConnection(
        testFileDescriptor: hostDescriptor,
        queue: queue,
        onClose: {
            Darwin.close(hostDescriptor)
            Darwin.close(peerDescriptor)
            closeProbe.recordClose()
        }
    )
    return (connection, closeProbe)
}

private func waitForConnectRequest(
    from driver: FakeVirtualMachineDriver
) async -> Bool {
    for _ in 0..<500 {
        if driver.operations.contains(.connect(port: 7000)) {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return driver.operations.contains(.connect(port: 7000))
}

private final class VsockConnectionCloseProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCloseCount = 0

    var closeCount: Int {
        lock.withLock { storedCloseCount }
    }

    func recordClose() {
        lock.withLock { storedCloseCount += 1 }
    }
}
