import DiagnosticsCore
import Foundation
import ImageCore
import RuntimeCore

/// Inputs for `apkrun dev boot` (cli.md §5; #012-#014).
public struct DevBootOptions: Sendable {
    /// `--gpu none` selects the development `headless` profile.
    public var headless: Bool
    /// Guest vCPUs of a newly provisioned instance.
    public var cpuCount: Int
    /// Guest memory in bytes of a newly provisioned instance.
    public var memoryBytes: UInt64
    /// Logical `userdata.img` size in bytes of a newly provisioned instance.
    public var userdataBytes: UInt64
    /// Provision a fresh instance even if one exists ("Reset Android").
    public var resetInstance: Bool
    /// Stop the VM once Android is ready, instead of waiting for a stop request.
    public var stopWhenReady: Bool

    /// Creates options for one development boot.
    public init(
        headless: Bool = true,
        cpuCount: Int = InstanceSizing.default.cpuCount,
        memoryBytes: UInt64 = InstanceSizing.default.memoryBytes,
        userdataBytes: UInt64 = InstanceSizing.default.userdataBytes,
        resetInstance: Bool = false,
        stopWhenReady: Bool = false
    ) {
        self.headless = headless
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.userdataBytes = userdataBytes
        self.resetInstance = resetInstance
        self.stopWhenReady = stopWhenReady
    }
}

/// What `apkrun dev boot` reports while it runs.
public enum DevBootEvent: Sendable {
    /// A runtime state change, as text (`booting(init)`, `ready`, …).
    case state(String)
    /// Bytes from the kernel console.
    case console(Data)
    /// A one-line status message for the developer.
    case message(String)
    /// A human-readable development warning.
    case warning(String)
}

/// Boots the Android image of a development bundle inside the embedded CLI process.
public struct DevBoot: Sendable {
    /// Creates the development boot runner.
    public init() {}

    /// Boots the current image, provisions the instance if needed, and waits for a stop request.
    ///
    /// The instance lock is held for the whole run. The current image is checked quickly before
    /// the boot (android-image.md §9.3). An instance made from another image version is refused,
    /// because migration arrives with #058; `--reset` provisions a new instance instead. Developer
    /// mode is always on: the Android serial shell answers on hvc1, and logcat is captured to
    /// `<logs>/guest/logcat-<timestamp>.log` (android-image.md §7.1).
    public func run(
        options: DevBootOptions,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        stopRequests: AsyncStream<Void>,
        onEvent: @escaping @Sendable (DevBootEvent) -> Void
    ) async throws {
        // Every log line of the boot carries one operation ID (AGENTS §8).
        try await OperationContext.withNew {
            try await execute(
                options: options, environment: environment, stopRequests: stopRequests, onEvent: onEvent
            )
        }
    }

    private func execute(
        options: DevBootOptions,
        environment: [String: String],
        stopRequests: AsyncStream<Void>,
        onEvent: @escaping @Sendable (DevBootEvent) -> Void
    ) async throws {
        let paths = APKRunPaths(allowingHomeOverride: true, environment: environment)
        let lock = try InstanceLock.acquire(paths: paths, owner: .apkrunDev)
        defer { lock.close() }
        let diagnostics = DiagnosticsContext.live(paths: paths)

        let images = ImageStore(paths: paths, trust: .standard(), diagnostics: diagnostics)
        try await images.removeOrphanedInstalls()
        let image = try await images.current()
        try await images.verify(image, depth: .quick)
        onEvent(.message("image \(image.version.description) (current)"))
        let store = InstanceStore(paths: paths, diagnostics: diagnostics)
        let sizing = InstanceSizing(
            cpuCount: options.cpuCount,
            memoryBytes: options.memoryBytes,
            userdataBytes: options.userdataBytes
        )
        if options.resetInstance {
            _ = try await store.resetAndroid(image: image, sizing: sizing)
            onEvent(.message("reset the Android instance"))
        } else if let existing = try await store.load(image: image) {
            guard existing.imageVersion == image.version else {
                throw ImageFailure.instanceCorrupt(
                    reason:
                        "the instance uses \(existing.imageVersion.description), not \(image.version.description); use --reset"
                )
            }
        } else {
            _ = try await store.provision(image: image, sizing: sizing)
            onEvent(.message("provisioned a new Android instance"))
        }

        let supervisor = RuntimeSupervisor(
            image: image,
            instanceStore: store,
            options: BootOptions(
                gpuProfile: options.headless ? .headless : .drmVirgl,
                developerMode: true,
                captureLogcat: true
            ),
            diagnostics: diagnostics
        )
        let logcat = try LogcatFile(directory: paths.logsRoot.appendingPathComponent("guest", isDirectory: true))
        onEvent(.message("logcat goes to \(logcat.url.path)"))
        let eventTask = Task {
            for await event in supervisor.events {
                switch event {
                case .state(let state):
                    onEvent(.state(Self.describe(state)))
                case .console(let bytes):
                    onEvent(.console(bytes))
                case .logcat(let bytes):
                    logcat.write(bytes)
                case .firstBootSettingsApplied:
                    onEvent(.message("applied the first-boot settings (Bluetooth off, Wi-Fi on VirtWifi)"))
                }
            }
        }
        defer {
            eventTask.cancel()
            logcat.close()
        }

        let started = ContinuousClock.now
        try await supervisor.ensureReady(.cli)
        onEvent(.message("Android is ready after \(ContinuousClock.now - started)"))
        if !options.stopWhenReady {
            onEvent(.message("press Ctrl-C to stop Android"))
            for await _ in stopRequests {
                break
            }
        }
        onEvent(.message("stopping Android"))
        await supervisor.stop()
    }

    static func describe(_ state: RuntimeState) -> String {
        switch state {
        case .stopped: "stopped"
        case .booting(let phase): "booting(\(phase))"
        case .ready: "ready"
        case .stopping: "stopping"
        case .failed(let failure): "failed(\(failure.qualifiedCode))"
        }
    }
}

/// The logcat capture of one development boot.
private final class LogcatFile: @unchecked Sendable {
    let url: URL
    private let handle: FileHandle
    private let lock = NSLock()

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        url = directory.appendingPathComponent("logcat-\(formatter.string(from: Date())).log")
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        handle = try FileHandle(forWritingTo: url)
    }

    func write(_ data: Data) {
        lock.withLock { try? handle.write(contentsOf: data) }
    }

    func close() {
        lock.withLock { try? handle.close() }
    }
}
