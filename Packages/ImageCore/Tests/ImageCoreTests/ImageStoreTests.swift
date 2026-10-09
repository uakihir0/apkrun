import Darwin
import DiagnosticsCore
import Foundation
import Testing

@testable import ImageCore

/// Every entry under `root`, including `root` itself. Synchronous, because enumerators are not
/// iterable from an async context.
private func treeEntries(_ root: URL) -> [URL] {
    var entries = [root]
    if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: []) {
        for case let url as URL in walker {
            entries.append(url)
        }
    }
    return entries
}

/// A temporary APKRUN_HOME on the volume of the temporary directory, which must be APFS (§10.3).
private struct StoreSandbox {
    let root: URL
    let paths: APKRunPaths

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-065-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
    }

    func remove() {
        // Installed images are read-only, so the owner's write bits come back before deletion.
        for url in treeEntries(root) {
            let mode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
            try? FileManager.default.setAttributes(
                [.posixPermissions: (mode?.intValue ?? 0o644) | 0o200], ofItemAtPath: url.path
            )
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// `apfs` for the sandbox volume, read from `statfs(2)`.
    var fileSystem: String {
        var status = statfs()
        guard statfs(root.path, &status) == 0 else {
            return "unknown"
        }
        return withUnsafeBytes(of: status.f_fstypename) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    func store(trust: ImageTrustStore = testImageTrust) -> ImageStore {
        ImageStore(paths: paths, trust: trust, diagnostics: .live(paths: paths))
    }

    /// A new bundle directory under the sandbox, written with the given options.
    func bundle(_ name: String, version: String = "2026.10.0-cf1-arm64", kernel: Data? = nil) throws -> URL {
        try SignedBundleFixture.write(
            to: root.appendingPathComponent("source-\(name)", isDirectory: true),
            version: version,
            kernel: kernel ?? Data(repeating: 0x42, count: 64)
        )
    }

    var images: URL { paths.imagesDirectory }
}

/// Counts the clones and fails the one at `failAt`, to interrupt an install.
private final class CloneCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let failAt: Int?

    init(failAt: Int?) {
        self.failAt = failAt
    }

    func clone(_ source: URL, _ destination: URL) throws {
        let index = lock.withLock { () -> Int in
            count += 1
            return count
        }
        if index == failAt {
            throw ImageFailure.cloneFailed(underlying: UnderlyingError(domain: "test", code: 1))
        }
        try FileCloner.clone(source, destination)
    }
}

@Test
func theSandboxIsOnAPFS() throws {
    let sandbox = try StoreSandbox()
    defer { sandbox.remove() }
    #expect(sandbox.fileSystem == "apfs", "the store tests need an APFS volume")
}

@Test
func aSignedBundleInstallsAndBecomesCurrent() async throws {
    let sandbox = try StoreSandbox()
    defer { sandbox.remove() }
    let source = try sandbox.bundle("a")
    let store = sandbox.store()

    let installed = try await store.install(from: .directory(source))
    #expect(installed.version.description == "2026.10.0-cf1-arm64")
    #expect(installed.root == sandbox.images.appendingPathComponent("2026.10.0-cf1-arm64"))
    let current = try await store.current()
    #expect(current.version == installed.version)
    #expect(current.manifest == installed.manifest)
    #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: sandbox.images.appendingPathComponent("current").path)
            == "2026.10.0-cf1-arm64")
    #expect(
        !FileManager.default.fileExists(
            atPath: sandbox.images.appendingPathComponent(".installing-2026.10.0-cf1-arm64").path))
}

@Test
func aReinstallOfTheSameBundleChangesNothing() async throws {
    let sandbox = try StoreSandbox()
    defer { sandbox.remove() }
    let source = try sandbox.bundle("a")
    let store = sandbox.store()
    let first = try await store.install(from: .directory(source))
    let second = try await store.install(from: .directory(source))
    #expect(first == second)
}

@Test
func sparseFilesKeepTheirHolesThroughTheInstall() async throws {
    let sandbox = try StoreSandbox()
    defer { sandbox.remove() }
    let installed = try await sandbox.store().install(from: .directory(try sandbox.bundle("a")))
    let disk = installed.root.appendingPathComponent("disks/os.img")
    var status = stat()
    #expect(stat(disk.path, &status) == 0)
    let logical = UInt64(status.st_size)
    let allocated = UInt64(status.st_blocks) * 512
    #expect(logical == 4 * 1024 * 1024)
    #expect(allocated < logical / 2, "allocated \(allocated) bytes of \(logical)")
}

