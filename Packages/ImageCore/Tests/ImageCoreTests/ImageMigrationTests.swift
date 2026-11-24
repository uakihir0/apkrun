import AppleArchive
import DiagnosticsCore
import Foundation
import System
import Testing

@testable import ImageCore

/// A temporary APKRUN_HOME plus an installed image pair, for migration tests.
private struct MigrationSandbox {
    let root: URL
    let paths: APKRunPaths

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-059-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
    }

    func remove() {
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in walker {
                let mode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
                try? FileManager.default.setAttributes(
                    [.posixPermissions: (mode?.intValue ?? 0o644) | 0o200], ofItemAtPath: url.path
                )
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    var images: ImageStore {
        ImageStore(paths: paths, trust: testImageTrust, diagnostics: .live(paths: paths))
    }

    var instances: InstanceStore {
        InstanceStore(paths: paths, diagnostics: .testing())
    }

    var service: ImageMigrationService {
        ImageMigrationService(store: instances, diagnostics: .testing())
    }

    func bundle(_ name: String, version: String) throws -> URL {
        try SignedBundleFixture.write(
            to: root.appendingPathComponent("source-\(name)", isDirectory: true),
            version: version
        )
    }
}

private let oldVersion = "2026.10.0-cf1-arm64"
private let newVersion = "2026.10.1-cf1-arm64"

private func installPair(_ sandbox: MigrationSandbox) async throws -> (InstalledImage, InstalledImage) {
    let store = sandbox.images
    let source = try await store.install(from: .directory(try sandbox.bundle("a", version: oldVersion)))
    let target = try await store.install(from: .directory(try sandbox.bundle("b", version: newVersion)))
    return (source, target)
}

@Test
func checkAllowedAcceptsAMatchingUpgrade() async throws {
    let sandbox = try MigrationSandbox()
    defer { sandbox.remove() }
    let (source, target) = try await installPair(sandbox)
    try await sandbox.service.checkAllowed(
        from: source, to: target,
        hostRuntimeVersion: "1.2.0", hostProtocol: (min: 1, max: 2), userdataSchema: 1
    )
}

@Test
func checkAllowedRejectsEachGate() async throws {
    let sandbox = try MigrationSandbox()
    defer { sandbox.remove() }
    let (source, target) = try await installPair(sandbox)
    let service = sandbox.service

    await #expect(throws: ImageFailure.downgradeRejected(from: newVersion, to: oldVersion)) {
        try await service.checkAllowed(
            from: target, to: source,
            hostRuntimeVersion: "1.2.0", hostProtocol: (min: 1, max: 1), userdataSchema: 1
        )
    }
    await #expect(throws: ImageFailure.incompatibleRuntime(minimum: "1.0.0", found: "0.9.0")) {
        try await service.checkAllowed(
            from: source, to: target,
            hostRuntimeVersion: "0.9.0", hostProtocol: (min: 1, max: 1), userdataSchema: 1
        )
    }
    await #expect(
        throws: ImageFailure.incompatibleProtocol(minimum: 1, maximum: 1, hostMinimum: 2, hostMaximum: 3)
    ) {
        try await service.checkAllowed(
            from: source, to: target,
            hostRuntimeVersion: "1.2.0", hostProtocol: (min: 2, max: 3), userdataSchema: 1
        )
    }
    await #expect(throws: ImageFailure.userdataSchemaUnsupported(schema: 3, supported: [1])) {
        try await service.checkAllowed(
            from: source, to: target,
            hostRuntimeVersion: "1.2.0", hostProtocol: (min: 1, max: 1), userdataSchema: 3
        )
    }
}

@Test
func checkAllowedRejectsASourceOlderThanTheMinimum() async throws {
    let sandbox = try MigrationSandbox()
    defer { sandbox.remove() }
    let store = sandbox.images
    let ancient = try await store.install(
        from: .directory(try sandbox.bundle("old", version: "2026.09.0-cf1-arm64"))
    )
    let target = try await store.install(from: .directory(try sandbox.bundle("b", version: newVersion)))
    await #expect(
        throws: ImageFailure.migrationSourceTooOld(source: "2026.09.0-cf1-arm64", minimum: "2026.10.0")
    ) {
        try await sandbox.service.checkAllowed(
            from: ancient, to: target,
            hostRuntimeVersion: "1.2.0", hostProtocol: (min: 1, max: 1), userdataSchema: 1
        )
    }
}

