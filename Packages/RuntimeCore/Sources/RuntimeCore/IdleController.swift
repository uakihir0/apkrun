import Foundation

/// A source of monotonic time that stops advancing while the host is asleep.
public protocol RuntimeIdleClock: Sendable {
    /// The current monotonic offset from this clock's origin.
    var now: Duration { get }

    /// Sleeps until a monotonic deadline.
    func sleep(until deadline: Duration) async throws
}

/// Uses Swift's suspending clock so host sleep does not count as runtime idle time.
public struct SuspendingRuntimeIdleClock: RuntimeIdleClock {
    private let clock: SuspendingClock
    private let origin: SuspendingClock.Instant

    /// Creates a clock whose idle time does not advance while macOS is asleep.
    public init() {
        let clock = SuspendingClock()
        self.clock = clock
        origin = clock.now
    }

    /// The elapsed awake time since this clock was created.
    public var now: Duration {
        origin.duration(to: clock.now)
    }

    /// Sleeps until the requested awake-time deadline.
    public func sleep(until deadline: Duration) async throws {
        try await clock.sleep(until: origin.advanced(by: deadline))
    }
}

/// Identifies a source that keeps the Android runtime active.
public struct ActivityKind: RawRepresentable, Sendable, Hashable {
    /// The stable name used for this activity source.
    public let rawValue: String

    /// Creates an activity source with a stable name.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// An app session, including one whose window is backgrounded.
    public static let session = Self(rawValue: "session")

    /// A task retained by `window.closeBehavior = keepRunning`.
    public static let backgroundTask = Self(rawValue: "backgroundTask")

    /// An install, uninstall, update install, icon render, or metadata refresh.
    public static let storeOperation = Self(rawValue: "storeOperation")

    /// A diagnostics collection.
    public static let diagnostics = Self(rawValue: "diagnostics")

    /// An image migration.
    public static let migration = Self(rawValue: "migration")

    /// First-run provisioning.
    public static let provisioning = Self(rawValue: "provisioning")

    /// An active ADB bridge client.
    public static let adbClient = Self(rawValue: "adbClient")

    /// `apkrun runtime start --hold`.
    public static let cli = Self(rawValue: "cli")

    /// The activity sources defined by runtime-daemon.md §5.1.
    public static let runtimeSources: [Self] = [
        .session,
        .backgroundTask,
        .storeOperation,
        .diagnostics,
        .migration,
        .provisioning,
        .adbClient,
        .cli,
    ]
}

/// Runtime idle policy settings. Timer values are minutes in the documented 0–1440 range.
public struct RuntimeIdleSettings: Sendable, Equatable {
    /// The idle duration after which the runtime is asked to suspend.
    public let idleSuspendMinutes: Int

    /// The idle duration after which the runtime is asked to stop.
    public let idleStopMinutes: Int

    /// The policy used to start the runtime at login.
    public let startPolicy: StartPolicy

    /// How the runtime is started by the daemon.
    public enum StartPolicy: String, Sendable {
        /// Start only when an operation requires Android.
        case onDemand

        /// Preboot after login. The preboot trigger is implemented in #70 step 2.
        case atLogin
    }

    /// A settings validation failure.
    public enum ValidationError: Error, Equatable, Sendable {
        /// A timer value is outside the documented range.
        case timerMinutesOutOfRange(name: String)
    }

    /// Creates settings with the documented defaults and validates both timer values.
    public init(
        idleSuspendMinutes: Int = 10,
        idleStopMinutes: Int = 60,
        startPolicy: StartPolicy = .onDemand
    ) throws(ValidationError) {
        guard (0...1440).contains(idleSuspendMinutes) else {
            throw .timerMinutesOutOfRange(name: "runtime.idleSuspendMinutes")
        }
        guard (0...1440).contains(idleStopMinutes) else {
            throw .timerMinutesOutOfRange(name: "runtime.idleStopMinutes")
        }
        self.idleSuspendMinutes = idleSuspendMinutes
        self.idleStopMinutes = idleStopMinutes
        self.startPolicy = startPolicy
    }

