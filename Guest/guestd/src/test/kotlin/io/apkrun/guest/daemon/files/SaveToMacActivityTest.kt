package io.apkrun.guest.daemon.files

import android.content.ClipData
import android.content.Intent
import android.net.Uri
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class SaveToMacActivityTest {
    @Test
    fun acceptsTwentyContentUrisAndRejectsTwentyOne() {
        val twenty = (0 until 20).map { Uri.parse("content://example.test/$it") }
        val accepted =
            Intent(Intent.ACTION_SEND_MULTIPLE)
                .putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(twenty))
        assertEquals(twenty, sharedContentUris(accepted))

        val twentyOne = (0 until 21).map { Uri.parse("content://example.test/$it") }
        val rejected =
            Intent(Intent.ACTION_SEND_MULTIPLE)
                .putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(twentyOne))
        assertTrue(sharedContentUris(rejected).isEmpty())
    }

    @Test
    fun fallsBackToClipDataAndRejectsNonContentUris() {
        val contentUri = Uri.parse("content://example.test/file")
        val clipped =
            Intent(Intent.ACTION_SEND).apply {
                clipData =
                    ClipData("shared file", arrayOf("text/uri-list"), ClipData.Item(contentUri))
            }
        assertEquals(listOf(contentUri), sharedContentUris(clipped))

        val external =
            Intent(Intent.ACTION_SEND)
                .putExtra(Intent.EXTRA_STREAM, Uri.parse("file:///tmp/private"))
        assertTrue(sharedContentUris(external).isEmpty())
    }
}
