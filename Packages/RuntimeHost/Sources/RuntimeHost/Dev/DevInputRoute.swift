import Foundation
import RuntimeAPI
import RuntimeCore

/// The development input route of one embedded app window (#25, #31, decision D10).
///
/// It converts wire batches to InputCore values and routes them through the shared ``InputRouter``. Focus can arrive
/// before the Guest Agent input stream is ready, so the desired focus is retained and applied when the router binds.
public actor DevInputRoute {
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
        guard !isTerminal, router == nil, displayID >= 0 else {
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
        guard !isTerminal else {
            return nil
        }
        await unbind()
        guard !isTerminal else {
            return nil
        }
        let failure = await router.register(session: session, displayID: targetDisplayID, state: .running)
        guard !isTerminal else {
            if failure == nil {
                await router.sessionEnded(session)
            }
            return failure
        }
        guard failure == nil else {
            localCounters.droppedInvalid += 1
            return failure
        }
        self.router = router
        self.session = session
        if isFocused {
            await router.focusChanged(session, focused: true, generation: focusGeneration)
        }
        return nil
    }

    /// Applies a window's key-focus change. The shared router serializes focus with routed events.
    public func focusChanged(_ focused: Bool, generation: UInt64) async {
        guard !isTerminal, generation > focusGeneration else {
            return
        }
        focusGeneration = generation
        isFocused = focused
        guard let router, let session else {
            return
        }
        await router.focusChanged(session, focused: focused, generation: generation)
    }

    /// Reapplies key-window focus when Android reports a task after the initial focus event.
    ///
    /// AppKit can make a window key before its Android task exists. In that case `FocusDisplay` fails
    /// closed; a task-appearance event is the first reliable point at which the Guest Agent can focus it.
    public func reapplyFocusIfNeeded() async {
        guard !isTerminal, isFocused, let router, let session else {
            return
        }
        await router.focusChanged(session, focused: true, generation: focusGeneration)
    }

    /// Unbinds the route. The session ends on the router, so that the guest cancels its open gestures and keys. The
    /// counts of the router are kept after it ends, so that the route's total covers every router it has had.
    public func unbind(cancelGuestState: Bool = true) async {
        guard let router, let session else {
            return
        }
        self.router = nil
        self.session = nil
        await router.sessionEnded(session, cancelGuestState: cancelGuestState)
        localCounters.add(await router.counters)
    }

    /// Detaches local input state immediately and finishes guest cancellation asynchronously after reconnect.
    public func detachForGuestReconciliation() -> Task<Void, Never>? {
        isTerminal = true
        isFocused = false
        guard let router, let session else {
            return nil
        }
        self.router = nil
        self.session = nil
        return Task { [weak self] in
            await router.sessionEnded(session)
            let counters = await router.counters
            await self?.addRouterCounters(counters)
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
