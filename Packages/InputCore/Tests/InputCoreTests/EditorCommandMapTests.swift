import Foundation
import Testing

@testable import InputCore

// The selector table of input.md §5.4 and the secure-field detection of §5.5.

private let plain = EditorContext(hasMarkedText: false, inputType: 0, imeOptions: 0)

private func command(_ selector: String, context: EditorContext = plain) -> EditorCommand {
    EditorCommandMap.command(for: selector, context: context)
}

private func key(_ selector: String, context: EditorContext = plain) -> (Int32, AndroidMetaState) {
    guard case .key(let code, let meta) = command(selector, context: context) else {
        Issue.record("expected key for \(selector), got \(command(selector, context: context))")
        return (0, [])
    }
    return (code, meta)
}

@Test func deleteSelectors() {
    #expect(key("deleteBackward:").0 == 67)
    #expect(key("deleteForward:").0 == 112)
    let (code, meta) = key("deleteWordBackward:")
    #expect(code == 67)
    #expect(meta.contains(.ctrlOn))
    #expect(key("deleteWordForward:").0 == 112)
    #expect(key("deleteWordForward:", context: plain).1.contains(.ctrlOn))
}

@Test func insertNewlineSendsTheEditorAction() {
    // DONE=5, single-line, no NO_ENTER_ACTION: the editor's action goes (input.md §5.4).
    let context = EditorContext(hasMarkedText: false, inputType: 0, imeOptions: 5)
    guard case .editorAction(5) = command("insertNewline:", context: context) else {
        Issue.record("expected editorAction(5)")
        return
    }
}

@Test func insertNewlineFallsBackToEnter() {
    // Multi-line, NONE, UNSPECIFIED, or NO_ENTER_ACTION: an Enter key (input.md §5.4).
    for options in [0, 1] {
        #expect(
            key(
                "insertNewline:", context: EditorContext(hasMarkedText: false, inputType: 0, imeOptions: Int32(options))
            ).0 == 66)
    }
    #expect(
        key("insertNewline:", context: EditorContext(hasMarkedText: false, inputType: 0x20000, imeOptions: 5)).0 == 66)
    #expect(
        key("insertNewline:", context: EditorContext(hasMarkedText: false, inputType: 0, imeOptions: 5 | 0x4000_0000)).0
            == 66)
    // Line-break variants are always Shift+Enter.
    let (code, meta) = key("insertLineBreak:")
    #expect(code == 66)
    #expect(meta.contains(.shiftOn))
    #expect(key("insertNewlineIgnoringFieldEditor:").1.contains(.shiftOn))
}

@Test func tabAndMovementSelectors() {
    #expect(key("insertTab:").0 == 61)
    #expect(key("insertBacktab:").1.contains(.shiftOn))
    #expect(key("moveLeft:").0 == 21)
    #expect(key("moveRight:").0 == 22)
    #expect(key("moveUp:").0 == 19)
    #expect(key("moveDown:").0 == 20)
    #expect(key("moveLeftAndModifySelection:").1.contains(.shiftOn))
    #expect(key("moveWordLeft:").1.contains(.ctrlOn))
    #expect(key("moveWordRight:").1.contains(.ctrlOn))
    #expect(key("moveToBeginningOfLine:").0 == 122)
    #expect(key("moveToEndOfLine:").0 == 123)
    #expect(key("moveToLeftEndOfLine:").0 == 122)
    #expect(key("moveToRightEndOfLine:").0 == 123)
    let (docCode, docMeta) = key("moveToBeginningOfDocument:")
    #expect(docCode == 122)
    #expect(docMeta.contains(.ctrlOn))
    #expect(key("moveToEndOfDocument:").0 == 123)
    #expect(key("pageUp:").0 == 92)
    #expect(key("scrollPageUp:").0 == 92)
    #expect(key("pageDown:").0 == 93)
    #expect(key("scrollPageDown:").0 == 93)
}

@Test func cancelOperation() {
    // Without marked text it is BACK; with marked text it is consumed (input.md §5.4).
    #expect(key("cancelOperation:").0 == 4)
    guard
        case .consumed = command(
            "cancelOperation:",
            context: EditorContext(hasMarkedText: true, inputType: 0, imeOptions: 0))
    else {
        Issue.record("expected consumed with marked text")
        return
    }
}

@Test func unmappedSelectorsAreCounted() {
    guard case .unmapped = command("noop:"),
        case .unmapped = command("insertDoubleQuoteIgnoringSubstitution:"),
        case .unmapped = command("moveToBeginningOfParagraph:")
    else {
        Issue.record("expected unmapped")
        return
    }
}

@Test func secureFieldDetection() {
    // §5.5: TEXT class (1) with PASSWORD/VISIBLE_PASSWORD/WEB_PASSWORD, NUMBER (2) with password.
    #expect(SecureFieldPolicy.isSecure(inputType: 0x1 | 0x80))
    #expect(SecureFieldPolicy.isSecure(inputType: 0x1 | 0x90))
    #expect(SecureFieldPolicy.isSecure(inputType: 0x1 | 0xE0))
    #expect(SecureFieldPolicy.isSecure(inputType: 0x2 | 0x10))
    #expect(!SecureFieldPolicy.isSecure(inputType: 0x1))
    #expect(!SecureFieldPolicy.isSecure(inputType: 0x2))
    #expect(!SecureFieldPolicy.isSecure(inputType: 0))
}

@Test func textInputModelTracksMarkedText() {
    var model = TextInputModel()
    #expect(!model.hasMarkedText)
    #expect(model.markedRange.location == NSNotFound)
    model.setMarked(text: "にほん", selectedRange: NSRange(location: 2, length: 0))
    #expect(model.hasMarkedText)
    #expect(model.markedRange == NSRange(location: 0, length: 3))
    #expect(model.selectionRange == TextRange(start: 2, end: 2))
    model.clearMarked()
    #expect(!model.hasMarkedText)
    model.updateCursorRect(CGRect(x: 1, y: 2, width: 3, height: 4))
    #expect(model.cursorRectPx == CGRect(x: 1, y: 2, width: 3, height: 4))
}
