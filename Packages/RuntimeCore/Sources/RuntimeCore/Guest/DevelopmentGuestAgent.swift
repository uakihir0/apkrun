import DiagnosticsCore
import Foundation
import GuestProtocol

/// A relay from the supervisor's restart closure to the coordinator. The coordinator is an actor that holds the
/// supervisor, so the closure cannot capture it while the two are built.
private final class RestartRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (GuestAgentLoss) async -> Bool)?

    func set(_ handler: @escaping @Sendable (GuestAgentLoss) async -> Bool) {
        lock.withLock { self.handler = handler }
    }

    func restart(_ loss: GuestAgentLoss) async -> Bool {
        let current = lock.withLock { handler }
        guard let current else {
            return false
        }
        return await current(loss)
    }
}

/// The result of `LaunchApplication`, as the host reports it (guest-protocol.md §7.1 #14).
public struct GuestLaunchReport: Equatable, Sendable {
    /// The task that the launch started or brought to the front.
    public let taskID: Int32
    /// The component of the task's top activity.
    public let component: String
    /// `started`, `broughtToFront`, or `movedFromDisplay`.
    public let outcome: String

    /// Creates a report.
    public init(taskID: Int32, component: String, outcome: String) {
        self.taskID = taskID
        self.component = component
        self.outcome = outcome
    }
}

/// A task lifecycle event relayed from the Guest Agent to embedded runtime clients.
public enum DevelopmentGuestTaskEvent: Equatable, Sendable {
    /// The Guest Agent reported a task for a package.
    case appeared(packageID: String, taskID: Int32)
    /// The Guest Agent removed a task for a package.
    case vanished(packageID: String, taskID: Int32)
}

