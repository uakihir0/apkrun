import Foundation
import Synchronization

/// One input-latency histogram of a measured segment (diagnostics.md §9.3).
public struct LatencyHistogram: Equatable, Sendable {
    /// The measured segment: `input.translate` or `input.route`.
    public let segment: String
    /// The upper bound of each bucket in microseconds; the last bucket is open-ended.
    public let boundsUs: [Int64]
    /// The sample count in each bucket.
    public let counts: [Int64]
}

/// Records host-side input-segment durations for `perfStatistics` (diagnostics.md §9.3).
///
/// `input.translate` is measured where NSEvents become guest `InputEvent`s (InputCore
/// translators) and `input.route` where batches enter the guest input stream
/// (`InputRouter.route`). Both land in the process that runs them; apkrund reports the
/// histograms it accumulated. The recorder keeps bounded state only — no timestamps, no
/// event content.
public final class InputLatencyRecorder: Sendable {
    /// The process-wide recorder used by the translators and the input router.
    public static let shared = InputLatencyRecorder()

    /// The bucket upper bounds, in microseconds; the last count is the open-ended bucket.
    public static let boundsUs: [Int64] = [
        64, 128, 256, 512, 1_024, 2_048, 4_096, 8_192, 16_384, 32_768, 65_536, 131_072,
        262_144, 524_288, 1_048_576,
    ]

    private struct State: Sendable {
        var counts: [String: [Int64]] = [:]
    }

    private let state = Mutex(State())

    /// Creates an empty recorder.
    public init() {}

    /// Records one measured duration of `segment`.
    public func record(segment: String, microseconds: Int64) {
        let bucket: Int
        if let index = Self.boundsUs.firstIndex(where: { microseconds < $0 }) {
            bucket = index
        } else {
            bucket = Self.boundsUs.count
        }
        state.withLock { state in
            var counts = state.counts[segment] ?? [Int64](repeating: 0, count: Self.boundsUs.count + 1)
            counts[bucket] += 1
            state.counts[segment] = counts
        }
    }

    /// The histograms accumulated since the last `reset`, sorted by segment name.
    public func histograms() -> [LatencyHistogram] {
        state.withLock { state in
            state.counts.keys.sorted().map { segment in
                LatencyHistogram(
                    segment: segment,
                    boundsUs: Self.boundsUs,
                    counts: state.counts[segment] ?? [])
            }
        }
    }

    /// Clears every histogram.
    public func reset() {
        state.withLock { state in
            state.counts = [:]
        }
    }
}
