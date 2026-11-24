import APKStoreCore
import DiagnosticsCore
import Foundation
import IntegrationCore
import RuntimeAPI
import Testing

@testable import RuntimeHost

private final class SecurityScopeStopCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var countValue = 0

    func recordStop() {
        lock.lock()
        countValue += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return countValue
    }
}

private func makeTemporaryDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test(.timeLimit(.minutes(1)))
func sharedFolderConfigurationAddsUpdatesAndRemovesBookmarkedRoot() async throws {
    let base = try makeTemporaryDirectory("apkrun-shared-folders")
    defer { try? FileManager.default.removeItem(at: base) }
    let home = base.appendingPathComponent("home", isDirectory: true)
    let selected = base.appendingPathComponent("selected", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)

    let bookmark = Data("selected-folder-bookmark".utf8)
    let stopCounter = SecurityScopeStopCounter()
    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": base.appendingPathComponent("data", isDirectory: true).path]
    )
    let service = try await SharedFolderConfigurationService.open(
        paths: paths,
        homeDirectory: home,
        resolveBookmark: { _ in (selected, false) },
        createBookmark: { _ in bookmark },
        startSecurityScope: { _ in true },
        stopSecurityScope: { _ in stopCounter.recordStop() }
    )

    let initialFolders = try await service.listFolders()
    #expect(initialFolders.map(\.id) == ["shared"])
    #expect(initialFolders.first?.builtIn == true)

    let added = try await service.add(AddSharedFolderRequest(bookmark: bookmark))
    #expect(added.name == "selected")
    #expect(added.access == .readOnly)
    #expect(added.builtIn == false)

    let updated = try await service.setAccess(SetSharedFolderAccessRequest(id: added.id, access: .readWrite))
    #expect(updated.access == .readWrite)

    try await service.remove(added.id)
    #expect(try await service.listFolders().map(\.id) == ["shared"])
    #expect(stopCounter.count == 1)
    await service.shutdown()
}

@Test(.timeLimit(.minutes(1)))
func sharedFolderConfigurationRefreshesPackageAndGlobalAccessBeforeRequests() async throws {
    let base = try makeTemporaryDirectory("apkrun-shared-folder-policy")
    defer { try? FileManager.default.removeItem(at: base) }
    let home = base.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": base.appendingPathComponent("data", isDirectory: true).path]
    )
    let packageID = "io.apkrun.fixture.reader"
    try FileManager.default.createDirectory(
        at: paths.packageDirectory(packageID: packageID),
        withIntermediateDirectories: true
    )
    let initialGlobalSettings: [String: Any] = [
        "integrations": [
            "enabled": ["sharedFolders": true],
            "defaults": ["sharedFolders": "readWrite"],
        ]
    ]
    try JSONSerialization.data(withJSONObject: initialGlobalSettings)
        .write(to: paths.settingsFile, options: .atomic)
    let packageSettingsURL = paths.packageSettingsFile(packageID: packageID)
    try JSONSerialization.data(withJSONObject: ["integrations": ["sharedFolders": "readWrite"]])
        .write(to: packageSettingsURL, options: .atomic)

    let service = try await SharedFolderConfigurationService.open(
        paths: paths,
        homeDirectory: home,
        startSecurityScope: { _ in true }
    )
    defer { Task { await service.shutdown() } }
    let sharedFile = paths.sharedDirectory.appendingPathComponent("document.txt")
    try Data("shared".utf8).write(to: sharedFile)
    let opened = try await service.fileService.openFile(
        packageID: packageID,
        rootID: "shared",
        path: "document.txt",
        mode: .read
    )

    try JSONSerialization.data(withJSONObject: ["integrations": ["sharedFolders": "readOnly"]])
        .write(to: packageSettingsURL, options: .atomic)
    async let firstRefresh: Void = service.refreshPackageAccess(for: packageID)
    async let secondRefresh: Void = service.refreshPackageAccess(for: packageID)
    try await (firstRefresh, secondRefresh)
    await expectIntegrationFailure(.packageAccessDenied) {
        _ = try await service.fileService.readRange(
            packageID: packageID,
            handle: opened.handle,
            offset: 0,
            length: 6
        )
    }

    try JSONSerialization.data(withJSONObject: ["integrations": ["sharedFolders": "off"]])
        .write(to: packageSettingsURL, options: .atomic)
    try await service.refreshPackageAccess(for: packageID)
    await expectIntegrationFailure(.packageAccessDenied) {
        _ = try await service.fileService.readRange(
            packageID: packageID,
            handle: opened.handle,
            offset: 0,
            length: 6
        )
    }

    try JSONSerialization.data(withJSONObject: ["integrations": ["sharedFolders": "readWrite"]])
        .write(to: packageSettingsURL, options: .atomic)
    let disabledGlobalSettings: [String: Any] = [
        "integrations": [
            "enabled": ["sharedFolders": false],
            "defaults": ["sharedFolders": "readWrite"],
        ]
    ]
    try JSONSerialization.data(withJSONObject: disabledGlobalSettings)
        .write(to: paths.settingsFile, options: .atomic)
    try await service.refreshPackageAccess(for: packageID)
    await expectIntegrationFailure(.packageAccessDenied) {
        _ = try await service.fileService.openFile(
            packageID: packageID,
            rootID: "shared",
            path: "document.txt",
            mode: .read
        )
    }
}

