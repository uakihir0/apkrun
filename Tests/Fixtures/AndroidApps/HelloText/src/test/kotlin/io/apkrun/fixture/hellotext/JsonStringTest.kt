package io.apkrun.fixture.hellotext

import org.junit.Assert.assertEquals
import org.junit.Test

/** The JSON literal of the `text` event (#26). */
class JsonStringTest {
    @Test
    fun aPlainTextIsQuoted() {
        assertEquals("\"Hello, APKRun 123!\"", JsonString.encode("Hello, APKRun 123!"))
    }

    @Test
    fun quotesBackslashesAndControlCharactersAreEscaped() {
        assertEquals("\"a\\\"b\\\\c\\nd\\u0001\"", JsonString.encode("a\"b\\c\nd\u0001"))
    }
}
