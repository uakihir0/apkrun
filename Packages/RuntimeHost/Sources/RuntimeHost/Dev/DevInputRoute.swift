import Foundation
import GuestProtocol
import InputCore
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
    /// The development IME channel of input.md §5, when one is bound.
    private var imeChannel: GuestImeChannel?
    /// The task that relays the bound IME channel's states to `editorStates`.
    private var imeStatesTask: Task<Void, Never>?
    /// The sequence number of the next `ImeCommand`.
    private var imeSeq: UInt64 = 0
    /// The editor reports of the bound IME channel (input.md §5.1). Latest wins.
    public let editorStates: AsyncStream<EditorState>
    private let editorStateContinuation: AsyncStream<EditorState>.Continuation

    /// Creates an unbound route.
    public init() {
        (editorStates, editorStateContinuation) = AsyncStream.makeStream(
            of: EditorState.self, bufferingPolicy: .bufferingNewest(8))
    }

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
    public func unbind() async {
        guard let router, let session else {
            return
        }
        self.router = nil
        self.session = nil
        await router.sessionEnded(session)
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

    /// Binds the development IME channel (input.md §5), or clears it with nil. The bound channel's states are
    /// published on ``editorStates`` until the next bind.
    public func bindIme(_ channel: GuestImeChannel?) {
        imeStatesTask?.cancel()
        imeStatesTask = nil
        imeChannel = channel
        guard let channel else {
            return
        }
        let continuation = editorStateContinuation
        imeStatesTask = Task {
            for await state in channel.states {
                continuation.yield(Self.editorState(state))
            }
        }
    }

    /// Sends one editor event on the bound IME channel (input.md §5.1). Without a channel the event is
    /// dropped and counted as not running.
    public func sendText(_ event: RuntimeAPI.WireImeTextEvent) async {
        guard let imeChannel else {
            localCounters.droppedNotRunning += 1
            return
        }
        var command = GPImeCommand()
        imeSeq += 1
        command.seq = imeSeq
        command.displayID = targetDisplayID
        switch event {
        case .commit(let text):
            command.commitText = text
        case .setComposing(let text, let selection):
            var composing = GPComposing()
            composing.text = text
            composing.selectionStart = Int32(clamping: selection.start)
            composing.selectionEnd = Int32(clamping: selection.end)
            command.setComposing = composing
        case .finishComposing:
            command.finishComposing = GPFinishComposing()
        case .key(let key):
            var body = GPKeyEvent()
            body.action = key.action == .down ? .down : .up
            body.keyCode = key.androidKeyCode
            body.metaState = UInt32(bitPattern: key.metaState)
            body.repeatCount = key.repeatCount
            command.key = body
        case .editorAction(let action):
            command.editorAction = action
        case .contextMenuAction(let action):
            command.contextMenuAction = Self.contextMenuAction(action)
        }
        do {
            try await imeChannel.send(command)
        } catch {
            localCounters.droppedNotRunning += 1
        }
    }

    /// The wire action in the proto enum (guest-protocol.md §9).
    private static func contextMenuAction(_ action: RuntimeAPI.ContextMenuAction) -> GPContextMenuAction {
        switch action {
        case .copy: .copy
        case .cut: .cut
        case .paste: .paste
        case .selectAll: .selectAll
        }
    }

    /// The proto report in the view's editor state (input.md §5.1); the editor's text is never mirrored.
    private static func editorState(_ state: GPImeState) -> EditorState {
        var cursorRectPx: CGRect?
        if state.hasCursorRectPx {
            cursorRectPx = CGRect(
                x: CGFloat(state.cursorRectPx.left),
                y: CGFloat(state.cursorRectPx.top),
                width: CGFloat(state.cursorRectPx.right - state.cursorRectPx.left),
                height: CGFloat(state.cursorRectPx.bottom - state.cursorRectPx.top))
        }
        var composing: InputCore.TextRange?
        if state.composingStart >= 0 {
            composing = InputCore.TextRange(start: state.composingStart, end: state.composingEnd)
        }
        return EditorState(
            editorFocused: state.editorFocused,
            displayID: state.displayID,
            packageID: state.package,
            inputType: state.inputType,
            imeOptions: state.imeOptions,
            selection: InputCore.TextRange(start: state.selectionStart, end: state.selectionEnd),
            composing: composing,
            cursorRectPx: cursorRectPx)
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
