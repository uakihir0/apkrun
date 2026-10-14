package io.apkrun.fixture.hellotext

/**
 * Bounded, in-memory trace of the HelloText counter button. It is inert until a debug command
 * starts a capture.
 *
 * Timestamps are monotonic nanoseconds supplied by the Android call site. Keeping the buffer
 * independent of Android lets its bounds and serialized wire format be tested on the JVM.
 */
class CounterTouchTraceBuffer(private val capacity: Int = DEFAULT_CAPACITY) {
    private val events = ArrayDeque<CounterTouchTraceEvent>()

    @Volatile private var recording = false

    @Volatile private var executionMode = CounterClickExecutionMode.QUEUE

    private var startedAtNanos: Long? = null
    private var nextSequence = 1L
    private var droppedEvents = 0L

    init {
        require(capacity > 0) { "capacity must be positive" }
    }

    fun isRecording(): Boolean = recording

    @Synchronized
    fun start(
        atNanos: Long,
        mode: CounterClickExecutionMode = CounterClickExecutionMode.QUEUE,
    ): Boolean {
        if (recording) {
            return false
        }
        events.clear()
        startedAtNanos = atNanos
        nextSequence = 1L
        droppedEvents = 0L
        executionMode = mode
        recording = true
        return true
    }

    fun currentExecutionMode(): CounterClickExecutionMode =
        if (recording) executionMode else CounterClickExecutionMode.QUEUE

    fun recordTouch(atNanos: Long, action: TouchTraceAction, pressed: Boolean) {
        record(
            atNanos = atNanos,
            kind = TouchTraceKind.TOUCH,
            action = action.wireName,
            pressed = pressed,
        )
    }

    fun recordPressed(atNanos: Long, pressed: Boolean) {
        record(atNanos = atNanos, kind = TouchTraceKind.PRESSED, pressed = pressed)
    }

    fun recordPressedStateWaitElapsed(atNanos: Long) {
        record(atNanos = atNanos, kind = TouchTraceKind.PRESSED_STATE_WAIT_ELAPSED)
    }

    fun recordClickCallback(atNanos: Long) {
        record(atNanos = atNanos, kind = TouchTraceKind.CLICK_CALLBACK)
    }

    fun recordCounterWrite(
        atNanos: Long,
        durationNanos: Long,
        requestedValue: Int,
        saved: Boolean,
        observedValue: Int,
    ) {
        record(
            atNanos = atNanos,
            kind = TouchTraceKind.COUNTER_WRITE,
            durationNanos = durationNanos,
            requestedValue = requestedValue,
            saved = saved,
            observedValue = observedValue,
        )
    }

    /**
     * Stops capture and consumes its events. The returned lines contain one JSON document split
     * into bounded logcat messages. A second read cannot replay this capture.
     */
    @Synchronized
    fun drainLines(): List<String> {
        recording = false
        val snapshot =
            CounterTouchTraceSnapshot(
                startedAtNanos = startedAtNanos,
                executionMode = if (startedAtNanos == null) null else executionMode,
                droppedEvents = droppedEvents,
                events = events.toList(),
            )
        startedAtNanos = null
        executionMode = CounterClickExecutionMode.QUEUE
        events.clear()
        droppedEvents = 0L
        return serialize(snapshot)
    }

    private fun record(
        atNanos: Long,
        kind: TouchTraceKind,
        action: String? = null,
        pressed: Boolean? = null,
        durationNanos: Long? = null,
        requestedValue: Int? = null,
        saved: Boolean? = null,
        observedValue: Int? = null,
    ) {
        if (!recording) {
            return
        }
        synchronized(this) {
            if (!recording) {
                return
            }
            if (events.size == capacity) {
                events.removeFirst()
                droppedEvents++
            }
            events.addLast(
                CounterTouchTraceEvent(
                    sequence = nextSequence++,
                    atNanos = atNanos,
                    kind = kind,
                    action = action,
                    pressed = pressed,
                    durationNanos = durationNanos,
                    requestedValue = requestedValue,
                    saved = saved,
                    observedValue = observedValue,
                )
            )
        }
    }

