import DiagnosticsCore
import DiagnosticsCoreTestSupport
import Foundation
import Testing
import VirtualMachineCoreTestSupport

@testable import VirtualMachineCore

@Test
func vmHealthChecksReportVirtualizationAvailabilityAndStoppedState() async throws {
    let registry = HealthCheckRegistry()
    let controller = makeController(
        factory: FakeVirtualMachineDriverFactory(drivers: [])
    )
    try await VMHealthChecks.register(
        in: registry,
        controller: controller,
        virtualizationSupported: { false }
    )
    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": FileManager.default.temporaryDirectory.path]
    )
    let context = HealthContext(
        daemonAvailable: true,
        runtimeRunning: false,
        paths: paths,
        clock: ManualDiagnosticsClock()
    )
    let results = await registry.run(context: context)

    #expect(
        await registry.checkIDs()
            == ["vm.virtualizationSupported", "vm.state", "vm.network", "vm.consoleWriter"]
    )
    #expect(
        results.map(\.id)
            == ["vm.virtualizationSupported", "vm.state", "vm.network", "vm.consoleWriter"]
    )
    #expect(results[0].state == .failure)
    #expect(results[0].error?.code == "vm.virtualizationUnavailable")
    #expect(results[1].state == .pass)
    #expect(results[1].detail == "The virtual machine is stopped.")
    #expect(results[2].state == .skipped)
    #expect(results[3].state == .pass)
}

@Test(.timeLimit(.minutes(1)))
func vmNetworkHealthWarnsOnDisconnectAndResetsAfterRestart() async throws {
    let firstDriver = FakeVirtualMachineDriver()
    let secondDriver = FakeVirtualMachineDriver()
    let controller = VMController(
        definition: try makeValidatedDefinition(networkEnabled: true),
        diagnostics: .testing(),
        queue: VMQueue(label: "io.apkrun.vm.network-health.test"),
        driverFactory: FakeVirtualMachineDriverFactory(
            drivers: [firstDriver, secondDriver]
        )
    )
    let registry = HealthCheckRegistry()
    // Inject the capability probe. The real VZVirtualMachine.isSupported is false on
    // hosted CI runners, which would turn every verdict into hostUnsupported.
    try await VMHealthChecks.register(
        in: registry,
        controller: controller,
        virtualizationSupported: { true }
    )
    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": FileManager.default.temporaryDirectory.path]
    )
    let context = HealthContext(
        daemonAvailable: true,
        runtimeRunning: true,
        paths: paths,
        clock: ManualDiagnosticsClock()
    )

    try await controller.start()
    let connectedResults = await registry.run(context: context)
    let connected = try #require(connectedResults.first { $0.id == "vm.network" })
    #expect(connected.state == .pass)

    let underlying = VZErrorInfo(
        domain: "VZErrorDomain",
        code: 5,
        description: "private diagnostic detail"
    )
    firstDriver.emit(.networkAttachmentDisconnected(underlying))
    #expect(await waitForNetworkError(underlying, on: controller))
    #expect(await controller.state == .running)

    let disconnectedResults = await registry.run(context: context)
    let disconnected = try #require(disconnectedResults.first { $0.id == "vm.network" })
    #expect(disconnected.state == .warning)
    #expect(disconnected.error?.code == VMFailure.networkAttachmentLost.qualifiedCode)
    #expect(
        disconnected.error?.remediation?.fallback
            == "Restart Android. If it happens again, create a diagnostics report."
    )
    #expect(
        HealthVerdict.evaluate(
            results: disconnectedResults,
            context: HealthVerdictContext(runtimeState: .ready)
        ) == .degraded
    )

    try await controller.stop()
    try await controller.start()
    let reconnectedResults = await registry.run(context: context)
    let reconnected = try #require(reconnectedResults.first { $0.id == "vm.network" })
    #expect(reconnected.state == .pass)
    try await controller.stop()
}

