package io.apkrun.guest.ime

import io.apkrun.guest.daemon.KeyEventFactory
import io.apkrun.guest.daemon.KeySpec
import io.apkrun.guest.protocol.v1.ContextMenuAction
import io.apkrun.guest.protocol.v1.ImeCommand
import io.apkrun.guest.protocol.v1.ImeState
import io.apkrun.guest.protocol.v1.KeyAction
import io.apkrun.guest.protocol.v1.Rect

/**
 * The editing surface a bound editor exposes to the IME (input.md §5.3). It mirrors the calls of
 * `android.view.inputmethod.InputConnection` that the command set needs, kept framework-free so the
 * JVM tests can run the full mapping (decision: the service itself only adapts).
 */
interface ImeEditorConnection {
    /** `InputConnection.commitText(text, 1)`. */
    fun commitText(text: String)

    /** `InputConnection.setComposingText(text, 1)`. */
    fun setComposingText(text: String)

    /**
     * `InputConnection.setSelection(start, end)` with absolute editor offsets. Used to place the
     * selection inside a composing region (input.md §5.3).
     */
    fun setSelection(start: Int, end: Int)

    /** The current absolute selection end, or -1 when it cannot be read. */
    fun selectionEnd(): Int

    /** `InputConnection.finishComposingText()`. */
    fun finishComposingText()

    /** `InputConnection.sendKeyEvent` with an already created framework `KeyEvent`. */
    fun sendKeyEvent(event: Any)

    /** `InputConnection.performEditorAction` with an `EditorInfo.IME_ACTION_*` value. */
    fun performEditorAction(action: Int)

    /**
     * `InputConnection.performContextMenuAction` with an `android.R.id.*` action id. The mapping
     * from [ContextMenuAction] to the platform ids is supplied by the caller because `android.R`
     * constants live in the framework.
     */
    fun performContextMenuAction(id: Int)
}

/**
 * Applies one [ImeCommand] to the currently bound editor (input.md §5.3–5.4). A command that
 * arrives without a bound editor is dropped and counted, per input.md §5.6.
 */
class ImeCommandApplier(
    /**
     * The context-menu action ids, in the order copy, cut, paste, select all (`android.R.id.*`).
     */
    private val contextMenuIds: ContextMenuIds,
    /** Builds framework `KeyEvent`s from wire specs (the Android factory in production). */
    private val keyEvents: KeyEventFactory,
    /** Wall time in ms used for injected key events. */
    private val uptimeMillis: () -> Long = { 0L },
) {
    /** Context menu ids resolved by the caller (`android.R.id.copy` etc.). */
    data class ContextMenuIds(val copy: Int, val cut: Int, val paste: Int, val selectAll: Int)

    /** Commands dropped because no editor was bound (input.md §5.6). */
    var droppedNoEditor = 0L
        private set

    /** Returns false (and counts the command) when no editor is bound. */
    fun apply(command: ImeCommand, editor: ImeEditorConnection?): Boolean {
        if (editor == null) {
            droppedNoEditor += 1
            return false
        }
        when (command.kindCase) {
            ImeCommand.KindCase.COMMIT_TEXT -> {
                // Wire limit is 4 KiB UTF-8 (input.proto); longer input is dropped.
                if (command.commitText.toByteArray(Charsets.UTF_8).size > MAX_COMMIT_BYTES) {
                    return true
                }
                editor.commitText(command.commitText)
            }
            ImeCommand.KindCase.SET_COMPOSING -> {
                val composing = command.setComposing
                editor.setComposingText(composing.text)
                // The selection offsets are relative to the composing text (input.proto). With
                // newCursorPosition = 1 the cursor sits right after the composing region, so its
                // absolute start is selectionEnd - text.length.
                val anchor = editor.selectionEnd()
                if (anchor >= 0) {
                    val start = anchor - composing.text.length
                    editor.setSelection(
                        start + composing.selectionStart.coerceIn(0, composing.text.length),
                        start + composing.selectionEnd.coerceIn(0, composing.text.length),
                    )
                }
            }
            ImeCommand.KindCase.FINISH_COMPOSING -> editor.finishComposingText()
            ImeCommand.KindCase.KEY -> {
                val key = command.key
                val action =
                    when (key.action) {
                        KeyAction.KEY_ACTION_DOWN -> 0 // KeyEvent.ACTION_DOWN
                        else -> 1 // KeyEvent.ACTION_UP
                    }
                val now = uptimeMillis()
                editor.sendKeyEvent(
                    keyEvents.create(
                        KeySpec(
                            action = action,
                            downTime = now,
                            eventTime = now,
                            keyCode = key.keyCode,
                            repeatCount = key.repeatCount,
                            metaState = key.metaState.toInt(),
                        )
                    )
                )
            }
            ImeCommand.KindCase.EDITOR_ACTION -> editor.performEditorAction(command.editorAction)
            ImeCommand.KindCase.CONTEXT_MENU_ACTION ->
                editor.performContextMenuAction(
                    when (command.contextMenuAction) {
                        ContextMenuAction.CONTEXT_MENU_ACTION_COPY -> contextMenuIds.copy
                        ContextMenuAction.CONTEXT_MENU_ACTION_CUT -> contextMenuIds.cut
                        ContextMenuAction.CONTEXT_MENU_ACTION_PASTE -> contextMenuIds.paste
                        ContextMenuAction.CONTEXT_MENU_ACTION_SELECT_ALL -> contextMenuIds.selectAll
                        else -> return true
                    }
                )
            else -> return true
        }
        return true
    }

    private companion object {
        const val MAX_COMMIT_BYTES = 4 * 1024
    }
}

