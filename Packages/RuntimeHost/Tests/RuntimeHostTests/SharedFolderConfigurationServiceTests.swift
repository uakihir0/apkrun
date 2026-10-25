import DiagnosticsCore
import Foundation
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
