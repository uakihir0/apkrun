package io.apkrun.fixture.hellotext

/**
 * The debug-only commands of the counter (IR-920). An ADB broadcast sends one, so that the counter can be advanced
 * and read without a tap (#17 criterion 1). Both commands go through the [CounterStore] that the button uses.
 *
 * The class lives in `main` so that the release unit tests can run it. Only the debug receiver calls it. The
 * release manifest has no receiver, so no broadcast can reach it in the release build.
 */
class DebugCounterCommands(private val counter: CounterStore) {
    /**
     * Runs the command for [action] and returns the logcat line that reports it, or null when [action] is not one
     * of the debug commands.
     */
    fun run(action: String?): String? = when (action) {
        ACTION_INCREMENT -> increment()
        ACTION_READ -> "debug read ${counter.current()}"
        else -> null
    }

    private fun increment(): String =
        try {
            "debug increment ${counter.increment()}"
        } catch (failure: IllegalStateException) {
            "debug increment not saved: ${failure.message}"
        }

    companion object {
        const val ACTION_INCREMENT = "io.apkrun.fixture.hellotext.debug.INCREMENT"
        const val ACTION_READ = "io.apkrun.fixture.hellotext.debug.READ"
    }
}
