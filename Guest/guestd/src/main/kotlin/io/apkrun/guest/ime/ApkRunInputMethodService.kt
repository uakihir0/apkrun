package io.apkrun.guest.ime

import android.graphics.RectF
import android.inputmethodservice.InputMethodService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.View
import android.view.inputmethod.CursorAnchorInfo
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.ExtractedTextRequest
import android.view.inputmethod.InputConnection
import io.apkrun.guest.BuildConfig
import io.apkrun.guest.daemon.AndroidKeyEventFactory
import io.apkrun.guest.protocol.GuestProtocolFailure
import io.apkrun.guest.protocol.v1.AgentInfo
import io.apkrun.guest.protocol.v1.AgentKind
import io.apkrun.guest.protocol.v1.AndroidInfo
import io.apkrun.guest.protocol.v1.Rect
import io.apkrun.guest.runtime.AgentLog
import io.apkrun.guest.runtime.AgentSocketServer
import io.apkrun.guest.runtime.SocketNameInUse
import java.io.IOException

/**
 * The development IME (input.md §5.6): an `InputMethodService` with no input view of its own. The
 * composing text and candidates live in the Mac window; every `ImeCommand` of the
 * `@apkrun-guest-ime` socket is applied to the bound `InputConnection`, and editor state goes back
 * as `ImeState` reports.
 *
 * The service exists only in development images, where the host connects as the shell user
 * (`PeerCheck` in the socket server enforces it).
 */
class ApkRunInputMethodService : InputMethodService() {
    private val handler = Handler(Looper.getMainLooper())
    private val tracker = ImeStateTracker()
    private val applier =
        ImeCommandApplier(
            ImeCommandApplier.ContextMenuIds(
                copy = android.R.id.copy,
                cut = android.R.id.cut,
                paste = android.R.id.paste,
                selectAll = android.R.id.selectAll,
            ),
            AndroidKeyEventFactory,
            SystemClock::uptimeMillis,
        )

    private var server: AgentSocketServer? = null
    @Volatile private var channel: ImeChannel? = null

    override fun onCreate() {
        super.onCreate()
        val socketServer =
            AgentSocketServer(SOCKET_NAME) { socket, _ ->
                Thread({ serve(socket) }, "apkrun-ime-conn").apply {
                    isDaemon = true
                    start()
                }
            }
        try {
            socketServer.bind()
            socketServer.start()
            server = socketServer
        } catch (error: SocketNameInUse) {
            // A second service instance means an image misconfiguration; stay inert rather than
            // fight over the socket name (guest-components.md §3.2).
            AgentLog.error("the IME socket is already bound", error)
        } catch (error: IOException) {
            AgentLog.error("the IME socket could not be bound", error)
        }
    }

    override fun onDestroy() {
        server?.close()
        channel?.close()
        super.onDestroy()
    }

    override fun onStartInput(attribute: EditorInfo, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        tracker.editorStarted(
            displayId = display?.displayId ?: 0,
            packageName = attribute.packageName.orEmpty(),
            inputType = attribute.inputType,
            imeOptions = attribute.imeOptions,
        )
        publish()
    }

    override fun onStartInputView(info: EditorInfo, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        // The candidates live in the Mac window (input.md §5.1); cursor changes are reported.
        currentInputConnection?.requestCursorUpdates(
            InputConnection.CURSOR_UPDATE_MONITOR or InputConnection.CURSOR_UPDATE_IMMEDIATE
        )
    }

    override fun onFinishInput() {
        tracker.editorFinished()
        publish()
        super.onFinishInput()
    }

    override fun onUpdateSelection(
        oldSelStart: Int,
        oldSelEnd: Int,
        newSelStart: Int,
        newSelEnd: Int,
        candidatesStart: Int,
        candidatesEnd: Int,
    ) {
        super.onUpdateSelection(
            oldSelStart,
            oldSelEnd,
            newSelStart,
            newSelEnd,
            candidatesStart,
            candidatesEnd,
        )
        tracker.selection(newSelStart, newSelEnd, candidatesStart, candidatesEnd)
        publish()
    }