@Test
func aBadSignatureIsRefusedAndNothingIsLeftBehind() async throws {
    let sandbox = try StoreSandbox()
    defer { sandbox.remove() }
    let source = try sandbox.bundle("a")
    let signature = source.appendingPathComponent("manifest.sig")
    // Flip one bit of the decoded signature, so the file stays well-formed and only the check fails.
    let lines = try String(contentsOf: signature, encoding: .ascii).split(
        separator: "\n", omittingEmptySubsequences: false)
    var bytes = try #require(Data(base64Encoded: String(lines[3].dropFirst("signature: ".count))))
    bytes[0] ^= 0x01
    let tampered = [
        String(lines[0]), String(lines[1]), String(lines[2]), "signature: " + bytes.base64EncodedString(), "",
    ]
    try Data(tampered.joined(separator: "\n").utf8).write(to: signature)

    let store = sandbox.store()
    await #expect(throws: ImageFailure.signatureInvalid(keyID: testImageKeyID)) {
        _ = try await store.install(from: .directory(source))
    }
    #expect(!FileManager.default.fileExists(atPath: sandbox.images.appendingPathComponent("2026.10.0-cf1-arm64").path))
    let remaining = (try? FileManager.default.contentsOfDirectory(atPath: sandbox.images.path)) ?? []
    #expect(remaining.isEmpty)
}

@Test
func anUntrustedKeyIsRefused() async throws {
    let sandbox = try StoreSandbox()
    defer { sandbox.remove() }
    let store = sandbox.store(trust: ImageTrustStore(keys: []))
    await #expect(throws: ImageFailure.untrustedKey(keyID: testImageKeyID)) {
        _ = try await store.install(from: .directory(try sandbox.bundle("a")))
    }
}

@Test
func anExtraFileIsRefused() async throws {
    let sandbox = try StoreSandbox()
    defer { sandbox.remove() }
    let source = try sandbox.bundle("a")
    try Data("extra".utf8).write(to: source.appendingPathComponent("boot/extra"))
    await #expect(throws: ImageFailure.unexpectedFile(file: "boot/extra")) {
        _ = try await sandbox.store().install(from: .directory(source))
    }
}

@Test
func aMissingFileIsRefused() async throws {
    let sandbox = try StoreSandbox()
    defer { sandbox.remove() }
    let source = try sandbox.bundle("a")
    try FileManager.default.removeItem(at: source.appendingPathComponent("boot/cmdline.txt"))
    await #expect(throws: ImageFailure.missingFile(file: "boot/cmdline.txt")) {
        _ = try await sandbox.store().install(from: .directory(source))
    }
}

@Test
func aFileOfTheWrongSizeIsRefused() async throws {
    let sandbox = try StoreSandbox()
    defer { sandbox.remove() }
    let source = try sandbox.bundle("a")
    let handle = try FileHandle(forWritingTo: source.appendingPathComponent("boot/kernel"))
    try handle.truncate(atOffset: 10)
    try handle.close()
    await #expect(throws: ImageFailure.hashMismatch(file: "boot/kernel")) {
        _ = try await sandbox.store().install(from: .directory(source))
    }
}

@Test
func aFileWithTheRightSizeAndAWrongHashIsRefusedBeforeItIsActivated() async throws {
    let sandbox = try StoreSandbox()
    defer { sandbox.remove() }
    let source = try sandbox.bundle("a")
    // The quick check passes on the source (same size), so only the full check on the copy finds it.
    let handle = try FileHandle(forWritingTo: source.appendingPathComponent("boot/ramdisk.img"))
    try handle.write(contentsOf: Data("fixture-ramdisX".utf8))
    try handle.close()
    let store = sandbox.store()
    await #expect(throws: ImageFailure.hashMismatch(file: "boot/ramdisk.img")) {
        _ = try await store.install(from: .directory(source))
    }
    await #expect(throws: ImageFailure.noCurrentImage) {
        _ = try await store.current()
    }
    let remaining = (try? FileManager.default.contentsOfDirectory(atPath: sandbox.images.path)) ?? []
    #expect(remaining.isEmpty, "\(remaining)")
}

@Test
func aDifferentManifestUnderTheSameVersionIsRefused() async throws {
    let sandbox = try StoreSandbox()
    defer { sandbox.remove() }
    let store = sandbox.store()
    _ = try await store.install(from: .directory(try sandbox.bundle("a")))
    let changed = try sandbox.bundle("b", kernel: Data(repeating: 0x43, count: 64))
    await #expect(throws: ImageFailure.unexpectedFile(file: "manifest.json")) {
        _ = try await store.install(from: .directory(changed))
    }
}

