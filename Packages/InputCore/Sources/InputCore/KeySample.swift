/// The macOS virtual key codes (`kVK_*`) that key mode and the window adapter name (input.md §5.2, §6).
public enum MacVirtualKey {
    /// `kVK_ANSI_A`.
    public static let a: UInt16 = 0x00
    /// `kVK_ANSI_Z`.
    public static let z: UInt16 = 0x06
    /// `kVK_ANSI_X`.
    public static let x: UInt16 = 0x07
    /// `kVK_ANSI_C`.
    public static let c: UInt16 = 0x08
    /// `kVK_ANSI_V`.
    public static let v: UInt16 = 0x09
    /// `kVK_ANSI_LeftBracket`, the key of ⌘[ (BACK).
    public static let leftBracket: UInt16 = 0x21
    /// `kVK_Escape`.
    public static let escape: UInt16 = 0x35
    /// `kVK_RightCommand`.
    public static let rightCommand: UInt16 = 0x36
    /// `kVK_Command`.
    public static let command: UInt16 = 0x37
    /// `kVK_Shift`.
    public static let shift: UInt16 = 0x38
    /// `kVK_CapsLock`.
    public static let capsLock: UInt16 = 0x39
    /// `kVK_Option`.
    public static let option: UInt16 = 0x3A
    /// `kVK_Control`.
    public static let control: UInt16 = 0x3B
    /// `kVK_RightShift`.
    public static let rightShift: UInt16 = 0x3C
    /// `kVK_RightOption`.
    public static let rightOption: UInt16 = 0x3D
    /// `kVK_RightControl`.
    public static let rightControl: UInt16 = 0x3E
}

/// The modifier keys that are down when a key event happens, as plain values (decision D1: `WindowingCore` reads them
/// from the device-dependent bits of `NSEvent.modifierFlags`). Shift, Control, and Option have one bit per side, so the
/// meta state can name the side (input.md §5.2). Command is one bit, because Command is not forwarded.
public struct KeyModifiers: OptionSet, Sendable, Equatable {
    /// The bits of the set.
    public let rawValue: UInt16

    /// Creates the set from its bits.
    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// The left Shift key is down.
    public static let shiftLeft = KeyModifiers(rawValue: 1 << 0)
    /// The right Shift key is down.
    public static let shiftRight = KeyModifiers(rawValue: 1 << 1)
    /// The left Control key is down.
    public static let controlLeft = KeyModifiers(rawValue: 1 << 2)
    /// The right Control key is down.
    public static let controlRight = KeyModifiers(rawValue: 1 << 3)
    /// The left Option key is down.
    public static let optionLeft = KeyModifiers(rawValue: 1 << 4)
    /// The right Option key is down.
    public static let optionRight = KeyModifiers(rawValue: 1 << 5)
    /// A Command key is down.
    public static let command = KeyModifiers(rawValue: 1 << 6)
    /// Caps Lock is on (the lock state, not the key).
    public static let capsLock = KeyModifiers(rawValue: 1 << 7)
}

/// A key event from the window, in plain values (decision D1). The key is a macOS virtual key code, and `modifiers` is
/// the state after the event, so the translator needs no history to compute the meta state.
public struct KeySample: Sendable, Equatable {
    /// The kind of key event.
    public enum Kind: Sendable, Equatable {
        /// A key goes down (`keyDown`). A repeat has `isRepeat` set.
        case down
        /// A key goes up (`keyUp`).
        case up
        /// A modifier key changes (`flagsChanged`). `pressed` is its state after the change. Caps Lock sends one change
        /// per toggle.
        case modifierChanged(pressed: Bool)
    }

    /// The kind of event.
    public var kind: Kind
    /// The macOS virtual key code (`kVK_*`).
    public var virtualKeyCode: UInt16
    /// The modifier keys that are down after the event.
    public var modifiers: KeyModifiers
    /// Whether a `down` is an automatic repeat of a held key (`isARepeat`).
    public var isRepeat: Bool
    /// The event time.
    public var time: InputTimestamp

    /// Creates a key sample. The modifiers default to none, and `isRepeat` to false.
    public init(
        kind: Kind, virtualKeyCode: UInt16, modifiers: KeyModifiers = [], isRepeat: Bool = false, time: InputTimestamp
    ) {
        self.kind = kind
        self.virtualKeyCode = virtualKeyCode
        self.modifiers = modifiers
        self.isRepeat = isRepeat
        self.time = time
    }
}
