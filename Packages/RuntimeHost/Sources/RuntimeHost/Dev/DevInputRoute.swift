import Foundation
import RuntimeAPI
import RuntimeCore

/// Keeps every window route closed until a complete input binding has passed its session checks.
final class DevInputRouteActivation: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen: Bool
    private var generation: UInt64 = 0

    init(isOpen: Bool = false) {
        self.isOpen = isOpen
    }

    var activationGeneration: UInt64 {
        lock.withLock { generation }
    }

    func activate(ifUnchangedSince generation: UInt64) -> Bool {
        lock.withLock {
            guard self.generation == generation else {
                return false
            }
            isOpen = true
            return true
        }
    }

    func deactivate() {
        lock.withLock {
            isOpen = false
            generation &+= 1
        }
    }

    var allowsInput: Bool {
        lock.withLock { isOpen }
    }
}

/// The development input route of one embedded app window (#25, #31, decision D10).
///
/// It converts wire batches to InputCore values and routes them through the shared ``InputRouter``. Focus can arrive
/// before the Guest Agent input stream is ready, so the desired focus is retained and applied when the router binds.
public actor DevInputRoute {
    enum BindingPreparation: Sendable {
        case prepared
        case unavailable
        case failed(InputRouterRegistrationFailure)
    }

    /// The development session. Its identifier is fixed, so that a caller and its tests name the same session.
    /// The identifier, as the UUID string 0024a2d0-0000-4000-8000-0000000024d0.
    public static let developmentSession = SessionID.app(
        UUID(uuid: (0x00, 0x24, 0xa2, 0xd0, 0x00, 0x00, 0x40, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x24, 0xd0)))
    /// The Android display of the development session (input.md §7.1).
    public static let displayID: Int32 = 0
    /// The most events in one wire batch. A longer batch keeps its first events (runtime-api.md §7.3).
    public static let maximumEventsPerBatch = 512

    private var router: InputRouter?
    private var session: SessionID?
    private var preparedBinding:
        (
            router: InputRouter,
            session: SessionID,
            activation: DevInputRouteActivation?
        )?
    private var preparingBindingSession: SessionID?
    private var activation: DevInputRouteActivation?
    private var targetDisplayID = DevInputRoute.displayID
    private var isFocused = false
    private var isTerminal = false
    private var focusGeneration: UInt64 = 0
    /// The drops that happen before the router sees the events: the events of an unbound route, and the events cut
    /// from a long batch.
    private var localCounters = InputCounters()

    /// Creates an unbound route.
    public init() {}

    /// Selects the Android display before the route is bound to the guest input router.
    public func setDisplayID(_ displayID: Int32) {
        guard !isTerminal, router == nil, preparedBinding == nil, displayID >= 0 else {
            return
        }
        targetDisplayID = displayID
    }

    func canBind() -> Bool {
        !isTerminal
    }

    /// The selected Android display, for the development binding status message.
    func targetDisplayIDForDiagnostics() -> Int32 {
        targetDisplayID
    }

    /// Binds the route to the shared router for `session`, registered on its selected display.
    @discardableResult
    public func bind(
        router: InputRouter,
        session: SessionID = DevInputRoute.developmentSession
    ) async -> InputRouterRegistrationFailure? {
        switch await prepareBinding(router: router, session: session) {
        case .prepared:
            _ = await activatePreparedBinding(session: session)
            return nil
        case .unavailable:
            return nil
        case .failed(let failure):
            return failure
        }
    }

    /// Registers and focuses a session without exposing it to `send` until it is explicitly activated.
    func prepareBinding(
        router: InputRouter,
        session: SessionID,
        activation: DevInputRouteActivation? = nil
    ) async -> BindingPreparation {
        guard !isTerminal else {
            return .unavailable
        }
        await discardPreparedBinding()
        await unbind()
        guard !isTerminal else {
            return .unavailable
        }
        let failure = await router.register(session: session, displayID: targetDisplayID, state: .running)
        guard !isTerminal else {
            if failure == nil {
                await router.sessionEnded(session, cancelGuestState: false)
            }
            return .unavailable
        }
        if let failure {
            localCounters.droppedInvalid += 1
            return .failed(failure)
        }
        preparedBinding = (router, session, activation)
        if isFocused {
            preparingBindingSession = session
            await router.focusChanged(session, focused: true, generation: focusGeneration)
            if preparingBindingSession == session {
                preparingBindingSession = nil
            }
            guard !isTerminal else {
                preparedBinding = nil
                await router.sessionEnded(session, cancelGuestState: false)
                return .unavailable
            }
        }
        return .prepared
    }

    /// Reconciles current focus while the route remains closed, then makes the session available to its shared gate.
    func activatePreparedBinding(session: SessionID) async -> Bool {
        guard !isTerminal, let preparedBinding, preparedBinding.session == session else {
            return false
        }
        preparingBindingSession = session
        while !isTerminal, self.preparedBinding?.session == session {
            let generation = focusGeneration
            let focused = isFocused
            await preparedBinding.router.focusChanged(
                session,
                focused: focused,
                generation: generation
            )
            guard !isTerminal, self.preparedBinding?.session == session else {
                preparingBindingSession = nil
                return false
            }
            guard generation != focusGeneration || focused != isFocused else {
                break
            }
        }
        preparingBindingSession = nil
        guard !isTerminal, self.preparedBinding?.session == session else {
            return false
        }
        router = preparedBinding.router
        self.session = preparedBinding.session
        activation = preparedBinding.activation
        self.preparedBinding = nil
        return true
    }

    /// Ends a registered session that was never made visible to `send`.
    func discardPreparedBinding(cancelGuestState: Bool = true) async {
        guard let preparedBinding else {
            return
        }
        self.preparedBinding = nil
        if preparingBindingSession == preparedBinding.session {
            preparingBindingSession = nil
        }
        await preparedBinding.router.sessionEnded(
            preparedBinding.session,
            cancelGuestState: cancelGuestState
        )
        localCounters.add(await preparedBinding.router.counters)
    }

    /// Applies a window's key-focus change. The shared router serializes focus with routed events.
    public func focusChanged(_ focused: Bool, generation: UInt64) async {
        guard !isTerminal, generation > focusGeneration else {
            return
        }
        focusGeneration = generation
        isFocused = focused
        if let router, let session {
            await router.focusChanged(session, focused: focused, generation: generation)
            return
        }
        guard let preparedBinding else {
            return
        }
        guard preparingBindingSession != preparedBinding.session else {
            return
        }
        await preparedBinding.router.focusChanged(
            preparedBinding.session,
            focused: focused,
            generation: generation
        )
    }

    /// Reapplies key-window focus when Android reports a task after the initial focus event.
    ///
    /// AppKit can make a window key before its Android task exists. In that case `FocusDisplay` fails
    /// closed; a task-appearance event is the first reliable point at which the Guest Agent can focus it.
    public func reapplyFocusIfNeeded() async {
        guard !isTerminal, isFocused else {
            return
        }
        if let router, let session {
            await router.focusChanged(session, focused: true, generation: focusGeneration)
            return
        }
        guard let preparedBinding, preparingBindingSession != preparedBinding.session else {
            return
        }
        await preparedBinding.router.focusChanged(
            preparedBinding.session,
            focused: true,
            generation: focusGeneration
        )
    }

    /// Unbinds the route. The session ends on the router, so that the guest cancels its open gestures and keys. The
    /// counts of the router are kept after it ends, so that the route's total covers every router it has had.
    public func unbind(cancelGuestState: Bool = true) async {
        var bindings: [(router: InputRouter, session: SessionID)] = []
        if let router, let session {
            self.router = nil
            self.session = nil
            activation = nil
            bindings.append((router, session))
        }
        if let preparedBinding {
            self.preparedBinding = nil
            if preparingBindingSession == preparedBinding.session {
                preparingBindingSession = nil
            }
            bindings.append((preparedBinding.router, preparedBinding.session))
        }
        guard !bindings.isEmpty else {
            return
        }
        for binding in bindings {
            await binding.router.sessionEnded(
                binding.session,
                cancelGuestState: cancelGuestState
            )
            localCounters.add(await binding.router.counters)
        }
    }

    /// Detaches local input state immediately and finishes guest cancellation asynchronously after reconnect.
    public func detachForGuestReconciliation(cancelGuestState: Bool) -> Task<Void, Never>? {
        isTerminal = true
        isFocused = false
        var bindings: [(router: InputRouter, session: SessionID)] = []
        if let router, let session {
            self.router = nil
            self.session = nil
            activation = nil
            bindings.append((router, session))
        }
        if let preparedBinding {
            self.preparedBinding = nil
            if preparingBindingSession == preparedBinding.session {
                preparingBindingSession = nil
            }
            bindings.append((preparedBinding.router, preparedBinding.session))
        }
        guard !bindings.isEmpty else {
            return nil
        }
        return Task { [weak self] in
            for binding in bindings {
                await binding.router.sessionEnded(
                    binding.session,
                    cancelGuestState: cancelGuestState
                )
                let counters = await binding.router.counters
                await self?.addRouterCounters(counters)
            }
        }
    }

    private func addRouterCounters(_ counters: InputCounters) {
        localCounters.add(counters)
    }

    /// Routes a wire batch. The events beyond ``maximumEventsPerBatch`` are dropped and counted as invalid. The rest
    /// are dropped as not running when the route is unbound.
    public func send(_ batch: RuntimeAPI.InputBatch) async {
        var wire = batch.events
        if wire.count > Self.maximumEventsPerBatch {
            localCounters.droppedInvalid += wire.count - Self.maximumEventsPerBatch
            wire.removeLast(wire.count - Self.maximumEventsPerBatch)
        }
        let events = WireInputConversion.events(wire)
        if let activation, !activation.allowsInput {
            localCounters.droppedNotRunning += events.count
            return
        }
        guard let router, let session else {
            localCounters.droppedNotRunning += events.count
            return
        }
        await router.route(events, from: session)
    }

    /// The counts of the route: the router's, and the drops that happened before it.
    public func counters() async -> InputCounters {
        var total = localCounters
        if let router {
            total.add(await router.counters)
        }
        return total
    }

    /// Starts bounded ACK capture on the bound router, with optional sent-event tracing.
    ///
    /// When `everyBatch` is true, each accepted event is sent in its own protobuf batch and that batch requests an ACK.
    /// When false, the normal batching and every-32nd-batch ACK cadence are preserved. Sent-event history has its own
    /// opt-in because it formats and retains each routed event.
    public func startAcknowledgementHistoryCapture(
        everyBatch: Bool = false,
        captureSentEventHistory: Bool = false
    ) async -> InputCounters? {
        guard let router else {
            return nil
        }
        var total = localCounters
        total.add(
            await router.startAcknowledgementHistoryCapture(
                everyBatch: everyBatch,
                captureSentEventHistory: captureSentEventHistory
            )
        )
        return total
    }

    /// Stops bounded ACK history capture and returns its final snapshot.
    public func stopAcknowledgementHistoryCapture() async -> InputAcknowledgementHistory {
        guard let router else {
            return InputAcknowledgementHistory(records: [], discardedRecords: 0)
        }
        return await router.stopAcknowledgementHistoryCapture()
    }

    /// The bounded ACK history of the currently bound router, for development diagnostics.
    public func acknowledgementHistory() async -> InputAcknowledgementHistory {
        guard let router else {
            return InputAcknowledgementHistory(records: [], discardedRecords: 0)
        }
        return await router.acknowledgementHistory
    }

    /// The bounded history of host input events successfully sent by the currently bound router.
    public func sentEventHistory() async -> InputSentEventHistory {
        guard let router else {
            return InputSentEventHistory(records: [], discardedRecords: 0)
        }
        return await router.sentEventHistory
    }

    /// Whether the bound guest negotiated guest event-time metadata in input ACKs.
    public func supportsAcknowledgementEventTimeTrace() async -> Bool {
        guard let router else {
            return false
        }
        return await router.supportsAcknowledgementEventTimeTrace
    }
}
