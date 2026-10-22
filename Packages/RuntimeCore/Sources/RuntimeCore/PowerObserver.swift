import DiagnosticsCore
import Dispatch
import Foundation
import IOKit
import IOKit.pwr_mgt

/// A host power event that can affect the Android VM lifecycle.
public enum PowerObserverEvent: Sendable, Equatable {
    /// The host is about to sleep. The handler should pause the VM before it returns.
    case systemWillSleep
    /// A pending sleep was cancelled. The handler may undo a pause it initiated for that sleep.
    case systemWillNotSleep
    /// The host has powered on. The handler may resume a VM paused for host sleep.
    case systemHasPoweredOn
}

/// A failure to register the host power notifications.
public enum PowerObserverFailure: Error, Equatable, Sendable {
    /// IOKit did not provide a root power connection and notification port.
    case registrationFailed
}

/// Receives sleep and wake events from IOKit without taking ownership of the runtime lifecycle.
///
/// `systemWillSleep` is acknowledged after the asynchronous handler returns, or after the five-second budget if it
/// runs late. A late handler is logged as `power.pauseLate`; later power events remain ordered behind it. The handler
/// owns the VM pause. Idle-sleep requests are always allowed immediately.
public final class PowerObserver: @unchecked Sendable {
    /// The asynchronous consumer of host power events.
    public typealias EventHandler = @Sendable (PowerObserverEvent) async -> Void

    private let source: any PowerEventSource
    private let delivery: PowerEventDelivery
    private let lock = NSLock()
    private var isStarted = false

    /// Creates an observer that registers with IOKit when `start()` is called.
    public convenience init(handler: @escaping EventHandler) {
        self.init(source: IOKitPowerEventSource(), handler: handler)
    }

    init(
        source: any PowerEventSource,
        willSleepAcknowledgementDeadline: Duration = .seconds(5),
        handler: @escaping EventHandler
    ) {
        self.source = source
        delivery = PowerEventDelivery(
            handler: handler,
            willSleepAcknowledgementDeadline: willSleepAcknowledgementDeadline
        )
    }

    /// Registers for host sleep and wake events. Repeated calls are harmless.
    public func start() throws(PowerObserverFailure) {
        lock.lock()
        defer { lock.unlock() }
        guard !isStarted else { return }
        do {
            try source.start { [delivery] message in
                switch message {
                case .canSystemSleep(let acknowledge):
                    // APKRun never vetoes an idle sleep request and does not need a lifecycle callback for it.
                    acknowledge()
                case .systemWillSleep(let acknowledge):
                    delivery.enqueue(.systemWillSleep, acknowledgement: acknowledge)
                case .systemWillNotSleep:
                    delivery.enqueue(.systemWillNotSleep)
                case .systemHasPoweredOn:
                    delivery.enqueue(.systemHasPoweredOn)
                }
            }
            isStarted = true
        } catch {
            throw error
        }
    }

    /// Unregisters from IOKit. Repeated calls are harmless.
    public func stop() {
        let shouldStop = lock.withLock { () -> Bool in
            guard isStarted else { return false }
            isStarted = false
            return true
        }
        if shouldStop {
            source.stop()
        }
    }

    deinit {
        stop()
    }
}

enum PowerSystemMessage: Sendable {
    case canSystemSleep(acknowledge: @Sendable () -> Void)
    case systemWillSleep(acknowledge: @Sendable () -> Void)
    case systemWillNotSleep
    case systemHasPoweredOn
}

protocol PowerEventSource: Sendable {
    func start(handler: @escaping @Sendable (PowerSystemMessage) -> Void) throws(PowerObserverFailure)
    func stop()
}

/// Preserves notification order while allowing each lifecycle callback to suspend asynchronously.
private final class PowerEventDelivery: @unchecked Sendable {
    private struct PendingEvent {
        let event: PowerObserverEvent
        let sleepAcknowledgement: PowerHandlerCompletionRace?
    }

    private let lock = NSLock()
    private let handler: PowerObserver.EventHandler
    private let willSleepAcknowledgementDeadline: Duration
    private let logger = APKLogger(category: RuntimeLogCategory.power)
    private var pending: [PendingEvent] = []
    private var isDelivering = false

    init(
        handler: @escaping PowerObserver.EventHandler,
        willSleepAcknowledgementDeadline: Duration
    ) {
        precondition(willSleepAcknowledgementDeadline > .zero)
        self.handler = handler
        self.willSleepAcknowledgementDeadline = willSleepAcknowledgementDeadline
    }

    func enqueue(_ event: PowerObserverEvent, acknowledgement: (@Sendable () -> Void)? = nil) {
        let sleepAcknowledgement = acknowledgement.map(PowerHandlerCompletionRace.init(acknowledge:))
        if let sleepAcknowledgement {
            // Start the five-second budget when IOKit delivers the message, not when earlier work
            // happens to let this callback reach the head of the delivery queue.
            let deadline = willSleepAcknowledgementDeadline
            Task {
                do {
                    try await Task.sleep(for: deadline)
                } catch {
                    return
                }
                sleepAcknowledgement.resolve(completed: false)
            }
        }
        let shouldStartDelivery = lock.withLock {
            pending.append(PendingEvent(event: event, sleepAcknowledgement: sleepAcknowledgement))
            guard !isDelivering else { return false }
            isDelivering = true
            return true
        }
        guard shouldStartDelivery else { return }
        Task { await deliverPendingEvents() }
    }

