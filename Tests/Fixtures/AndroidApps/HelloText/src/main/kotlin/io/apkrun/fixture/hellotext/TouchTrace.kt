package io.apkrun.fixture.hellotext

/**
 * A bounded, in-memory trace of the increment button's input dispatch.
 *
 * Capturing is opt-in. The debug-only Activity hook records scalar MotionEvent fields before Button
 * handling, while post-dispatch samples and click callbacks are appended only during an active
 * capture. No record is logged or persisted until [stopAndDrain] returns it to the debug receiver.
 */
class TouchTrace(private val capacity: Int = DEFAULT_CAPACITY) {
    private val ring: Array<TouchTraceRecord?> = arrayOfNulls(capacity)
    private var firstRecordIndex = 0
    private var recordCount = 0
    private var nextRecordSequence = 1L
    private var droppedRecordCount = 0L
    private var capturing = false
    private var captureToken: Any = Any()
    private var clickOrdinal = 0L
    private var pendingUpCount = 0L
    private var pendingUpSequence: Long? = null
    private var pendingUpIdentityKnown = false

    init {
        require(capacity > 0) { "capacity must be positive" }
    }

    /** True only between [start] and [stopAndDrain]. */
    val isCapturing: Boolean
        get() = synchronized(this) { capturing }

    /**
     * Clears any prior capture state and starts a fresh capture.
     *
     * @return the fixed record capacity.
     */
    fun start(): Int =
        synchronized(this) {
            clearRecords()
            captureToken = Any()
            nextRecordSequence = 1
            droppedRecordCount = 0
            clickOrdinal = 0
            pendingUpCount = 0
            pendingUpSequence = null
            pendingUpIdentityKnown = false
            capturing = true
            capacity
        }

    /**
     * Records a DOWN, UP, or CANCEL before normal View handling.
     *
     * @return the record sequence to attach a later post-dispatch sample to, or null when capture
     *   is off or the action is not one of the three traced actions.
     */
    fun recordTouch(
        eventTimeMillis: Long,
        downTimeMillis: Long,
        action: Int,
        pressedBefore: Boolean,
        enabled: Boolean,
        focused: Boolean,
        inside: Boolean,
        shown: Boolean,
    ): TouchTraceInputToken? {
        val actionName = TouchTraceAction.fromMaskedValue(action) ?: return null
        return synchronized(this) {
            if (!capturing) {
                return@synchronized null
            }

            val sequence = allocateSequence()
            append(
                TouchTraceRecord.Touch(
                    sequence = sequence,
                    eventTimeMillis = eventTimeMillis,
                    downTimeMillis = downTimeMillis,
                    action = actionName,
                    pressedBefore = pressedBefore,
                    enabled = enabled,
                    focused = focused,
                    inside = inside,
                    shown = shown,
                )
            )
            if (actionName == TouchTraceAction.UP) {
                if (pendingUpCount == 0L) {
                    pendingUpSequence = sequence
                    pendingUpIdentityKnown = true
                } else {
                    pendingUpSequence = null
                    pendingUpIdentityKnown = false
                }
                if (pendingUpCount < Long.MAX_VALUE) {
                    pendingUpCount += 1
                }
            }
            TouchTraceInputToken(sequence, captureToken)
        }
    }

    /** Appends a pressed-state sample posted after default View handling. */
    fun recordPostDispatchPressed(
        input: TouchTraceInputToken,
        sampledAtUptimeMillis: Long,
        pressed: Boolean,
    ) {
        synchronized(this) {
            if (!capturing || input.captureToken !== captureToken) {
                return
            }
            append(
                TouchTraceRecord.PressedSample(
                    sequence = allocateSequence(),
                    inputSequence = input.sequence,
                    sampledAtUptimeMillis = sampledAtUptimeMillis,
                    pressed = pressed,
                )
            )
        }
    }

