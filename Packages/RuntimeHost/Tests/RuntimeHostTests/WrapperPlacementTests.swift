import DiagnosticsCore
import Foundation
import RuntimeAPI
import Testing
import WrapperCore

@testable import RuntimeHost

private func placementDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-placement-tests-\(UUID().uuidString)", isDirectory: true)
}

// MARK: - T1: placeStagedWrapper (wrapper.md §6.3, runtime-api.md §10.3)

@Test func placeStagedWrapperRejectsAnUnknownToken() async throws {
    let root = placementDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": root.path]
    )
    let host = RuntimeHost(paths: paths)

    do {
        _ = try await host.placeStagedWrapper(
            stagingToken: "nope",
            finalURL: root.appendingPathComponent("HelloText.app"),
            bookmark: nil
        )
        Issue.record("placeStagedWrapper must reject an unknown token")
    } catch let failure as RuntimeWireError {
        #expect(failure.code == "wrapper.stagingExpired")
    }
}

@Test func placeStagedWrapperExpiresAStaleStagingEntry() async throws {
    let root = placementDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": root.path]
    )
    let host = RuntimeHost(paths: paths)
    let registry = await host.wrapperRegistryInstance()
    var entry = WrapperRegistryEntry(
        bundleId: "io.apkrun.android.io.apkrun.fixture.hellotext",
        packageId: "io.apkrun.fixture.hellotext",
        kind: .local,
        state: .pending,
        path: root.appendingPathComponent("HelloText.app").path,
        cdhash: "cd",
        launcherVersion: "0.1.0",
        launcherAPI: "1.0",
        fileName: "HelloText",
        displayName: "HelloText",
        createdAt: Date()
    )
    // The bundle is gone (cleanup ran or the dir vanished): the token is
    // dead even though the registry entry is still pending.
    entry.stagingPath =
        paths.wrapperStagingDirectory(identifier: "tok")
        .appendingPathComponent("HelloText.app").path
    try await registry.markPending(entry)

    do {
        _ = try await host.placeStagedWrapper(
            stagingToken: "tok",
            finalURL: root.appendingPathComponent("HelloText.app"),
            bookmark: nil
        )
        Issue.record("placeStagedWrapper must expire a token with no staged bundle")
    } catch let failure as RuntimeWireError {
        #expect(failure.code == "wrapper.stagingExpired")
    }
}

@Test func placeStagedWrapperRejectsAMismatchedBundle() async throws {
    let root = placementDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": root.path]
    )
    let host = RuntimeHost(paths: paths)
    let registry = await host.wrapperRegistryInstance()

    // A real staged bundle exists so the token stays alive.
    let staged = paths.wrapperStagingDirectory(identifier: "tok")
        .appendingPathComponent("HelloText.app")
    try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)

    var entry = WrapperRegistryEntry(
        bundleId: "io.apkrun.android.io.apkrun.fixture.hellotext",
        packageId: "io.apkrun.fixture.hellotext",
        kind: .local,
        state: .pending,
        path: root.appendingPathComponent("HelloText.app").path,
        cdhash: "cd",
        launcherVersion: "0.1.0",
        launcherAPI: "1.0",
        fileName: "HelloText",
        displayName: "HelloText",
        createdAt: Date()
    )
    entry.stagingPath = staged.path
    try await registry.markPending(entry)

    // The final bundle does not exist where the client claims it is.
    do {
        _ = try await host.placeStagedWrapper(
            stagingToken: "tok",
            finalURL: root.appendingPathComponent("HelloText.app"),
            bookmark: nil
        )
        Issue.record("placeStagedWrapper must reject a missing final bundle")
    } catch let failure as RuntimeWireError {
        #expect(failure.code == "wrapper.bundleInvalid")
    }
}