@Test(.timeLimit(.minutes(1)))
func sharedFolderPackageDirectoryIndexInvalidatesForDirectoryChangesAndKeepsSettingsFresh() async throws {
    let base = try makeTemporaryDirectory("apkrun-shared-folder-package-index")
    defer { try? FileManager.default.removeItem(at: base) }
    let home = base.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": base.appendingPathComponent("data", isDirectory: true).path]
    )

    let initialPackageDirectory = paths.packageDirectory(packageID: "io.example.initial")
    try FileManager.default.createDirectory(at: initialPackageDirectory, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: [
        "integrations": [
            "enabled": ["sharedFolders": true],
            "defaults": ["sharedFolders": "readWrite"],
        ]
    ])
    .write(to: paths.settingsFile, options: .atomic)

    let service = try await SharedFolderConfigurationService.open(
        paths: paths,
        homeDirectory: home,
        startSecurityScope: { _ in true }
    )
    defer { Task { await service.shutdown() } }

    let packageID = "io.example.added"
    let packageDirectory = paths.packageDirectory(packageID: packageID)
    try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
    let packageSettingsURL = paths.packageSettingsFile(packageID: packageID)
    try JSONSerialization.data(withJSONObject: ["integrations": ["sharedFolders": "readWrite"]])
        .write(to: packageSettingsURL, options: .atomic)

    let sharedFile = paths.sharedDirectory.appendingPathComponent("package-index.txt")
    try Data("shared".utf8).write(to: sharedFile)
    let opened = try await service.fileService.openFile(
        packageID: packageID,
        rootID: "shared",
        path: "package-index.txt",
        mode: .read
    )
    try await service.fileService.closeFile(packageID: packageID, handle: opened.handle)

    // Updating settings must be observed even while the directory-name index remains valid.
    try JSONSerialization.data(withJSONObject: ["integrations": ["sharedFolders": "off"]])
        .write(to: packageSettingsURL, options: .atomic)
    try await service.refreshPackageAccess(for: packageID)
    await expectIntegrationFailure(.packageAccessDenied) {
        _ = try await service.fileService.openFile(
            packageID: packageID,
            rootID: "shared",
            path: "package-index.txt",
            mode: .read
        )
    }

    // With a permissive default, a removed package must still lose access when the cached name
    // becomes stale.
    try FileManager.default.removeItem(at: packageDirectory)
    try await service.refreshPackageAccess(for: packageID)
    await expectIntegrationFailure(.packageAccessDenied) {
        _ = try await service.fileService.openFile(
            packageID: packageID,
            rootID: "shared",
            path: "package-index.txt",
            mode: .read
        )
    }
    await service.shutdown()
}

