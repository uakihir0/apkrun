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

    #expect(await registry.checkIDs() == ["vm.virtualizationSupported", "vm.state"])
    #expect(results.map(\.id) == ["vm.virtualizationSupported", "vm.state"])
    #expect(results[0].state == .failure)
    #expect(results[0].error?.code == "vm.virtualizationUnavailable")
    #expect(results[1].state == .pass)
    #expect(results[1].detail == "The virtual machine is stopped.")
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

private func makeValidatedDefinition() throws -> ValidatedVMDefinition {
    let builder = VMDefinitionBuilder()
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
