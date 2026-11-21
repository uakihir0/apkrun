import CoreGraphics
import Foundation

/// A context-menu action of the editor path (input.md §5, matching `ContextMenuAction` on the wire).
public enum ContextMenuAction: Sendable, Equatable {
    /// Copy the selection.
    case copy
    /// Cut the selection.
    case cut
    /// Paste the clipboard.
    case paste
    /// Select everything.
    case selectAll
}

/// A text or editor event of the IME path, produced by `NSTextInputClient` (input.md §5.1, §5.3).
/// The events travel on the IME channel, ordered with the editing keys the same path sends.
public enum ImeTextEvent: Sendable, Equatable {
    /// `insertText`: commit text. An active composition is replaced, as `commitText` does.
    case commit(String)
    /// `setMarkedText`: the composing text and its selection, relative to the text.
    case setComposing(String, TextRange)
    /// `unmarkText`: the composition ends.
    case finishComposing
    /// A `doCommand` key, sent as `sendKeyEvent` on the bound editor.
    case key(KeyEvent)
    /// An `EditorInfo.IME_ACTION_*` value.
    case editorAction(Int32)
    /// A context menu command.
    case contextMenuAction(ContextMenuAction)
}

/// The editor state the IME reports, narrowed to what the view needs (input.md §5.1). It never
/// carries the editor's text.
public struct EditorState: Sendable, Equatable {
    /// Whether an Android editor is bound to the IME.
    public var editorFocused: Bool
    /// The display whose editor is bound.
    public var displayID: Int32
    /// The package of the bound editor.
    public var packageID: String
    /// `EditorInfo.inputType`.
    public var inputType: Int32
    /// `EditorInfo.imeOptions`.
    public var imeOptions: Int32
    /// The selection in the editor's text.
    public var selection: TextRange
    /// The composing range, or nil when there is none.
    public var composing: TextRange?
    /// The cursor rectangle in display pixels, or nil when unknown.
    public var cursorRectPx: CGRect?

    /// Creates a state.
    public init(
        editorFocused: Bool,
        displayID: Int32,
        packageID: String,
        inputType: Int32,
        imeOptions: Int32,
        selection: TextRange,
        composing: TextRange?,
        cursorRectPx: CGRect?
    ) {
        self.editorFocused = editorFocused
        self.displayID = displayID
        self.packageID = packageID
        self.inputType = inputType
        self.imeOptions = imeOptions
        self.selection = selection
        self.composing = composing
        self.cursorRectPx = cursorRectPx
    }

    /// The command context of this state (input.md §5.4).
    public func commandContext(hasMarkedText: Bool) -> EditorContext {
        EditorContext(hasMarkedText: hasMarkedText, inputType: inputType, imeOptions: imeOptions)
    }
}
