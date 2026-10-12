/// Translates key samples into the key events of the guest in key mode (input.md §5.1, §5.2, §6; #025).
///
/// Key mode is the only path before the IME (#071). The translator keeps the keys that are down, so that every release is
/// sent with the Android key code of its press, even when the mapping of the release would differ (for example, when
/// Command is released before the C of ⌘C). A key that is not forwarded has no entry on the guest, and its release is
/// dropped too. The meta state of each event comes from the modifiers of its sample.
///
/// A key that is held sends a `down` with the repeat count, and no `up` comes between the repeats (input.md §5.2).
public struct KeyTranslator: Sendable {
    /// What Escape sends (`input.escapeKey`, input.md §5.2).
    public enum EscapeKey: Sendable, Equatable {
        /// `KEYCODE_BACK`, the default (FR-IN-04).
        case back
        /// `KEYCODE_ESCAPE`.
        case escape
    }

    /// `KEYCODE_BACK`.
    private static let androidBack: Int32 = 4
    /// `KEYCODE_ESCAPE`.
    private static let androidEscape: Int32 = 111
    /// The Ctrl bits that a ⌘ shortcut adds: the Ctrl combination is the left Control key (input.md §6).
    private static let shortcutMeta: AndroidMetaState = [.ctrlOn, .ctrlLeftOn]
    /// The keys whose ⌘ combination is a Ctrl combination (input.md §6).
    private static let commandShortcutKeys: Set<UInt16> = [
        MacVirtualKey.a, MacVirtualKey.c, MacVirtualKey.v, MacVirtualKey.x, MacVirtualKey.z,
    ]
    /// The modifiers that make ⌘[ something else than BACK.
    private static let otherModifiers: KeyModifiers = [
        .shiftLeft, .shiftRight, .controlLeft, .controlRight, .optionLeft, .optionRight,
    ]

    /// A key that is down, as the guest has it. `androidKeyCode` is nil for a key that is not forwarded.
    private struct PressedKey: Sendable, Equatable {
        var androidKeyCode: Int32?
        /// The meta bits that the mapping of the press adds, such as Control for ⌘C.
        var extraMeta: AndroidMetaState
        var repeatCount: Int32
    }

    private let escapeKey: EscapeKey
    private var pressed: [UInt16: PressedKey] = [:]

    /// Creates a translator. Escape sends `escapeKey`.
    public init(escapeKey: EscapeKey = .back) {
        self.escapeKey = escapeKey
    }

    /// Whether `sample` is a ⌘ shortcut that key mode forwards: ⌘C, ⌘X, ⌘V, ⌘A, ⌘Z, and ⌘[ with no other modifier. The
    /// window checks it before the menus, so that the menus do not take these shortcuts (input.md §6).
    public static func forwardsCommandShortcut(_ sample: KeySample) -> Bool {
        guard sample.kind == .down, sample.modifiers.contains(.command) else {
            return false
        }
        if sample.virtualKeyCode == MacVirtualKey.leftBracket {
            return sample.modifiers.isDisjoint(with: otherModifiers)
        }
        return commandShortcutKeys.contains(sample.virtualKeyCode)
    }

    /// Translates one key sample, in order.
    public mutating func translate(_ sample: KeySample) -> [InputEvent] {
        switch sample.kind {
        case .down:
            return keyDown(sample)
        case .up:
            return keyUp(sample)
        case .modifierChanged(let isDown):
            return modifierChanged(sample, isDown: isDown)
        }
    }

    /// Forgets the keys that are down. The window calls it when it loses focus, and it sends `.cancelAll` too, which
    /// ends the keys on the guest (input.md §7.3).
    public mutating func reset() {
        pressed.removeAll()
    }

    private mutating func keyDown(_ sample: KeySample) -> [InputEvent] {
        let code = sample.virtualKeyCode
        if var held = pressed[code] {
            // A held key is a repeat, whether or not the window marks it: the DOWN carries the count, and no UP is sent.
            held.repeatCount += 1
            pressed[code] = held
            guard let androidKeyCode = held.androidKeyCode else {
                return []
            }
            let state = Self.metaState(sample.modifiers, extra: held.extraMeta)
            return [key(.down, androidKeyCode, state, held.repeatCount, sample.time)]
        }
        let mapping = mapping(for: sample)
        pressed[code] = PressedKey(androidKeyCode: mapping.androidKeyCode, extraMeta: mapping.extraMeta, repeatCount: 0)
        guard let androidKeyCode = mapping.androidKeyCode else {
            return []
        }
        let state = Self.metaState(sample.modifiers, extra: mapping.extraMeta)
        return [key(.down, androidKeyCode, state, 0, sample.time)]
    }