@Test
func vmConsoleLogHealthWarnsWhenLogFilesCannotBeOpened() async throws {
    let fileSystem = FakeConsoleLogFileSystem()
    fileSystem.failOpens()
    let controller = VMController(
        definition: try makeValidatedDefinition(),
        diagnostics: .testing(),
        queue: VMQueue(label: "io.apkrun.vm.console-health.test"),
        driverFactory: FakeVirtualMachineDriverFactory(drivers: [FakeVirtualMachineDriver()]),
        consoleLogFileSystem: fileSystem,
        consoleLogClock: ManualConsoleLogClock()
    )
    try await controller.start()

    let registry = HealthCheckRegistry()
    try await VMHealthChecks.register(in: registry, controller: controller)
    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": FileManager.default.temporaryDirectory.path]
    )
    let results = await registry.run(
        context: HealthContext(
            daemonAvailable: true,
            runtimeRunning: true,
            paths: paths,
            clock: ManualDiagnosticsClock()
        )
    )

    let consoleResult = try #require(results.first { $0.id == "vm.consoleWriter" })
    #expect(consoleResult.state == .warning)
    #expect(consoleResult.error?.code == "vm.consoleLogWriteFailed")
    try await controller.stop()
}

@Test
func vmStateHealthCheckReportsCataloguedFailure() async throws {
    let driver = FakeVirtualMachineDriver(
        script: FakeVirtualMachineDriverScript(
            start: .failure(
                VZErrorInfo(domain: "VZErrorDomain", code: 2, description: "private")
            )
        )
    )
    let controller = makeController(
        factory: FakeVirtualMachineDriverFactory(drivers: [driver])
    )
    await #expect(
        throws: VMFailure.startFailed(
            underlying: VZErrorInfo(domain: "VZErrorDomain", code: 2, description: "private")
        )
    ) {
        try await controller.start()
    }

    let registry = HealthCheckRegistry()
    try await VMHealthChecks.register(
        in: registry,
        controller: controller,
        virtualizationSupported: { true }
    )
    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": FileManager.default.temporaryDirectory.path]
    )
    let results = await registry.run(
        context: HealthContext(
            daemonAvailable: true,
            runtimeRunning: false,
            paths: paths,
            clock: ManualDiagnosticsClock()
        )
    )

    let stateResult = try #require(results.first { $0.id == "vm.state" })
    #expect(stateResult.state == .failure)
    #expect(stateResult.error?.code == "vm.startFailed")
    #expect(stateResult.error?.message.parameters.isEmpty == true)
    #expect(stateResult.error?.message.fallback == "Android couldn't start.")
}

@Test(.timeLimit(.minutes(1)))
func failedVMTransitionSynchronizesConsoleLogsBeforeReset() async throws {
    let fileSystem = FakeConsoleLogFileSystem()
    let underlying = VZErrorInfo(
        domain: "VZErrorDomain",
        code: 2,
        description: "private"
    )
    let controller = VMController(
        definition: try makeValidatedDefinition(),
        diagnostics: .testing(),
        queue: VMQueue(label: "io.apkrun.vm.console-failed-flush.test"),
        driverFactory: FakeVirtualMachineDriverFactory(
            drivers: [
                FakeVirtualMachineDriver(
                    script: FakeVirtualMachineDriverScript(start: .failure(underlying))
                )
            ]
        ),
        consoleLogFileSystem: fileSystem,
        consoleLogClock: ManualConsoleLogClock()
    )

    await #expect(throws: VMFailure.startFailed(underlying: underlying)) {
        try await controller.start()
    }
    #expect(fileSystem.synchronizeCallCount >= 2)
    #expect(await controller.state == .failed(.startFailed(underlying: underlying)))

    try await controller.reset()
    #expect(await controller.state == .stopped)
}

private func makeController(
    factory: any VirtualMachineDriverFactory
) -> VMController {
    let definition = try! makeValidatedDefinition()
    return VMController(
        definition: definition,
        diagnostics: .testing(),
        queue: VMQueue(label: "io.apkrun.vm.health.test"),
        driverFactory: factory
    )
}

private func makeValidatedDefinition(networkEnabled: Bool = false) throws -> ValidatedVMDefinition {
    var builder = VMDefinitionBuilder()
    if networkEnabled {
        builder.networks = [.nat(macAddress: "02:00:00:00:00:01")]
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
    let validator = VMDefinitionValidator(
        host: host,
        frameworkValidator: FakeFrameworkConfigurationValidator()
    )
    return try validator.validate(builder.build())
}

private func waitForNetworkError(
    _ expected: VZErrorInfo,
    on controller: VMController
) async -> Bool {
    for _ in 0..<1_000 {
        if await controller.networkAttachmentError == expected { return true }
        await Task.yield()
    }
    return await controller.networkAttachmentError == expected
}