/**
 * The editor state the IME reports to the host as `ImeState` (input.md §5.1, §5.3). Fields are
 * updated by the service callbacks; [snapshot] builds the wire message. The text itself is never
 * reported (input.proto).
 */
class ImeStateTracker {
    private var focused = false
    private var displayId = 0
    private var packageName = ""
    private var inputType = 0
    private var imeOptions = 0
    private var selectionStart = 0
    private var selectionEnd = 0
    private var composingStart = -1
    private var composingEnd = -1
    private var cursorRect: Rect? = null

    /**
     * An editor bound: `onStartInput` (input.md §5.6). A `TYPE_NULL` start is a non-text view, so
     * it is not an editor for the host (input.md §5.1).
     */
    fun editorStarted(displayId: Int, packageName: String, inputType: Int, imeOptions: Int) {
        focused = (inputType and TYPE_MASK_CLASS) != TYPE_NULL
        this.displayId = displayId
        this.packageName = packageName
        this.inputType = inputType
        this.imeOptions = imeOptions
        selectionStart = 0
        selectionEnd = 0
        composingStart = -1
        composingEnd = -1
        cursorRect = null
    }

    /** The editor unbound: `onFinishInput` (input.md §5.6). */
    fun editorFinished() {
        focused = false
        composingStart = -1
        composingEnd = -1
        cursorRect = null
    }

    /** `onUpdateSelection`: absolute selection and composing offsets. */
    fun selection(newSelStart: Int, newSelEnd: Int, compStart: Int, compEnd: Int) {
        selectionStart = newSelStart
        selectionEnd = newSelEnd
        composingStart = compStart
        composingEnd = compEnd
    }

    /** `onUpdateCursorAnchorInfo`: the insertion marker rect in display pixels. */
    fun cursorRect(rect: Rect?) {
        cursorRect = rect
    }

    /** The display of the bound editor, for the command display check (input.md §5.1). */
    val boundDisplayId: Int
        get() = displayId

    /** `EditorInfo.inputType` masks; the constants are inlined so the JVM tests need no stubs. */
    private companion object {
        const val TYPE_MASK_CLASS = 0xF
        const val TYPE_NULL = 0
    }

    /** The wire message. */
    fun snapshot(): ImeState {
        val builder =
            ImeState.newBuilder()
                .setEditorFocused(focused)
                .setDisplayId(displayId)
                .setPackage(packageName)
                .setInputType(inputType)
                .setImeOptions(imeOptions)
                .setSelectionStart(selectionStart)
                .setSelectionEnd(selectionEnd)
                .setComposingStart(composingStart)
                .setComposingEnd(composingEnd)
        cursorRect?.let { builder.setCursorRectPx(it) }
        return builder.build()
    }
}