    private mutating func keyUp(_ sample: KeySample) -> [InputEvent] {
        // A release without a press is not sent: the guest never had the key down.
        guard let held = pressed.removeValue(forKey: sample.virtualKeyCode), let androidKeyCode = held.androidKeyCode
        else {
            return []
        }
        let state = Self.metaState(sample.modifiers, extra: held.extraMeta)
        return [key(.up, androidKeyCode, state, 0, sample.time)]
    }

    private mutating func modifierChanged(_ sample: KeySample, isDown: Bool) -> [InputEvent] {
        let code = sample.virtualKeyCode
        let androidKeyCode = KeyCodeMap.androidKeyCode(forVirtualKeyCode: code)
        if code == MacVirtualKey.capsLock {
            // Caps Lock is a toggle, so each change is a tap. The state after the change is in the meta state.
            guard let androidKeyCode else {
                return []
            }
            let state = Self.metaState(sample.modifiers, extra: [])
            return [key(.down, androidKeyCode, state, 0, sample.time), key(.up, androidKeyCode, state, 0, sample.time)]
        }
        guard isDown else {
            return keyUp(sample)
        }
        // A change that repeats the state already held is not a new press.
        guard pressed[code] == nil else {
            return []
        }
        pressed[code] = PressedKey(androidKeyCode: androidKeyCode, extraMeta: [], repeatCount: 0)
        guard let androidKeyCode else {
            return []
        }
        let state = Self.metaState(sample.modifiers, extra: [])
        return [key(.down, androidKeyCode, state, 0, sample.time)]
    }

    /// The Android key code of a key that goes down, and the meta bits that its mapping adds (input.md §5.2, §6). A nil
    /// code is a key that is not forwarded.
    private func mapping(for sample: KeySample) -> (androidKeyCode: Int32?, extraMeta: AndroidMetaState) {
        let code = sample.virtualKeyCode
        guard sample.modifiers.contains(.command) else {
            if code == MacVirtualKey.escape {
                return (escapeKey == .back ? Self.androidBack : Self.androidEscape, [])
            }
            return (KeyCodeMap.androidKeyCode(forVirtualKeyCode: code), [])
        }
        if code == MacVirtualKey.leftBracket, sample.modifiers.isDisjoint(with: Self.otherModifiers) {
            return (Self.androidBack, [])
        }
        if Self.commandShortcutKeys.contains(code),
            let androidKeyCode = KeyCodeMap.androidKeyCode(forVirtualKeyCode: code)
        {
            return (androidKeyCode, Self.shortcutMeta)
        }
        // The other Command combinations are not forwarded (input.md §6).
        return (nil, [])
    }

    /// The meta state of the modifiers and the extra bits of a mapping (`KeyEvent.META_*`, input.md §5.2). Command adds
    /// no bit, because it is not forwarded.
    static func metaState(_ modifiers: KeyModifiers, extra: AndroidMetaState) -> AndroidMetaState {
        var state = extra
        if modifiers.contains(.shiftLeft) {
            state.formUnion([.shiftOn, .shiftLeftOn])
        }
        if modifiers.contains(.shiftRight) {
            state.formUnion([.shiftOn, .shiftRightOn])
        }
        if modifiers.contains(.controlLeft) {
            state.formUnion([.ctrlOn, .ctrlLeftOn])
        }
        if modifiers.contains(.controlRight) {
            state.formUnion([.ctrlOn, .ctrlRightOn])
        }
        if modifiers.contains(.optionLeft) {
            state.formUnion([.altOn, .altLeftOn])
        }
        if modifiers.contains(.optionRight) {
            state.formUnion([.altOn, .altRightOn])
        }
        if modifiers.contains(.capsLock) {
            state.insert(.capsLockOn)
        }
        return state
    }

    private func key(
        _ action: KeyEvent.Action, _ androidKeyCode: Int32, _ state: AndroidMetaState, _ repeatCount: Int32,
        _ time: InputTimestamp
    ) -> InputEvent {
        .key(
            KeyEvent(
                action: action, androidKeyCode: androidKeyCode, metaState: state, repeatCount: repeatCount, time: time))
    }
}
