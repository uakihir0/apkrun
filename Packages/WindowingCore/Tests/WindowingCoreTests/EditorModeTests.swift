import AppKit
import InputCore
import Testing

@testable import WindowingCore

// Editor mode (input.md §5): the NSTextInputClient paths produce ImeTextEvents, and the secure
// input counter of §5.5 stays balanced.

private final class RecordingTextSink: ImeTextSink, @unchecked Sendable {
    private(set) var events: [ImeTextEvent] = []

    func deliverText(_ event: ImeTextEvent) {
        events.append(event)
    }
}

@MainActor
private func makeView() -> (IOSurfaceLayerView, RecordingTextSink) {
    let view = IOSurfaceLayerView(
        frame: NSRect(x: 0, y: 0, width: 100, height: 100),
        contentSize: CGSize(width: 100, height: 100),
        contentScale: 1
    )
    view.update(
        pixelWidth: 100, pixelHeight: 100, generation: 1,
        contentSize: CGSize(width: 100, height: 100), contentsScale: 1)
    let sink = RecordingTextSink()
    view.imeTextSink = sink
    view.updateEditor(editorState())
    return (view, sink)
}

private func editorState(inputType: Int32 = 0) -> EditorState {
    EditorState(
        editorFocused: true, displayID: 0, packageID: "app",
        inputType: inputType, imeOptions: 0,
        selection: TextRange(start: 0, end: 0), composing: nil, cursorRectPx: nil)
}

@MainActor
@Test func insertTextCommits() {
    let (view, sink) = makeView()
    #expect(view.isEditorMode)
    view.insertText("a", replacementRange: NSRange(location: 0, length: 0))
    #expect(sink.events == [.commit("a")])
}

@MainActor
@Test func markedTextProducesComposingAndFinish() {
    let (view, sink) = makeView()
    view.setMarkedText(
        "にほ", selectedRange: NSRange(location: 1, length: 1), replacementRange: NSRange(location: 0, length: 0))
    #expect(sink.events == [.setComposing("にほ", TextRange(start: 1, end: 2))])
    #expect(view.hasMarkedText())
    view.unmarkText()
    #expect(sink.events == [.setComposing("にほ", TextRange(start: 1, end: 2)), .finishComposing])
    #expect(!view.hasMarkedText())
}

@MainActor
@Test func doCommandSendsKeysAndCountsUnmapped() throws {
    let (view, sink) = makeView()
    view.doCommand(by: #selector(NSResponder.deleteBackward))
    try #require(sink.events.count == 2)
    guard case .key(let down) = sink.events[0], case .key(let up) = sink.events[1] else {
        Issue.record("expected key down/up")
        return
    }
    #expect(down.androidKeyCode == 67 && down.action == .down)
    #expect(up.action == .up)
    view.doCommand(by: #selector(NSResponder.insertText(_:)))  // unmapped selector name
    #expect(view.unmappedCommandCount == 1)
}

@MainActor
@Test func editorModeOffDeliversNothing() {
    let (view, sink) = makeView()
    // No editor is focused: editor mode is off, so input-client calls are dropped (input.md §5.1).
    // Rebuild without a focused editor: editor mode is off, calls are dropped (input.md §5.1).
    view.cancelAll()
    #expect(!view.isEditorMode)
    view.insertText("a", replacementRange: NSRange(location: 0, length: 0))
    view.doCommand(by: #selector(NSResponder.deleteBackward))
    #expect(sink.events.isEmpty)
}

@MainActor
@Test func secureInputBalancesAcrossFocusAndState() {
    let (view, _) = makeView()
    var enables = 0
    var disables = 0
    let controller = SecureInputController(
        enable: { enables += 1 }, disable: { disables += 1 })
    // Secure on: password field focused, window key (input.md §5.5).
    controller.update(true, inputContext: nil)
    controller.update(true, inputContext: nil)  // a repeated state is a no-op
    #expect(enables == 1 && disables == 0 && controller.isActive)
    // Off when the field leaves focus.
    controller.update(false, inputContext: nil)
    #expect(enables == 1 && disables == 1 && !controller.isActive)
    #expect(view.secureInput.depth == 0)
}

@MainActor
@Test func secureFieldDrivesSecureInputThroughUpdateEditor() {
    let (view, _) = makeView()
    var enables = 0
    var disables = 0
    view.secureInput = SecureInputController(enable: { enables += 1 }, disable: { disables += 1 })
    // A password variation focuses: secure input goes on (input.md §5.5).
    view.updateEditor(editorState(inputType: 0x1 | 0x80))
    #expect(enables == 1 && disables == 0)
    // It stays on while a password variation is bound.
    view.updateEditor(editorState(inputType: 0x1 | 0x90))
    #expect(enables == 1 && disables == 0)
    // The window losing key ends it; a state while not key does not restart it.
    view.focusLost(sendCancellation: false)
    #expect(disables == 1)
    view.updateEditor(editorState(inputType: 0x1 | 0x90))
    #expect(enables == 1)
    view.windowBecameKey()
    #expect(enables == 2)
    // A plain field ends it.
    view.updateEditor(editorState(inputType: 0))
    #expect(disables == 2)
    view.cancelAll()
}
