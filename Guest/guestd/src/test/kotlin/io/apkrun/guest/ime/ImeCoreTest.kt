package io.apkrun.guest.ime

import io.apkrun.guest.daemon.KeyEventFactory
import io.apkrun.guest.daemon.KeySpec
import io.apkrun.guest.protocol.v1.Composing
import io.apkrun.guest.protocol.v1.ContextMenuAction
import io.apkrun.guest.protocol.v1.FinishComposing
import io.apkrun.guest.protocol.v1.ImeCommand
import io.apkrun.guest.protocol.v1.KeyAction
import io.apkrun.guest.protocol.v1.KeyEvent
import io.apkrun.guest.protocol.v1.Rect
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The `ImeCommand` → `InputConnection` mapping and the `ImeState` report (input.md §5.3, §5.1). */
class ImeCoreTest {
    private val menuIds =
        ImeCommandApplier.ContextMenuIds(copy = 101, cut = 102, paste = 103, selectAll = 104)
    private val keyEvents =
        object : KeyEventFactory {
            override fun create(spec: KeySpec): Any = spec
        }
    private val editor = FakeEditor()
    private val applier = ImeCommandApplier(menuIds, keyEvents) { 500L }

    @Test
    fun `commit text lands with a new cursor`() {
        applier.apply(ImeCommand.newBuilder().setCommitText("日本語").build(), editor)
        assertEquals(listOf("commit:日本語"), editor.calls)
    }

    @Test
    fun `a commit over the wire limit is dropped`() {
        val long = "x".repeat(4 * 1024 + 1)
        applier.apply(ImeCommand.newBuilder().setCommitText(long).build(), editor)
        assertTrue(editor.calls.isEmpty())
    }

    @Test
    fun `composing selection offsets are relative to the text`() {
        editor.selectionEnd = 17 // cursor sits right after the composing region
        val composing =
            Composing.newBuilder().setText("にほんご").setSelectionStart(1).setSelectionEnd(3).build()
        applier.apply(ImeCommand.newBuilder().setSetComposing(composing).build(), editor)
        // composing start = 17 - 4 chars = 13; selection = 13 + 1 .. 13 + 3
        assertEquals(listOf("compose:にほんご", "select:14..16"), editor.calls)
    }

    @Test
    fun `finish composing finishes`() {
        applier.apply(
            ImeCommand.newBuilder()
                .setFinishComposing(FinishComposing.getDefaultInstance())
                .build(),
            editor,
        )
        assertEquals(listOf("finish"), editor.calls)
    }

    @Test
    fun `key commands carry action, code, repeat and meta`() {
        applier.apply(
            ImeCommand.newBuilder()
                .setKey(
                    KeyEvent.newBuilder()
                        .setAction(KeyAction.KEY_ACTION_DOWN)
                        .setKeyCode(66)
                        .setMetaState(2)
                        .setRepeatCount(1)
                )
                .build(),
            editor,
        )
        val spec = editor.calls.single() as KeySpec
        assertEquals(0, spec.action)
        assertEquals(66, spec.keyCode)
        assertEquals(1, spec.repeatCount)
        assertEquals(2, spec.metaState)
        assertEquals(500L, spec.downTime)
        assertEquals(500L, spec.eventTime)
    }

    @Test
    fun `editor and context-menu actions are applied`() {
        applier.apply(ImeCommand.newBuilder().setEditorAction(6).build(), editor)
        applier.apply(
            ImeCommand.newBuilder()
                .setContextMenuAction(ContextMenuAction.CONTEXT_MENU_ACTION_PASTE)
                .build(),
            editor,
        )
        applier.apply(
            ImeCommand.newBuilder()
                .setContextMenuAction(ContextMenuAction.CONTEXT_MENU_ACTION_SELECT_ALL)
                .build(),
            editor,
        )
        assertEquals(listOf("action:6", "menu:103", "menu:104"), editor.calls)
    }

    @Test
    fun `a command without an editor is dropped and counted`() {
        assertFalse(applier.apply(ImeCommand.newBuilder().setCommitText("x").build(), null))
        assertEquals(1L, applier.droppedNoEditor)
    }

    @Test
    fun `the tracker builds the wire state`() {
        val tracker = ImeStateTracker()
        tracker.editorStarted(5, "com.hello", 1, 8)
        tracker.selection(2, 7, 0, 4)
        tracker.cursorRect(Rect.newBuilder().setLeft(1).setTop(2).setRight(9).setBottom(12).build())
        val state = tracker.snapshot()
        assertTrue(state.editorFocused)
        assertEquals(5, state.displayId)
        assertEquals("com.hello", state.`package`)
        assertEquals(1, state.inputType)
        assertEquals(8, state.imeOptions)
        assertEquals(2, state.selectionStart)
        assertEquals(7, state.selectionEnd)
        assertEquals(0, state.composingStart)
        assertEquals(4, state.composingEnd)
        assertEquals(9, state.cursorRectPx.right)

        tracker.editorFinished()
        val off = tracker.snapshot()
        assertFalse(off.editorFocused)
        assertEquals(-1, off.composingStart)
        assertFalse(off.hasCursorRectPx())
    }

    /** Records the editor calls; `selectionEnd` reports the field set on it. */
    private class FakeEditor : ImeEditorConnection {
        val calls = mutableListOf<Any>()
        var selectionEnd = 0

        override fun commitText(text: String) {
            calls += "commit:$text"
        }

        override fun setComposingText(text: String) {
            calls += "compose:$text"
        }

        override fun setSelection(start: Int, end: Int) {
            calls += "select:$start..$end"
        }

        override fun selectionEnd(): Int = selectionEnd

        override fun finishComposingText() {
            calls += "finish"
        }

        override fun sendKeyEvent(event: Any) {
            calls += event
        }

        override fun performEditorAction(action: Int) {
            calls += "action:$action"
        }

        override fun performContextMenuAction(id: Int) {
            calls += "menu:$id"
        }
    }
}
