/// A host timestamp: the mach continuous time of the `NSEvent`, in nanoseconds (input.md §2).
public struct InputTimestamp: Sendable, Equatable, Comparable {
    /// Nanoseconds of mach continuous time.
    public var hostNanos: UInt64

    /// Creates a timestamp from nanoseconds of mach continuous time.
    public init(hostNanos: UInt64) {
        self.hostNanos = hostNanos
    }

    /// Orders timestamps by their nanoseconds.
    public static func < (lhs: InputTimestamp, rhs: InputTimestamp) -> Bool {
        lhs.hostNanos < rhs.hostNanos
    }
}

/// A point in display pixels of the session's display, with the origin at the top-left (Android's y-down convention).
public struct DisplayPoint: Sendable, Equatable {
    /// Horizontal position in pixels.
    public var x: Double
    /// Vertical position in pixels, growing downwards.
    public var y: Double

    /// Creates a point in display pixels.
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A mouse button, as Android's `MotionEvent` names it (input.md §4.1).
public enum MouseButton: Sendable, Equatable {
    /// The primary button, `BUTTON_PRIMARY`.
    case primary
    /// The secondary button, `BUTTON_SECONDARY`: the right button and Control-click.
    case secondary
    /// The tertiary button, `BUTTON_TERTIARY`.
    case tertiary
    /// The back button, `BUTTON_BACK`.
    case back
    /// The forward button, `BUTTON_FORWARD`.
    case forward

    /// The `MotionEvent.BUTTON_*` bit of this button.
    public var androidButtonBit: Int32 {
        switch self {
        case .primary: 1
        case .secondary: 2
        case .tertiary: 4
        case .back: 8
        case .forward: 16
        }
    }
}

/// The mouse buttons that are down, with the `MotionEvent.BUTTON_*` bits.
public struct MouseButtons: OptionSet, Sendable {
    /// The `BUTTON_*` bits.
    public let rawValue: Int32

    /// Creates the set from `BUTTON_*` bits.
    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    /// Creates the set that holds one button.
    public init(_ button: MouseButton) {
        self.rawValue = button.androidButtonBit
    }

    /// `BUTTON_PRIMARY`.
    public static let primary = MouseButtons(rawValue: 1)
    /// `BUTTON_SECONDARY`.
    public static let secondary = MouseButtons(rawValue: 2)
    /// `BUTTON_TERTIARY`.
    public static let tertiary = MouseButtons(rawValue: 4)
    /// `BUTTON_BACK`.
    public static let back = MouseButtons(rawValue: 8)
    /// `BUTTON_FORWARD`.
    public static let forward = MouseButtons(rawValue: 16)
}

/// The `KeyEvent.META_*` modifier bits of Android (used by key events, #26).
public struct AndroidMetaState: OptionSet, Sendable {
    /// The `META_*` bits.
    public let rawValue: Int32

    /// Creates the set from `META_*` bits.
    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    /// `META_SHIFT_ON`.
    public static let shiftOn = AndroidMetaState(rawValue: 0x1)
    /// `META_ALT_ON`.
    public static let altOn = AndroidMetaState(rawValue: 0x2)
    /// `META_SYM_ON`.
    public static let symOn = AndroidMetaState(rawValue: 0x4)
    /// `META_FUNCTION_ON`.
    public static let functionOn = AndroidMetaState(rawValue: 0x8)
    /// `META_ALT_LEFT_ON`.
    public static let altLeftOn = AndroidMetaState(rawValue: 0x10)
    /// `META_ALT_RIGHT_ON`.
    public static let altRightOn = AndroidMetaState(rawValue: 0x20)
    /// `META_SHIFT_LEFT_ON`.
    public static let shiftLeftOn = AndroidMetaState(rawValue: 0x40)
    /// `META_SHIFT_RIGHT_ON`.
    public static let shiftRightOn = AndroidMetaState(rawValue: 0x80)
    /// `META_CTRL_ON`.
    public static let ctrlOn = AndroidMetaState(rawValue: 0x1000)
    /// `META_CTRL_LEFT_ON`.
    public static let ctrlLeftOn = AndroidMetaState(rawValue: 0x2000)
    /// `META_CTRL_RIGHT_ON`.
    public static let ctrlRightOn = AndroidMetaState(rawValue: 0x4000)
    /// `META_META_ON`.
    public static let metaOn = AndroidMetaState(rawValue: 0x10000)
    /// `META_META_LEFT_ON`.
    public static let metaLeftOn = AndroidMetaState(rawValue: 0x20000)
    /// `META_META_RIGHT_ON`.
    public static let metaRightOn = AndroidMetaState(rawValue: 0x40000)
    /// `META_CAPS_LOCK_ON`.
    public static let capsLockOn = AndroidMetaState(rawValue: 0x100000)
    /// `META_NUM_LOCK_ON`.
    public static let numLockOn = AndroidMetaState(rawValue: 0x200000)
    /// `META_SCROLL_LOCK_ON`.
    public static let scrollLockOn = AndroidMetaState(rawValue: 0x400000)
}

/// A touch event of the left button, injected as `SOURCE_TOUCHSCREEN` (input.md §4.1).
public struct TouchEvent: Sendable, Equatable {
    /// The phase of the touch gesture.
    public enum Phase: Sendable, Equatable {
        /// The finger goes down, `ACTION_DOWN`.
        case down
        /// The finger moves, `ACTION_MOVE`.
        case move
        /// The finger goes up, `ACTION_UP`.
        case up
        /// The gesture is cancelled, `ACTION_CANCEL`.
        case cancel
    }

