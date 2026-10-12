/// The input wire types of runtime-api.md §7.2.
///
/// They are copies of the InputCore values, because RuntimeAPI cannot import InputCore (runtime-api.md §7.1). The
/// launcher converts InputCore values to these, and RuntimeHost converts them back before `InputRouter`. The names
/// `InputTimestamp`, `DisplayPoint`, and `MouseButton` also exist in InputCore, so a file that imports both modules
/// must qualify them.

/// A batch of input events, in the order they happened (runtime-api.md §7.3: 1 to 512 events).
public struct InputBatch: Codable, Sendable, Equatable {
    /// The events, in order.
    public var events: [WireInputEvent]

    /// Creates a batch.
    public init(events: [WireInputEvent]) {
        self.events = events
    }
}

/// The mach continuous time of an `NSEvent`, in nanoseconds.
public struct InputTimestamp: Codable, Sendable, Equatable {
    /// Nanoseconds of mach continuous time.
    public var hostNanos: UInt64

    /// Creates a timestamp.
    public init(hostNanos: UInt64) {
        self.hostNanos = hostNanos
    }
}

/// A point in display pixels, with the origin at the top-left.
public struct DisplayPoint: Codable, Sendable, Equatable {
    /// Horizontal position in pixels.
    public var x: Double
    /// Vertical position in pixels, growing downwards.
    public var y: Double

    /// Creates a point.
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A range of text in UTF-16 code units.
public struct TextRange: Codable, Sendable, Equatable {
    /// The first code unit.
    public var start: Int
    /// The code unit after the last one.
    public var end: Int

    /// Creates a range.
    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

/// One input event on the wire.
public enum WireInputEvent: Codable, Sendable, Equatable {
    /// A touch event of the left button.
    case touch(WireTouchEvent)
    /// A mouse event: hover, or a button press or release.
    case mouse(WireMouseEvent)
    /// A scroll event.
    case scroll(WireScrollEvent)
    /// A key event.
    case key(WireKeyEvent)
    /// A long press at a position.
    case longPress(DisplayPoint, InputTimestamp)
    /// Cancels the open gestures and releases the pressed buttons and keys.
    case cancelAll(InputTimestamp)
}

/// A touch event on the wire.
public struct WireTouchEvent: Codable, Sendable, Equatable {
    /// The phase of the gesture.
    public var phase: TouchPhase
    /// The pointer identifier. 0 in v1.
    public var pointerID: Int
    /// The position in display pixels.
    public var position: DisplayPoint
    /// The time of the event.
    public var time: InputTimestamp

    /// Creates a touch event.
    public init(phase: TouchPhase, pointerID: Int, position: DisplayPoint, time: InputTimestamp) {
        self.phase = phase
        self.pointerID = pointerID
        self.position = position
        self.time = time
    }
}

/// A mouse event on the wire.
public struct WireMouseEvent: Codable, Sendable, Equatable {
    /// What the mouse did.
    public var action: MouseAction
    /// The position in display pixels.
    public var position: DisplayPoint
    /// The `MotionEvent.BUTTON_*` bits of the buttons that are down after the event.
    public var buttons: Int32
    /// The time of the event.
    public var time: InputTimestamp

    /// Creates a mouse event.
    public init(action: MouseAction, position: DisplayPoint, buttons: Int32, time: InputTimestamp) {
        self.action = action
        self.position = position
        self.buttons = buttons
        self.time = time
    }
}

/// A scroll event on the wire.
public struct WireScrollEvent: Codable, Sendable, Equatable {
    /// The position of the pointer in display pixels.
    public var position: DisplayPoint
    /// The `AXIS_VSCROLL` value.
    public var vertical: Double
    /// The `AXIS_HSCROLL` value.
    public var horizontal: Double
    /// The time of the event.
    public var time: InputTimestamp

    /// Creates a scroll event.
    public init(position: DisplayPoint, vertical: Double, horizontal: Double, time: InputTimestamp) {
        self.position = position
        self.vertical = vertical
        self.horizontal = horizontal
        self.time = time
    }
}

/// A key event on the wire.
public struct WireKeyEvent: Codable, Sendable, Equatable {
    /// The key goes down or up.
    public var action: KeyAction
    /// The `KEYCODE_*` value.
    public var androidKeyCode: Int32
    /// The `META_*` modifier bits held with the key.
    public var metaState: Int32
    /// The repeat count of a held key.
    public var repeatCount: Int32
    /// The time of the event.
    public var time: InputTimestamp

    /// Creates a key event.
    public init(action: KeyAction, androidKeyCode: Int32, metaState: Int32, repeatCount: Int32, time: InputTimestamp) {
        self.action = action
        self.androidKeyCode = androidKeyCode
        self.metaState = metaState
        self.repeatCount = repeatCount
        self.time = time
    }
}

/// A text or editor event of the IME path, on the wire (input.md §5; sent by `sendText`).
public enum WireImeTextEvent: Codable, Sendable, Equatable {
    /// Commits text.
    case commit(String)
    /// Sets the composing text and its selection.
    case setComposing(String, selection: TextRange)
    /// Ends the composition.
    case finishComposing
    /// A key in editor mode.
    case key(WireKeyEvent)
    /// An `EditorInfo.IME_ACTION_*` value.
    case editorAction(Int32)
    /// A context menu command.
    case contextMenuAction(ContextMenuAction)
}

/// The phase of a touch event. The raw values are the case names (runtime-api.md §4.2).
public enum TouchPhase: String, Codable, Sendable, Equatable {
    /// The finger goes down.
    case down
    /// The finger moves.
    case move
    /// The finger goes up.
    case up
    /// The gesture is cancelled.
    case cancel
}

/// A mouse button. The raw values are the case names (runtime-api.md §4.2).
public enum MouseButton: String, Codable, Sendable, Equatable {
    /// The primary button.
    case primary
    /// The secondary button: the right button and Control-click.
    case secondary
    /// The tertiary button.
    case tertiary
    /// The back button.
    case back
    /// The forward button.
    case forward
}

/// What a mouse event did.
public enum MouseAction: Codable, Sendable, Equatable {
    /// The pointer enters the display.
    case hoverEnter
    /// The pointer moves without a button.
    case hoverMove
    /// The pointer leaves the display.
    case hoverExit
    /// A button goes down.
    case press(MouseButton)
    /// A button goes up.
    case release(MouseButton)
}

/// The direction of a key event. The raw values are the case names (runtime-api.md §4.2).
public enum KeyAction: String, Codable, Sendable, Equatable {
    /// The key goes down.
    case down
    /// The key goes up.
    case up
}

/// A context menu command of the editor. The raw values are the case names (runtime-api.md §4.2).
public enum ContextMenuAction: String, Codable, Sendable, Equatable {
    /// Copies the selection.
    case copy
    /// Cuts the selection.
    case cut
    /// Pastes the clipboard.
    case paste
    /// Selects all text.
    case selectAll
}
