package io.apkrun.fixture.hellocompose

/**
 * The screen that the debug commands act on. [MainActivity] implements it while the list is shown.
 */
interface DebugComposeHost {
    /** Scrolls the list so that [index] is the first visible row. */
    fun scrollTo(index: Int)

    /** Sets the text of the field. */
    fun setText(value: String)
}

/**
 * The debug-only commands of HelloCompose (IR-920). An ADB broadcast to the debug receiver of src/debug sends one, so a
 * test can scroll the list and set the field without a gesture or the IME. [run] applies the command through a
 * [DebugComposeHost] and returns the logcat line that reports it, or null when the action is not a debug command.
 *
 * The class has no Android types, so the release unit tests can run it. The release manifest has no receiver, so no
 * broadcast reaches it in the release build.
 */
object DebugComposeCommands {
    /** Broadcast action that scrolls the list. The int extra [EXTRA_FIRST] is the index. */
    const val ACTION_SCROLL = "io.apkrun.fixture.hellocompose.debug.SCROLL"

    /** Broadcast action that sets the field. The string extra [EXTRA_TEXT] is the text. */
    const val ACTION_TEXT = "io.apkrun.fixture.hellocompose.debug.TEXT"

    const val EXTRA_FIRST = "first"
    const val EXTRA_TEXT = "text"

    /**
     * Runs the command for [action]. [first] is the int extra of SCROLL (-1 when it is missing), and [text] is the
     * string extra of TEXT (null when it is missing). [host] is null when no list or field is shown.
     */
    fun run(action: String?, first: Int, text: String?, host: DebugComposeHost?): String? = when (action) {
        ACTION_SCROLL -> scroll(first, host)
        ACTION_TEXT -> setText(text, host)
        else -> null
    }

    private fun scroll(first: Int, host: DebugComposeHost?): String = when {
        first !in 0 until ListRows.COUNT -> "debug scroll rejected: first=$first is outside 0..${ListRows.COUNT - 1}"
        host == null -> "debug scroll not applied: no list is shown"
        else -> {
            host.scrollTo(first)
            "debug scroll first=$first"
        }
    }

    // The text itself is not logged (AGENTS.md §8). The line carries its length only.
    private fun setText(text: String?, host: DebugComposeHost?): String = when {
        text == null -> "debug text rejected: no text extra"
        host == null -> "debug text not applied: no field is shown"
        else -> {
            host.setText(text)
            "debug text length=${text.length}"
        }
    }
}
