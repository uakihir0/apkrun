package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.FrameReader
import io.apkrun.guest.protocol.FrameWriter
import io.apkrun.guest.protocol.v1.BulkFrame
import io.apkrun.guest.protocol.v1.CollectDiagnostics
import io.apkrun.guest.protocol.v1.DiagnosticsItem
import io.apkrun.guest.protocol.v1.DiagnosticsItemStatus
import io.apkrun.guest.protocol.v1.Envelope
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * CollectDiagnostics: a known item collects and transfers on the bulk connection, an unknown item
 * reports UNSUPPORTED without failing, and a payload over maxBytes truncates (diagnostics.md §5).
 */
class DiagnosticsServiceTest {
    private fun requestFor(vararg items: DiagnosticsItem, maxBytes: Long = 16 * 1024 * 1024) =
        CollectDiagnostics.newBuilder()
            .apply {
                addAllItems(items.toList())
                this.maxBytes = maxBytes
            }
            .build()

    @Test
    fun unknownItemIsUnsupportedWithoutFailing() {
        val service = DiagnosticsService(BulkTransfers())
        val result = service.collect(requestFor(DiagnosticsItem.DIAGNOSTICS_ITEM_UNSPECIFIED))
        assertEquals(1, result.itemsCount)
        assertEquals(
            DiagnosticsItemStatus.DIAGNOSTICS_ITEM_STATUS_UNSUPPORTED,
            result.getItems(0).status,
        )
    }

    @Test
    fun getpropKeepsOnlyAllowlistedKeys() {
        val bulk = BulkTransfers()
        val output = ByteArrayOutputStream()
        bulk.attach(FrameWriter(output))
        val service =
            DiagnosticsService(
                bulk,
                object : DiagnosticsService.ShellRunner {
                    override fun run(vararg command: String) =
                        ("[ro.build.version.sdk]: [37]\n" +
                                "[ro.serialno]: [EMULATOR12345]\n" +
                                "[ro.product.model]: [sdk_phone]\n" +
                                "[persist.sys.timezone]: [Asia/Tokyo]\n")
                            .toByteArray()
                },
            )

        val result = service.collect(requestFor(DiagnosticsItem.DIAGNOSTICS_ITEM_GETPROP))
        assertEquals(DiagnosticsItemStatus.DIAGNOSTICS_ITEM_STATUS_OK, result.getItems(0).status)
        val payload = bulkPayload(output.toByteArray())
        val text = String(payload, Charsets.UTF_8)
        assertTrue(text.contains("ro.build.version.sdk"))
        assertTrue(text.contains("ro.product.model"))
        assertTrue(!text.contains("persist.sys.timezone"))
        assertTrue(!text.contains("serialno") && !text.contains("EMULATOR12345"))
    }

    @Test
    fun agentLogReadsTheRingFiles() {
        val dir = createTempDir("agentlog")
        val log = java.io.File(dir, "agent.log")
        log.writeText("I agent: hello\n")
        val service =
            DiagnosticsService(
                BulkTransfers().also { it.attach(FrameWriter(ByteArrayOutputStream())) },
                object : DiagnosticsService.ShellRunner {
                    override fun run(vararg command: String) = ByteArray(0)
                },
                agentLogPaths = listOf(log.path, java.io.File(dir, "agent.log.1").path),
            )
        val result = service.collect(requestFor(DiagnosticsItem.DIAGNOSTICS_ITEM_AGENT_LOG))
        assertEquals(DiagnosticsItemStatus.DIAGNOSTICS_ITEM_STATUS_OK, result.getItems(0).status)
    }

    @Test
    fun tombstonesFallBackToDropboxWhenUnlistable() {
        val bulk = BulkTransfers()
        val output = ByteArrayOutputStream()
        bulk.attach(FrameWriter(output))
        val service =
            DiagnosticsService(
                bulk,
                object : DiagnosticsService.ShellRunner {
                    override fun run(vararg command: String) =
                        if (command.contentEquals(arrayOf("ls", "-l", "/data/tombstones/"))) {
                            throw IllegalStateException("denied")
                        } else {
                            ("2026-09-30 10:15:02 system_app_crash (text, 1234 bytes)\n" +
                                    "2026-09-30 10:14:00 system_server_activity (text, 100 bytes)\n")
                                .toByteArray()
                        }
                },
            )
        val result = service.collect(requestFor(DiagnosticsItem.DIAGNOSTICS_ITEM_TOMBSTONE_LIST))
        assertEquals(DiagnosticsItemStatus.DIAGNOSTICS_ITEM_STATUS_OK, result.getItems(0).status)
        val payload = bulkPayload(output.toByteArray())
        assertTrue(String(payload).contains("system_app_crash"))
        assertTrue(!String(payload).contains("system_server_activity"))
    }