@Test
func anInterruptedInstallLeavesNothingBehind() async throws {
    let sandbox = try StoreSandbox()
    defer { sandbox.remove() }
    let source = try sandbox.bundle("a")
    let counter = CloneCounter(failAt: 3)
    let store = ImageStore(
        paths: sandbox.paths,
        trust: testImageTrust,
        diagnostics: .live(paths: sandbox.paths),
        cloneFile: counter.clone,
        beforeActivation: {}
    )
    await #expect(throws: ImageFailure.self) {
        _ = try await store.install(from: .directory(source))
    }
    let remaining = (try? FileManager.default.contentsOfDirectory(atPath: sandbox.images.path)) ?? []
    #expect(remaining.isEmpty, "\(remaining)")
    await #expect(throws: ImageFailure.noCurrentImage) {
        _ = try await store.current()
    }
}

@Test
func anInstallLeftBehindByACrashIsRemovedAtStartup() async throws {
    let sandbox = try StoreSandbox()
    defer { sandbox.remove() }
    let store = sandbox.store()
    let installed = try await store.install(from: .directory(try sandbox.bundle("a")))
    let orphan = sandbox.images.appendingPathComponent(".installing-2026.10.1-cf2-arm64")
    try FileManager.default.createDirectory(
        at: orphan.appendingPathComponent("disks"), withIntermediateDirectories: true)
    try Data("partial".utf8).write(to: orphan.appendingPathComponent("disks/os.img"))

    try await store.removeOrphanedInstalls()
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
    #expect(try await store.current().version == installed.version)
}

@Test
func aDowngradeIsRefused() async throws {
    let sandbox = try StoreSandbox()
    defer { sandbox.remove() }
    let store = sandbox.store()
    _ = try await store.install(from: .directory(try sandbox.bundle("new")))
    let older = try sandbox.bundle("old", version: "2026.09.0-cf1-arm64")
    await #expect(throws: ImageFailure.downgradeRejected(from: "2026.10.0-cf1-arm64", to: "2026.09.0-cf1-arm64")) {
        _ = try await store.install(from: .directory(older))
    }
}

@Test
func setCurrentMovesThePreviousImage() async throws {
    let sandbox = try StoreSandbox()
    defer { sandbox.remove() }
    let store = sandbox.store()
    let first = try await store.install(from: .directory(try sandbox.bundle("a")))
    let second = try await store.install(
        from: .directory(try sandbox.bundle("b", version: "2026.10.1-cf1-arm64"))
    )
    #expect(try await store.current().version == second.version)
    #expect(await store.previous()?.version == first.version)

    try await store.setCurrent(first.version)
    #expect(try await store.current().version == first.version)
    #expect(await store.previous()?.version == second.version)
}

@Test
func setCurrentRefusesAnImageThatIsNotInstalled() async throws {
    let sandbox = try StoreSandbox()
    defer { sandbox.remove() }
    let store = sandbox.store()
    _ = try await store.install(from: .directory(try sandbox.bundle("a")))
    let absent = try #require(ImageVersion("2026.11.0-cf9-arm64"))
    await #expect(throws: ImageFailure.imageNotInstalled(version: "2026.11.0-cf9-arm64")) {
        try await store.setCurrent(absent)
    }
}

@Test
func garbageCollectKeepsCurrentAndPrevious() async throws {
    let sandbox = try StoreSandbox()
    defer { sandbox.remove() }
    let store = sandbox.store()
    _ = try await store.install(from: .directory(try sandbox.bundle("a")))
    _ = try await store.install(from: .directory(try sandbox.bundle("b", version: "2026.10.1-cf1-arm64")))
    let newest = try await store.install(
        from: .directory(try sandbox.bundle("c", version: "2026.10.2-cf1-arm64"))
    )
    try await store.garbageCollect()
    let names = Set(try FileManager.default.contentsOfDirectory(atPath: sandbox.images.path))
    #expect(names.contains("2026.10.2-cf1-arm64"))
    #expect(names.contains("2026.10.1-cf1-arm64"))
    #expect(!names.contains("2026.10.0-cf1-arm64"))
    #expect(try await store.current().version == newest.version)
}