@Test(.timeLimit(.minutes(1)))
func sharedFolderPolicyDoesNotResolveCaseCollidingPackageDirectory() async throws {
    let base = try makeTemporaryDirectory("apkrun-shared-folder-case-collision")
    defer { try? FileManager.default.removeItem(at: base) }
    let home = base.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": base.appendingPathComponent("data", isDirectory: true).path]
    )

    let firstPackageID = "io.example.reader"
    let collidingPackageID = "IO.example.reader"
    let firstPackageDirectory = paths.packageDirectory(packageID: firstPackageID)
    let digestSuffix = String(SHA256Digest(data: Data(collidingPackageID.utf8)).hexValue.prefix(8))
    let collidingPackageDirectory = paths.packagesDirectory
        .appendingPathComponent("\(collidingPackageID)~\(digestSuffix)", isDirectory: true)
    try FileManager.default.createDirectory(at: firstPackageDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: collidingPackageDirectory, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["integrations": ["sharedFolders": "readWrite"]])
        .write(
            to: firstPackageDirectory.appendingPathComponent("settings.json"),
            options: .atomic
        )
    try JSONSerialization.data(withJSONObject: ["integrations": ["sharedFolders": "off"]])
        .write(
            to: collidingPackageDirectory.appendingPathComponent("settings.json"),
            options: .atomic
        )
    try JSONSerialization.data(withJSONObject: [
        "integrations": [
            "enabled": ["sharedFolders": true],
            "defaults": ["sharedFolders": "off"],
        ]
    ])
    .write(to: paths.settingsFile, options: .atomic)

    let service = try await SharedFolderConfigurationService.open(
        paths: paths,
        homeDirectory: home,
        startSecurityScope: { _ in true }
    )
    defer { Task { await service.shutdown() } }
    try await service.refreshPackageAccess(for: collidingPackageID)

    let source = paths.sharedDirectory.appendingPathComponent("document.txt")
    try Data("private".utf8).write(to: source)
    await expectIntegrationFailure(.packageAccessDenied) {
        _ = try await service.fileService.openFile(
            packageID: collidingPackageID,
            rootID: "shared",
            path: "document.txt",
            mode: .read
        )
    }

    try JSONSerialization.data(withJSONObject: ["integrations": ["sharedFolders": "readWrite"]])
        .write(
            to: collidingPackageDirectory.appendingPathComponent("settings.json"),
            options: .atomic
        )
    try await service.refreshPackageAccess(for: collidingPackageID)
    let collidingPackageFile = try await service.fileService.openFile(
        packageID: collidingPackageID,
        rootID: "shared",
        path: "document.txt",
        mode: .read
    )
    try await service.fileService.closeFile(
        packageID: collidingPackageID,
        handle: collidingPackageFile.handle
    )
}

@Test(.timeLimit(.minutes(1)))
func sharedFolderListRefreshesAvailabilityWhenRootDisappearsAndReturns() async throws {
    let base = try makeTemporaryDirectory("apkrun-shared-folder-health")
    defer { try? FileManager.default.removeItem(at: base) }
    let home = base.appendingPathComponent("home", isDirectory: true)
    let selected = base.appendingPathComponent("selected", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
    let bookmark = Data("selected-folder-bookmark".utf8)
    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": base.appendingPathComponent("data", isDirectory: true).path]
    )
    let service = try await SharedFolderConfigurationService.open(
        paths: paths,
        homeDirectory: home,
        resolveBookmark: { _ in (selected, false) },
        startSecurityScope: { _ in true }
    )
    let added = try await service.add(AddSharedFolderRequest(bookmark: bookmark))
    #expect(added.availability == .available)
    let packageID = "io.apkrun.fixture.reader"
    try await service.fileService.replacePackageAccess([
        packageID: [added.id: IntegrationCore.SharedFolderAccess.readOnly]
    ])
    let initialRoots = try await service.fileService.listRoots(packageID: packageID)
    #expect(initialRoots.first(where: { $0.id == added.id })?.isAvailable == true)

    try FileManager.default.removeItem(at: selected)

    let folders = try await service.listFolders()
    #expect(folders.first(where: { $0.id == added.id })?.availability == .missing)
    let missingRoots = try await service.fileService.listRoots(packageID: packageID)
    #expect(missingRoots.first(where: { $0.id == added.id })?.isAvailable == false)
    let updated = try await service.setAccess(
        SetSharedFolderAccessRequest(id: added.id, access: .readWrite)
    )
    #expect(updated.availability == .missing)

    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
    let restoredFolders = try await service.listFolders()
    #expect(restoredFolders.first(where: { $0.id == added.id })?.availability == .available)
    let restoredRoots = try await service.fileService.listRoots(packageID: packageID)
    #expect(restoredRoots.first(where: { $0.id == added.id })?.isAvailable == true)
    let page = try await service.fileService.queryChildren(
        packageID: packageID,
        rootID: added.id,
        path: ""
    )
    #expect(page.entries.isEmpty)
    await service.shutdown()
}

@Test(.timeLimit(.minutes(1)))
func sharedFolderConfigurationRefusesHiddenRootsWithoutExposingPath() async throws {
    let base = try makeTemporaryDirectory("apkrun-hidden-folder")
    defer { try? FileManager.default.removeItem(at: base) }
    let home = base.appendingPathComponent("home", isDirectory: true)
    let hidden = base.appendingPathComponent(".private", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)

    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": base.appendingPathComponent("data", isDirectory: true).path]
    )
    let service = try await SharedFolderConfigurationService.open(
        paths: paths,
        homeDirectory: home,
        resolveBookmark: { _ in (hidden, false) }
    )

    do {
        _ = try await service.add(
            AddSharedFolderRequest(bookmark: Data("hidden-folder-bookmark".utf8))
        )
        Issue.record("A hidden root must be refused.")
    } catch let error as RuntimeWireError {
        #expect(error.code == "integration.folderRefused")
        #expect(!error.message.contains(hidden.path))
    }
    await service.shutdown()
}
