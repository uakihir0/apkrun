package io.apkrun.guest.daemon

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.PersistableBundle
import io.apkrun.guest.protocol.v1.ClipData as WireClipData
import io.apkrun.guest.protocol.v1.ClipOrigin
import io.apkrun.guest.protocol.v1.Event
import java.security.MessageDigest

/**
 * The Android end of the clipboard path (desktop-integration.md §4.2, §4.3). `SetClipboard` (op 40)
 * writes the clip the host pushed; [onClipChanged] reports every other clip as a `ClipboardChanged`
 * event. A clip this bridge just wrote is recognized by its content hash and skipped, so an own
 * write never echoes back to the host (the loop prevention of §4.4, the agent side).
 *
 * The framework calls live in [ClipAccess]; [AndroidClipAccess] implements them over
 * `ClipboardManager`, and a unit test gives a fake. The agent's sequence is the `clipboard_seq` of
 * the snapshot (guest-protocol.md §8.4).
 */
internal class ClipboardBridge(
    private val events: EventBus,
    private val clipboard: ClipAccess,
) {

    /** The one clip, reduced to what the bridge exchanges with the host. */
    internal data class RawClip(val text: String, val html: String, val sensitive: Boolean)

    /**
     * The ClipboardManager calls the bridge needs (desktop-integration.md §4.3). A call to [read]
     * made during a change notification returns the new primary clip.
     */
    internal interface ClipAccess {
        fun read(): RawClip?

        fun write(text: String, html: String, sensitive: Boolean)

        fun addChangeListener(listener: () -> Unit)

        fun removeChangeListener(listener: () -> Unit)
    }

    // The listener notification and setClipboard can run on different threads, so the echo marker
    // and the sequence are guarded by the lock.
    private val lock = Any()

    /** The hash of the clip this bridge last wrote; one matching change call is skipped. */
    private var lastAppliedHash: String? = null

    /** The agent-side ClipData sequence (guest-protocol.md §8.4). */
    private var sequence = 0L

    /** The one registered change callback; the same instance goes to add and to remove. */
    private val changeListener: () -> Unit = { onClipChanged() }

    /** Starts reporting clipboard changes. */
    fun start() {
        clipboard.addChangeListener(changeListener)
    }

    /** Stops reporting clipboard changes. */
    fun stop() {
        clipboard.removeChangeListener(changeListener)
    }

    /** The current sequence, for the snapshot's `clipboard_seq` field. */
    fun currentSequence(): Long = synchronized(lock) { sequence }

    /**
     * Applies a host clip: plain text with HTML when given (desktop-integration.md §4.4).
     * `sensitive` is carried as `ClipDescription.EXTRA_IS_SENSITIVE`, so the system never shows the
     * content in its clipboard preview.
     */
    fun setClipboard(request: WireClipData) {
        synchronized(lock) {
            lastAppliedHash = contentHash(request.text, request.html)
            sequence += 1
        }
        clipboard.write(request.text, request.html, request.sensitive)
    }

    /**
     * Reads the new primary clip and publishes `ClipboardChanged`. A call for the clip this bridge
     * just wrote is consumed by the echo marker (desktop-integration.md §4.4).
     */
    fun onClipChanged() {
        val raw = clipboard.read() ?: return
        val hash = contentHash(raw.text, raw.html)
        val nextSeq: Long
        synchronized(lock) {
            if (hash == lastAppliedHash) {
                lastAppliedHash = null
                return
            }
            sequence += 1
            nextSeq = sequence
        }
        var clipped = raw.text
        var truncated = false
        if (clipped.toByteArray(Charsets.UTF_8).size > TEXT_BYTE_LIMIT) {
            clipped = truncate(clipped, TEXT_BYTE_LIMIT)
            truncated = true
        }
        var clippedHtml = raw.html
        if (clippedHtml.toByteArray(Charsets.UTF_8).size > TEXT_BYTE_LIMIT) {
            clippedHtml = truncate(clippedHtml, TEXT_BYTE_LIMIT)
            truncated = true
        }
        val data =
            WireClipData.newBuilder()
                .setSeq(nextSeq)
                .setOrigin(ClipOrigin.CLIP_ORIGIN_GUEST)
                .setText(clipped)
                .setTruncated(truncated)
                .setHtml(clippedHtml)
                .setSourcePackage("")
                .setSensitive(raw.sensitive)
                .build()
        events.publish { event: Event.Builder -> event.setClipboardChanged(data) }
    }

    private fun contentHash(text: String, html: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update(text.toByteArray(Charsets.UTF_8))
        digest.update(html.toByteArray(Charsets.UTF_8))
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun truncate(text: String, byteLimit: Int): String {
        var bytes = 0
        val end = StringBuilder()
        for (character in text) {
            val next = bytes + character.toString().toByteArray(Charsets.UTF_8).size
            if (next > byteLimit) {
                break
            }
            bytes = next
            end.append(character)
        }
        return end.toString()
    }

    /**
     * The ClipboardManager calls of a bridge (desktop-integration.md §4.2, §4.3), plus the
     * `OnPrimaryClipChangedListener` registration. Reads made on a shell-uid agent may throw
     * SecurityException on a stock image; the listener then moves to the IME (#72).
     */
    private class AndroidClipAccess(context: Context) :
        ClipboardManager.OnPrimaryClipChangedListener, ClipAccess {

        private val clipboard: ClipboardManager =
            context.getSystemService(ClipboardManager::class.java)

        private var listeners = mutableListOf<() -> Unit>()

        override fun onPrimaryClipChanged() {
            listeners.forEach { it() }
        }

        override fun read(): RawClip? {
            val clip = clipboard.primaryClip ?: return null
            if (clip.itemCount == 0) {
                return null
            }
            val item = clip.getItemAt(0)
            val text = item.text?.toString() ?: return null
            val sensitive =
                clip.description.extras?.containsKey(ClipDescription.EXTRA_IS_SENSITIVE) == true
            return RawClip(text = text, html = item.htmlText ?: "", sensitive = sensitive)
        }

        override fun write(text: String, html: String, sensitive: Boolean) {
            val item =
                if (html.isNotEmpty()) {
                    ClipData.newHtmlText(LABEL, text, html)
                } else {
                    ClipData.newPlainText(LABEL, text)
                }
            if (sensitive) {
                val extras = PersistableBundle()
                extras.putInt(ClipDescription.EXTRA_IS_SENSITIVE, 1)
                item.description.extras = extras
            }
            clipboard.setPrimaryClip(item)
        }

        override fun addChangeListener(listener: () -> Unit) {
            if (listeners.isEmpty()) {
                clipboard.addPrimaryClipChangedListener(this)
            }
            listeners += listener
        }

        override fun removeChangeListener(listener: () -> Unit) {
            listeners -= listener
            if (listeners.isEmpty()) {
                clipboard.removePrimaryClipChangedListener(this)
            }
        }

        private companion object {
            const val LABEL = "io.apkrun.clip"
        }
    }

    companion object {
        /** The 1 MiB limit of desktop-integration.md §4.4. */
        const val TEXT_BYTE_LIMIT = 1_048_576

        /** A bridge over the real ClipboardManager (the production path of the agent). */
        fun create(context: Context, events: EventBus): ClipboardBridge =
            ClipboardBridge(events, AndroidClipAccess(context))
    }
}