    /**
     * Records a click callback and correlates it only when one identifiable UP is pending.
     *
     * An ambiguous callback consumes one pending-UP count without guessing which UP it matched. Any
     * remaining candidate UPs retain an unknown identity until the pending set is exhausted.
     */
    fun recordClick(storedCounter: Int?, saveSucceeded: Boolean): Long? =
        synchronized(this) {
            if (!capturing) {
                return@synchronized null
            }

            clickOrdinal += 1
            val pendingAtClick = pendingUpCount
            val correlatedUpSequence =
                if (pendingAtClick == 1L && pendingUpIdentityKnown) pendingUpSequence else null
            val correlation =
                if (correlatedUpSequence != null) {
                    TouchTraceRecord.Click.Correlation.UNIQUE_UP
                } else {
                    TouchTraceRecord.Click.Correlation.AMBIGUOUS
                }
            val sequence = allocateSequence()
            append(
                TouchTraceRecord.Click(
                    sequence = sequence,
                    clickOrdinal = clickOrdinal,
                    storedCounter = storedCounter,
                    saveSucceeded = saveSucceeded,
                    correlation = correlation,
                    pendingUpCount = pendingAtClick,
                    correlatedUpSequence = correlatedUpSequence,
                )
            )

            if (pendingUpCount > 0L) {
                pendingUpCount -= 1
                pendingUpSequence = null
                pendingUpIdentityKnown = false
            }
            sequence
        }

    /**
     * Stops capture, returns all retained records in order, and empties the ring.
     *
     * The returned overflow count is the number of older records overwritten by the fixed-size
     * ring.
     */
    fun stopAndDrain(): TouchTraceDrain =
        synchronized(this) {
            capturing = false
            val records =
                buildList(recordCount) {
                    repeat(recordCount) { offset ->
                        val index = (firstRecordIndex + offset) % capacity
                        ring[index]?.let(::add)
                    }
                }
            val drain = TouchTraceDrain(records, droppedRecordCount)
            clearRecords()
            droppedRecordCount = 0
            pendingUpCount = 0
            pendingUpSequence = null
            pendingUpIdentityKnown = false
            drain
        }

    private fun allocateSequence(): Long {
        val result = nextRecordSequence
        if (nextRecordSequence < Long.MAX_VALUE) {
            nextRecordSequence += 1
        }
        return result
    }

    private fun append(record: TouchTraceRecord) {
        if (recordCount < capacity) {
            val index = (firstRecordIndex + recordCount) % capacity
            ring[index] = record
            recordCount += 1
            return
        }

        ring[firstRecordIndex] = record
        firstRecordIndex = (firstRecordIndex + 1) % capacity
        if (droppedRecordCount < Long.MAX_VALUE) {
            droppedRecordCount += 1
        }
    }

    private fun clearRecords() {
        ring.fill(null)
        firstRecordIndex = 0
        recordCount = 0
    }

    companion object {
        const val DEFAULT_CAPACITY = 4_096
    }
}

/**
 * MotionEvent action values needed by the debug trace; numeric values match Android's masked
 * constants.
 */
enum class TouchTraceAction(val maskedValue: Int) {
    DOWN(0),
    UP(1),
    CANCEL(3);

    companion object {
        fun fromMaskedValue(value: Int): TouchTraceAction? = entries.firstOrNull {
            it.maskedValue == value
        }
    }
}

/** Immutable records retained by [TouchTrace]. */
sealed class TouchTraceRecord {
    abstract val sequence: Long