/// The development Guest Agent of one boot (guest-components.md §3, §6.1): it installs and starts the agent, keeps
/// the control connection, restarts a dead agent within the restart budget, and removes its forwards when it stops.
public actor DevelopmentGuestAgent {
    /// The control connection, with its keepalive and resync.
    public nonisolated let supervisor: GuestAgentSupervisor
    /// Task lifecycle changes from the control connection, narrowed to the RuntimeCore API.
    public nonisolated let taskEvents: AsyncStream<DevelopmentGuestTaskEvent>
    /// Display lifecycle changes from the same sequenced Guest Agent event relay.
    public nonisolated let displayEvents: AsyncStream<GuestDisplayEvent>
    /// Android reboot notifications inferred from consecutive supervisor snapshots.
    public nonisolated var androidRestartEvents: AsyncStream<GuestAndroidRestart> {
        supervisor.androidRestartEvents
    }

    private let adb: AdbClient
    private let provisioner: GuestAgentProvisioner
    private let logger: APKLogger
    private let clock: @Sendable () -> ContinuousClock.Instant
    /// The transport of the control connection, which the input connection shares.
    private let transport: any GuestTransport
    private let hostVersion: String
    private let logSink: (any LogSink)?
    private var budget = GuestAgentRestartBudget()
    private var restartsRefused = false
    /// Counts the stops, so that a start in flight can tell that the boot that asked for it has ended.
    private var generation: UInt64 = 0
    /// The input connection, and the control session token that it presents (input.md §8, decision D11).
    private var inputConnection: GuestConnection?
    private var inputConnectionToken: Data?
    private let taskEventContinuation: AsyncStream<DevelopmentGuestTaskEvent>.Continuation
    private let displayEventContinuation: AsyncStream<GuestDisplayEvent>.Continuation
    private var taskEventRelay: Task<Void, Never>?

    /// Creates the coordinator for `bundle`, reached through `adb`.
    public init(
        adb: AdbClient,
        bundle: GuestAgentBundle,
        hostVersion: String = "dev",
        logSink: (any LogSink)? = nil,
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.adb = adb
        self.clock = clock
        self.hostVersion = hostVersion
        self.logSink = logSink
        logger = APKLogger(category: RuntimeLogCategory.agents, sink: logSink)
        provisioner = GuestAgentProvisioner(adb: adb, bundle: bundle)
        let transport = ADBForwardGuestTransport(adb: adb, logSink: logSink)
        self.transport = transport
        let relay = RestartRelay()
        supervisor = GuestAgentSupervisor(
            transport: transport,
            hostVersion: hostVersion,
            logSink: logSink,
            restartAgent: { loss in await relay.restart(loss) }
        )
        let (taskEvents, taskEventContinuation) = AsyncStream.makeStream(
            of: DevelopmentGuestTaskEvent.self,
            bufferingPolicy: .bufferingNewest(1024)
        )
        self.taskEvents = taskEvents
        self.taskEventContinuation = taskEventContinuation
        let (displayEvents, displayEventContinuation) = AsyncStream.makeStream(
            of: GuestDisplayEvent.self,
            bufferingPolicy: .bufferingNewest(1024)
        )
        self.displayEvents = displayEvents
        self.displayEventContinuation = displayEventContinuation
        relay.set { [weak self] loss in
            guard let self else {
                return false
            }
            return await self.handleLoss(loss)
        }
    }

    /// Installs the agent, starts it, and connects within `connectTimeout` (guest-components.md §3.1, §3.2). The
    /// forwards that an earlier boot left behind are removed first, because they would make the forward fail. A
    /// ``stop()`` during the start ends it with `stopped`. A start that is not running after its connection failed is
    /// `startFailed`.
    public func start(connectTimeout: Duration = .seconds(5)) async throws(GuestAgentFailure) {
        let started = generation
        do {
            try await adb.awaitDevice(timeout: .seconds(30))
        } catch {
            logger.error("The Guest Agent failed at the device wait", errorCode: error.qualifiedCode)
            throw .adb(error)
        }
        try requireStarted(started)
        // The cleanup of forwards that an earlier boot left is best effort: a forward that cannot be listed does not
        // stop the agent from starting.
        do {
            try await removeForwards()
        } catch {
            logger.warning("The stale Guest Agent forwards could not be removed: \(error.qualifiedCode, .public)")
        }
        try requireStarted(started)
        do {
            try await provisioner.install()
        } catch {
            logger.error("The Guest Agent failed at the install", errorCode: error.qualifiedCode)
            throw error
        }
        try requireStarted(started)
        do {
            try await provisioner.startAgent()
        } catch {
            logger.error("The Guest Agent failed at the start", errorCode: error.qualifiedCode)
            throw error
        }
        try requireStarted(started)
        startTaskEventRelay()
        do {
            try await supervisor.start(connectTimeout: connectTimeout)
        } catch GuestAgentFailure.stopped {
            throw .stopped
        } catch {
            if case .connectTimedOut = error, (try? await provisioner.isRunning()) == false {
                logger.error(
                    "The Guest Agent process is not running after the start",
                    errorCode: "runtime.guestAgentStartFailed")
                throw .startFailed
            }
            logger.error("The Guest Agent did not answer its handshake", errorCode: error.qualifiedCode)
            throw error
        }
    }

    /// Stops the supervisor and removes the forwards of the agent. A start in flight ends with `stopped`. The agent
    /// process keeps running, because the next start replaces it, and the guest is not powered off.
    public func stop() async {
        generation += 1
        await supervisor.stop()
        taskEventRelay?.cancel()
        taskEventRelay = nil
        taskEventContinuation.finish()
        displayEventContinuation.finish()
        // The input connection belongs to the control session, so it ends with it.
        await inputConnection?.close()
        inputConnection = nil
        inputConnectionToken = nil
        try? await removeForwards()
    }

    /// The number of `adb shell` commands that this agent's ADB client has started (input.md §11, #024). The input path
    /// runs none, so the count does not change while input is routed (the box "no shell command per event").
    public var adbShellInvocationCount: Int {
        get async {
            await adb.shellInvocationCount
        }
    }

    /// The input channel of the control session (input.md §8, decision D11). The input connection opens on the first
    /// call, presents the control session's token, and is reused while it is usable. It is opened again when it is not
    /// usable, or when the control session has another token, because a new control session refuses the old one.
    public func inputChannel() async throws(GuestAgentFailure) -> GuestInputChannel {
        try requireAvailable()
        guard let token = await supervisor.session?.sessionToken else {
            throw .operationFailed(reason: GuestProtocolFailure.disconnected.catalogName)
        }
        if let connection = await reusableInputConnection(token: token) {
            return GuestInputChannel(connection: connection)
        }
        let connection = GuestConnection(
            endpoint: .guestInput,
            transport: transport,
            presentedToken: token,
            hostVersion: hostVersion,
            logSink: logSink
        )
        do throws(GuestProtocolFailure) {
            _ = try await connection.open()
        } catch {
            throw Self.inputFailure(error)
        }
        // A caller that ran meanwhile may have opened a usable one. It is kept, and the new one is closed.
        if let kept = await reusableInputConnection(token: token) {
            await connection.close()
            return GuestInputChannel(connection: kept)
        }
        await inputConnection?.close()
        inputConnection = connection
        inputConnectionToken = token
        return GuestInputChannel(connection: connection)
    }

    /// The input connection, when it is usable and presents `token`.
    private func reusableInputConnection(token: Data) async -> GuestConnection? {
        guard let connection = inputConnection, inputConnectionToken == token, await connection.isUsable else {
            return nil
        }
        return connection
    }

    /// The agent failure of an input connection that did not open.
    private static func inputFailure(_ failure: GuestProtocolFailure) -> GuestAgentFailure {
        switch failure {
        case .incompatibleVersion, .handshakeFailed:
            .handshakeFailed(reason: failure.catalogName)
        default:
            .operationFailed(reason: failure.catalogName)
        }
    }

    /// Starts relaying task lifecycle events before the control connection can publish them.
    private func startTaskEventRelay() {
        guard taskEventRelay == nil else {
            return
        }
        let updates = supervisor.updates
        let continuation = taskEventContinuation
        let displayContinuation = displayEventContinuation
        taskEventRelay = Task {
            for await event in updates {
                guard let kind = event.kind else {
                    continue
                }
                switch kind {
                case .taskAppeared(let task), .taskChanged(let task):
                    continuation.yield(.appeared(packageID: task.package, taskID: task.taskID))
                case .taskVanished(let task):
                    continuation.yield(.vanished(packageID: task.package, taskID: task.taskID))
                case .displayAdded(let display):
                    displayContinuation.yield(.added(Self.displaySnapshot(display)))
                case .displayChanged(let display):
                    displayContinuation.yield(.changed(Self.displaySnapshot(display)))
                case .displayRemoved(let display):
                    displayContinuation.yield(.removed(displayID: display.displayID))
                case .tasksCleared(let tasks):
                    displayContinuation.yield(.tasksCleared(displayID: tasks.displayID))
                default:
                    break
                }
            }
        }
    }

    /// Throws `stopped` when ``stop()`` has run since `started`, so that a start in flight does not go on.
    private func requireStarted(_ started: UInt64) throws(GuestAgentFailure) {
        if generation != started {
            throw .stopped
        }
    }

    /// Launches a package on a display through `LaunchApplication` (guest-components.md §6.4). The result is the task
    /// that the agent reports, and a failure is the protocol failure, named as the agent's error.
    public func launch(package: String, displayID: Int32) async throws(GuestAgentFailure) -> GuestLaunchReport {
        try requireAvailable()
        let result: GPLaunchResult
        do {
            result = try await supervisor.send(GuestLaunchApplication(package: package, displayID: displayID))
        } catch {
            throw .operation(error)
        }
        let outcome: String
        switch result.outcome {
        case .broughtToFront: outcome = "broughtToFront"
        case .movedFromDisplay: outcome = "movedFromDisplay"
        default: outcome = "started"
        }
        return GuestLaunchReport(taskID: result.taskID, component: result.component, outcome: outcome)
    }

    /// Waits for display 0 to adopt a scanout mode, then applies the matching density and local IME policy.
    public func applyDisplayPolicy(for mode: ResolvedDisplayMode) async -> Bool {
        let width = mode.pixelSize.width
        let height = mode.pixelSize.height
        guard
            await supervisor.waitForDisplayMode(
                displayID: 0,
                width: width,
                height: height,
                timeout: .seconds(3)
            )
        else {
            logger.warning(
                "Android display 0 did not report resized mode \(width, .public)x\(height, .public) within 3 s")
            return false
        }
        do throws(GuestProtocolFailure) {
            _ = try await supervisor.send(
                GuestSetDisplayPolicy(
                    displayID: 0,
                    densityDPI: Int32(mode.densityDpi),
                    imePolicy: .local
                )
            )
            logger.info(
                "Applied resized display 0 policy at \(mode.densityDpi, .public) dpi for \(width, .public)x\(height, .public)"
            )
            return true
        } catch {
            logger.warning(
                "Android display 0 density update failed: \(error.catalogName, .public)")
            return false
        }
    }

    /// Installs a development APK through Android's PackageInstaller for `apkrun dev launch <apk>` (#026).
    ///
    /// The Guest Agent owns the shared ADB client; this narrow method keeps raw ADB use inside RuntimeCore.
    public func installAPK(_ apk: URL, package: String) async throws(AdbFailure) {
        let installLogger = APKLogger(
            category: RuntimeLogCategory.agents,
            sink: logSink,
            context: LogContext(packageID: package, displayID: "0")
        )
        installLogger.info("Installing the Android package through PackageInstaller")
        do {
            try await adb.install(apk: apk)
            installLogger.info("Installed the Android package through PackageInstaller")
        } catch {
            installLogger.error("The Android package install failed", errorCode: error.qualifiedCode)
            throw error
        }
    }

    /// Installs a base APK and its splits in one PackageInstaller session through the development ADB channel.
    public func installMultiple(
        apks: [URL],
        allowDowngrade: Bool = false
    ) async throws(AdbFailure) {
        do {
            try await adb.installMultiple(apks: apks, allowDowngrade: allowDowngrade)
        } catch {
            logger.error("The Android package set install failed", errorCode: error.qualifiedCode)
            throw error
        }
    }

    /// Queries the Android PackageManager through Guest Agent operation 19.
    ///
    /// `nil` means the package is not installed. The stock-image channel does not use `pm` output as package truth.
    public func queryPackage(_ package: String) async throws(GuestAgentFailure) -> GPPackageInfo? {
        try requireAvailable()
        do {
            return try await supervisor.send(GuestQueryPackage(package: package))
        } catch let failure {
            if case .remote(code: .notFound, _, operation: "QueryPackage") = failure {
                return nil
            }
            throw .operation(failure)
        }
    }

    /// Lists Android packages through Guest Agent operation 20.
    public func listPackages(
        filter: GPPackageFilter = .userInstalled
    ) async throws(GuestAgentFailure) -> [GPPackageSummary] {
        try requireAvailable()
        do {
            let result = try await supervisor.send(GuestListPackages(filter: filter))
            return result.packages
        } catch {
            throw .operation(error)
        }
    }

    /// Finishes every task of a package without force-stopping its process (#026, guest-protocol.md §7.1 #15).
    ///
    /// The Guest Agent emits `TaskVanished` before acknowledging this operation. This bounded snapshot check keeps
    /// the host session open until those events have been applied, while leaving margin inside the protocol's 5 s
    /// operation deadline.
    public func stopApplication(package: String) async throws(GuestAgentFailure) -> Bool {
        try requireAvailable()
        do {
            _ = try await supervisor.send(GuestStopApplication(package: package))
        } catch {
            throw .operation(error)
        }
        let deadline = ContinuousClock.now + .seconds(4)
        while ContinuousClock.now < deadline {
            let stillRunning = await supervisor.snapshot.tasks.values.contains { $0.package == package }
            if !stillRunning {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !(await supervisor.snapshot.tasks.values.contains { $0.package == package })
    }

    /// Throws `requiredAgentUnavailable` once the restart budget is spent, and the agent stays down.
    public func requireAvailable() throws(GuestAgentFailure) {
        if restartsRefused {
            throw .requiredAgentUnavailable
        }
    }

    /// The decision on a lost agent (guest-components.md §3.3). A connection that closed while the process still runs
    /// reconnects without a restart. A dead or unresponsive agent counts a death, and it is restarted within the budget.
    /// Internal so that a test can drive the restart without a connection (`@testable`).
    func handleLoss(_ loss: GuestAgentLoss) async -> Bool {
        if loss == .disconnected, (try? await provisioner.isRunning()) == true {
            return true
        }
        guard budget.recordDeath(at: clock()) else {
            restartsRefused = true
            return false
        }
        logger.notice("Restarting the Guest Agent after a \(String(describing: loss), .public) loss")
        do {
            try await provisioner.startAgent()
            return true
        } catch {
            restartsRefused = true
            logger.error("The Guest Agent did not restart", errorCode: error.qualifiedCode)
            return false
        }
    }

    /// Removes the forwards of the Guest Agent sockets (`localabstract:apkrun-`).
    private func removeForwards() async throws(GuestAgentFailure) {
        do {
            for forward in try await adb.forwardList() where forward.remote.hasPrefix("localabstract:apkrun-") {
                let port = forward.local.dropFirst("tcp:".count)
                if let number = UInt16(port) {
                    try await adb.forwardRemove(port: number)
                }
            }
        } catch {
            throw .adb(error)
        }
    }

    private static func displaySnapshot(_ display: GPDisplayInfo) -> GuestDisplaySnapshot {
        let product =
            display.hasProduct
            ? GuestDisplayProductInfo(
                manufacturerPnpID: display.product.manufacturerPnpID,
                productID: display.product.productID
            )
            : nil
        return GuestDisplaySnapshot(
            displayID: display.displayID,
            uniqueID: display.uniqueID,
            mode: GuestDisplaySize(width: Int(display.mode.widthPx), height: Int(display.mode.heightPx)),
            densityDPI: Int(display.densityDpi),
            product: product
        )
    }
}

extension DevelopmentGuestAgent: DisplayControlChannel {
    /// Returns the current Android display inventory from the Guest Agent supervisor.
    public func displaySnapshot() async -> [GuestDisplaySnapshot] {
        let snapshot = await supervisor.snapshot
        return snapshot.displays.values.map(Self.displaySnapshot)
    }

    /// Applies density and input-method placement policy to one Android display.
    public func setDisplayPolicy(
        _ displayID: Int32,
        densityDPI: Int,
        imePolicy: GuestDisplayIMEPolicy
    ) async throws(DisplayControlFailure) {
        guard await supervisor.state == .ready else {
            throw .unavailable
        }
        let guestIMEPolicy: GPImePolicy
        switch imePolicy {
        case .local: guestIMEPolicy = .local
        case .fallbackDisplay: guestIMEPolicy = .fallbackDisplay
        case .hide: guestIMEPolicy = .hide
        }
        do throws(GuestProtocolFailure) {
            _ = try await supervisor.send(
                GuestSetDisplayPolicy(
                    displayID: displayID,
                    densityDPI: Int32(densityDPI),
                    imePolicy: guestIMEPolicy
                )
            )
        } catch {
            throw .operationFailed
        }
    }

    /// Finishes the tasks on one display before the host disables its scanout.
    public func clearDisplay(_ displayID: Int32) async throws(DisplayControlFailure) {
        guard await supervisor.state == .ready else {
            throw .unavailable
        }
        do throws(GuestProtocolFailure) {
            _ = try await supervisor.send(GuestClearDisplay(displayID: displayID, policy: .finishTasks))
        } catch {
            throw .operationFailed
        }
    }
}
