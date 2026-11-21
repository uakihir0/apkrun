import Foundation

/// The editor context an `ImeState` report carries, reduced to what the command map needs
/// (input.md §5.4, §5.5).
public struct EditorContext: Sendable, Equatable {
    /// Whether the Android editor holds a composition.
    public var hasMarkedText: Bool
    /// `EditorInfo.inputType`.
    public var inputType: Int32
    /// `EditorInfo.imeOptions`.
    public var imeOptions: Int32

    /// Creates a context.
    public init(hasMarkedText: Bool, inputType: Int32, imeOptions: Int32) {
        self.hasMarkedText = hasMarkedText
        self.inputType = inputType
        self.imeOptions = imeOptions
    }
}

/// What a `doCommand(by:)` selector becomes (input.md §5.4).
public enum EditorCommand: Sendable, Equatable {
    /// An `InputConnection.sendKeyEvent` key event, as `.key(...)` on the IME channel.
    case key(androidKeyCode: Int32, metaState: AndroidMetaState)
    /// An `InputConnection.performEditorAction` call with an `IME_ACTION_*` value.
    case editorAction(Int32)
    /// Nothing is sent. The caller counts it as `input.ime.unmappedCommand` and logs the selector
    /// at debug level (input.md §5.4).
    case unmapped
    /// The selector is consumed on the host: Escape while a composition is active goes to the
    /// macOS IME, not to Android (input.md §5.4).
    case consumed
}

/// The `doCommand(by:)` selector map of input.md §5.4. Selectors come in as Objective-C selector
/// strings (`"deleteBackward:"`).
public enum EditorCommandMap {
    /// The Android action of `insertNewline:`, or nil when the editor does not offer one.
    public static func command(for selector: String, context: EditorContext) -> EditorCommand {
        // The modify-selection variants carry Shift (input.md §5.4).
        switch selector {
        case "deleteBackward:": return .key(androidKeyCode: AndroidKeyCode.del, metaState: [])
        case "deleteForward:": return .key(androidKeyCode: AndroidKeyCode.forwardDel, metaState: [])
        case "deleteWordBackward:":
            return .key(androidKeyCode: AndroidKeyCode.del, metaState: [.ctrlOn])
        case "deleteWordForward:":
            return .key(androidKeyCode: AndroidKeyCode.forwardDel, metaState: [.ctrlOn])
        case "insertNewline:":
            if let action = editorAction(context) {
                return .editorAction(action)
            }
            return .key(androidKeyCode: AndroidKeyCode.enter, metaState: [])
        case "insertLineBreak:", "insertNewlineIgnoringFieldEditor:":
            return .key(androidKeyCode: AndroidKeyCode.enter, metaState: [.shiftOn])
        case "insertTab:": return .key(androidKeyCode: AndroidKeyCode.tab, metaState: [])
        case "insertBacktab:":
            return .key(androidKeyCode: AndroidKeyCode.tab, metaState: [.shiftOn])
        case "moveLeft:": return .key(androidKeyCode: AndroidKeyCode.dpadLeft, metaState: [])
        case "moveRight:": return .key(androidKeyCode: AndroidKeyCode.dpadRight, metaState: [])
        case "moveUp:": return .key(androidKeyCode: AndroidKeyCode.dpadUp, metaState: [])
        case "moveDown:": return .key(androidKeyCode: AndroidKeyCode.dpadDown, metaState: [])
        case "moveLeftAndModifySelection:":
            return .key(androidKeyCode: AndroidKeyCode.dpadLeft, metaState: [.shiftOn])
        case "moveRightAndModifySelection:":
            return .key(androidKeyCode: AndroidKeyCode.dpadRight, metaState: [.shiftOn])
        case "moveUpAndModifySelection:":
            return .key(androidKeyCode: AndroidKeyCode.dpadUp, metaState: [.shiftOn])
        case "moveDownAndModifySelection:":
            return .key(androidKeyCode: AndroidKeyCode.dpadDown, metaState: [.shiftOn])
        case "moveWordLeft:": return .key(androidKeyCode: AndroidKeyCode.dpadLeft, metaState: [.ctrlOn])
        case "moveWordRight:": return .key(androidKeyCode: AndroidKeyCode.dpadRight, metaState: [.ctrlOn])
        case "moveWordLeftAndModifySelection:":
            return .key(androidKeyCode: AndroidKeyCode.dpadLeft, metaState: [.ctrlOn, .shiftOn])
        case "moveWordRightAndModifySelection:":
            return .key(androidKeyCode: AndroidKeyCode.dpadRight, metaState: [.ctrlOn, .shiftOn])
        case "moveToBeginningOfLine:", "moveToLeftEndOfLine:":
            return .key(androidKeyCode: AndroidKeyCode.moveHome, metaState: [])
        case "moveToEndOfLine:", "moveToRightEndOfLine:":
            return .key(androidKeyCode: AndroidKeyCode.moveEnd, metaState: [])
        case "moveToBeginningOfLineAndModifySelection:", "moveToLeftEndOfLineAndModifySelection:":
            return .key(androidKeyCode: AndroidKeyCode.moveHome, metaState: [.shiftOn])
        case "moveToEndOfLineAndModifySelection:", "moveToRightEndOfLineAndModifySelection:":
            return .key(androidKeyCode: AndroidKeyCode.moveEnd, metaState: [.shiftOn])
        case "moveToBeginningOfDocument:":
            return .key(androidKeyCode: AndroidKeyCode.moveHome, metaState: [.ctrlOn])
        case "moveToEndOfDocument:":
            return .key(androidKeyCode: AndroidKeyCode.moveEnd, metaState: [.ctrlOn])
        case "moveToBeginningOfDocumentAndModifySelection:":
            return .key(androidKeyCode: AndroidKeyCode.moveHome, metaState: [.ctrlOn, .shiftOn])
        case "moveToEndOfDocumentAndModifySelection:":
            return .key(androidKeyCode: AndroidKeyCode.moveEnd, metaState: [.ctrlOn, .shiftOn])
        case "pageUp:", "scrollPageUp:":
            return .key(androidKeyCode: AndroidKeyCode.pageUp, metaState: [])
        case "pageDown:", "scrollPageDown:":
            return .key(androidKeyCode: AndroidKeyCode.pageDown, metaState: [])
        case "cancelOperation:":
            // With marked text the macOS IME consumes Escape (input.md §5.4).
            return context.hasMarkedText
                ? .consumed
                : .key(androidKeyCode: AndroidKeyCode.back, metaState: [])
        default:
            return .unmapped
        }
    }

