package io.apkrun.fixture.hellotext

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The debug commands of the screens on the JVM (#025). */
class DebugFixtureCommandsTest {
    @Test
    fun textReportsTheFieldAsAJsonStringOnRequest() {
        FixtureState.fieldText = "Hi"
        assertEquals("text \"Hi\"", DebugFixtureCommands().run(DebugFixtureCommands.ACTION_TEXT))
    }

    @Test
    fun theDetailsAndUnknownActionsReportNoLine() {
        assertNull(DebugFixtureCommands().run(DebugFixtureCommands.ACTION_DETAILS))
        assertNull(DebugFixtureCommands().run("io.apkrun.fixture.hellotext.debug.UNKNOWN"))
    }
}
