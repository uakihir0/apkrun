package io.apkrun.fixture.hellocompose

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/** The debug-only commands on the JVM, with a recording host in place of the Compose screen (IR-920). */
class DebugComposeCommandsTest {
    private class RecordingHost : DebugComposeHost {
        val scrolls = mutableListOf<Int>()
        val texts = mutableListOf<String>()

        override fun scrollTo(index: Int) {
            scrolls += index
        }

        override fun setText(value: String) {
            texts += value
        }
    }

    @Test
    fun scrollCallsTheHostAndLogsTheIndex() {
        val host = RecordingHost()

        assertEquals(
            "debug scroll first=50",
            DebugComposeCommands.run(DebugComposeCommands.ACTION_SCROLL, 50, null, host),
        )
        assertEquals(listOf(50), host.scrolls)
    }

    @Test
    fun theFirstAndLastRowsAreInRange() {
        val host = RecordingHost()

        DebugComposeCommands.run(DebugComposeCommands.ACTION_SCROLL, 0, null, host)
        DebugComposeCommands.run(DebugComposeCommands.ACTION_SCROLL, ListRows.COUNT - 1, null, host)

        assertEquals(listOf(0, ListRows.COUNT - 1), host.scrolls)
    }

    @Test
    fun anIndexOutsideTheListIsRejectedWithoutScrolling() {
        val host = RecordingHost()

        assertEquals(
            "debug scroll rejected: first=-1 is outside 0..199",
            DebugComposeCommands.run(DebugComposeCommands.ACTION_SCROLL, -1, null, host),
        )
        assertEquals(
            "debug scroll rejected: first=200 is outside 0..199",
            DebugComposeCommands.run(DebugComposeCommands.ACTION_SCROLL, ListRows.COUNT, null, host),
        )
        assertEquals(emptyList<Int>(), host.scrolls)
    }

    @Test
    fun aScrollWithNoListShownIsNotApplied() {
        assertEquals(
            "debug scroll not applied: no list is shown",
            DebugComposeCommands.run(DebugComposeCommands.ACTION_SCROLL, 3, null, null),
        )
    }

    @Test
    fun textSetsTheFieldAndLogsOnlyItsLength() {
        val host = RecordingHost()
        val typed = "Hello, APKRun 123!"

        val line = DebugComposeCommands.run(DebugComposeCommands.ACTION_TEXT, -1, typed, host)

        assertEquals("debug text length=18", line)
        assertFalse(line.orEmpty().contains("Hello"))
        assertEquals(listOf(typed), host.texts)
    }

    @Test
    fun anEmptyTextClearsTheField() {
        val host = RecordingHost()

        assertEquals("debug text length=0", DebugComposeCommands.run(DebugComposeCommands.ACTION_TEXT, -1, "", host))
        assertEquals(listOf(""), host.texts)
    }

    @Test
    fun aTextBroadcastWithoutTheExtraIsRejected() {
        val host = RecordingHost()

        assertEquals(
            "debug text rejected: no text extra",
            DebugComposeCommands.run(DebugComposeCommands.ACTION_TEXT, -1, null, host),
        )
        assertEquals(emptyList<String>(), host.texts)
    }

    @Test
    fun aTextWithNoFieldShownIsNotApplied() {
        assertEquals(
            "debug text not applied: no field is shown",
            DebugComposeCommands.run(DebugComposeCommands.ACTION_TEXT, -1, "abc", null),
        )
    }

    @Test
    fun anUnknownActionIsIgnored() {
        val host = RecordingHost()

        assertNull(DebugComposeCommands.run("io.apkrun.fixture.hellocompose.debug.OTHER", 1, "a", host))
        assertNull(DebugComposeCommands.run(null, 1, "a", host))
        assertEquals(emptyList<Int>(), host.scrolls)
        assertEquals(emptyList<String>(), host.texts)
    }
}
