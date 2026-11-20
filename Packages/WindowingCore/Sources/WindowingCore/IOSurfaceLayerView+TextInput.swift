import AppKit
import InputCore

/// Editor mode (input.md §5.1, §5.3): the view is an `NSTextInputClient`, so the macOS input method
/// produces `insertText`, marked text, and `doCommand` calls, and they leave as `ImeTextEvent`s on
/// the IME channel. The composition itself lives in the Android editor; this view mirrors only what
/// the input method asks about.
extension IOSurfaceLayerView: @preconcurrency NSTextInputClient {
    /// `insertText` commits; it replaces an active composition, as `commitText` does (input.md §5.3).
    public func insertText(_ string: Any, replacementRange: NSRange) {
        guard isEditorMode else {
            return
        }
        textInputModel.clearMarked()
        deliverText(.commit(plainText(string)))
    }

    /// `setMarkedText` replaces the composing text; its selection is relative to the text
    /// (input.md §5.3).
    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard isEditorMode else {
            return
        }
        let text = plainText(string)
        textInputModel.setMarked(text: text, selectedRange: selectedRange)
        deliverText(.setComposing(text, textInputModel.selectionRange))
    }

    /// `unmarkText` ends the composition (input.md §5.3).
    public func unmarkText() {
        guard isEditorMode, textInputModel.hasMarkedText else {
            return
        }
        textInputModel.clearMarked()
        deliverText(.finishComposing)
    }

    /// `hasMarkedText` (input.md §5.3).
    public func hasMarkedText() -> Bool {
        textInputModel.hasMarkedText
    }

    /// `markedRange`: the whole composing text, or `{NSNotFound, 0}`.
    public func markedRange() -> NSRange {
        textInputModel.markedRange
    }

    /// `selectedRange`: the selection inside the composing text.
    public func selectedRange() -> NSRange {
        textInputModel.selectedRange
    }

    /// Surrounding text is not mirrored, so reconversion is unsupported (input.md §10).
    public func attributedSubstring(
        forProposedRange range: NSRange, actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        nil
    }

    /// The candidate window's anchor: the last cursor rectangle of the IME, in display pixels
    /// mapped to the view, the window, and the screen. Without a cursor rectangle the answer is the
    /// bottom-left of the content rect (input.md §5.3).
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        var point: CGPoint
        if let rect = textInputModel.cursorRectPx, let geometry {
            let scaleX = contentRect.width / CGFloat(geometry.pixelWidth)
            let scaleY = contentRect.height / CGFloat(geometry.pixelHeight)
            point = CGPoint(
                x: contentRect.minX + rect.midX * scaleX,
                y: contentRect.maxY - rect.midY * scaleY
            )
            let height = max(1, rect.height * scaleY)
            let inWindow = convert(CGRect(x: point.x, y: point.y - height, width: 1, height: height), to: nil)
            return window?.convertToScreen(inWindow) ?? inWindow
        }
        point = CGPoint(x: contentRect.minX, y: contentRect.maxY)
        let inWindow = convert(CGRect(origin: point, size: CGSize(width: 1, height: 1)), to: nil)
        return window?.convertToScreen(inWindow) ?? inWindow
    }

    /// No hit testing into the editor text; the location is not mirrored (input.md §10).
    public func characterIndex(for point: NSPoint) -> Int {
        0
    }

    /// `doCommand` selectors map to editing keys or the editor action (input.md §5.4). They are sent
    /// on the IME channel so they stay ordered with the committed text.
    public override func doCommand(by selector: Selector) {
        guard isEditorMode, let state = editorState else {
            return
        }
        let name = NSStringFromSelector(selector)
        let context = state.commandContext(hasMarkedText: textInputModel.hasMarkedText)
        switch EditorCommandMap.command(for: name, context: context) {
        case .key(let androidKeyCode, let metaState):
            let now = Self.now()
            deliverText(
                .key(
                    KeyEvent(
                        action: .down, androidKeyCode: androidKeyCode, metaState: metaState,
                        repeatCount: 0, time: now)))
            deliverText(
                .key(
                    KeyEvent(
                        action: .up, androidKeyCode: androidKeyCode, metaState: metaState,
                        repeatCount: 0, time: now)))
        case .editorAction(let action):
            deliverText(.editorAction(action))
        case .unmapped:
            unmappedCommandCount += 1
        case .consumed:
            break
        }
    }

    /// No extra marked-text attributes are offered.
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    /// The ⌘ equivalents of editor mode (input.md §5.4): the context menu commands and the ⌘[
    /// BACK shortcut go through the IME channel, so they stay ordered with text. Returns true when
    /// the key is consumed.
    func editorKeyEquivalent(_ characters: String) -> Bool {
        let action: ContextMenuAction?
        switch characters.lowercased() {
        case "c": action = .copy
        case "x": action = .cut
        case "v": action = .paste
        case "a": action = .selectAll
        case "[":
            let now = Self.now()
            deliverText(
                .key(
                    KeyEvent(
                        action: .down, androidKeyCode: AndroidKeyCode.back, metaState: [],
                        repeatCount: 0, time: now)))
            deliverText(
                .key(
                    KeyEvent(
                        action: .up, androidKeyCode: AndroidKeyCode.back, metaState: [],
                        repeatCount: 0, time: now)))
            return true
        default:
            // ⌘Z and the rest have no Android context menu command (input.md §5.4, "Others").
            return false
        }
        if let action {
            deliverText(.contextMenuAction(action))
            return true
        }
        return false
    }

    /// The plain string of an `insertText`/`setMarkedText` argument.
    private func plainText(_ string: Any) -> String {
        if let attributed = string as? NSAttributedString {
            return attributed.string
        }
        return (string as? String) ?? ""
    }

    /// Sends one text event to the sink.
    private func deliverText(_ event: ImeTextEvent) {
        imeTextSink?.deliverText(event)
    }

    /// The secure input policy of input.md §5.5: on while a password variation is focused and the
    /// window is key.
    func updateSecureInput() {
        let wanted =
            windowIsKey
            && isEditorMode
            && SecureFieldPolicy.isSecure(inputType: editorState?.inputType ?? 0)
        secureInput.update(wanted, inputContext: inputContext)
    }
}
