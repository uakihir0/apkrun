import CoreGraphics
import Foundation

/// A contributor built from a closure; the owning module supplies the code
/// that writes its section (diagnostics.md §8.2). Modules that prefer a
/// named type write their own `DiagnosticsContributor`.
public struct ClosureDiagnosticsContributor: DiagnosticsContributor {
    /// The owning module's name.
    public let name: String
    /// The section's time budget.
    public let budget: Duration
    private let work: @Sendable (DiagnosticsBundleBuilder, DiagnosticsOptions) async throws -> Void

    /// Creates a contributor from a closure.
    public init(
        name: String,
        budget: Duration = .seconds(10),
        work: @escaping @Sendable (DiagnosticsBundleBuilder, DiagnosticsOptions) async throws -> Void
    ) {
        self.name = name
        self.budget = budget
        self.work = work
    }

    /// Runs the closure.
    public func contribute(to bundle: DiagnosticsBundleBuilder, options: DiagnosticsOptions) async throws {
        try await work(bundle, options)
    }
}

/// `host/environment.json`: Mac model, chip, memory, macOS version and
/// build, displays, locale, data volume (§8.2, filtered by §6.2).
public struct HostEnvironmentContributor: DiagnosticsContributor {
    /// The owning module's name.
    public let name = "host"
    /// Environment collection is quick.
    public let budget = Duration.seconds(10)

    /// Creates the contributor.
    public init() {}

    /// Writes `host/environment.json`.
    public func contribute(to bundle: DiagnosticsBundleBuilder, options: DiagnosticsOptions) async throws {
        try bundle.addJSON("host/environment.json", Self.environment())
    }

    /// The environment record as a JSON object.
    public static func environment() -> [String: Any] {
        var object: [String: Any] = [:]
        let process = ProcessInfo.processInfo
        object["macOSVersion"] = process.operatingSystemVersionString
        object["macOSBuild"] = sysctlString("kern.osversion")
        object["hostModel"] = sysctlString("hw.model")
        object["chip"] = sysctlString("machdep.cpu.brand_string")
        object["physicalCores"] = process.processorCount
        object["memoryBytes"] = process.physicalMemory
        object["uptimeSeconds"] = Int(process.systemUptime)
        object["localeIdentifier"] = Locale.current.identifier
        object["architecture"] = sysctlString("hw.machine")

        if let volume = try? FileManager.default.attributesOfFileSystem(
            forPath: NSHomeDirectory())
        {
            if let free = volume[.systemFreeSize] as? Int64 {
                object["dataVolumeFreeBytes"] = free
            }
            if let total = volume[.systemSize] as? Int64 {
                object["dataVolumeBytes"] = total
            }
        }

        var displays: [[String: Any]] = []
        var displayID = CGMainDisplayID()
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        if CGGetActiveDisplayList(16, &ids, &count) == .success {
            for index in 0..<Int(count) {
                displayID = ids[index]
                var entry: [String: Any] = [
                    "widthPoints": CGDisplayPixelsWide(displayID),
                    "heightPoints": CGDisplayPixelsHigh(displayID),
                ]
                let mode = CGDisplayCopyDisplayMode(displayID)
                if let mode {
                    entry["refreshRate"] = mode.refreshRate
                }
                entry["main"] = displayID == CGMainDisplayID()
                displays.append(entry)
            }
        }
        object["displays"] = displays
        return object
    }

    /// One sysctl string, or nil when the key does not exist.
    static func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

/// `host/versions.json`: the BuildInfo map the daemon knows (APKRun.app,
/// apkrund, CLI, launcher, image, agents) plus API/protocol versions.
public struct VersionsContributor: DiagnosticsContributor {
    /// The owning module's name.
    public let name = "host"
    /// Versions are in memory.
    public let budget = Duration.seconds(10)

    /// The caller's build map: `apkrund`, `cli`, `launcher`, `image`,
    /// `agent`, `storeAgent`, `apiLevel`, `protocolVersion`, `build`.
    public var versions: @Sendable () async -> [String: String]

    /// Creates the contributor with a version source.
    public init(versions: @escaping @Sendable () async -> [String: String]) {
        self.versions = versions
    }

    /// Writes `host/versions.json`.
    public func contribute(to bundle: DiagnosticsBundleBuilder, options: DiagnosticsOptions) async throws {
        try bundle.addJSON("host/versions.json", await versions())
    }
}

/// `host/health.json` and `host/health.txt`: the health report (deep when
/// the report asks) and its doctor rendering (§8.2).
public struct HealthContributor: DiagnosticsContributor {
    /// The owning module's name.
    public let name = "host"
    /// A deep check may take the full per-contributor budget.
    public let budget = Duration.seconds(10)

    /// Runs the checks and returns the doctor text plus its JSON encoding.
    public var probe: @Sendable (Bool) async -> (json: Data, text: String)?

    /// Creates the contributor with a health source.
    public init(
        probe: @escaping @Sendable (Bool) async -> (json: Data, text: String)?
    ) {
        self.probe = probe
    }

    /// Writes `host/health.json` and `host/health.txt`.
    public func contribute(to bundle: DiagnosticsBundleBuilder, options: DiagnosticsOptions) async throws {
        guard let report = await probe(options.deep) else {
            bundle.omit("host/health.json", reason: "unavailable")
            return
        }
        try bundle.add("host/health.json", data: report.json)
        try bundle.add("host/health.txt", text: report.text)
    }
}

/// `host/config.json`: global settings cut to the allowlisted keys (§6.2).
public struct ConfigContributor: DiagnosticsContributor {
    /// The owning module's name.
    public let name = "host"
    /// Reads one file.
    public let budget = Duration.seconds(10)

    /// The raw settings file (`config.json` under the state directory).
    public var settingsFile: URL
    /// Extra keys allowed beyond `DiagnosticsAllowlists.configKeys`.
    public var extraKeys: Set<String>

    /// Creates the contributor.
    public init(settingsFile: URL, extraKeys: Set<String> = []) {
        self.settingsFile = settingsFile
        self.extraKeys = extraKeys
    }

    /// Writes `host/config.json`.
    public func contribute(to bundle: DiagnosticsBundleBuilder, options: DiagnosticsOptions) async throws {
        guard let data = try? Data(contentsOf: settingsFile),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            bundle.omit("host/config.json", reason: "unavailable")
            return
        }
        let allowed = DiagnosticsAllowlists.configKeys.union(extraKeys)
        var filtered: [String: Any] = [:]
        for (key, value) in object where allowed.contains(key) {
            filtered[key] = value
        }
        try bundle.addJSON("host/config.json", filtered)
    }
}

/// `host/metrics.json`: the MetricsSnapshot of diagnostics.md §5.
public struct MetricsContributor: DiagnosticsContributor {
    /// The owning module's name.
    public let name = "host"
    /// The snapshot is already in memory.
    public let budget = Duration.seconds(10)

    /// The snapshot JSON, or nil when metrics are not wired.
    public var snapshot: @Sendable () async -> Data?

    /// Creates the contributor.
    public init(snapshot: @escaping @Sendable () async -> Data?) {
        self.snapshot = snapshot
    }

    /// Writes `host/metrics.json`, or omits it.
    public func contribute(to bundle: DiagnosticsBundleBuilder, options: DiagnosticsOptions) async throws {
        guard let data = await snapshot() else {
            bundle.omit("host/metrics.json", reason: "unavailable")
            return
        }
        try bundle.add("host/metrics.json", data: data)
    }
}