    /// The defaults from configuration.md.
    public static let `default` = RuntimeIdleSettings(
        validatedIdleSuspendMinutes: 10,
        idleStopMinutes: 60,
        startPolicy: .onDemand
    )

    private init(
        validatedIdleSuspendMinutes idleSuspendMinutes: Int,
        idleStopMinutes: Int,
        startPolicy: StartPolicy
    ) {
        self.idleSuspendMinutes = idleSuspendMinutes
        self.idleStopMinutes = idleStopMinutes
        self.startPolicy = startPolicy
    }
}

/// An event for the RuntimeHost lifecycle owner to apply.
public enum IdleControllerAction: Sendable, Equatable {
    /// An activity began and the runtime must be ready to serve it.
    case activityBegan(ActivityKind)

    /// The idle suspend deadline elapsed.
    case suspend

    /// The idle stop deadline elapsed.
    case stop
}

/// Holds the runtime active until explicitly released or deinitialized.
public final class RuntimeActivityAssertion: @unchecked Sendable {
    /// The source that holds the runtime active.
    public let kind: ActivityKind

    private let lock = NSLock()
    private let onRelease: @Sendable () -> Void
    private var isReleased = false

    fileprivate init(kind: ActivityKind, onRelease: @escaping @Sendable () -> Void) {
        self.kind = kind
        self.onRelease = onRelease
    }

    /// Releases the activity hold. Repeated calls and deinitialization are harmless.
    public func release() {
        lock.lock()
        let shouldRelease = !isReleased
        isReleased = true
        lock.unlock()

        if shouldRelease {
            onRelease()
        }
    }

    deinit {
        release()
    }
}

