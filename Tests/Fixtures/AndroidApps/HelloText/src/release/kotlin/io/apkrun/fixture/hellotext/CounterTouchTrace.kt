package io.apkrun.fixture.hellotext

/** Release fixture builds keep the input trace and its synchronous diagnostic mode disabled. */
object CounterTouchTrace {
    fun isRecording(): Boolean = false

    fun executionMode(): CounterClickExecutionMode = CounterClickExecutionMode.QUEUE

    fun recordClickCallback(atNanos: Long) = Unit

    fun recordCounterWrite(
        atNanos: Long,
        durationNanos: Long,
        requestedValue: Int,
        saved: Boolean,
        observedValue: Int,
    ) = Unit
}