    private fun serialize(snapshot: CounterTouchTraceSnapshot): List<String> {
        val json = buildString {
            append("{\"version\":1,\"started_at_ns\":")
            append(snapshot.startedAtNanos?.toString() ?: "null")
            append(",\"mode\":")
            append(snapshot.executionMode?.let { "\"${it.wireValue}\"" } ?: "null")
            append(",\"dropped_events\":")
            append(snapshot.droppedEvents)
            append(",\"events\":[")
            snapshot.events.forEachIndexed { index, event ->
                if (index > 0) {
                    append(',')
                }
                appendEvent(event, snapshot.startedAtNanos)
            }
            append("]}")
        }
        val pieces = json.chunked(MAX_JSON_CHUNK_CHARS)
        return pieces.mapIndexed { index, piece ->
            "debug trace chunk ${index + 1}/${pieces.size} $piece"
        }
    }

    private fun StringBuilder.appendEvent(event: CounterTouchTraceEvent, startNanos: Long?) {
        append("{\"seq\":")
        append(event.sequence)
        append(",\"elapsed_ns\":")
        append(if (startNanos == null) "null" else (event.atNanos - startNanos).coerceAtLeast(0L))
        append(",\"kind\":\"")
        append(event.kind.wireName)
        append('"')
        event.action?.let {
            append(",\"action\":\"")
            append(it)
            append('"')
        }
        event.pressed?.let {
            append(",\"pressed\":")
            append(it)
        }
        event.durationNanos?.let {
            append(",\"duration_ns\":")
            append(it)
        }
        event.requestedValue?.let {
            append(",\"requested\":")
            append(it)
        }
        event.saved?.let {
            append(",\"saved\":")
            append(it)
        }
        event.observedValue?.let {
            append(",\"observed\":")
            append(it)
        }
        append('}')
    }

    companion object {
        const val DEFAULT_CAPACITY = 1024
        const val MAX_JSON_CHUNK_CHARS = 3000
    }
}

enum class TouchTraceAction(val wireName: String) {
    DOWN("down"),
    MOVE("move"),
    UP("up"),
    CANCEL("cancel"),
}

enum class CounterClickExecutionMode(val wireValue: String) {
    QUEUE("queue"),
    SYNCHRONOUS("synchronous");

    companion object {
        fun parse(value: String?): CounterClickExecutionMode? = entries.firstOrNull {
            it.wireValue == value
        }
    }
}

private enum class TouchTraceKind(val wireName: String) {
    TOUCH("touch"),
    PRESSED("pressed"),
    PRESSED_STATE_WAIT_ELAPSED("pressed_state_wait_elapsed"),
    CLICK_CALLBACK("click_callback"),
    COUNTER_WRITE("counter_write"),
}

private data class CounterTouchTraceEvent(
    val sequence: Long,
    val atNanos: Long,
    val kind: TouchTraceKind,
    val action: String? = null,
    val pressed: Boolean? = null,
    val durationNanos: Long? = null,
    val requestedValue: Int? = null,
    val saved: Boolean? = null,
    val observedValue: Int? = null,
)

private data class CounterTouchTraceSnapshot(
    val startedAtNanos: Long?,
    val executionMode: CounterClickExecutionMode?,
    val droppedEvents: Long,
    val events: List<CounterTouchTraceEvent>,
)

/** The debug-only start/read commands for a trace capture. */
class DebugCounterTouchTraceCommands(private val trace: CounterTouchTraceBuffer) {
    fun run(action: String?, atNanos: Long, mode: String? = null): List<String>? {
        return when (action) {
            ACTION_TRACE_START -> {
                val executionMode =
                    if (mode == null) {
                        CounterClickExecutionMode.QUEUE
                    } else {
                        CounterClickExecutionMode.parse(mode)
                    }
                if (executionMode == null) {
                    return listOf("debug trace start rejected: mode must be queue or synchronous")
                }
                if (trace.start(atNanos, executionMode)) {
                    listOf("debug trace started")
                } else {
                    listOf("debug trace start rejected: a capture is already active")
                }
            }

            ACTION_TRACE_READ -> trace.drainLines()
            else -> null
        }
    }

    companion object {
        const val EXTRA_MODE = "mode"
        const val ACTION_TRACE_START = "io.apkrun.fixture.hellotext.debug.TRACE_START"
        const val ACTION_TRACE_READ = "io.apkrun.fixture.hellotext.debug.TRACE_READ"
    }
}
