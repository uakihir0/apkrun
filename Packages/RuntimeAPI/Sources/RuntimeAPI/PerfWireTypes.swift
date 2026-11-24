import Foundation

/// The launcher's own timing stamps, in continuous-clock nanoseconds
/// ([process-model-and-ipc.md](../../docs/01-architecture/process-model-and-ipc.md) §2.3).
/// apkrund records `WRAPPER_PROCESS_START` and `APP_LAUNCH_REQUEST` from them.
public struct LaunchTiming: Codable, Equatable, Sendable {
    /// Kernel start time of the launcher process (`proc_pidinfo(PROC_PIDTBSDINFO)`).
    public var processStart: UInt64
    /// When the launch request was sent.
    public var requestSent: UInt64

    /// Creates a launch timing pair.
    public init(processStart: UInt64, requestSent: UInt64) {
        self.processStart = processStart
        self.requestSent = requestSent
    }
}

/// `perfStatistics` control request body (diagnostics.md §9.3, runtime-api.md §13.1).
public struct PerfStatisticsRequest: Codable, Equatable, Sendable {
    /// Clear the statistics after returning them.
    public var reset: Bool

    /// Creates a perf-statistics request.
    public init(reset: Bool = false) {
        self.reset = reset
    }
}

/// Distribution of one perf marker's segment durations, in microseconds.
public struct WireMarkerStatistics: Codable, Equatable, Sendable {
    /// The marker name, for example `FIRST_FRAME_DISPLAYED`.
    public var name: String
    /// How many segment samples were measured.
    public var count: Int
    /// The median segment duration.
    public var p50Us: Int64
    /// The 95th-percentile segment duration.
    public var p95Us: Int64
    /// The slowest segment duration.
    public var maxUs: Int64

    /// Creates a marker statistic row.
    public init(name: String, count: Int, p50Us: Int64, p95Us: Int64, maxUs: Int64) {
        self.name = name
        self.count = count
        self.p50Us = p50Us
        self.p95Us = p95Us
        self.maxUs = maxUs
    }
}

/// One input latency histogram for a segment of the input path.
public struct WireInputHistogram: Codable, Equatable, Sendable {
    /// The measured segment: `input.translate` or `input.route`.
    public var segment: String
    /// The upper bound of each bucket, in microseconds; the last bucket is open-ended.
    public var boundsUs: [Int64]
    /// The sample count in each bucket.
    public var counts: [Int64]

    /// Creates an input histogram.
    public init(segment: String, boundsUs: [Int64], counts: [Int64]) {
        self.segment = segment
        self.boundsUs = boundsUs
        self.counts = counts
    }
}

/// Graphics statistics of one app session (runtime-api.md §13.1).
public struct SessionGraphicsStatistics: Codable, Equatable, Sendable {
    /// The package that owns the session.
    public var packageID: RuntimePackageID
    /// The Android display the session presents to.
    public var displayID: Int32?
    /// Frames per second averaged over the last 10 seconds.
    public var fps: Double
    /// Frames replaced before they were shown.
    public var droppedFrames: UInt64
    /// GPU-to-CPU readbacks made by the host. Must stay zero (AGENTS.md §6.4).
    public var hostReadbacks: UInt64
    /// CPU copies of pixel data. Must stay zero on the drmVirgl path.
    public var cpuPixelCopies: UInt64
    /// The median GPU present time.
    public var presentGPUTimeP50Us: Int64
    /// The 95th-percentile GPU present time.
    public var presentGPUTimeP95Us: Int64

    /// Creates a session graphics statistics row.
    public init(
        packageID: RuntimePackageID,
        displayID: Int32? = nil,
        fps: Double,
        droppedFrames: UInt64,
        hostReadbacks: UInt64,
        cpuPixelCopies: UInt64,
        presentGPUTimeP50Us: Int64,
        presentGPUTimeP95Us: Int64
    ) {
        self.packageID = packageID
        self.displayID = displayID
        self.fps = fps
        self.droppedFrames = droppedFrames
        self.hostReadbacks = hostReadbacks
        self.cpuPixelCopies = cpuPixelCopies
        self.presentGPUTimeP50Us = presentGPUTimeP50Us
        self.presentGPUTimeP95Us = presentGPUTimeP95Us
    }
}

/// Resident memory of one guest process from `dumpsys meminfo -c` (diagnostics.md §5).
public struct WireGuestProcessMemory: Codable, Equatable, Sendable {
    /// The process name, for example `system_server`.
    public var name: String
    /// Its proportional set size.
    public var pssBytes: Int64
    /// Its resident set size.
    public var rssBytes: Int64

    /// Creates a guest process memory row.
    public init(name: String, pssBytes: Int64, rssBytes: Int64) {
        self.name = name
        self.pssBytes = pssBytes
        self.rssBytes = rssBytes
    }
}