    /// The `IME_ACTION_*` of the editor, when `insertNewline:` should send it: the action is not
    /// NONE or UNSPECIFIED, the field is not multi-line, and `IME_FLAG_NO_ENTER_ACTION` is clear
    /// (input.md §5.4).
    private static func editorAction(_ context: EditorContext) -> Int32? {
        let action = context.imeOptions & imeMaskAction
        guard action != imeActionNone, action != imeActionUnspecified else {
            return nil
        }
        guard context.inputType & typeTextFlagMultiLine == 0,
            context.imeOptions & imeFlagNoEnterAction == 0
        else {
            return nil
        }
        return action
    }

    /// `EditorInfo.IME_MASK_ACTION`.
    private static let imeMaskAction: Int32 = 0xFF
    /// `EditorInfo.IME_ACTION_UNSPECIFIED`.
    private static let imeActionUnspecified: Int32 = 0
    /// `EditorInfo.IME_ACTION_NONE`.
    private static let imeActionNone: Int32 = 1
    /// `EditorInfo.IME_FLAG_NO_ENTER_ACTION`.
    private static let imeFlagNoEnterAction: Int32 = 0x4000_0000
    /// `InputType.TYPE_TEXT_FLAG_MULTI_LINE`.
    private static let typeTextFlagMultiLine: Int32 = 0x0002_0000
}

/// The key codes the editor commands send (input.md §5.4, input.md §5.2 names them).
public enum AndroidKeyCode {
    /// `KEYCODE_BACK`.
    public static let back: Int32 = 4
    /// `KEYCODE_DPAD_UP`.
    public static let dpadUp: Int32 = 19
    /// `KEYCODE_DPAD_DOWN`.
    public static let dpadDown: Int32 = 20
    /// `KEYCODE_DPAD_LEFT`.
    public static let dpadLeft: Int32 = 21
    /// `KEYCODE_DPAD_RIGHT`.
    public static let dpadRight: Int32 = 22
    /// `KEYCODE_TAB`.
    public static let tab: Int32 = 61
    /// `KEYCODE_ENTER`.
    public static let enter: Int32 = 66
    /// `KEYCODE_DEL`.
    public static let del: Int32 = 67
    /// `KEYCODE_PAGE_UP`.
    public static let pageUp: Int32 = 92
    /// `KEYCODE_PAGE_DOWN`.
    public static let pageDown: Int32 = 93
    /// `KEYCODE_FORWARD_DEL`.
    public static let forwardDel: Int32 = 112
    /// `KEYCODE_MOVE_HOME`.
    public static let moveHome: Int32 = 122
    /// `KEYCODE_MOVE_END`.
    public static let moveEnd: Int32 = 123
}

/// Whether the editor is a password variation and the secure input path applies (input.md §5.5).
public enum SecureFieldPolicy {
    /// True for `TYPE_TEXT_VARIATION_PASSWORD`, `TYPE_TEXT_VARIATION_VISIBLE_PASSWORD`,
    /// `TYPE_TEXT_VARIATION_WEB_PASSWORD`, and `TYPE_NUMBER_VARIATION_PASSWORD`.
    public static func isSecure(inputType: Int32) -> Bool {
        let typeClass = inputType & typeClassMask
        let variation = inputType & typeVariationMask
        switch typeClass {
        case typeClassText:
            return variation == textVariationPassword
                || variation == textVariationVisiblePassword
                || variation == textVariationWebPassword
        case typeClassNumber:
            return variation == numberVariationPassword
        default:
            return false
        }
    }

    /// `InputType.TYPE_MASK_CLASS`.
    private static let typeClassMask: Int32 = 0xF
    /// `InputType.TYPE_MASK_VARIATION`.
    private static let typeVariationMask: Int32 = 0xFF0
    /// `InputType.TYPE_CLASS_TEXT`.
    private static let typeClassText: Int32 = 0x1
    /// `InputType.TYPE_CLASS_NUMBER`.
    private static let typeClassNumber: Int32 = 0x2
    /// `InputType.TYPE_TEXT_VARIATION_PASSWORD`.
    private static let textVariationPassword: Int32 = 0x80
    /// `InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD`.
    private static let textVariationVisiblePassword: Int32 = 0x90
    /// `InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD`.
    private static let textVariationWebPassword: Int32 = 0xE0
    /// `InputType.TYPE_NUMBER_VARIATION_PASSWORD`.
    private static let numberVariationPassword: Int32 = 0x10
}
