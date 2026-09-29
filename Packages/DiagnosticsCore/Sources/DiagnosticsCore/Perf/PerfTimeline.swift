import Foundation
import Synchronization

/// A typed value attached to a lifecycle performance marker.
public enum PerfValue: Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case boolean(Bool)

    var signpostValue: String {
        switch self {
        case .string(let value):
            String(reflecting: value)
        case .integer(let value):
            String(value)
        case .double(let value):
            String(value)
        case .boolean(let value):
            String(value)
        }
    }
}

/// One in-memory performance marker and the operation active when it was recorded.
public struct PerfEvent: Equatable, Sendable {
    /// The lifecycle marker recorded for this event.
    public let marker: PerfMarker

    /// The monotonic timestamp at which the event occurred.
    public let time: ContinuousClock.Instant

    /// Validated, bounded attributes attached to the event.
    public let attributes: [String: PerfValue]

    /// The operation active when the event was recorded, if any.
    public let operationContext: OperationContext?

    /// Creates a performance event.
    public init(
        marker: PerfMarker,
        time: ContinuousClock.Instant,
        attributes: [String: PerfValue] = [:],
        operationContext: OperationContext? = OperationContext.current
    ) {
        self.marker = marker
        self.time = time
        self.attributes = attributes
        self.operationContext = operationContext
    }
}

/// A thread-safe ring buffer containing the most recent process performance markers.
public final class PerfTimeline: Sendable {
    /// The maximum number of recent events retained in memory.
    public static let capacity = 2_000

    private struct State: Sendable {
        var events = [PerfEvent?](repeating: nil, count: PerfTimeline.capacity)
        var nextIndex = 0
        var count = 0
    }

    private let state = Mutex(State())

    /// Creates an empty, thread-safe event ring buffer.
    public init() {}

    /// Returns the retained events from oldest to newest.
    public func snapshot() -> [PerfEvent] {
        state.withLock { state in
            guard state.count > 0 else {
                return []
            }
            let oldestIndex = state.count == Self.capacity ? state.nextIndex : 0
            return (0..<state.count).compactMap { offset in
                state.events[(oldestIndex + offset) % Self.capacity]
            }
        }
    }

    func append(_ event: PerfEvent) {
        state.withLock { state in
            state.events[state.nextIndex] = event
            state.nextIndex = (state.nextIndex + 1) % Self.capacity
            state.count = min(state.count + 1, Self.capacity)
        }
    }
}
