/// The US key map from macOS virtual key codes to Android key codes (input.md §5.2, #025).
///
/// The rows are the rows of `Packages/InputCore/Resources/keymap-mac-android.csv`. A T0 test reads the CSV and checks that
/// this table has the same rows, and that every Android name and value is in the API 37 list. The table is a literal so
/// that the module needs no resource bundle.
public struct KeyCodeMapEntry: Sendable, Equatable {
    /// The macOS virtual key code (`kVK_*`), which is the position of the key on an ANSI keyboard.
    public var virtualKeyCode: UInt16
    /// The `kVK_*` name of the key.
    public var macName: String
    /// The `KeyEvent.KEYCODE_*` value.
    public var androidKeyCode: Int32
    /// The `KEYCODE_*` name.
    public var androidName: String

    /// Creates an entry.
    public init(_ virtualKeyCode: UInt16, _ macName: String, _ androidKeyCode: Int32, _ androidName: String) {
        self.virtualKeyCode = virtualKeyCode
        self.macName = macName
        self.androidKeyCode = androidKeyCode
        self.androidName = androidName
    }
}

/// The key map of key mode (input.md §5.2). The keys that are not in the map are not forwarded.
public enum KeyCodeMap {
    /// Every row of the map, in the order of the CSV.
    public static let entries: [KeyCodeMapEntry] = [
        KeyCodeMapEntry(0x00, "kVK_ANSI_A", 29, "KEYCODE_A"),
        KeyCodeMapEntry(0x01, "kVK_ANSI_S", 47, "KEYCODE_S"),
        KeyCodeMapEntry(0x02, "kVK_ANSI_D", 32, "KEYCODE_D"),
        KeyCodeMapEntry(0x03, "kVK_ANSI_F", 34, "KEYCODE_F"),
        KeyCodeMapEntry(0x04, "kVK_ANSI_H", 36, "KEYCODE_H"),
        KeyCodeMapEntry(0x05, "kVK_ANSI_G", 35, "KEYCODE_G"),
        KeyCodeMapEntry(0x06, "kVK_ANSI_Z", 54, "KEYCODE_Z"),
        KeyCodeMapEntry(0x07, "kVK_ANSI_X", 52, "KEYCODE_X"),
        KeyCodeMapEntry(0x08, "kVK_ANSI_C", 31, "KEYCODE_C"),
        KeyCodeMapEntry(0x09, "kVK_ANSI_V", 50, "KEYCODE_V"),
        KeyCodeMapEntry(0x0B, "kVK_ANSI_B", 30, "KEYCODE_B"),
        KeyCodeMapEntry(0x0C, "kVK_ANSI_Q", 45, "KEYCODE_Q"),
        KeyCodeMapEntry(0x0D, "kVK_ANSI_W", 51, "KEYCODE_W"),
        KeyCodeMapEntry(0x0E, "kVK_ANSI_E", 33, "KEYCODE_E"),
        KeyCodeMapEntry(0x0F, "kVK_ANSI_R", 46, "KEYCODE_R"),
        KeyCodeMapEntry(0x10, "kVK_ANSI_Y", 53, "KEYCODE_Y"),
        KeyCodeMapEntry(0x11, "kVK_ANSI_T", 48, "KEYCODE_T"),
        KeyCodeMapEntry(0x12, "kVK_ANSI_1", 8, "KEYCODE_1"),
        KeyCodeMapEntry(0x13, "kVK_ANSI_2", 9, "KEYCODE_2"),
        KeyCodeMapEntry(0x14, "kVK_ANSI_3", 10, "KEYCODE_3"),
        KeyCodeMapEntry(0x15, "kVK_ANSI_4", 11, "KEYCODE_4"),
        KeyCodeMapEntry(0x16, "kVK_ANSI_6", 13, "KEYCODE_6"),
        KeyCodeMapEntry(0x17, "kVK_ANSI_5", 12, "KEYCODE_5"),
        KeyCodeMapEntry(0x18, "kVK_ANSI_Equal", 70, "KEYCODE_EQUALS"),
        KeyCodeMapEntry(0x19, "kVK_ANSI_9", 16, "KEYCODE_9"),
        KeyCodeMapEntry(0x1A, "kVK_ANSI_7", 14, "KEYCODE_7"),
        KeyCodeMapEntry(0x1B, "kVK_ANSI_Minus", 69, "KEYCODE_MINUS"),
        KeyCodeMapEntry(0x1C, "kVK_ANSI_8", 15, "KEYCODE_8"),
        KeyCodeMapEntry(0x1D, "kVK_ANSI_0", 7, "KEYCODE_0"),
        KeyCodeMapEntry(0x1E, "kVK_ANSI_RightBracket", 72, "KEYCODE_RIGHT_BRACKET"),
        KeyCodeMapEntry(0x1F, "kVK_ANSI_O", 43, "KEYCODE_O"),
        KeyCodeMapEntry(0x20, "kVK_ANSI_U", 49, "KEYCODE_U"),
        KeyCodeMapEntry(0x21, "kVK_ANSI_LeftBracket", 71, "KEYCODE_LEFT_BRACKET"),
        KeyCodeMapEntry(0x22, "kVK_ANSI_I", 37, "KEYCODE_I"),
        KeyCodeMapEntry(0x23, "kVK_ANSI_P", 44, "KEYCODE_P"),
        KeyCodeMapEntry(0x24, "kVK_Return", 66, "KEYCODE_ENTER"),
        KeyCodeMapEntry(0x25, "kVK_ANSI_L", 40, "KEYCODE_L"),
        KeyCodeMapEntry(0x26, "kVK_ANSI_J", 38, "KEYCODE_J"),
        KeyCodeMapEntry(0x27, "kVK_ANSI_Quote", 75, "KEYCODE_APOSTROPHE"),
        KeyCodeMapEntry(0x28, "kVK_ANSI_K", 39, "KEYCODE_K"),
        KeyCodeMapEntry(0x29, "kVK_ANSI_Semicolon", 74, "KEYCODE_SEMICOLON"),
        KeyCodeMapEntry(0x2A, "kVK_ANSI_Backslash", 73, "KEYCODE_BACKSLASH"),
        KeyCodeMapEntry(0x2B, "kVK_ANSI_Comma", 55, "KEYCODE_COMMA"),
        KeyCodeMapEntry(0x2C, "kVK_ANSI_Slash", 76, "KEYCODE_SLASH"),
        KeyCodeMapEntry(0x2D, "kVK_ANSI_N", 42, "KEYCODE_N"),
        KeyCodeMapEntry(0x2E, "kVK_ANSI_M", 41, "KEYCODE_M"),
        KeyCodeMapEntry(0x2F, "kVK_ANSI_Period", 56, "KEYCODE_PERIOD"),
        KeyCodeMapEntry(0x30, "kVK_Tab", 61, "KEYCODE_TAB"),
        KeyCodeMapEntry(0x31, "kVK_Space", 62, "KEYCODE_SPACE"),
        KeyCodeMapEntry(0x32, "kVK_ANSI_Grave", 68, "KEYCODE_GRAVE"),
        KeyCodeMapEntry(0x33, "kVK_Delete", 67, "KEYCODE_DEL"),
        KeyCodeMapEntry(0x35, "kVK_Escape", 4, "KEYCODE_BACK"),
        KeyCodeMapEntry(0x39, "kVK_CapsLock", 115, "KEYCODE_CAPS_LOCK"),
        KeyCodeMapEntry(0x3A, "kVK_Option", 57, "KEYCODE_ALT_LEFT"),
        KeyCodeMapEntry(0x3B, "kVK_Control", 113, "KEYCODE_CTRL_LEFT"),
        KeyCodeMapEntry(0x38, "kVK_Shift", 59, "KEYCODE_SHIFT_LEFT"),
        KeyCodeMapEntry(0x3C, "kVK_RightShift", 60, "KEYCODE_SHIFT_RIGHT"),
        KeyCodeMapEntry(0x3D, "kVK_RightOption", 58, "KEYCODE_ALT_RIGHT"),
        KeyCodeMapEntry(0x3E, "kVK_RightControl", 114, "KEYCODE_CTRL_RIGHT"),
        KeyCodeMapEntry(0x60, "kVK_F5", 135, "KEYCODE_F5"),
        KeyCodeMapEntry(0x61, "kVK_F6", 136, "KEYCODE_F6"),
        KeyCodeMapEntry(0x62, "kVK_F7", 137, "KEYCODE_F7"),
        KeyCodeMapEntry(0x63, "kVK_F3", 133, "KEYCODE_F3"),
        KeyCodeMapEntry(0x64, "kVK_F8", 138, "KEYCODE_F8"),
        KeyCodeMapEntry(0x65, "kVK_F9", 139, "KEYCODE_F9"),
        KeyCodeMapEntry(0x67, "kVK_F11", 141, "KEYCODE_F11"),
        KeyCodeMapEntry(0x6D, "kVK_F10", 140, "KEYCODE_F10"),
        KeyCodeMapEntry(0x6F, "kVK_F12", 142, "KEYCODE_F12"),
        KeyCodeMapEntry(0x76, "kVK_F4", 134, "KEYCODE_F4"),
        KeyCodeMapEntry(0x78, "kVK_F2", 132, "KEYCODE_F2"),
        KeyCodeMapEntry(0x7A, "kVK_F1", 131, "KEYCODE_F1"),
        KeyCodeMapEntry(0x73, "kVK_Home", 122, "KEYCODE_MOVE_HOME"),
        KeyCodeMapEntry(0x74, "kVK_PageUp", 92, "KEYCODE_PAGE_UP"),
        KeyCodeMapEntry(0x75, "kVK_ForwardDelete", 112, "KEYCODE_FORWARD_DEL"),
        KeyCodeMapEntry(0x77, "kVK_End", 123, "KEYCODE_MOVE_END"),
        KeyCodeMapEntry(0x79, "kVK_PageDown", 93, "KEYCODE_PAGE_DOWN"),
        KeyCodeMapEntry(0x7B, "kVK_LeftArrow", 21, "KEYCODE_DPAD_LEFT"),
        KeyCodeMapEntry(0x7C, "kVK_RightArrow", 22, "KEYCODE_DPAD_RIGHT"),
        KeyCodeMapEntry(0x7D, "kVK_DownArrow", 20, "KEYCODE_DPAD_DOWN"),
        KeyCodeMapEntry(0x7E, "kVK_UpArrow", 19, "KEYCODE_DPAD_UP"),
        KeyCodeMapEntry(0x52, "kVK_ANSI_Keypad0", 144, "KEYCODE_NUMPAD_0"),
        KeyCodeMapEntry(0x53, "kVK_ANSI_Keypad1", 145, "KEYCODE_NUMPAD_1"),
        KeyCodeMapEntry(0x54, "kVK_ANSI_Keypad2", 146, "KEYCODE_NUMPAD_2"),
        KeyCodeMapEntry(0x55, "kVK_ANSI_Keypad3", 147, "KEYCODE_NUMPAD_3"),
        KeyCodeMapEntry(0x56, "kVK_ANSI_Keypad4", 148, "KEYCODE_NUMPAD_4"),
        KeyCodeMapEntry(0x57, "kVK_ANSI_Keypad5", 149, "KEYCODE_NUMPAD_5"),
        KeyCodeMapEntry(0x58, "kVK_ANSI_Keypad6", 150, "KEYCODE_NUMPAD_6"),
        KeyCodeMapEntry(0x59, "kVK_ANSI_Keypad7", 151, "KEYCODE_NUMPAD_7"),
        KeyCodeMapEntry(0x5B, "kVK_ANSI_Keypad8", 152, "KEYCODE_NUMPAD_8"),
        KeyCodeMapEntry(0x5C, "kVK_ANSI_Keypad9", 153, "KEYCODE_NUMPAD_9"),
        KeyCodeMapEntry(0x41, "kVK_ANSI_KeypadDecimal", 158, "KEYCODE_NUMPAD_DOT"),
        KeyCodeMapEntry(0x43, "kVK_ANSI_KeypadMultiply", 155, "KEYCODE_NUMPAD_MULTIPLY"),
        KeyCodeMapEntry(0x45, "kVK_ANSI_KeypadPlus", 157, "KEYCODE_NUMPAD_ADD"),
        KeyCodeMapEntry(0x4B, "kVK_ANSI_KeypadDivide", 154, "KEYCODE_NUMPAD_DIVIDE"),
        KeyCodeMapEntry(0x4C, "kVK_ANSI_KeypadEnter", 160, "KEYCODE_NUMPAD_ENTER"),
        KeyCodeMapEntry(0x4E, "kVK_ANSI_KeypadMinus", 156, "KEYCODE_NUMPAD_SUBTRACT"),
        KeyCodeMapEntry(0x51, "kVK_ANSI_KeypadEquals", 161, "KEYCODE_NUMPAD_EQUALS"),
        KeyCodeMapEntry(0x5F, "kVK_JIS_KeypadComma", 159, "KEYCODE_NUMPAD_COMMA"),
        KeyCodeMapEntry(0x5D, "kVK_JIS_Yen", 216, "KEYCODE_YEN"),
        KeyCodeMapEntry(0x5E, "kVK_JIS_Underscore", 217, "KEYCODE_RO"),
    ]

    /// The Android key code of a macOS virtual key code, or nil when the key is not forwarded in key mode.
    public static func androidKeyCode(forVirtualKeyCode code: UInt16) -> Int32? {
        byVirtualKeyCode[code]?.androidKeyCode
    }

    /// The entry of a macOS virtual key code, or nil when the key is not in the map.
    public static func entry(forVirtualKeyCode code: UInt16) -> KeyCodeMapEntry? {
        byVirtualKeyCode[code]
    }

    /// The entries by virtual key code. The rows are unique (checked by T0), so no row is lost.
    private static let byVirtualKeyCode: [UInt16: KeyCodeMapEntry] = Dictionary(
        uniqueKeysWithValues: entries.map { ($0.virtualKeyCode, $0) })
}