    private func deliverPendingEvents() async {
        while true {
            let next = lock.withLock { () -> PendingEvent? in
                guard !pending.isEmpty else {
                    isDelivering = false
                    return nil
                }
                return pending.removeFirst()
            }
            guard let next else { return }
            guard let sleepAcknowledgement = next.sleepAcknowledgement else {
                await handler(next.event)
                continue
            }
            Task {
                await handler(next.event)
                sleepAcknowledgement.resolve(completed: true)
            }
            let completedBeforeDeadline = await sleepAcknowledgement.wait()
            if !completedBeforeDeadline {
                logger.warning("power.pauseLate: acknowledging host sleep before the pause handler completed")
            }
        }
    }
}

/// IOKit power notifications delivered on a dedicated serial dispatch queue.
private final class PowerHandlerCompletionRace: @unchecked Sendable {
    private let lock = NSLock()
    private let acknowledge: @Sendable () -> Void
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    init(acknowledge: @escaping @Sendable () -> Void) {
        self.acknowledge = acknowledge
    }

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            let completed = lock.withLock { () -> Bool? in
                if let result {
                    return result
                }
                self.continuation = continuation
                return nil
            }
            if let completed {
                continuation.resume(returning: completed)
            }
        }
    }

    func resolve(completed: Bool) {
        let resolution = lock.withLock { () -> (CheckedContinuation<Bool, Never>?, Bool)? in
            guard result == nil else { return nil }
            result = completed
            let current = continuation
            continuation = nil
            return (current, completed)
        }
        guard let (waiter, completion) = resolution else { return }
        acknowledge()
        waiter?.resume(returning: completion)
    }
}

private final class IOKitPowerEventSource: PowerEventSource, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.apkrun.runtime.power-observer")
    private let lock = NSLock()
    private var notificationPort: IONotificationPortRef?
    private var rootPort: io_connect_t = IO_OBJECT_NULL
    private var notifier: io_object_t = IO_OBJECT_NULL
    private var receiver: (@Sendable (PowerSystemMessage) -> Void)?

    func start(handler: @escaping @Sendable (PowerSystemMessage) -> Void) throws(PowerObserverFailure) {
        lock.lock()
        defer { lock.unlock() }
        guard notificationPort == nil else { return }
        receiver = handler

        var newNotificationPort: IONotificationPortRef?
        var newRootPort: io_connect_t = IO_OBJECT_NULL
        let newNotifier = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(),
            &newNotificationPort,
            ioKitPowerInterestCallback,
            &newRootPort
        )
        guard newNotifier != IO_OBJECT_NULL, let newNotificationPort else {
            receiver = nil
            if let newNotificationPort {
                IONotificationPortDestroy(newNotificationPort)
            }
            if newRootPort != IO_OBJECT_NULL {
                IOServiceClose(newRootPort)
            }
            throw .registrationFailed
        }

        notificationPort = newNotificationPort
        rootPort = newRootPort
        notifier = newNotifier
        IONotificationPortSetDispatchQueue(newNotificationPort, queue)
    }

    func stop() {
        var registration = lock.withLock { () -> (IONotificationPortRef?, io_connect_t, io_object_t) in
            let current = (notificationPort, rootPort, notifier)
            notificationPort = nil
            rootPort = IO_OBJECT_NULL
            notifier = IO_OBJECT_NULL
            receiver = nil
            return current
        }
        if registration.2 != IO_OBJECT_NULL {
            IODeregisterForSystemPower(&registration.2)
        }
        if let notificationPort = registration.0 {
            IONotificationPortDestroy(notificationPort)
        }
        if registration.1 != IO_OBJECT_NULL {
            IOServiceClose(registration.1)
        }
    }

    fileprivate func receive(messageType: natural_t, messageArgument: UnsafeMutableRawPointer?) {
        let receiver = lock.withLock { self.receiver }
        guard let receiver else { return }
        let argument = Int(bitPattern: messageArgument)
        switch messageType {
        case IOKitSystemPowerMessage.canSystemSleep:
            receiver(
                .canSystemSleep { [weak self] in
                    self?.allowPowerChange(messageArgument: argument)
                })
        case IOKitSystemPowerMessage.systemWillSleep:
            receiver(
                .systemWillSleep { [weak self] in
                    self?.allowPowerChange(messageArgument: argument)
                })
        case IOKitSystemPowerMessage.systemWillNotSleep:
            receiver(.systemWillNotSleep)
        case IOKitSystemPowerMessage.systemHasPoweredOn:
            receiver(.systemHasPoweredOn)
        default:
            break
        }
    }

    private func allowPowerChange(messageArgument: Int) {
        let rootPort = lock.withLock { self.rootPort }
        guard rootPort != IO_OBJECT_NULL else { return }
        IOAllowPowerChange(rootPort, messageArgument)
    }
}

/// Swift does not import the `iokit_common_msg(...)` macros in IOMessage.h. These are the documented
/// `iokit_common_msg(0x270/0x280/0x290/0x300)` values for the system sleep and wake messages.
private enum IOKitSystemPowerMessage {
    static let canSystemSleep: natural_t = 0xE000_0270
    static let systemWillSleep: natural_t = 0xE000_0280
    static let systemWillNotSleep: natural_t = 0xE000_0290
    static let systemHasPoweredOn: natural_t = 0xE000_0300
}

nonisolated(unsafe) private let ioKitPowerInterestCallback: IOServiceInterestCallback = {
    refcon, _, messageType, messageArgument in
    guard let refcon else { return }
    Unmanaged<IOKitPowerEventSource>.fromOpaque(refcon)
        .takeUnretainedValue()
        .receive(messageType: messageType, messageArgument: messageArgument)
}
