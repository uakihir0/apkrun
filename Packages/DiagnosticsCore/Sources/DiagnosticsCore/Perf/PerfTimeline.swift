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
        case let .string(value):
            String(reflecting: value)
        case let .integer(value):
            String(value)
        case let .double(value):
            String(value)
        case let .boolean(value):
            String(value)
        }
    }
}

/// One in-memory performance marker and the operation active when it was recorded.
public struct PerfEvent: Equatable, Sendable {
    public let marker: PerfMarker
    public let time: ContinuousClock.Instant
    public let attributes: [String: PerfValue]
    public let operationContext: OperationContext?

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
    public static let capacity = 2_000

    private struct State: Sendable {
        var events = [PerfEvent?](repeating: nil, count: PerfTimeline.capacity)
        var nextIndex = 0
        var count = 0
    }

    private let state = Mutex(State())

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
