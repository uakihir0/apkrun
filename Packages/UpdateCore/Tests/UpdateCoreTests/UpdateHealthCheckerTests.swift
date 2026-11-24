import Foundation
import Testing

@testable import APKStoreCore
@testable import UpdateCore

// T0 of #44: level choice (§8.1), the H1–H4 sequence, and per-step failure
// mapping of UpdateHealthChecker.

private let packageID = PackageID(rawValue: "io.apkrun.fixture.helloupdate")!

private func info(_ versionCode: VersionCode, signers: [SHA256Digest] = []) -> StorePackageInfo {
    StorePackageInfo(
        packageID: packageID,
        displayName: "HelloUpdate",
        versionCode: versionCode,
        enabled: true,
        targetSDK: 37,
        minSDK: 29,
        signingDigests: signers)
}

/// A Sendable clock that advances a fixed step per call.
private final class TestClock: @unchecked Sendable {
    private var value: ContinuousClock.Instant
    private let step: Duration

    init(start: ContinuousClock.Instant, step: Duration) {
        value = start
        self.step = step
    }

    func next() -> ContinuousClock.Instant {
        defer { value += step }
        return value
    }
}

private func checker(
    infos: [StorePackageInfo?],
    launch: @escaping @Sendable (PackageID, UpdateHealthCheckTimeouts) async -> HealthLaunchResult
) -> UpdateHealthChecker {
    return UpdateHealthChecker(
        installedInfo: { _ in infos.first ?? nil },
        launch: launch,
        sleep: { _ in })
}

// Level: no launcher or the setting off → versionOnly; an app that has
// never produced a first frame can only do processOnly (§8.1).
@Test func healthCheckLevelChoice() {
    #expect(
        HealthCheckLevel.level(
            hasLauncherActivity: false,
            healthCheckLaunchEnabled: true,
            hasProducedFrame: false) == .versionOnly)
    #expect(
        HealthCheckLevel.level(
            hasLauncherActivity: true,
            healthCheckLaunchEnabled: false,
            hasProducedFrame: false) == .versionOnly)
    #expect(
        HealthCheckLevel.level(
            hasLauncherActivity: true,
            healthCheckLaunchEnabled: true,
            hasProducedFrame: false) == .processOnly)
    #expect(
        HealthCheckLevel.level(
            hasLauncherActivity: true,
            healthCheckLaunchEnabled: true,
            hasProducedFrame: true) == .full)
}

// H1 pass at versionOnly ends the check without a launch.
@Test func healthCheckPassesAtVersionOnly() async {
    let result = await checker(
        infos: [info(2, signers: [SHA256Digest(hex: String(repeating: "a", count: 64))!])],
        launch: { _, _ in
            Issue.record("no launch at versionOnly")
            return .abandoned
        }
    ).run(
        packageID,
        expectedVersionCode: 2,
        expectedSigners: Set([SHA256Digest(hex: String(repeating: "a", count: 64))!]),
        level: .versionOnly,
        timeouts: UpdateHealthCheckTimeouts())
    #expect(result == nil)
}

// H1 never reports the version → versionNotConfirmed.
@Test func healthCheckVersionNotConfirmed() async {
    let clock = TestClock(start: ContinuousClock.now, step: .seconds(1))
    let result = await UpdateHealthChecker(
        installedInfo: { _ in info(1) },
        launch: { _, _ in .frameDrawn },
        now: { clock.next() },
        sleep: { _ in }
    ).run(
        packageID,
        expectedVersionCode: 2,
        expectedSigners: [],
        level: .versionOnly,
        timeouts: UpdateHealthCheckTimeouts(metadata: .seconds(30)))
    guard case .versionNotConfirmed(let found) = result else {
        Issue.record("expected versionNotConfirmed, got \(String(describing: result))")
        return
    }
    #expect(found == 1)
    #expect(result?.step == "H1")
}

// A launch failure maps to .launchFailed; a drawn frame passes at .full.
@Test func healthCheckLaunchFailuresAndFrame() async {
    let failure = await checker(
        infos: [info(2)],
        launch: { _, _ in .launchFailed(detail: "noDisplay") }
    ).run(
        packageID, expectedVersionCode: 2, expectedSigners: [],
        level: .full, timeouts: UpdateHealthCheckTimeouts())
    #expect(failure == .launchFailed(detail: "noDisplay"))
    #expect(failure?.step == "H2")

    let pass = await checker(
        infos: [info(2)],
        launch: { _, _ in .frameDrawn }
    ).run(
        packageID, expectedVersionCode: 2, expectedSigners: [],
        level: .full, timeouts: UpdateHealthCheckTimeouts())
    #expect(pass == nil)
}

// processAlive at .full fails H4; at .processOnly it passes.
@Test func healthCheckFrameOnlyRequiredAtFull() async {
    let atFull = await checker(
        infos: [info(2)],
        launch: { _, _ in .processAlive }
    ).run(
        packageID, expectedVersionCode: 2, expectedSigners: [],
        level: .full, timeouts: UpdateHealthCheckTimeouts())
    #expect(atFull == .frameNotDrawn)
    #expect(atFull?.step == "H4")

    let processOnly = await checker(
        infos: [info(2)],
        launch: { _, _ in .processAlive }
    ).run(
        packageID, expectedVersionCode: 2, expectedSigners: [],
        level: .processOnly, timeouts: UpdateHealthCheckTimeouts())
    #expect(processOnly == nil)
}
