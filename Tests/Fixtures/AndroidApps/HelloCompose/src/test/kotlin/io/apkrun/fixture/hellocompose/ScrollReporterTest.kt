package io.apkrun.fixture.hellocompose

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The scroll rule of the list on the JVM (test-strategy §4.2, #024 T2 checks HelloCompose's scroll). */
class ScrollReporterTest {
    @Test
    fun theInitialIndexIsNotReported() {
        assertNull(ScrollReporter().settled(0))
    }

    @Test
    fun aNewSettledIndexIsReported() {
        val reporter = ScrollReporter()

        assertEquals("scroll first=5", reporter.settled(5))
    }

    @Test
    fun aRepeatedSettledIndexIsReportedOnce() {
        val reporter = ScrollReporter()

        assertEquals("scroll first=5", reporter.settled(5))
        assertNull(reporter.settled(5))
    }

    @Test
    fun returningToTheReportedIndexAfterAnotherIsReportedAgain() {
        val reporter = ScrollReporter()

        assertEquals("scroll first=5", reporter.settled(5))
        assertEquals("scroll first=0", reporter.settled(0))
        assertEquals("scroll first=5", reporter.settled(5))
    }

    @Test
    fun theStartIndexOfAReporterIsTheReportedIndex() {
        val reporter = ScrollReporter(initialFirst = 40)

        assertNull(reporter.settled(40))
        assertEquals("scroll first=41", reporter.settled(41))
    }
}
