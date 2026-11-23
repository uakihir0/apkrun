import InputCore

/// Receives the pointer and key events of a development window (input.md §5.1, §7.1, #25, #26).
///
/// The window calls `deliver` on the main thread, once for each sample or timer flush that produces events. The events
/// keep their order across calls, so the receiver must keep it too. The window does not wait for the receiver, so a
/// receiver that needs time queues the events.
public protocol PointerInputSink: Sendable {
    /// Delivers `events`, in the order they happened.
    func deliver(_ events: [InputEvent])
}

/// Receives the text and editor events of editor mode (input.md §5.1). The events are produced on the
/// main thread by `NSTextInputClient` calls, in the order the macOS input method made them.
public protocol ImeTextSink: Sendable {
    /// Delivers one event.
    func deliverText(_ event: ImeTextEvent)
}
