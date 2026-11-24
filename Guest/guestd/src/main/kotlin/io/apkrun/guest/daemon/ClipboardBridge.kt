package io.apkrun.guest.daemon

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.PersistableBundle
import io.apkrun.guest.protocol.GuestCapability
import io.apkrun.guest.protocol.v1.ClipData as WireClipData
import io.apkrun.guest.protocol.v1.ClipImage as WireClipImage
import io.apkrun.guest.protocol.v1.ClipOrigin
import io.apkrun.guest.protocol.v1.Event
import io.apkrun.guest.runtime.AgentLog
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest

/**
 * The Android end of the clipboard path (desktop-integration.md §4.2, §4.3). `SetClipboard` (op 40)
 * writes the clip the host pushed; [onClipChanged] reports every other clip as a `ClipboardChanged`
 * event. A clip this bridge just wrote is recognized by its content hash and skipped, so an own
 * write never echoes back to the host (the loop prevention of §4.4, the agent side).
 *
 * Images ride the bulk channel (guest-protocol.md §10): a host clip names `image.transfer_id` whose
 * payload this bridge picks up from [InboundTransfers] and serves to Android through
 * [TransferFileProvider] (`io.apkrun.guest.files`); a guest clip is announced the other way with an
 * odd transfer ID.
 *
 * The framework calls live in [ClipAccess]; [AndroidClipAccess] implements them over
 * `ClipboardManager`, and a unit test gives a fake. The agent's sequence is the `clipboard_seq` of
 * the snapshot (guest-protocol.md §8.4).
 */
