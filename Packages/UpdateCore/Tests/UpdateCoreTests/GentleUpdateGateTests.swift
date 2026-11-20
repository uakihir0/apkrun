import APKStoreCore
import Foundation
import RuntimeAPI
import Testing

@testable import UpdateCore

/// T1: §7.1 GU1–GU7 each false alone, the §7.2 queue order, and admission
/// (update-system.md §7; manual clock).
struct GentleUpdateGateTests {
    final class FakeRuntime: UpdateRuntimeAccess, @unchecked Sendable {
        var state: WireRuntimeState = .ready
        var inUse = false
        var lastEnd: ContinuousClock.Instant? = nil
        var androidOK = true

        var runtimeState: WireRuntimeState { state }
        var runtimeEvents: AsyncStream<UpdateRuntimeEvent> {
            AsyncStream { _ in }
        }
        func hasActiveUse(_ packageID: PackageID) async -> Bool { inUse }
        func lastSessionEnd(_ packageID: PackageID) async -> ContinuousClock.Instant? { lastEnd }
        func androidAllowsGentleInstall(_ packageID: PackageID) async -> Bool { androidOK }
        func ensureReady(_ reason: UpdateStartReason) async throws {}
        func endSessions(for packageID: PackageID, reason: UpdateSessionEndReason) async {}
        func reopen(_ packageID: PackageID) async {}
        func assertStoreOperation() async -> UpdateActivityAssertion {
            UpdateActivityAssertion()
        }
    }

    final class Clock: @unchecked Sendable {
        var instant = ContinuousClock.now
        func now() -> ContinuousClock.Instant { instant }
    }

    final class Flags: @unchecked Sendable {
        var storeBusy = false
        var needsSlot = true
        var slotFree = true
    }

    let runtime = FakeRuntime()
    let clock = Clock()
    let flags = Flags()

    func makeGate() -> GentleUpdateGate {
        let flags = flags
        return GentleUpdateGate(
            runtime: runtime,
            storeBusy: { _ in flags.storeBusy },
            requiresDisplaySlot: { _ in flags.needsSlot },
            displaySlotFree: { flags.slotFree },
            quietPeriod: .seconds(15),
            now: clock.now)
    }

    static let packageA = PackageID(rawValue: "io.apkrun.fixture.helloupdate")!
    static let packageB = PackageID(rawValue: "io.apkrun.fixture.hellotext")!
    static let packageC = PackageID(rawValue: "io.apkrun.fixture.helloaudio")!

    @Test func allConditionsPassOpens() async throws {
        let gate = makeGate()
        let evaluation = await gate.evaluate(Self.packageA)
        #expect(evaluation.isOpen)
        #expect(evaluation.blocks.isEmpty)
    }

    @Test func gu1BlocksUnlessReady() async throws {
        let gate = makeGate()
        runtime.state = .booting(.systemServer)
        #expect(await gate.evaluate(Self.packageA).blocks == [.runtimeNotReady])
        runtime.state = .stopped
        #expect(await gate.evaluate(Self.packageA).blocks == [.runtimeNotReady])
        // Suspended counts as ready only for a user-initiated update (§7.3).
        runtime.state = .suspended
        #expect(await gate.evaluate(Self.packageA).blocks == [.runtimeNotReady])
        #expect(await gate.evaluate(Self.packageA, userInitiated: true).isOpen)
    }

    @Test func gu2gu3BlockWhileInUse() async throws {
        let gate = makeGate()
        runtime.inUse = true
        #expect(await gate.evaluate(Self.packageA).blocks == [.packageInUse])
    }

    @Test func gu4BlocksInsideTheQuietPeriod() async throws {
        let gate = makeGate()
        runtime.lastEnd = clock.instant - .seconds(5)
        #expect(await gate.evaluate(Self.packageA).blocks == [.sessionEndedRecently])
        runtime.lastEnd = clock.instant - .seconds(16)
        #expect(await gate.evaluate(Self.packageA).isOpen)
        runtime.lastEnd = nil
        #expect(await gate.evaluate(Self.packageA).isOpen)
    }

    @Test func gu5BlocksUnlessUserInitiated() async throws {
        let gate = makeGate()
        runtime.androidOK = false
        #expect(await gate.evaluate(Self.packageA).blocks == [.androidBusy])
        #expect(await gate.evaluate(Self.packageA, userInitiated: true).isOpen)
    }

    @Test func gu6BlocksOnStoreTransaction() async throws {
        flags.storeBusy = true
        defer { flags.storeBusy = false }
        let gate = makeGate()
        #expect(await gate.evaluate(Self.packageA).blocks == [.storeTransactionActive])
    }

    @Test func gu7BlocksWithoutADisplaySlot() async throws {
        let gate = makeGate()
        flags.slotFree = false
        #expect(await gate.evaluate(Self.packageA).blocks == [.noDisplaySlot])
        flags.needsSlot = false
        #expect(await gate.evaluate(Self.packageA).isOpen)
    }

    @Test func requestInstallAdmitsOrQueues() async throws {
        let gate = makeGate()
        #expect(await gate.requestInstall(Self.packageA))
        #expect(await gate.isWaiting(Self.packageA))
        // A second package queues behind the running install.
        #expect(await gate.requestInstall(Self.packageB) == false)
        // Finishing admits the queued install next.
        #expect(await gate.finishInstall(Self.packageA) == Self.packageB)
        #expect(await gate.isWaiting(Self.packageB))
        #expect(await gate.isWaiting(Self.packageA) == false)
    }

    @Test func queuePutsUserInitiatedFirstThenLongestWaiting() async throws {
        let gate = makeGate()
        // Block every package so each request queues.
        runtime.inUse = true
        #expect(await gate.requestInstall(Self.packageA) == false)
        clock.instant += .seconds(1)
        #expect(await gate.requestInstall(Self.packageB) == false)
        clock.instant += .seconds(1)
        #expect(await gate.requestInstall(Self.packageC, userInitiated: true) == false)

        runtime.inUse = false
        // User-initiated goes first even though it queued last.
        #expect(await gate.nextReadyPackage() == Self.packageC)
        // Then longest waiting wins.
        #expect(await gate.finishInstall(Self.packageC) == Self.packageA)
        #expect(await gate.finishInstall(Self.packageA) == Self.packageB)
        #expect(await gate.finishInstall(Self.packageB) == nil)
    }

    @Test func triggerReevaluatesAClosedGate() async throws {
        let gate = makeGate()
        runtime.inUse = true
        #expect(await gate.requestInstall(Self.packageA) == false)
        #expect(await gate.nextReadyPackage() == nil)
        runtime.inUse = false
        #expect(await gate.nextReadyPackage() == Self.packageA)
    }

    @Test func waitingReasonsReportLastEvaluation() async throws {
        let gate = makeGate()
        runtime.state = .booting(.systemServer)
        runtime.inUse = true
        _ = await gate.evaluate(Self.packageA)
        #expect(await gate.waitingReasons(Self.packageA) == [.runtimeNotReady, .packageInUse])
        runtime.state = .ready
        runtime.inUse = false
        _ = await gate.evaluate(Self.packageA)
        #expect(await gate.waitingReasons(Self.packageA).isEmpty)
    }
}