    override fun onUpdateCursorAnchorInfo(cursorAnchorInfo: CursorAnchorInfo) {
        super.onUpdateCursorAnchorInfo(cursorAnchorInfo)
        // The insertion marker, mapped to display pixels (input.md §5.1): the primitive values are
        // view-relative, and the matrix places the view on the display. A marker that the editor
        // does not report (NaN) clears the rect.
        val horizontal = cursorAnchorInfo.insertionMarkerHorizontal
        val top = cursorAnchorInfo.insertionMarkerTop
        val bottom = cursorAnchorInfo.insertionMarkerBottom
        if (horizontal.isNaN() || top.isNaN() || bottom.isNaN() || bottom <= top) {
            tracker.cursorRect(null)
        } else {
            val bounds = RectF(horizontal, top, horizontal, bottom)
            cursorAnchorInfo.matrix.mapRect(bounds)
            tracker.cursorRect(
                Rect.newBuilder()
                    .setLeft(bounds.left.toInt())
                    .setTop(bounds.top.toInt())
                    .setRight(bounds.right.toInt())
                    .setBottom(bounds.bottom.toInt())
                    .build()
            )
        }
        publish()
    }

    /** No input view of its own (input.md §5.6). */
    override fun onCreateInputView(): View = View(this)

    override fun onEvaluateInputViewShown(): Boolean = false

    /** Reports the current editor state if a channel is up. Main thread. */
    private fun publish() {
        channel?.publish(tracker.snapshot())
    }

    /** The accepted connection's reader loop, on its own thread. */
    private fun serve(socket: android.net.LocalSocket) {
        try {
            val imeChannel =
                ImeChannel(
                    input = socket.inputStream,
                    output = socket.outputStream,
                    agentInfo =
                        AgentInfo.newBuilder()
                            .setKind(AgentKind.AGENT_KIND_GUEST_IME)
                            .setVersionName(BuildConfig.VERSION_NAME)
                            .setVersionCode(BuildConfig.VERSION_CODE.toLong())
                            .setBuildId(BuildConfig.VERSION_NAME)
                            .build(),
                    androidInfo =
                        AndroidInfo.newBuilder()
                            .setSdkInt(Build.VERSION.SDK_INT)
                            .setRelease(Build.VERSION.RELEASE)
                            .setBuildFingerprint(Build.FINGERPRINT)
                            .setBuildType(Build.TYPE)
                            .build(),
                    runtimeImageVersion = "",
                ) { command ->
                    // The InputConnection belongs to the main thread (input.md §5.6).
                    handler.post { apply(command) }
                }
            channel = imeChannel
            // The host reads the editor state right after the handshake: a focused editor
            // announces itself (input.md §5.1).
            imeChannel.serve()
        } catch (error: GuestProtocolFailure) {
            AgentLog.warning("the IME channel closed: ${error::class.java.simpleName}")
        } catch (error: IOException) {
            AgentLog.warning("the IME channel broke: ${error::class.java.simpleName}")
        } catch (error: Exception) {
            AgentLog.error("the IME channel failed", error)
        } finally {
            channel = null
            try {
                socket.close()
            } catch (error: IOException) {
                // The socket was already closed.
            }
        }
    }

    /** Applies a command to the bound editor, main thread. */
    private fun apply(command: io.apkrun.guest.protocol.v1.ImeCommand) {
        val connection = currentInputConnection?.let(::AndroidEditorConnection)
        applier.apply(command, connection)
    }

    /** The `InputConnection` of the bound editor as an [ImeEditorConnection]. */
    private class AndroidEditorConnection(private val connection: InputConnection) :
        ImeEditorConnection {
        override fun commitText(text: String) {
            connection.commitText(text, 1)
        }

        override fun setComposingText(text: String) {
            connection.setComposingText(text, 1)
        }

        override fun setSelection(start: Int, end: Int) {
            connection.setSelection(start, end)
        }

        override fun selectionEnd(): Int =
            connection.getExtractedText(ExtractedTextRequest(), 0)?.selectionEnd ?: -1

        override fun finishComposingText() {
            connection.finishComposingText()
        }

        override fun sendKeyEvent(event: Any) {
            connection.sendKeyEvent(event as android.view.KeyEvent)
        }

        override fun performEditorAction(action: Int) {
            connection.performEditorAction(action)
        }

        override fun performContextMenuAction(id: Int) {
            connection.performContextMenuAction(id)
        }
    }

    private companion object {
        const val SOCKET_NAME = "apkrun-guest-ime"
    }
}