    private fun bulkPayload(output: ByteArray): ByteArray {
        val reader = FrameReader(ByteArrayInputStream(output))
        val chunks = mutableListOf<ByteArray>()
        while (true) {
            val envelope =
                try {
                    reader.next()
                } catch (end: Exception) {
                    break
                }
            if (envelope.bodyCase == Envelope.BodyCase.BULK && envelope.bulk.hasChunk()) {
                chunks.add(envelope.bulk.chunk.toByteArray())
            }
        }
        val result = ByteArrayOutputStream()
        chunks.forEach(result::write)
        return result.toByteArray()
    }

    @Test
    fun meminfoCollectsOverTheBulkConnection() {
        val bulk = BulkTransfers()
        val output = ByteArrayOutputStream()
        bulk.attach(FrameWriter(output))
        val payload = "pid,system_server,rss\n1,system_server,1024".toByteArray()
        val service =
            DiagnosticsService(
                bulk,
                object : DiagnosticsService.ShellRunner {
                    override fun run(vararg command: String) = payload
                },
            )

        val result = service.collect(requestFor(DiagnosticsItem.DIAGNOSTICS_ITEM_DUMPSYS_MEMINFO))
        assertEquals(1, result.itemsCount)
        val item = result.getItems(0)
        assertEquals(DiagnosticsItemStatus.DIAGNOSTICS_ITEM_STATUS_OK, item.status)
        assertTrue(item.hasTransferId())
        assertTrue(item.transferId % 2L == 1L)

        // begin → chunks → end on the bulk connection carry the payload back.
        val reader = FrameReader(ByteArrayInputStream(output.toByteArray()))
        val frames = mutableListOf<BulkFrame>()
        while (true) {
            val envelope =
                try {
                    reader.next()
                } catch (end: Exception) {
                    break
                }
            if (envelope.bodyCase == Envelope.BodyCase.BULK) {
                frames.add(envelope.bulk)
            }
        }
        assertTrue(frames.firstOrNull()?.hasBegin() == true)
        val chunks = frames.filter { it.hasChunk() }
        val reassembled =
            chunks
                .fold(ByteArrayOutputStream()) { acc, frame ->
                    acc.write(frame.chunk.toByteArray())
                    acc
                }
                .toByteArray()
        assertTrue(reassembled.contentEquals(payload))
        assertTrue(frames.lastOrNull()?.hasEnd() == true)
    }

    @Test
    fun meminfoTruncatesAtMaxBytes() {
        val bulk = BulkTransfers()
        bulk.attach(FrameWriter(ByteArrayOutputStream()))
        val payload = ByteArray(2_000) { 'a'.code.toByte() }
        val service =
            DiagnosticsService(
                bulk,
                object : DiagnosticsService.ShellRunner {
                    override fun run(vararg command: String) = payload
                },
            )

        val result =
            service.collect(
                requestFor(DiagnosticsItem.DIAGNOSTICS_ITEM_DUMPSYS_MEMINFO, maxBytes = 1_000)
            )
        val item = result.getItems(0)
        assertEquals(DiagnosticsItemStatus.DIAGNOSTICS_ITEM_STATUS_OK, item.status)
        assertTrue(item.truncated)
    }

    @Test
    fun meminfoWithoutABulkConnectionFailsTheItemOnly() {
        val service =
            DiagnosticsService(
                BulkTransfers(),
                object : DiagnosticsService.ShellRunner {
                    override fun run(vararg command: String) = ByteArray(10)
                },
            )
        val result = service.collect(requestFor(DiagnosticsItem.DIAGNOSTICS_ITEM_DUMPSYS_MEMINFO))
        assertEquals(
            DiagnosticsItemStatus.DIAGNOSTICS_ITEM_STATUS_FAILED,
            result.getItems(0).status,
        )
    }

    @Test
    fun shellFailureFailsTheItemOnly() {
        val bulk = BulkTransfers()
        bulk.attach(FrameWriter(ByteArrayOutputStream()))
        val service =
            DiagnosticsService(
                bulk,
                object : DiagnosticsService.ShellRunner {
                    override fun run(vararg command: String): ByteArray =
                        throw RuntimeException("no shell")
                },
            )
        val result = service.collect(requestFor(DiagnosticsItem.DIAGNOSTICS_ITEM_DUMPSYS_MEMINFO))
        assertEquals(
            DiagnosticsItemStatus.DIAGNOSTICS_ITEM_STATUS_FAILED,
            result.getItems(0).status,
        )
    }
}
