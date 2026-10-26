/// Keeps at most one frame event queued for delivery to a window's main actor.
///
/// Call `enqueue` from the XPC callback queue while holding the source's lock. A `true` result means the caller
/// should schedule one main-queue drain. Later frames replace the pending frame until `takePending` is called.
/// Generation changes discard pending frames from an older surface pool.
public struct FrameEventCoalescer: Sendable {
    private var pending: FrameSourceEvent?
    private var deliveryScheduled = false
    private var newestGeneration: UInt64?
    private var newestSequence: UInt64?

    /// Creates an empty event queue.
    public init() {}

    /// Queues an event and returns whether a main-queue delivery should be scheduled.
    public mutating func enqueue(_ event: FrameSourceEvent) -> Bool {
        switch event {
        case .surfacesReplaced(let generation):
            guard generation > (newestGeneration ?? 0) else {
                return false
            }
            newestGeneration = generation
            pending = event
        case .frameReady(let generation, _, let sequence, _):
            guard generation >= (newestGeneration ?? generation) else {
                return false
            }
            if generation > (newestGeneration ?? 0) {
                newestGeneration = generation
            }
            guard sequence > (newestSequence ?? 0) else {
                return false
            }
            newestSequence = sequence
            // A frame in a new generation also tells the window to switch pools; the replacement marker can be
            // coalesced away because FrameSource.surfaceSet(generation:) already exposes the new pool.
            pending = event
        }

        guard !deliveryScheduled else {
            return false
        }
        deliveryScheduled = true
        return true
    }

    /// Takes the newest queued event and re-arms scheduling for the next event.
    public mutating func takePending() -> FrameSourceEvent? {
        defer {
            pending = nil
            deliveryScheduled = false
        }
        return pending
    }
}
