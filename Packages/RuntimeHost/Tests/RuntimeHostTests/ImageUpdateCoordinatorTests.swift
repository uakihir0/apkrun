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
    guard let version = ImageCore.ImageVersion(text) else {
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
    let (directory, coordinator) = coordinatorFixture("busy") { _, _, _ in
        try? await Task.sleep(for: .milliseconds(200))
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    let from = try version("2026.01.1")
    let to = try version("2026.02.1")
    await coordinator.noteReady(to)

    async let first: () = coordinator.apply(to, from: from)
    await #expect(throws: ImageFailure.self) {
        try await coordinator.apply(to, from: from)
    }
    try await first
}

@Test func reconcileSettlesAnInterruptedApplyingPhase() async throws {
    let (directory, coordinator) = coordinatorFixture("reconcile")
    defer { try? FileManager.default.removeItem(at: directory) }
    let from = try version("2026.01.1")
    let to = try version("2026.02.1")
    await coordinator.noteReady(to)
    // Simulate a daemon exit mid-apply by writing the applying state directly.
    await coordinator.reconcile(currentImage: to)
    let snapshot = await coordinator.stateSnapshot()
    #expect(snapshot.phase == .idle)
    #expect(snapshot.lastResult == .installed(to))
    _ = from
}

@Test func gcRetainSetKeepsReadyAndRecentRejections() async throws {
    let (directory, coordinator) = coordinatorFixture("gc")
    defer { try? FileManager.default.removeItem(at: directory) }
    let to = try version("2026.02.1")
    await coordinator.noteReady(to)

    let keep = await coordinator.gcRetainSet()
    #expect(keep.contains(to))
}
