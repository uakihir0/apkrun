import DiagnosticsCore
import Foundation

/// Estimates boot progress from recent boots of the same kind (runtime-daemon.md §3.3).
///
/// With history, the estimate compares boot elapsed time and the current phase's cumulative marker
/// time to the median `RUNTIME_READY` time. Without usable history, each phase receives an equal
/// share. In either mode, progress is monotonic and stays at or below 95% until the runtime is ready.
public struct BootProgressEstimator: Sendable {
    /// Maximum progress shown before the runtime is ready.
    public static let preReadyMaximum = 0.95

    private static let historyLimit = 5
    private static let phaseMarkers: [BootPhase: PerfMarker] = [
        .kernel: .kernelStart,
        .`init`: .androidInit,
        .systemServer: .systemServerReady,
        .bootCompleted: .bootCompleted,
        .agentsConnecting: .agentConnected,
    ]

    private let medianReadyMilliseconds: Double?
    private let medianPhaseMilliseconds: [BootPhase: Double]
    private var lastEstimate = 0.0

    /// Creates an estimator from the five newest successful boots with this `bootKind`.
    ///
    /// Records for another kind and unsuccessful boots do not affect the estimate.
    public init(bootKind: String, history: [BootRecord]) {
        let relevantHistory =
            history
            .filter { $0.bootKind == bootKind && $0.outcome == "ready" }
            .sorted { $0.recordedAt < $1.recordedAt }
            .suffix(Self.historyLimit)

        let readyTimes = relevantHistory.compactMap {
            Self.validMarker(.runtimeReady, in: $0)
        }
        medianReadyMilliseconds = Self.median(readyTimes)

        var phaseTimes: [BootPhase: [Double]] = [:]
        for record in relevantHistory {
            for (phase, marker) in Self.phaseMarkers {
                guard let milliseconds = Self.validMarker(marker, in: record) else {
                    continue
                }
                phaseTimes[phase, default: []].append(milliseconds)
            }
        }
        medianPhaseMilliseconds = phaseTimes.compactMapValues(Self.median)
    }

    /// Returns a monotonic progress fraction for a phase and elapsed time since `VM_START`.
    ///
    /// Without history, the current phase selects an equal-weight step. With history, progress
    /// follows elapsed boot time normalized against the median runtime-ready time and never falls
    /// behind the median timestamp of the current phase. Pass `runtimeReady: true` on the ready
    /// transition to return `1.0`.
    public mutating func fraction(
        phase: BootPhase,
        elapsedSinceStart: Duration,
        runtimeReady: Bool = false
    ) -> Double {
        if runtimeReady {
            lastEstimate = 1
            return lastEstimate
        }

        let estimate: Double
        if let medianReadyMilliseconds, medianReadyMilliseconds > 0 {
            let elapsedFraction = Self.milliseconds(elapsedSinceStart) / medianReadyMilliseconds
            let phaseFraction =
                medianPhaseMilliseconds[phase]
                .map { $0 / medianReadyMilliseconds }
                ?? Self.equalPhaseWeight(for: phase)
            estimate = max(elapsedFraction, phaseFraction)
        } else {
            estimate = Self.equalPhaseWeight(for: phase)
        }

        lastEstimate = max(lastEstimate, min(max(estimate, 0), Self.preReadyMaximum))
        return lastEstimate
    }

    private static func equalPhaseWeight(for phase: BootPhase) -> Double {
        Double(phase.rawValue + 1) / Double(BootPhase.orderedCases.count)
    }

    private static func validMarker(_ marker: PerfMarker, in record: BootRecord) -> Double? {
        guard let value = record.markers[marker.rawValue], value.isFinite, value >= 0 else {
            return nil
        }
        return value
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else {
            return nil
        }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return sorted[middle - 1] / 2 + sorted[middle] / 2
        }
        return sorted[middle]
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

extension BootPhase {
    fileprivate static let orderedCases: [BootPhase] = [
        .kernel,
        .`init`,
        .systemServer,
        .bootCompleted,
        .agentsConnecting,
    ]
}
