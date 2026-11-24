/// The state of one buffer of a surface pool (display-and-windowing.md §5.2).
///
/// Only `free` buffers are rendered into. `offered` and `displayed` buffers may be on screen, so they
/// are never overwritten (rule 1).
enum PresentBufferState: Equatable, Sendable {
    case free
    case rendering
    case offered(sequence: UInt64)
    case displayed(sequence: UInt64)
}

/// The states of the buffers of one pool, with the transitions of display-and-windowing.md §5.2.
///
/// The value holds no IOSurface, so the rules can be tested without a GPU. The pool calls it under its lock.
struct PresentBufferStates: Equatable, Sendable {
    private(set) var states: [PresentBufferState]

    /// Creates `bufferCount` free buffers.
    init(bufferCount: Int) {
        states = Array(repeating: .free, count: bufferCount)
    }

    /// The number of buffers in the pool.
    var count: Int {
        states.count
    }

    /// Takes the first free buffer that `isInUse` does not refuse, and marks it `rendering`. Returns `nil` when none is.
    ///
    /// `isInUse` asks the system whether WindowServer still reads the surface (rule 2b). A buffer that is still in use
    /// stays free, and the next acquire tries again.
    mutating func acquire(isInUse: (Int) -> Bool) -> Int? {
        guard
            let index = states.indices.first(where: { index in
                states[index] == .free && !isInUse(index)
            })
        else {
            return nil
        }
        states[index] = .rendering
        return index
    }

    /// The blit of buffer `index` has finished on the GPU, so the frame `sequence` is offered (`rendering` → `offered`).
    ///
    /// Only a `rendering` buffer may be offered. Any other state is left alone, and the caller checks the result.
    @discardableResult
    mutating func markReady(_ index: Int, sequence: UInt64) -> Bool {
        guard states.indices.contains(index), states[index] == .rendering else {
            return false
        }
        states[index] = .offered(sequence: sequence)
        return true
    }

    /// The blit of buffer `index` failed, so the buffer goes back to `free` without an offer.
    @discardableResult
    mutating func abandon(_ index: Int) -> Bool {
        guard states.indices.contains(index), states[index] == .rendering else {
            return false
        }
        states[index] = .free
        return true
    }

    /// The consumer reports that frame `sequence` is displayed.
    ///
    /// The buffer that holds `sequence` becomes `displayed`. Each older `offered` or `displayed` buffer becomes free
    /// (rule 2a). A newer buffer is left alone, and a report for a frame that is not offered changes nothing.
    /// Returns the number of buffers that became free.
    @discardableResult
    mutating func consumerDisplayed(upTo sequence: UInt64) -> Int {
        // An acknowledgement must name a frame that was actually offered. In particular, a future sequence must
        // not release every outstanding buffer.
        guard hasOffered(sequence: sequence) else {
            return 0
        }
        var released = 0
        for index in states.indices {
            switch states[index] {
            case .offered(let offered) where offered == sequence:
                states[index] = .displayed(sequence: offered)
            case .offered(let offered) where offered < sequence, .displayed(let offered) where offered < sequence:
                states[index] = .free
                released += 1
            default:
                break
            }
        }
        return released
    }

    /// True when the consumer has not yet acknowledged any offered frame.
    var hasOfferedBuffers: Bool {
        states.contains { state in
            if case .offered = state { true } else { false }
        }
    }

    /// True when `sequence` belongs to a frame that was offered to the consumer.
    func hasOffered(sequence: UInt64) -> Bool {
        states.contains(.offered(sequence: sequence))
    }

    /// True when some buffer is `free`. It does not check the in-use state, which `acquire` checks.
    var hasFreeBuffer: Bool {
        states.contains(.free)
    }
}

/// The latest-frame policy of one scanout (graphics.md §6.2 rule 1, the RiftVM `LatestFrameScheduler`).
///
/// At most one blit per scanout is in flight. A request that arrives while one is in flight, or while no buffer is
/// free, is held. A newer request replaces the held one, and the replaced frame counts as dropped.
struct LatestFrameScheduler<Request: Sendable>: Sendable {
    /// True from the moment a blit is started until it completes or fails.
    private(set) var isBlitInFlight = false
    /// The newest request that waits for the in-flight blit or for a free buffer.
    private(set) var pending: Request?
    /// Frames replaced before they were presented.
    private(set) var droppedFrames: UInt64 = 0

    /// Offers a request. Returns it when no blit is in flight, so the caller starts it or holds it. Otherwise the
    /// request is held, and it returns `nil`.
    mutating func submit(_ request: Request) -> Request? {
        guard !isBlitInFlight else {
            hold(request)
            return nil
        }
        // A request that starts now supersedes the held one, which would otherwise run after the newest frame.
        if pending != nil {
            droppedFrames &+= 1
            pending = nil
        }
        return request
    }

    /// Holds `request` until a blit can start. A held request that is replaced counts as dropped.
    mutating func hold(_ request: Request) {
        if pending != nil {
            droppedFrames &+= 1
        }
        pending = request
    }

    /// Records that a blit has started, so no other blit starts until `endBlit`.
    mutating func beginBlit() {
        isBlitInFlight = true
    }

    /// Records that the in-flight blit completed or failed.
    mutating func endBlit() {
        isBlitInFlight = false
    }

    /// Removes and returns the held request, when no blit is in flight.
    mutating func takePending() -> Request? {
        guard !isBlitInFlight, let request = pending else {
            return nil
        }
        pending = nil
        return request
    }

    /// Forgets the held request. The guest reset calls it, because the resource it names is no longer bound.
    mutating func discardPending() {
        pending = nil
    }
}

/// Presentation eligibility for one scanout (display-and-windowing.md §5.2, rules 4–5).
///
/// The presenter owns the acknowledgement timer; this value owns the transitions so timeout, visibility, and
/// acknowledgement behavior can be tested without waiting on wall-clock time.
struct PresentBackpressureState: Equatable, Sendable {
    private(set) var isVisible = true
    private(set) var acknowledgementTimedOut = false

    /// A blit may start only while visible and while the consumer is responding.
    var canPresent: Bool {
        isVisible && !acknowledgementTimedOut
    }

    /// Applies a visibility update and returns whether the current resource should be presented again.
    ///
    /// A transition to visible, or a visible update after the acknowledgement watchdog suspended the scanout,
    /// requests one current present. Repeated visible updates do not schedule duplicate work.
    mutating func setVisible(_ visible: Bool) -> Bool {
        let wasPresentable = canPresent
        isVisible = visible
        if visible {
            acknowledgementTimedOut = false
        }
        return visible && !wasPresentable
    }

    /// A valid acknowledgement proves that the consumer is responsive again.
    mutating func frameDisplayed() {
        acknowledgementTimedOut = false
    }

    /// Stops new presents after the caller's one-second outstanding-frame deadline expires.
    mutating func acknowledgementDeadlineExpired() {
        acknowledgementTimedOut = true
    }
}
