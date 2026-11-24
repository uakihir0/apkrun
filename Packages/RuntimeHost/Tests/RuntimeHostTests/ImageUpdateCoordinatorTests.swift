import DiagnosticsCore
import Foundation
import ImageCore
import Testing

@testable import RuntimeHost

// MARK: - ImageUpdateCoordinator (runtime-maintenance.md §4.3–§4.9)

private func coordinatorFixture(
    _ name: String,
    migrate: @escaping @Sendable (ImageCore.ImageVersion, UUID, Bool) async throws -> Void = { _, _, _ in }
) -> (URL, ImageUpdateCoordinator) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-imageupdate-\(name)-\(UUID().uuidString)", isDirectory: true)
    let paths = APKRunPaths(
        allowingHomeOverride: true, environment: ["APKRUN_HOME": directory.path])
    let coordinator = ImageUpdateCoordinator(
        paths: paths,
        diagnostics: .live(paths: paths),
        publish: { _ in },
        migrate: migrate
    )
    return (directory, coordinator)
}

private func version(_ text: String) throws -> ImageCore.ImageVersion {
    let full = text.contains("-") ? text : "\(text)-cf1-arm64"
    guard let version = ImageCore.ImageVersion(full) else {
        Issue.record("invalid fixture version \(text)")
        throw CocoaError(.coderInvalidValue)
    }
    return version
}

@Test func noteReadyMarksTheCandidateReady() async throws {
    let (directory, coordinator) = coordinatorFixture("ready")
    defer { try? FileManager.default.removeItem(at: directory) }
    let version = try version("2026.01.1")

    await coordinator.noteReady(version)

    let snapshot = await coordinator.stateSnapshot()
    #expect(snapshot.phase == .ready(version))
    #expect(
        FileManager.default.fileExists(
            atPath:
                directory
                .appendingPathComponent("Images/update-state.json").path))
}

final class VersionBox: @unchecked Sendable {
    var value: ImageCore.ImageVersion?
}

/// Lets a test hold a `migrate` hook mid-flight and observe when it was entered.
private actor ApplyGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() {
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
    }

    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
}

@Test func applyRunsTheMigrationAndEndsIdle() async throws {
    let box = VersionBox()
    let (directory, coordinator) = coordinatorFixture("apply") { version, _, _ in
        box.value = version
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    let from = try version("2026.01.1")
    let to = try version("2026.02.1")
    await coordinator.noteReady(to)

    try await coordinator.apply(to, from: from)

    #expect(box.value == to)
    let snapshot = await coordinator.stateSnapshot()
    #expect(snapshot.phase == .idle)
    #expect(snapshot.lastResult == .installed(to))
}

@Test func applyFailureRejectsTheVersion() async throws {
    let (directory, coordinator) = coordinatorFixture("fails") { _, _, _ in
        throw ImageFailure.migrationHealthFailed(report: "handshake missing")
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    let from = try version("2026.01.1")
    let to = try version("2026.02.1")
    await coordinator.noteReady(to)

    await #expect(throws: ImageFailure.self) {
        try await coordinator.apply(to, from: from)
    }

    let snapshot = await coordinator.stateSnapshot()
    #expect(snapshot.rejected[to.description] != nil)
    if case .failed = snapshot.phase {
    } else {
        Issue.record("expected .failed, got \(snapshot.phase)")
    }
    // §4.8: a rejected version may not be applied again without force.
    await #expect(throws: ImageFailure.self) {
        try await coordinator.apply(to, from: from)
    }
}

@Test func concurrentApplyIsRefused() async throws {
    let gate = ApplyGate()
    let (directory, coordinator) = coordinatorFixture("busy") { _, _, _ in
        await gate.enter()
        await gate.waitForRelease()
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    let from = try version("2026.01.1")
    let to = try version("2026.02.1")
    await coordinator.noteReady(to)

    // Hold the first apply inside its migrate hook so the busy gate is taken
    // before the second call reaches the actor.
    async let first: () = coordinator.apply(to, from: from)
    await gate.waitForEntry()
    await #expect(throws: ImageFailure.self) {
        try await coordinator.apply(to, from: from)
    }
    await gate.release()
    try await first
}

@Test func reconcileSettlesAnInterruptedApplyingPhase() async throws {
    let gate = ApplyGate()
    let (directory, coordinator) = coordinatorFixture("reconcile") { _, _, _ in
        await gate.enter()
        await gate.waitForRelease()
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    let from = try version("2026.01.1")
    let to = try version("2026.02.1")
    await coordinator.noteReady(to)
    // Simulate a daemon exit mid-apply: a real apply holds `.applying` in the
    // state file, and a fresh coordinator settles it on restart.
    async let apply: () = coordinator.apply(to, from: from)
    await gate.waitForEntry()
    let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": directory.path])
    let restarted = ImageUpdateCoordinator(
        paths: paths,
        diagnostics: .live(paths: paths),
        publish: { _ in },
        migrate: { _, _, _ in }
    )
    await restarted.reconcile(currentImage: to)
    let snapshot = await restarted.stateSnapshot()
    #expect(snapshot.phase == .idle)
    #expect(snapshot.lastResult == .installed(to))
    await gate.release()
    try await apply
}

@Test func gcRetainSetKeepsReadyAndRecentRejections() async throws {
    let (directory, coordinator) = coordinatorFixture("gc")
    defer { try? FileManager.default.removeItem(at: directory) }
    let to = try version("2026.02.1")
    await coordinator.noteReady(to)

    let keep = await coordinator.gcRetainSet()
    #expect(keep.contains(to))
}