@Test
func verifyCatchesAFileChangedAfterInstall() async throws {
    let sandbox = try StoreSandbox()
    defer { sandbox.remove() }
    let store = sandbox.store()
    let installed = try await store.install(from: .directory(try sandbox.bundle("a")))
    try await store.verify(installed, depth: .full)

    // An installed file is read-only, so the tampering first restores the owner's write bit.
    let tampered = installed.root.appendingPathComponent("boot/ramdisk.img")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tampered.path)
    let handle = try FileHandle(forWritingTo: tampered)
    try handle.write(contentsOf: Data("fixture-ramdisX".utf8))
    try handle.close()
    await #expect(throws: ImageFailure.hashMismatch(file: "boot/ramdisk.img")) {
        try await store.verify(installed, depth: .full)
    }
}

@Test
func aReinstallOfAnOlderImageIsADowngrade() async throws {
    let sandbox = try StoreSandbox()
    defer { sandbox.remove() }
    let store = sandbox.store()
    _ = try await store.install(from: .directory(try sandbox.bundle("old", version: "2026.10.0-cf1-arm64")))
    _ = try await store.install(from: .directory(try sandbox.bundle("new", version: "2026.10.1-cf1-arm64")))
    await #expect(
        throws: ImageFailure.downgradeRejected(from: "2026.10.1-cf1-arm64", to: "2026.10.0-cf1-arm64")
    ) {
        _ = try await store.install(from: .directory(try sandbox.bundle("old-again", version: "2026.10.0-cf1-arm64")))
    }
    #expect(try await store.current().version.description == "2026.10.1-cf1-arm64")
}

@Test
func aSourceThatChangesDuringTheInstallIsRefused() async throws {
    let sandbox = try StoreSandbox()
    defer { sandbox.remove() }
    let source = try sandbox.bundle("a")
    let other = try sandbox.bundle("b", kernel: Data(repeating: 0x43, count: 64))
    let replacementManifest = try Data(contentsOf: other.appendingPathComponent("manifest.json"))
    let replacementSignature = try Data(contentsOf: other.appendingPathComponent("manifest.sig"))
    let sourceManifest = source.appendingPathComponent("manifest.json")
    let sourceSignature = source.appendingPathComponent("manifest.sig")
    let store = ImageStore(
        paths: sandbox.paths,
        trust: testImageTrust,
        diagnostics: .live(paths: sandbox.paths),
        cloneFile: { from, to in
            // The source is replaced after it was verified and before its manifest is cloned.
            if from == sourceManifest {
                try replacementManifest.write(to: sourceManifest)
                try replacementSignature.write(to: sourceSignature)
            }
            try FileCloner.clone(from, to)
        },
        beforeActivation: {}
    )
    await #expect(throws: ImageFailure.unexpectedFile(file: "manifest.json")) {
        _ = try await store.install(from: .directory(source))
    }
    let remaining = (try? FileManager.default.contentsOfDirectory(atPath: sandbox.images.path)) ?? []
    #expect(remaining.isEmpty, "\(remaining)")
}

@Test
func aDowngradeIsRefusedWhenTheCurrentLinkIsMissing() async throws {
    let sandbox = try StoreSandbox()
    defer { sandbox.remove() }
    let store = sandbox.store()
    _ = try await store.install(from: .directory(try sandbox.bundle("new", version: "2026.10.1-cf1-arm64")))
    try FileManager.default.removeItem(at: sandbox.images.appendingPathComponent("current"))
    await #expect(
        throws: ImageFailure.downgradeRejected(from: "2026.10.1-cf1-arm64", to: "2026.10.0-cf1-arm64")
    ) {
        _ = try await store.install(from: .directory(try sandbox.bundle("old", version: "2026.10.0-cf1-arm64")))
    }
}

@Test
func aCrashBetweenTheRenameAndTheActivationStillBlocksADowngrade() async throws {
    let sandbox = try StoreSandbox()
    defer { sandbox.remove() }
    // The first install stops after the image is renamed into place and before it is made current.
    let crashing = ImageStore(
        paths: sandbox.paths,
        trust: testImageTrust,
        diagnostics: .live(paths: sandbox.paths),
        cloneFile: { from, to in try FileCloner.clone(from, to) },
        beforeActivation: {
            throw ImageFailure.cloneFailed(underlying: UnderlyingError(domain: "test", code: 2))
        }
    )
    await #expect(throws: ImageFailure.self) {
        _ = try await crashing.install(from: .directory(try sandbox.bundle("new", version: "2026.10.1-cf1-arm64")))
    }
    #expect(FileManager.default.fileExists(atPath: sandbox.images.appendingPathComponent("2026.10.1-cf1-arm64").path))
    #expect(!FileManager.default.fileExists(atPath: sandbox.images.appendingPathComponent("current").path))

    let store = sandbox.store()
    await #expect(
        throws: ImageFailure.downgradeRejected(from: "2026.10.1-cf1-arm64", to: "2026.10.0-cf1-arm64")
    ) {
        _ = try await store.install(from: .directory(try sandbox.bundle("old", version: "2026.10.0-cf1-arm64")))
    }
}

