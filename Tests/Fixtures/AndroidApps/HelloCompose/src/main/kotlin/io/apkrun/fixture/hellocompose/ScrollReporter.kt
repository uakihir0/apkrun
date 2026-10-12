package io.apkrun.fixture.hellocompose

/**
 * The scroll rule of HelloCompose (test-strategy §4.2): the list reports `scroll first=<index>` when its first
 * visible index has settled at a value other than the one last reported. A fling that passes through other indices
 * and settles back on the reported index logs nothing.
 *
 * The activity feeds it only settled indices (the first index held for a short time), so the log has one line per
 * settled position, not one per frame.
 */
class ScrollReporter(initialFirst: Int = 0) {
    private var reported = initialFirst

    /** Returns the line to log for a settled first visible [first], or null when it is the reported index. */
    fun settled(first: Int): String? {
        if (first == reported) {
            return null
        }
        reported = first
        return "scroll first=$first"
    }
}