/// An on-demand metrics sample (diagnostics.md §5). Missing figures stay `nil`.
public struct WireMetricsSnapshot: Codable, Equatable, Sendable {
    /// When the sample was taken.
    public var sampledAt: Date
    /// The VM's configured memory size, when a VM exists.
    public var vmDefinitionBytes: Int64?
    /// The balloon driver's current target, when running.
    public var balloonTargetBytes: Int64?
    /// Guest `MemTotal`, when the agent reported it.
    public var guestMemTotalBytes: Int64?
    /// Guest `MemAvailable`, when the agent reported it.
    public var guestMemAvailableBytes: Int64?
    /// Physical footprint of the Virtualization XPC service process (OQ-06).
    public var vmServiceFootprintBytes: Int64?
    /// Resident memory of the sampled guest processes (`DUMPSYS_MEMINFO`).
    public var guestProcesses: [WireGuestProcessMemory]
    /// Bytes of IOSurfaces allocated by the presenter pools.
    public var iosurfaceBytes: Int64
    /// `MTLDevice.currentAllocatedSize` of the render device, when known.
    public var metalAllocatedBytes: Int64?
    /// apkrund's physical footprint.
    public var daemonFootprintBytes: Int64
    /// apkrund's resident size.
    public var daemonResidentBytes: Int64
    /// apkrund's cumulative user CPU.
    public var daemonCPUUserUs: Int64
    /// apkrund's cumulative system CPU.
    public var daemonCPUSystemUs: Int64

    /// Creates a metrics snapshot.
    public init(
        sampledAt: Date,
        vmDefinitionBytes: Int64? = nil,
        balloonTargetBytes: Int64? = nil,
        guestMemTotalBytes: Int64? = nil,
        guestMemAvailableBytes: Int64? = nil,
        vmServiceFootprintBytes: Int64? = nil,
        guestProcesses: [WireGuestProcessMemory] = [],
        iosurfaceBytes: Int64 = 0,
        metalAllocatedBytes: Int64? = nil,
        daemonFootprintBytes: Int64,
        daemonResidentBytes: Int64,
        daemonCPUUserUs: Int64,
        daemonCPUSystemUs: Int64
    ) {
        self.sampledAt = sampledAt
        self.vmDefinitionBytes = vmDefinitionBytes
        self.balloonTargetBytes = balloonTargetBytes
        self.guestMemTotalBytes = guestMemTotalBytes
        self.guestMemAvailableBytes = guestMemAvailableBytes
        self.vmServiceFootprintBytes = vmServiceFootprintBytes
        self.guestProcesses = guestProcesses
        self.iosurfaceBytes = iosurfaceBytes
        self.metalAllocatedBytes = metalAllocatedBytes
        self.daemonFootprintBytes = daemonFootprintBytes
        self.daemonResidentBytes = daemonResidentBytes
        self.daemonCPUUserUs = daemonCPUUserUs
        self.daemonCPUSystemUs = daemonCPUSystemUs
    }
}

/// The host-side values `perfStatistics` returns (runtime-api.md §13.1).
public struct WirePerfStatistics: Codable, Equatable, Sendable {
    /// When the returned statistics started accumulating.
    public var since: Date
    /// Marker segment distributions.
    public var markers: [WireMarkerStatistics]
    /// Input latency histograms.
    public var input: [WireInputHistogram]
    /// Per-session graphics statistics.
    public var sessions: [SessionGraphicsStatistics]
    /// An on-demand metrics snapshot (diagnostics.md §5); `nil` when the sampler
    /// is not available.
    public var metrics: WireMetricsSnapshot?

    /// Creates a perf-statistics reply.
    public init(
        since: Date,
        markers: [WireMarkerStatistics],
        input: [WireInputHistogram],
        sessions: [SessionGraphicsStatistics],
        metrics: WireMetricsSnapshot? = nil
    ) {
        self.since = since
        self.markers = markers
        self.input = input
        self.sessions = sessions
        self.metrics = metrics
    }
}

/// `perfStatistics` through the authenticated control endpoint.
public struct RuntimePerfStatisticsControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader
    /// Clear the statistics after returning them.
    public var reset: Bool

    /// Creates a perf-statistics request.
    public init(header: APIRequestHeader, reset: Bool = false) {
        self.header = header
        self.reset = reset
    }
}

/// The reply of `perfStatistics`.
public struct RuntimePerfStatisticsControlReply: Codable, Equatable, Sendable {
    /// The statistics on success.
    public let result: WirePerfStatistics?
    /// The control error on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: WirePerfStatistics) {
        self.result = result
        error = nil
    }

    /// Creates an error reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// `frameStatistics` through the authenticated control endpoint. The session
/// channel carries it once the wrapper endpoint exists; until then launchers
/// name their session here (runtime-api.md §6.3, §13.1).
public struct RuntimeFrameStatisticsControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader
    /// The session to read. `nil` asks for every live session.
    public var sessionID: UUID?

    /// Creates a frame-statistics request.
    public init(header: APIRequestHeader, sessionID: UUID? = nil) {
        self.header = header
        self.sessionID = sessionID
    }
}

/// The reply of `frameStatistics`.
public struct RuntimeFrameStatisticsControlReply: Codable, Equatable, Sendable {
    /// The statistics of the sessions asked for.
    public let sessions: [SessionGraphicsStatistics]?
    /// The control error on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(sessions: [SessionGraphicsStatistics]) {
        self.sessions = sessions
        error = nil
    }

    /// Creates an error reply.
    public init(error: RuntimeWireError) {
        sessions = nil
        self.error = error
    }
}