internal class ClipboardBridge(
    private val events: EventBus,
    private val clipboard: ClipAccess,
    private val bulk: BulkImageSender? = null,
    private val inbound: InboundTransfers? = null,
) {

    /** The bulk sends the bridge needs; `BulkTransfers` implements it, a test fakes it. */
    internal fun interface BulkImageSender {
        fun sendClipboardImage(png: ByteArray): Long?
    }

    /** A clip image as it crosses the wire: PNG bytes within the §11.4 limits. */
    internal data class ImageClip(val png: ByteArray, val width: Int, val height: Int)

    /** The one clip, reduced to what the bridge exchanges with the host. */
    internal data class RawClip(
        val text: String,
        val html: String,
        val sensitive: Boolean,
        val image: ImageClip? = null,
    )

    /**
     * The ClipboardManager calls the bridge needs (desktop-integration.md §4.3). A call to [read]
     * made during a change notification returns the new primary clip. [write] takes the provider
     * URI of an inbound transfer file, or null for a text clip.
     */
    internal interface ClipAccess {
        fun read(): RawClip?

        fun write(text: String, html: String, sensitive: Boolean, imageUri: String?)

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
     * Applies a host clip: plain text with HTML and an image when given (desktop-integration.md
     * §4.4). An image names the transfer that carries its PNG bytes on the bulk channel; the file
     * stays on disk for the FileProvider as long as the clip lives. `sensitive` is carried as
     * `ClipDescription.EXTRA_IS_SENSITIVE`, so the system never shows the content in its clipboard
     * preview.
     */
    fun setClipboard(request: WireClipData) {
        val imageFile =
            if (request.hasImage()) {
                awaitTransfer(request.image.transferId)
            } else {
                null
            }
        if (request.hasImage() && imageFile == null) {
            // The text still goes: a lost transfer degrades the clip, it does not refuse it.
            AgentLog.warning("the image transfer ${request.image.transferId} never arrived")
        }
        val imageHash = imageFile?.let { sha256(it.readBytes()) }
        synchronized(lock) {
            lastAppliedHash = contentHash(request.text, request.html, imageHash)
            sequence += 1
        }
        clipboard.write(
            request.text,
            request.html,
            request.sensitive,
            imageFile?.let { TransferFileProvider.uriForName(it.name) },
        )
    }

    /**
     * Waits briefly for a transfer the host announced before its `SetClipboard`. The bulk frames
     * and the request ride different connections, so the payload can arrive a moment after the clip
     * that names it. Returns the file, or `null` on timeout.
     */
    private fun awaitTransfer(transferId: Long): File? {
        val store = inbound ?: return null
        var attempts = TRANSFER_WAIT_ATTEMPTS
        while (attempts > 0) {
            store.take(transferId)?.let {
                return it
            }
            attempts -= 1
            try {
                Thread.sleep(TRANSFER_WAIT_STEP_MILLIS)
            } catch (_: InterruptedException) {
                return null
            }
        }
        return null
    }

    /**
     * Reads the new primary clip and publishes `ClipboardChanged`. A call for the clip this bridge
     * just wrote is consumed by the echo marker (desktop-integration.md §4.4). An image clip is
     * announced after its bulk transfer is sent, so the `transfer_id` is always resolvable.
     */
    fun onClipChanged() {
        val raw = clipboard.read() ?: return
        val imageHash = raw.image?.let { sha256(it.png) }
        val hash = contentHash(raw.text, raw.html, imageHash)
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
        val image =
            raw.image?.let { image ->
                bulk?.sendClipboardImage(image.png)?.let { transferId ->
                    WireClipImage.newBuilder()
                        .setMimeType("image/png")
                        .setWidth(image.width)
                        .setHeight(image.height)
                        .setTransferId(transferId)
                        .build()
                }
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
                .apply { image?.let { setImage(it) } }
                .build()
        events.publish(
            if (image != null) GuestCapability.CLIPBOARD_IMAGE else GuestCapability.CLIPBOARD_TEXT
        ) { event: Event.Builder ->
            event.setClipboardChanged(data)
        }
    }

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun contentHash(text: String, html: String, imageHash: String? = null): String {
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update(text.toByteArray(Charsets.UTF_8))
        digest.update(html.toByteArray(Charsets.UTF_8))
        if (imageHash != null) {
            digest.update(imageHash.toByteArray(Charsets.UTF_8))
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun truncate(text: String, byteLimit: Int): String {
        var bytes = 0
        var index = 0
        // Iterating Char by Char splits surrogate pairs: an emoji is then cut in half or
        // undercounted. Code points keep the boundary whole and the byte count exact.
        while (index < text.length) {
            val point = Character.codePointAt(text, index)
            val next = bytes + String(Character.toChars(point)).toByteArray(Charsets.UTF_8).size
            if (next > byteLimit) {
                break
            }
            bytes = next
            index += Character.charCount(point)
        }
        return text.substring(0, index)
    }

    /**
     * The ClipboardManager calls of a bridge (desktop-integration.md §4.2, §4.3), plus the
     * `OnPrimaryClipChangedListener` registration. Reads made on a shell-uid agent may throw
     * SecurityException on a stock image; the listener then moves to the IME (#72).
     */
    private class AndroidClipAccess(private val context: Context) :
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
            val text = item.text?.toString()
            // A provider that throws (missing file, I/O, security) must not kill the agent:
            // the clip's text and HTML still go through without the image.
            val image = item.uri?.let { uri -> runCatching { readImage(uri) }.getOrNull() }
            if (text == null && image == null) {
                return null
            }
            val sensitive =
                clip.description.extras?.containsKey(ClipDescription.EXTRA_IS_SENSITIVE) == true
            return RawClip(
                text = text ?: "",
                html = item.htmlText ?: "",
                sensitive = sensitive,
                image = image,
            )
        }

        /**
         * Reads an image clip item inside the §11.4 limits. The bounds are decoded before the
         * bitmap so a small file cannot claim a huge one; a PNG passes unchanged and every other
         * format is re-encoded (issue #81).
         */
        private fun readImage(uri: android.net.Uri): ImageClip? {
            val mimeType = context.contentResolver.getType(uri) ?: return null
            if (!mimeType.startsWith("image/")) {
                return null
            }
            val bytes =
                context.contentResolver.openInputStream(uri)?.use { stream ->
                    readCapped(stream, IMAGE_BYTE_LIMIT + 1)
                } ?: return null
            if (bytes.isEmpty() || bytes.size > IMAGE_BYTE_LIMIT) {
                return null
            }
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            val width = bounds.outWidth
            val height = bounds.outHeight
            if (width <= 0 || height <= 0 || maxOf(width, height) > IMAGE_PIXEL_LIMIT) {
                return null
            }
            if (mimeType == "image/png") {
                return ImageClip(bytes, width, height)
            }
            val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
            val output = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
            val png = output.toByteArray()
            if (png.size > IMAGE_BYTE_LIMIT) {
                return null
            }
            return ImageClip(png, width, height)
        }

        /** Reads at most [cap] bytes; a stream longer than the cap is cut at it. */
        private fun readCapped(stream: java.io.InputStream, cap: Int): ByteArray {
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(64 * 1024)
            var total = 0
            while (total < cap) {
                val read = stream.read(buffer, 0, minOf(buffer.size, cap - total))
                if (read < 0) {
                    break
                }
                output.write(buffer, 0, read)
                total += read
            }
            return output.toByteArray()
        }

        override fun write(text: String, html: String, sensitive: Boolean, imageUri: String?) {
            val item: ClipData.Item
            val clip: ClipData
            if (imageUri != null) {
                // The image is the clip; text and HTML ride along as the plain fallback
                // (desktop-integration.md §4.4).
                val mimeTypes =
                    listOfNotNull(
                        "image/png",
                        "text/html".takeIf { html.isNotEmpty() },
                        "text/plain".takeIf { text.isNotEmpty() },
                    )
                item =
                    ClipData.Item(
                        text.ifEmpty { null },
                        html.ifEmpty { null },
                        null,
                        android.net.Uri.parse(imageUri),
                    )
                clip = ClipData(ClipDescription(LABEL, mimeTypes.toTypedArray()), item)
            } else {
                clip =
                    if (html.isNotEmpty()) {
                        ClipData.newHtmlText(LABEL, text, html)
                    } else {
                        ClipData.newPlainText(LABEL, text)
                    }
            }
            if (sensitive) {
                val extras = PersistableBundle()
                extras.putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
                clip.description.extras = extras
            }
            clipboard.setPrimaryClip(clip)
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
        /** The 1 MiB text limit of desktop-integration.md §4.4. */
        const val TEXT_BYTE_LIMIT = 1_048_576

        /** The 16 MiB image limit of runtime-api.md §11.4. */
        const val IMAGE_BYTE_LIMIT = 16 * 1024 * 1024

        /** The 8192 px per-side image limit (desktop-integration.md §4.4). */
        const val IMAGE_PIXEL_LIMIT = 8192

        /** How long setClipboard waits for the bulk frames of its image. */
        private const val TRANSFER_WAIT_ATTEMPTS = 60
        private const val TRANSFER_WAIT_STEP_MILLIS = 25L

        /** A bridge over the real ClipboardManager (the production path of the agent). */
        fun create(
            context: Context,
            events: EventBus,
            bulk: BulkImageSender,
            inbound: InboundTransfers,
        ): ClipboardBridge = ClipboardBridge(events, AndroidClipAccess(context), bulk, inbound)
    }
}
