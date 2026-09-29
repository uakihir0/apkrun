import DiagnosticsCore
import DiagnosticsCoreTestSupport
import Foundation
import Testing

@Test func hostChecksProducePassingResultsFromInjectedProbe() async {
    let results = await runHostChecks(deep: true)
    #expect(results.count == 9)
    #expect(results.allSatisfy { $0.state == .pass })
    #expect(results.contains(where: { $0.id == "host.hypervisor" && $0.group == .virtualization }))
    #expect(
        results.contains(where: {
            $0.id == "apkrund.registration" && $0.group == .backgroundService
        }))
}

@Test func hostRequirementChecksReportTypedFindings() async {
    let appleSilicon = await runHostChecks(state: .init(supportsAppleSilicon: false))
    #expect(result("host.appleSilicon", in: appleSilicon)?.state == .failure)
    #expect(result("host.appleSilicon", in: appleSilicon)?.error?.code == "runtime.hostRequirementsNotMet")
    #expect(result("host.appleSilicon", in: appleSilicon)?.error?.message.parameters["items"] == .text("appleSilicon"))

    let oldMacOS = await runHostChecks(state: .init(macOSVersion: HostOSVersion(major: 26, minor: 6)))
    #expect(result("host.macOSVersion", in: oldMacOS)?.state == .failure)
    #expect(result("host.macOSVersion", in: oldMacOS)?.detail == "macOS 26.6.0")

    let noHypervisor = await runHostChecks(state: .init(supportsHypervisor: false))
    #expect(result("host.hypervisor", in: noHypervisor)?.state == .failure)
    #expect(result("host.hypervisor", in: noHypervisor)?.error?.message.parameters["items"] == .text("virtualization"))

    let wrongLocation = await runHostChecks(state: .init(applicationIsInApplications: false))
    #expect(result("host.appLocation", in: wrongLocation)?.error?.code == "diagnostics.appNotInApplications")

    let badSignature = await runHostChecks(
        state: .init(applicationSignatureIsValid: false),
        deep: true
    )
    #expect(result("host.appSignature", in: badSignature)?.state == .failure)
    #expect(result("host.appSignature", in: badSignature)?.error?.action == .openDownloadsPage)

    let mismatchedBuilds = await runHostChecks(
        state: .init(
            componentBuilds: HostComponentBuilds(daemon: "2", cli: "1", launcher: "1")
        )
    )
    #expect(result("host.componentVersions", in: mismatchedBuilds)?.state == .failure)
    #expect(result("host.componentVersions", in: mismatchedBuilds)?.error?.message.parameters["build"] == .text("2"))
    #expect(result("host.componentVersions", in: mismatchedBuilds)?.detail == "apkrund uses build 2.")
}

@Test func hostStorageAndMemoryChecksApplyDocumentedThresholds() async {
    let unsupportedVolume = await runHostChecks(
        state: .init(dataVolumeInfo: HostVolumeInfo(isAPFS: false, availableBytes: 50_000_000_000))
    )
    #expect(result("host.dataVolume", in: unsupportedVolume)?.state == .failure)
    #expect(result("host.dataVolume", in: unsupportedVolume)?.error?.message.parameters["items"] == .text("apfsVolume"))

    let lowSpace = await runHostChecks(
        state: .init(dataVolumeInfo: HostVolumeInfo(isAPFS: true, availableBytes: 1_000_000_000))
    )
    #expect(result("host.dataVolume", in: lowSpace)?.state == .warning)
    #expect(result("host.dataVolume", in: lowSpace)?.error?.code == "diagnostics.lowDiskSpace")
    #expect(result("host.dataVolume", in: lowSpace)?.error?.action == .openStorageSettings)

    let lowMemory = await runHostChecks(
        state: .init(physicalMemoryBytes: 4 * 1_024 * 1_024 * 1_024)
    )
    #expect(result("host.memory", in: lowMemory)?.state == .warning)
    #expect(result("host.memory", in: lowMemory)?.error?.code == "diagnostics.lowMemory")
}

@Test func registrationCheckUsesBuildSpecificLaunchAgentLabelAndRemediation() async {
    let devBuild = BuildInfo(
        infoDictionary: [
            "APKRunBuildIdentity": "dev",
            "CFBundleVersion": "42",
        ]
    )
    let requiresApprovalProbe = FakeHostProbe(
        state: .init(
            componentBuilds: HostComponentBuilds(daemon: "42", cli: "42", launcher: "42"),
            runtimeRegistration: .requiresApproval
        )
    )
    let approvalResults = await runHostChecks(
        state: await requiresApprovalProbe.currentState(),
        buildInfo: devBuild,
        probe: requiresApprovalProbe
    )
    let approval = result("apkrund.registration", in: approvalResults)
    #expect(approval?.state == .failure)
    #expect(approval?.error?.code == "runtime.serviceUnavailable")
    #expect(approval?.error?.action == .openLoginItemsSettings)
    #expect(await requiresApprovalProbe.labelsRequested() == ["io.apkrun.apkrund.dev"])

    let unregistered = await runHostChecks(
        state: .init(runtimeRegistration: .notRegistered)
    )
    #expect(
        result("apkrund.registration", in: unregistered)?.error?.message.fallback
            == "APKRun's background service is not set up.")
}

@Test func buildInfoMapsOnlyKnownIdentitiesToLaunchAgentLabels() {
    #expect(BuildInfo(infoDictionary: ["APKRunBuildIdentity": "dev"]).launchAgentLabel == "io.apkrun.apkrund.dev")
    #expect(
        BuildInfo(infoDictionary: ["APKRunBuildIdentity": "updatetest"]).launchAgentLabel
            == "io.apkrun.apkrund.updatetest")
    #expect(BuildInfo(infoDictionary: ["APKRunBuildIdentity": "release"]).launchAgentLabel == "io.apkrun.apkrund")
    #expect(BuildInfo(infoDictionary: ["APKRunBuildIdentity": "unexpected"]).launchAgentLabel == "io.apkrun.apkrund")
}

private func runHostChecks(
    state: FakeHostProbe.State = .init(),
    deep: Bool = false,
    buildInfo: BuildInfo = .current,
    probe: FakeHostProbe? = nil
) async -> [HealthResult] {
    let hostProbe = probe ?? FakeHostProbe(state: state)
    let context = DiagnosticsContext.testing(
        root: URL(fileURLWithPath: "/tmp/apkrun-host-check-tests", isDirectory: true),
        buildInfo: buildInfo,
        hostProbe: hostProbe
    )
    return await context.healthChecks.run(
        deep: deep,
        context: context.healthContext(daemonAvailable: true, runtimeRunning: true)
    )
}

private func result(_ id: String, in results: [HealthResult]) -> HealthResult? {
    results.first(where: { $0.id == id })
}

extension FakeHostProbe {
    fileprivate func currentState() -> State {
        State(
            supportsAppleSilicon: true,
            macOSVersion: HostOSVersion(major: 27, minor: 0),
            supportsHypervisor: true,
            applicationIsInApplications: true,
            applicationSignatureIsValid: true,
            componentBuilds: HostComponentBuilds(daemon: "42", cli: "42", launcher: "42"),
            dataVolumeInfo: HostVolumeInfo(
                isAPFS: true,
                availableBytes: 20 * 1_024 * 1_024 * 1_024
            ),
            physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024,
            runtimeRegistration: .requiresApproval
        )
    }
}