@Test
func aSameTripleImageWithAnotherBaseIsNotNewer() async throws {
    let sandbox = try StoreSandbox()
    defer { sandbox.remove() }
    let store = sandbox.store()
    _ = try await store.install(from: .directory(try sandbox.bundle("a", version: "2026.10.0-cf16373615-arm64")))
    await #expect(
        throws: ImageFailure.downgradeRejected(
            from: "2026.10.0-cf16373615-arm64", to: "2026.10.0-cf16000000-arm64"
        )
    ) {
        _ = try await store.install(
            from: .directory(try sandbox.bundle("b", version: "2026.10.0-cf16000000-arm64"))
        )
    }
    #expect(try await store.current().version.description == "2026.10.0-cf16373615-arm64")
}

@Test
func aSymlinkedManifestIsRefusedBeforeItIsRead() async throws {
    let sandbox = try StoreSandbox()
    defer { sandbox.remove() }
    let source = try sandbox.bundle("a")
    // The manifest is a link to a copy outside the bundle. The link is refused before any size or byte is read.
    let elsewhere = sandbox.root.appendingPathComponent("elsewhere.json")
    try FileManager.default.copyItem(at: source.appendingPathComponent("manifest.json"), to: elsewhere)
    try FileManager.default.removeItem(at: source.appendingPathComponent("manifest.json"))
    try FileManager.default.createSymbolicLink(
        at: source.appendingPathComponent("manifest.json"), withDestinationURL: elsewhere
    )
    let store = sandbox.store()
    await #expect(throws: ImageFailure.unexpectedFile(file: "manifest.json")) {
        _ = try await store.install(from: .directory(source))
    }
    let remaining = (try? FileManager.default.contentsOfDirectory(atPath: sandbox.images.path)) ?? []
    #expect(remaining.isEmpty, "\(remaining)")
}

@Test
func aSymlinkedPayloadFileIsRefused() async throws {
    let sandbox = try StoreSandbox()
    defer { sandbox.remove() }
    let source = try sandbox.bundle("a")
    let elsewhere = sandbox.root.appendingPathComponent("elsewhere-kernel")
    try FileManager.default.copyItem(at: source.appendingPathComponent("boot/kernel"), to: elsewhere)
    try FileManager.default.removeItem(at: source.appendingPathComponent("boot/kernel"))
    try FileManager.default.createSymbolicLink(
        at: source.appendingPathComponent("boot/kernel"), withDestinationURL: elsewhere
    )
    await #expect(throws: ImageFailure.unexpectedFile(file: "boot/kernel")) {
        _ = try await sandbox.store().install(from: .directory(source))
    }
}

@Test
func anInstalledImageIsReadOnlyAndStillRemovable() async throws {
    let sandbox = try StoreSandbox()
    defer { sandbox.remove() }
    let store = sandbox.store()
    let first = try await store.install(from: .directory(try sandbox.bundle("a", version: "2026.10.0-cf1-arm64")))
    _ = try await store.install(from: .directory(try sandbox.bundle("b", version: "2026.10.1-cf1-arm64")))
    _ = try await store.install(from: .directory(try sandbox.bundle("c", version: "2026.10.2-cf1-arm64")))

    var checked: [String] = []
    for url in treeEntries(first.root) {
        let mode = try #require(
            (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
        )
        #expect(mode.intValue & 0o222 == 0, "\(url.lastPathComponent) is writable: \(String(mode.intValue, radix: 8))")
        checked.append(url.lastPathComponent)
    }
    #expect(checked.contains("kernel") && checked.contains("os.img"))
    let mode = try #require(
        (try FileManager.default.attributesOfItem(atPath: first.root.path)[.posixPermissions]) as? NSNumber
    )
    #expect(mode.intValue & 0o222 == 0, "the image directory is writable")

    let kernel = first.root.appendingPathComponent("boot/kernel")
    #expect(throws: (any Error).self) {
        _ = try FileHandle(forWritingTo: kernel)
    }

    // Garbage collection keeps the current and the previous image, and removes the oldest.
    try await store.garbageCollect()
    #expect(!FileManager.default.fileExists(atPath: first.root.path))
}
