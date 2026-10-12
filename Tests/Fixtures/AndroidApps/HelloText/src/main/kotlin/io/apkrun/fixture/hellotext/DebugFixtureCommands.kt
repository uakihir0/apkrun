package io.apkrun.fixture.hellotext

/**
 * The debug-only commands of the screens (#025). Like [DebugCounterCommands], the class lives in `main` so that the
 * release unit tests can run it. Only the debug receiver calls it.
 */
class DebugFixtureCommands {
    /**
     * Runs the command for [action] and returns the logcat line that reports it, or null when [action] is not a command
     * that reports a line. [ACTION_DETAILS] opens the Details screen, and the receiver does that itself.
     */
    fun run(action: String?): String? = when (action) {
        ACTION_TEXT -> "text ${JsonString.encode(FixtureState.fieldText)}"
        else -> null
    }

    companion object {
        const val ACTION_TEXT = "io.apkrun.fixture.hellotext.debug.TEXT"
        const val ACTION_DETAILS = "io.apkrun.fixture.hellotext.debug.DETAILS"
    }
}
