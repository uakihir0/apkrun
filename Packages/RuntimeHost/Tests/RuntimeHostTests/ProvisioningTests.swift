import DiagnosticsCore
import Foundation
import Testing

@testable import RuntimeHost

private func temporaryStore(_ name: String) -> (URL, RuntimeStateStore) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-provisioning-\(name)-\(UUID().uuidString)", isDirectory: true)
    let store = RuntimeStateStore(fileURL: directory.appendingPathComponent("state.json"))
    return (directory, store)
}

// MARK: - RuntimeStateStore (runtime-daemon.md §9.2)

@Test func runtimeStateStoreLoadsEmptyRecordWhenFileIsAbsent() async throws {
    let (directory, store) = temporaryStore("empty")
    defer { try? FileManager.default.removeItem(at: directory) }

    let record = try await store.load()
    #expect(!record.provisioned)
    #expect(record.completedSteps.isEmpty)
    #expect(record.failedFirstBoots == 0)
}

@Test func runtimeStateStoreRoundTripsPartialProgress() async throws {
    let (directory, store) = temporaryStore("resume")
    defer { try? FileManager.default.removeItem(at: directory) }

    // A quit after `installingImage` leaves a resumable record (§9.2).
    var record = ProvisioningRecord()
    record.completedSteps = ["checkingHost", "installingImage"]
    record.failedFirstBoots = 1
    try await store.save(record)

    // A new store instance reads the same file, as a restarted apkrund would.
    let reloaded = RuntimeStateStore(
        fileURL: directory.appendingPathComponent("state.json"))
    let loaded = try await reloaded.load()
    #expect(loaded.completedSteps == ["checkingHost", "installingImage"])
    #expect(loaded.failedFirstBoots == 1)
    #expect(!loaded.provisioned)
}

@Test func runtimeStateStoreUpdateMutatesAtomically() async throws {
    let (directory, store) = temporaryStore("update")
    defer { try? FileManager.default.removeItem(at: directory) }

    let record = try await store.update { record in
        record.completedSteps.append("checkingHost")
        record.provisioned = true
        record.userdataGeneration = UUID()
    }
    #expect(record.provisioned)
    #expect(try await store.load() == record)
}

@Test func runtimeStateStoreFailsOnCorruptFile() async throws {
    let (directory, store) = temporaryStore("corrupt")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: directory.appendingPathComponent("state.json"))

    do {
        _ = try await store.load()
        Issue.record("expected stateFileUnreadable")
    } catch let error as RuntimeStoreFailure {
        guard case .stateFileUnreadable = error else {
            Issue.record("expected stateFileUnreadable, got \(error)")
            return
        }
    }
}

// MARK: - HostRequirementsCheck (runtime-daemon.md §9.1)

/// Minimal host facts for the §9.1 rows.
private actor ProvisioningFakeProbe: HostProbe {
    var silicon = true
    var version = HostOSVersion(major: 27, minor: 0, patch: 0)
    var hypervisor = true
    var volume = HostVolumeInfo(isAPFS: true, availableBytes: 0)

    func supportsAppleSilicon() async -> Bool { silicon }
    func macOSVersion() async -> HostOSVersion { version }
    func supportsHypervisor() async -> Bool { hypervisor }
    func applicationIsInApplications() async -> Bool { true }
    func applicationSignatureIsValid() async -> Bool { true }
    func componentBuilds() async -> HostComponentBuilds {
        HostComponentBuilds(daemon: "1", cli: "1", launcher: "1")
    }
    func dataVolumeInfo(at path: URL) async -> HostVolumeInfo { volume }
    func physicalMemoryBytes() async -> UInt64 { 16 * 1024 * 1024 * 1024 }
    func runtimeRegistration(label: String) async -> HostRuntimeRegistration { .enabled }

    func set(
        silicon: Bool? = nil,
        version: HostOSVersion? = nil,
        hypervisor: Bool? = nil,
        volume: HostVolumeInfo? = nil
    ) {
        if let silicon { self.silicon = silicon }
        if let version { self.version = version }
        if let hypervisor { self.hypervisor = hypervisor }
        if let volume { self.volume = volume }
    }
}

@Test func hostRequirementsCheckPassesOnCapableHost() async throws {
    let probe = ProvisioningFakeProbe()
    await probe.set(volume: HostVolumeInfo(isAPFS: true, availableBytes: 100_000_000_000))
    let check = HostRequirementsCheck(
        probe: probe,
        dataRoot: URL(fileURLWithPath: "/tmp"),
        requiredFreeBytes: 50_000_000_000
    )
    #expect(await check.unmetRequirements().isEmpty)
}

@Test func hostRequirementsCheckReportsEveryFailedRowInSpecOrder() async throws {
    let probe = ProvisioningFakeProbe()
    await probe.set(
        silicon: false,
        version: HostOSVersion(major: 26, minor: 6, patch: 0),
        hypervisor: false,
        volume: HostVolumeInfo(isAPFS: false, availableBytes: 0)
    )
    let needed: Int64 = 46_000_000_000
    let check = HostRequirementsCheck(
        probe: probe,
        dataRoot: URL(fileURLWithPath: "/tmp"),
        requiredFreeBytes: needed
    )
    let unmet = await check.unmetRequirements()
    #expect(
        unmet == [
            .appleSilicon,
            .macOSVersion,
            .virtualization,
            .apfsVolume,
            .freeDiskSpace(needed: needed),
        ])
    #expect(
        unmet.map(\.itemName) == [
            "appleSilicon", "macOSVersion", "virtualization", "apfsVolume", "freeDiskSpace",
        ])
}

@Test func hostRequirementsCheckFreeDiskUsesExpandedImagePlusUserdataPlusMargin() {
    let image: Int64 = 4_000_000_000
    let userdata: Int64 = 32 * 1024 * 1024 * 1024
    #expect(
        HostRequirementsCheck.requiredFreeBytes(
            expandedImageBytes: image,
            userdataBytes: userdata
        ) == image + userdata + 10 * 1024 * 1024 * 1024)
}