    /// The phase of the gesture.
    public var phase: Phase
    /// The pointer identifier. Always 0 in v1, a single pointer.
    public var pointerID: Int
    /// The position in display pixels.
    public var position: DisplayPoint
    /// The time of the event.
    public var time: InputTimestamp

    /// Creates a touch event.
    public init(phase: Phase, pointerID: Int, position: DisplayPoint, time: InputTimestamp) {
        self.phase = phase
        self.pointerID = pointerID
        self.position = position
        self.time = time
    }
}

/// A mouse event, injected as `SOURCE_MOUSE` (input.md §4.1).
public struct MouseEvent: Sendable, Equatable {
    /// What the mouse did.
    public enum Action: Sendable, Equatable {
        /// The pointer enters the display, `ACTION_HOVER_ENTER`.
        case hoverEnter
        /// The pointer moves without a button, `ACTION_HOVER_MOVE`.
        case hoverMove
        /// The pointer leaves the display, `ACTION_HOVER_EXIT`.
        case hoverExit
        /// A button goes down, `ACTION_BUTTON_PRESS`.
        case press(MouseButton)
        /// A button goes up, `ACTION_BUTTON_RELEASE`.
        case release(MouseButton)
    }

    /// What the mouse did.
    public var action: Action
    /// The position in display pixels.
    public var position: DisplayPoint
    /// The buttons that are down after the event.
    public var buttons: MouseButtons
    /// The time of the event.
    public var time: InputTimestamp

    /// Creates a mouse event.
    public init(action: Action, position: DisplayPoint, buttons: MouseButtons, time: InputTimestamp) {
        self.action = action
        self.position = position
        self.buttons = buttons
        self.time = time
    }
}

/// A scroll event, injected as `ACTION_SCROLL` with the `AXIS_VSCROLL` and `AXIS_HSCROLL` values (input.md §4.4).
public struct ScrollEvent: Sendable, Equatable {
    /// The position of the pointer in display pixels.
    public var position: DisplayPoint
    /// The `AXIS_VSCROLL` value, computed from the deltas as input.md §4.4 specifies.
    public var vertical: Double
    /// The `AXIS_HSCROLL` value, computed from the deltas as input.md §4.4 specifies.
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

/// A key event, injected as a key in key mode (#26, `KeyTranslator`).
public struct KeyEvent: Sendable, Equatable {
    /// The key goes down or up.
    public enum Action: Sendable, Equatable {
        /// The key goes down, `ACTION_DOWN`.
        case down
        /// The key goes up, `ACTION_UP`.
        case up
    }

    /// The key goes down or up.
    public var action: Action
    /// The `KEYCODE_*` value.
    public var androidKeyCode: Int32
    /// The modifier bits held with the key.
    public var metaState: AndroidMetaState
    /// The repeat count of a held key.
    public var repeatCount: Int32
    /// The time of the event.
    public var time: InputTimestamp

    /// Creates a key event.
    public init(
        action: Action, androidKeyCode: Int32, metaState: AndroidMetaState, repeatCount: Int32, time: InputTimestamp
    ) {
        self.action = action
        self.androidKeyCode = androidKeyCode
        self.metaState = metaState
        self.repeatCount = repeatCount
        self.time = time
    }
}

/// An event the translator produces for the guest (input.md §2).
public enum InputEvent: Sendable, Equatable {
    /// A touch event of the left button.
    case touch(TouchEvent)
    /// A mouse event: hover, or a button press or release.
    case mouse(MouseEvent)
    /// A scroll event.
    case scroll(ScrollEvent)
    /// A key event of key mode (#26).
    case key(KeyEvent)
    /// A long press at a position. Not produced in #25 (D6).
    case longPress(DisplayPoint, InputTimestamp)
    /// Cancels the open gestures, releases the pressed buttons, and ends the hover, on the guest.
    case cancelAll(InputTimestamp)
}
