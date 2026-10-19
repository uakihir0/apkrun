import DiagnosticsCore
import Foundation
import Testing

@testable import RuntimeCore

@Test
func bootProgressUsesEqualPhaseWeightsWithoutHistory() {
    var estimator = BootProgressEstimator(bootKind: "cold", history: [])

    #expect(estimator.fraction(phase: .kernel, elapsedSinceStart: .seconds(1)) == 0.2)
    #expect(estimator.fraction(phase: .`init`, elapsedSinceStart: .seconds(2)) == 0.4)
    #expect(estimator.fraction(phase: .systemServer, elapsedSinceStart: .seconds(3)) == 0.6)
    #expect(estimator.fraction(phase: .bootCompleted, elapsedSinceStart: .seconds(4)) == 0.8)
    #expect(estimator.fraction(phase: .agentsConnecting, elapsedSinceStart: .seconds(5)) == 0.95)
    #expect(
        estimator.fraction(phase: .agentsConnecting, elapsedSinceStart: .seconds(5), runtimeReady: true)
            == 1
    )
}

@Test
func bootProgressUsesTheMedianOfTheFiveNewestSuccessfulMatchingBoots() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let history = [
        progressRecord(recordedAt: now, readyMilliseconds: 10_000, kernelStartMilliseconds: 1_000),
        progressRecord(
            recordedAt: now.addingTimeInterval(1),
            readyMilliseconds: 20_000,
            kernelStartMilliseconds: 2_000
        ),
        progressRecord(
            recordedAt: now.addingTimeInterval(2),
            readyMilliseconds: 30_000,
            kernelStartMilliseconds: 3_000
        ),
        progressRecord(
            recordedAt: now.addingTimeInterval(3),
            readyMilliseconds: 40_000,
            kernelStartMilliseconds: 4_000
        ),
        progressRecord(
            recordedAt: now.addingTimeInterval(4),
            readyMilliseconds: 50_000,
            kernelStartMilliseconds: 5_000
        ),
        progressRecord(
            recordedAt: now.addingTimeInterval(5),
            readyMilliseconds: 60_000,
            kernelStartMilliseconds: 6_000
        ),
        progressRecord(
            recordedAt: now.addingTimeInterval(6),
            bootKind: "firstBoot",
            readyMilliseconds: 900_000,
            kernelStartMilliseconds: 900_000
        ),
        progressRecord(
            recordedAt: now.addingTimeInterval(7),
            readyMilliseconds: 900_000,
            kernelStartMilliseconds: 900_000,
            outcome: "failed:bootTimedOut"
        ),
    ]
    var estimator = BootProgressEstimator(bootKind: "cold", history: history)

    let estimate = estimator.fraction(phase: .kernel, elapsedSinceStart: .seconds(20))

    // The newest five matching successful ready times are 20–60 s, whose median is 40 s.
    #expect(estimate == 0.5)
}

@Test
func bootProgressUsesTheCurrentPhaseMarkerAsAProgressFloor() {
    let record = progressRecord(
        recordedAt: Date(timeIntervalSince1970: 1_800_000_000),
        readyMilliseconds: 10_000,
        kernelStartMilliseconds: 4_000
    )
    var estimator = BootProgressEstimator(bootKind: "cold", history: [record])

    let estimate = estimator.fraction(phase: .kernel, elapsedSinceStart: .zero)

    #expect(estimate == 0.4)
}

@Test
func bootProgressNeverExceedsNinetyFivePercentBeforeReadyOrRegresses() {
    let record = progressRecord(
        recordedAt: Date(timeIntervalSince1970: 1_800_000_000),
        readyMilliseconds: 10_000,
        kernelStartMilliseconds: 1_000
    )
    var estimator = BootProgressEstimator(bootKind: "cold", history: [record])

    let delayedBoot = estimator.fraction(phase: .agentsConnecting, elapsedSinceStart: .seconds(60))
    let stalePhase = estimator.fraction(phase: .kernel, elapsedSinceStart: .seconds(1))
    let ready = estimator.fraction(phase: .agentsConnecting, elapsedSinceStart: .seconds(60), runtimeReady: true)

    #expect(delayedBoot == BootProgressEstimator.preReadyMaximum)
    #expect(stalePhase == delayedBoot)
    #expect(ready == 1)
}

private func progressRecord(
    recordedAt: Date,
    bootKind: String = "cold",
    readyMilliseconds: Double,
    kernelStartMilliseconds: Double,
    outcome: String = "ready"
) -> BootRecord {
    BootRecord(
        recordedAt: recordedAt,
        operationID: UUID(uuidString: "3F9A1C2E-0000-4000-8000-000000000001")!,
        bootKind: bootKind,
        image: "2026.10.0-cf16373615-arm64",
        gpuProfile: "headless",
        memoryGiB: 4,
        cpuCount: 4,
        markers: [
            PerfMarker.vmStart.rawValue: 0,
            PerfMarker.kernelStart.rawValue: kernelStartMilliseconds,
            PerfMarker.runtimeReady.rawValue: readyMilliseconds,
        ],
        outcome: outcome
    )
}
