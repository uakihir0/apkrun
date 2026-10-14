package io.apkrun.fixture.hellotext

/** The process-wide trace shared by the debug Activity and its ADB-only receiver. */
object CounterTouchTrace {
    private val buffer = CounterTouchTraceBuffer()

    fun isRecording(): Boolean = buffer.isRecording()

    fun executionMode(): CounterClickExecutionMode = buffer.currentExecutionMode()

    fun runDebugCommand(action: String?, atNanos: Long, mode: String?): List<String>? =
        DebugCounterTouchTraceCommands(buffer).run(action, atNanos, mode)

    fun recordTouch(atNanos: Long, action: TouchTraceAction, pressed: Boolean) =
        buffer.recordTouch(atNanos, action, pressed)

    fun recordPressed(atNanos: Long, pressed: Boolean) = buffer.recordPressed(atNanos, pressed)

    fun recordPressedStateWaitElapsed(atNanos: Long) = buffer.recordPressedStateWaitElapsed(atNanos)

    fun recordClickCallback(atNanos: Long) = buffer.recordClickCallback(atNanos)

    fun recordCounterWrite(
        atNanos: Long,
        durationNanos: Long,
        requestedValue: Int,
        saved: Boolean,
        observedValue: Int,
    ) = buffer.recordCounterWrite(atNanos, durationNanos, requestedValue, saved, observedValue)
}