/// Tracks runtime activity and emits one-shot suspend and stop deadline actions.
public actor IdleController {
    /// Receives activity and idle lifecycle actions.
    ///
    /// The handler must not acquire an activity assertion while handling an action. Doing so
    /// would wait for the handler's own serialized action queue to finish.
    public typealias ActionHandler = @Sendable (IdleControllerAction) async -> Void

    private struct PendingAction {
        let action: IdleControllerAction
        let completion: CheckedContinuation<Void, Never>?
    }

    private let clock: any RuntimeIdleClock
    private let onAction: ActionHandler
    private var settings: RuntimeIdleSettings
    private var assertions: [UUID: ActivityKind] = [:]
    private var pendingActions: [PendingAction] = []
    private var idleSince: Duration?
    private var timerTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var didSuspend = false
    private var didStop = false
    private var isStarted = false
    private var isDeliveringActions = false
    private var isActivityActionPending = false
    private var activityActionWaiters: [CheckedContinuation<Void, Never>] = []

    /// Creates an idle controller. Call `start()` when daemon lifecycle setup is complete.
    public init(
        settings: RuntimeIdleSettings = .default,
        clock: any RuntimeIdleClock = SuspendingRuntimeIdleClock(),
        onAction: @escaping ActionHandler = { _ in }
    ) {
        self.settings = settings
        self.clock = clock
        self.onAction = onAction
    }

    /// Starts idle tracking. Repeated calls have no effect.
    public func start() {
        guard !isStarted else {
            return
        }
        isStarted = true
        if assertions.isEmpty {
            idleSince = clock.now
            scheduleNextDeadline()
        }
    }

    /// Acquires a hold for an activity source and notifies the lifecycle owner on idle-to-active.
    ///
    /// This returns only after the lifecycle owner has handled the activity action. Lifecycle
    /// action handlers must not acquire activity assertions, directly or through child tasks,
    /// because the serialized handler would wait on its own queue.
    public func assertActivity(_ kind: ActivityKind) async -> RuntimeActivityAssertion {
        let wasIdle = assertions.isEmpty
        let id = UUID()
        assertions[id] = kind
        if wasIdle {
            idleSince = nil
            didSuspend = false
            didStop = false
            pendingActions.removeAll { pendingAction in
                switch pendingAction.action {
                case .activityBegan:
                    return false
                case .suspend, .stop:
                    return true
                }
            }
            cancelTimer()
            isActivityActionPending = true
            await enqueueAndWaitForAction(.activityBegan(kind))
        } else if isActivityActionPending {
            await withCheckedContinuation { continuation in
                activityActionWaiters.append(continuation)
            }
        }
        return RuntimeActivityAssertion(kind: kind) { [weak self] in
            Task {
                await self?.releaseAssertion(id)
            }
        }
    }

    /// Applies a settings update without resetting the current idle start time.
    public func update(settings: RuntimeIdleSettings) {
        self.settings = settings
        guard isStarted, assertions.isEmpty else {
            return
        }
        scheduleNextDeadline()
    }

    /// Returns the active number of assertions, primarily for health reporting and tests.
    public var activeAssertionCount: Int {
        assertions.count
    }

    /// Returns the current settings.
    public var currentSettings: RuntimeIdleSettings {
        settings
    }

    private func releaseAssertion(_ id: UUID) async {
        guard assertions.removeValue(forKey: id) != nil else {
            return
        }
        guard assertions.isEmpty, isStarted else {
            return
        }
        idleSince = clock.now
        didSuspend = false
        didStop = false
        scheduleNextDeadline()
    }

    private func scheduleNextDeadline() {
        cancelTimer()
        guard let idleSince, !didStop else {
            return
        }

        let suspendDeadline =
            settings.idleSuspendMinutes > 0 && !didSuspend
            ? idleSince + .seconds(settings.idleSuspendMinutes * 60)
            : nil
        let stopDeadline =
            settings.idleStopMinutes > 0
            ? idleSince + .seconds(settings.idleStopMinutes * 60)
            : nil

        let nextAction: IdleControllerAction
        let nextDeadline: Duration
        switch (suspendDeadline, stopDeadline) {
        case (let suspend?, let stop?) where stop < suspend:
            nextAction = .stop
            nextDeadline = stop
        case (let suspend?, _):
            nextAction = .suspend
            nextDeadline = suspend
        case (nil, let stop?):
            nextAction = .stop
            nextDeadline = stop
        case (nil, nil):
            return
        }

        generation &+= 1
        let scheduledGeneration = generation
        let clock = self.clock
        timerTask = Task { [weak self] in
            do {
                try await clock.sleep(until: nextDeadline)
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            await self?.deadlineReached(
                action: nextAction,
                scheduledGeneration: scheduledGeneration
            )
        }
    }

    private func deadlineReached(
        action: IdleControllerAction,
        scheduledGeneration: UInt64
    ) {
        guard generation == scheduledGeneration, assertions.isEmpty, idleSince != nil else {
            return
        }
        timerTask = nil
        switch action {
        case .activityBegan:
            return
        case .suspend:
            didSuspend = true
        case .stop:
            didStop = true
        }
        enqueue(action)
        if action == .suspend {
            scheduleNextDeadline()
        }
    }

    private func enqueueAndWaitForAction(_ action: IdleControllerAction) async {
        await withCheckedContinuation { continuation in
            pendingActions.append(PendingAction(action: action, completion: continuation))
            startActionDeliveryIfNeeded()
        }
    }

    private func enqueue(_ action: IdleControllerAction) {
        pendingActions.append(PendingAction(action: action, completion: nil))
        startActionDeliveryIfNeeded()
    }

    private func startActionDeliveryIfNeeded() {
        guard !isDeliveringActions else {
            return
        }
        isDeliveringActions = true
        Task { [weak self] in
            await self?.deliverActions()
        }
    }

    private func deliverActions() async {
        while !pendingActions.isEmpty {
            let pendingAction = pendingActions.removeFirst()
            let shouldDeliver: Bool
            switch pendingAction.action {
            case .activityBegan:
                shouldDeliver = true
            case .suspend, .stop:
                shouldDeliver = assertions.isEmpty
            }

            if shouldDeliver {
                await onAction(pendingAction.action)
            }
            if case .activityBegan = pendingAction.action {
                isActivityActionPending = false
                let waiters = activityActionWaiters
                activityActionWaiters.removeAll()
                pendingAction.completion?.resume()
                for waiter in waiters {
                    waiter.resume()
                }
                continue
            }
            pendingAction.completion?.resume()
        }
        isDeliveringActions = false
    }

    private func cancelTimer() {
        generation &+= 1
        timerTask?.cancel()
        timerTask = nil
    }
}