@Test
func beginRecordsTheMigrationAndCompleteClearsIt() async throws {
    let sandbox = try MigrationSandbox()
    defer { sandbox.remove() }
    let (source, target) = try await installPair(sandbox)
    let sizing = InstanceSizing(cpuCount: 2, memoryBytes: 2 << 30, userdataBytes: 64 * 1024 * 1024)
    _ = try await sandbox.instances.provision(image: source, sizing: sizing)

    let name = try await sandbox.service.beginMigration(
        from: source, to: target, images: sandbox.images
    )
    #expect(name.contains(target.version.description))

    let during = try await sandbox.instances.load(image: target)
    #expect(during?.migration == .init(from: source.version, to: target.version))
    #expect(during?.imageVersion == target.version)
    #expect(try await sandbox.images.current().version == target.version)
    #expect(await sandbox.images.previous()?.version == source.version)
    #expect(try await sandbox.service.hasInterruptedMigration(image: target) == true)

    try await sandbox.service.completeMigration()
    #expect(try await sandbox.service.hasInterruptedMigration(image: target) == false)
}

@Test
func abortRestoresTheRecoveryPoint() async throws {
    let sandbox = try MigrationSandbox()
    defer { sandbox.remove() }
    let (source, target) = try await installPair(sandbox)
    let sizing = InstanceSizing(cpuCount: 2, memoryBytes: 2 << 30, userdataBytes: 64 * 1024 * 1024)
    _ = try await sandbox.instances.provision(image: source, sizing: sizing)

    _ = try await sandbox.service.beginMigration(from: source, to: target, images: sandbox.images)
    try await sandbox.service.abortMigration(restoredTo: source)

    let restored = try await sandbox.instances.load(image: source)
    #expect(restored?.migration == nil)
    #expect(restored?.imageVersion == source.version)
    let failed = try FileManager.default.contentsOfDirectory(
        atPath: sandbox.paths.recoveryPointsDirectory.path
    ).filter { $0.hasPrefix("failed-") }
    #expect(failed.count == 1)
}

// MARK: - Archive extraction

/// Packs `directory` into an .aar with `/usr/bin/aa`; returns the archive URL.
private func makeArchive(_ directory: URL, _ sandbox: URL) throws -> URL {
    let archive = sandbox.appendingPathComponent("pack-\(UUID().uuidString).aar")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/aa")
    process.arguments = ["archive", "-d", directory.path, "-o", archive.path]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return archive
}

@Test
func entryAllowedRejectsUnsafeEntries() {
    #expect(ImageArchiveExtractor.entryAllowed(.regularFile, path: FilePath("files/a.img")) == true)
    #expect(ImageArchiveExtractor.entryAllowed(.directory, path: FilePath("files")) == true)
    #expect(ImageArchiveExtractor.entryAllowed(.link, path: FilePath("files/link")) == false)
    #expect(ImageArchiveExtractor.entryAllowed(nil, path: FilePath("files/x")) == false)
    #expect(ImageArchiveExtractor.entryAllowed(.regularFile, path: FilePath("/etc/passwd")) == false)
    #expect(ImageArchiveExtractor.entryAllowed(.regularFile, path: FilePath("../out")) == false)
    #expect(ImageArchiveExtractor.entryAllowed(.regularFile, path: FilePath("a/../../out")) == false)
    #expect(ImageArchiveExtractor.entryAllowed(.regularFile, path: FilePath()) == false)
}

@Test
func extractUnpacksACleanArchive() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-059-aar-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("pack", isDirectory: true)
    try FileManager.default.createDirectory(
        at: source.appendingPathComponent("boot", isDirectory: true), withIntermediateDirectories: true
    )
    try Data("kernel".utf8).write(to: source.appendingPathComponent("boot/kernel"))
    try Data("manifest".utf8).write(to: source.appendingPathComponent("runtime-image.json"))

    let destination = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try ImageArchiveExtractor.extract(try makeArchive(source, root), to: destination)

    #expect(
        try String(contentsOf: destination.appendingPathComponent("boot/kernel"), encoding: .utf8) == "kernel"
    )
    #expect(
        try String(contentsOf: destination.appendingPathComponent("runtime-image.json"), encoding: .utf8)
            == "manifest"
    )
}

@Test
func extractRefusesAnArchiveWithASymlink() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-059-aar-bad-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("pack", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: source.appendingPathComponent("evil"), withDestinationURL: URL(fileURLWithPath: "/etc")
    )

    let destination = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    #expect(throws: ImageFailure.imageArchiveUnsafeEntry(path: "evil")) {
        try ImageArchiveExtractor.extract(try makeArchive(source, root), to: destination)
    }
    #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("evil").path) == false)
}