    /** A compact key/value line that the debug receiver emits only after capture stops. */
    fun toLogcatLine(): String =
        when (this) {
            is Touch ->
                "kind=touch sequence=$sequence eventTimeMs=$eventTimeMillis downTimeMs=$downTimeMillis " +
                    "action=${action.name} pressedBefore=$pressedBefore enabled=$enabled focused=$focused " +
                    "inside=$inside shown=$shown"
            is PressedSample ->
                "kind=pressed-sample phase=post-dispatch-next-frame sequence=$sequence " +
                    "inputSequence=$inputSequence sampledAtUptimeMs=$sampledAtUptimeMillis pressed=$pressed"
            is Click ->
                "kind=click sequence=$sequence clickOrdinal=$clickOrdinal " +
                    "storedCounter=${storedCounter ?: "none"} saveSucceeded=$saveSucceeded " +
                    "correlation=${correlation.name.lowercase()} pendingUpCount=$pendingUpCount " +
                    "correlatedUpSequence=${correlatedUpSequence ?: "none"}"
        }

    data class Touch(
        override val sequence: Long,
        val eventTimeMillis: Long,
        val downTimeMillis: Long,
        val action: TouchTraceAction,
        val pressedBefore: Boolean,
        val enabled: Boolean,
        val focused: Boolean,
        val inside: Boolean,
        val shown: Boolean,
    ) : TouchTraceRecord()

    data class PressedSample(
        override val sequence: Long,
        val inputSequence: Long,
        val sampledAtUptimeMillis: Long,
        val pressed: Boolean,
    ) : TouchTraceRecord()

    data class Click(
        override val sequence: Long,
        val clickOrdinal: Long,
        val storedCounter: Int?,
        val saveSucceeded: Boolean,
        val correlation: Correlation,
        val pendingUpCount: Long,
        val correlatedUpSequence: Long?,
    ) : TouchTraceRecord() {
        enum class Correlation {
            UNIQUE_UP,
            AMBIGUOUS,
        }
    }
}

/** One fully drained capture. */
data class TouchTraceDrain(val records: List<TouchTraceRecord>, val droppedRecordCount: Long)

/** Capture-scoped handle that prevents a delayed sample from leaking into a later capture. */
class TouchTraceInputToken
internal constructor(
    val sequence: Long,
    internal val captureToken: Any,
)

/** The shared session controlled by debug broadcasts and observed by the debug Activity hook. */
object DebugTouchTraceSession {
    private val trace = TouchTrace()
    private var captureStateObserver: ((Boolean) -> Unit)? = null

    val isCapturing: Boolean
        get() = trace.isCapturing

    fun setCaptureStateObserver(observer: ((Boolean) -> Unit)?) {
        captureStateObserver = observer
        observer?.invoke(isCapturing)
    }

    fun start(): Int {
        val capacity = trace.start()
        captureStateObserver?.invoke(true)
        return capacity
    }

    fun recordTouch(
        eventTimeMillis: Long,
        downTimeMillis: Long,
        action: Int,
        pressedBefore: Boolean,
        enabled: Boolean,
        focused: Boolean,
        inside: Boolean,
        shown: Boolean,
    ): TouchTraceInputToken? =
        trace.recordTouch(
            eventTimeMillis = eventTimeMillis,
            downTimeMillis = downTimeMillis,
            action = action,
            pressedBefore = pressedBefore,
            enabled = enabled,
            focused = focused,
            inside = inside,
            shown = shown,
        )

    fun recordPostDispatchPressed(
        input: TouchTraceInputToken,
        sampledAtUptimeMillis: Long,
        pressed: Boolean,
    ) = trace.recordPostDispatchPressed(input, sampledAtUptimeMillis, pressed)

    fun recordClick(storedCounter: Int?, saveSucceeded: Boolean) =
        trace.recordClick(storedCounter, saveSucceeded)

    fun stopAndDrain(): TouchTraceDrain {
        val drain = trace.stopAndDrain()
        captureStateObserver?.invoke(false)
        return drain
    }
}

/** Intent actions accepted by the debug-only broadcast receiver. */
object DebugTouchTraceActions {
    const val START = "io.apkrun.fixture.hellotext.debug.TOUCH_TRACE_START"
    const val STOP_AND_DRAIN = "io.apkrun.fixture.hellotext.debug.TOUCH_TRACE_DRAIN"
}
