package io.apkrun.fixture.hellotext

/**
 * What the fixture shows, kept for the debug commands. The debug receiver reports the text of the field and the screen
 * without a view. The text is reported only when a `text` command asks for it, and never when it changes, so a log line
 * does not carry typed text on its own (AGENTS §8).
 */
object FixtureState {
    /** The screen that is shown: [SCREEN_MAIN] or [SCREEN_DETAILS]. */
    @Volatile
    var screen: String = SCREEN_MAIN

    /** The text of the main screen's field. */
    @Volatile
    var fieldText: String = ""

    const val SCREEN_MAIN = "main"
    const val SCREEN_DETAILS = "details"
}
