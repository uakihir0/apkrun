import DiagnosticsCore
import Foundation
import ImageCore
import RuntimeAPI
import RuntimeCore

/// First-run provisioning status persisted in `state.json` (runtime-daemon.md §9, filesystem-layout.md §2).
/// Survives a quit in the middle of setup: completed steps are recorded so a restarted `setup`
/// resumes at the first incomplete step.
public struct ProvisioningRecord: Codable, Equatable, Sendable {
    /// The `state.json` schema version.
    public var schemaVersion: Int
    /// Whether provisioning completed.
    public var provisioned: Bool
    /// Steps that finished successfully, in completion order.
    public var completedSteps: [String]
    /// How many first boots failed so far; two or more recreate the instance (§9.4).
    public var failedFirstBoots: Int
    /// The instance's current userdata generation, when one exists.
    public var userdataGeneration: UUID?
    /// The last APKRun version that provisioned, for migrations.
    public var lastRuntimeVersion: String?
    /// The last APKRun build that provisioned, for migrations.
    public var lastRuntimeBuild: String?
    /// The self-update probe's persistence block (runtime-maintenance.md §9).
    public var selfUpdate: SelfUpdateProbeState?

    /// Creates an empty record for a data root that was never provisioned.
    public init() {
        schemaVersion = 1
        provisioned = false
        completedSteps = []
        failedFirstBoots = 0
        userdataGeneration = nil
        lastRuntimeVersion = nil
        lastRuntimeBuild = nil
        selfUpdate = nil
    }
}

/// Reads and writes the root `state.json` provisioning record atomically.
public actor RuntimeStateStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    /// Creates a store for one `state.json` file.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    /// Loads the record, or an empty record when the file is absent. A corrupt file is a
    /// read failure: better to fail setup than to re-provision over an intact install.
    public func load() throws -> ProvisioningRecord {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ProvisioningRecord()
        }
        do {
            return try decoder.decode(ProvisioningRecord.self, from: Data(contentsOf: fileURL))
        } catch let error as NSError {
            throw RuntimeStoreFailure.stateFileUnreadable(
                underlying: UnderlyingError(domain: error.domain, code: error.code)
            )
        }
    }

    /// Atomically replaces the record on disk.
    public func save(_ record: ProvisioningRecord) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(record).write(to: fileURL, options: .atomic)
        } catch let error as NSError {
            throw RuntimeStoreFailure.stateFileUnwritable(
                underlying: UnderlyingError(domain: error.domain, code: error.code)
            )
        }
    }

    /// Applies a mutation to the loaded record and saves it.
    public func update(_ mutate: (inout ProvisioningRecord) -> Void) throws -> ProvisioningRecord {
        var record = try load()
        mutate(&record)
        try save(record)
        return record
    }
}

/// A `state.json` read or write failure.
public enum RuntimeStoreFailure: Error, Equatable {
    /// `state.json` could not be parsed.
    case stateFileUnreadable(underlying: UnderlyingError)

    /// `state.json` could not be written.
    case stateFileUnwritable(underlying: UnderlyingError)
}

/// Evaluates the host requirements of runtime-daemon.md §9.1 and returns every failed row.
public struct HostRequirementsCheck: Sendable {
    /// The probe that measures the host.
    private let probe: any HostProbe
    /// The data root whose volume must be APFS with enough free space.
    private let dataRoot: URL
    /// The required free space: expanded image + userdata + margin.
    private let requiredFreeBytes: Int64

    /// Creates a check. `requiredFreeBytes` defaults to the §9.1 floor:
    /// the image's expanded size plus a 32 GiB userdata disk and 10 GiB of margin.
    public init(
        probe: any HostProbe = SystemHostProbe(),
        dataRoot: URL,
        requiredFreeBytes: Int64
    ) {
        self.probe = probe
        self.dataRoot = dataRoot
        self.requiredFreeBytes = requiredFreeBytes
    }

    /// Returns the unmet requirements, in §9.1 table order.
    public func unmetRequirements() async -> [HostRequirement] {
        var failures: [HostRequirement] = []
        if await !probe.supportsAppleSilicon() {
            failures.append(.appleSilicon)
        }
        if await probe.macOSVersion() < HostOSVersion(major: 27, minor: 0, patch: 0) {
            failures.append(.macOSVersion)
        }
        if await !probe.supportsHypervisor() {
            failures.append(.virtualization)
        }
        let volume = await probe.dataVolumeInfo(at: dataRoot)
        if !volume.isAPFS {
            failures.append(.apfsVolume)
        }
        if volume.availableBytes < requiredFreeBytes {
            failures.append(.freeDiskSpace(needed: requiredFreeBytes))
        }
        return failures
    }

    /// The default required free space for one expanded image, one userdata disk, and margin.
    public static func requiredFreeBytes(expandedImageBytes: Int64, userdataBytes: Int64) -> Int64 {
        expandedImageBytes + userdataBytes + 10 * 1024 * 1024 * 1024
    }
}
