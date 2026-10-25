import Darwin
import Foundation
import Testing

@testable import IntegrationCore

private let sharedFolderTestPackage = "io.apkrun.fixture.hellofiles"
private let readOnlyTestPackage = "io.apkrun.fixture.hellofilesreadonly"

@Test func sharedFolderAccessUsesTheLowerPackageAndRootPermission() {
    #expect(SharedFolderService.effectiveAccess(.readWrite, rootMaximum: .readWrite) == .readWrite)
    #expect(SharedFolderService.effectiveAccess(.readWrite, rootMaximum: .readOnly) == .readOnly)
    #expect(SharedFolderService.effectiveAccess(.readOnly, rootMaximum: .readWrite) == .readOnly)
    #expect(SharedFolderService.effectiveAccess(.off, rootMaximum: .readWrite) == nil)
    #expect(SharedFolderService.effectiveAccess(.readWrite, rootMaximum: .off) == .off)
    #expect(SharedFolderService.canOpenHandle(openCount: 63, reservedCount: 0))
    #expect(!SharedFolderService.canOpenHandle(openCount: 64, reservedCount: 0))
    #expect(!SharedFolderService.canOpenHandle(openCount: 63, reservedCount: 1))
    #expect(!SharedFolderService.canOpenHandle(openCount: 63, reservedCount: 2))
    #expect(SharedFolderService.hasInFlightCapacity(15))
    #expect(!SharedFolderService.hasInFlightCapacity(16))
}

@Test func sharedFolderServicePagesVisibleEntriesAndRejectsUnsafePaths() async throws {
    let temporary = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: temporary.parent) }

    let root = temporary.parent.appendingPathComponent("Shared", isDirectory: true)
    let outside = temporary.parent.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data("shared".utf8).write(to: root.appendingPathComponent("visible.txt"))
    try Data("also shared".utf8).write(to: root.appendingPathComponent("another.txt"))
    try Data("inside".utf8).write(to: root.appendingPathComponent("inside.txt"))
    try Data("outside".utf8).write(to: outside.appendingPathComponent("secret.txt"))
    try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden"))
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Nested.app", isDirectory: true),
        withIntermediateDirectories: false
    )
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Photos.photoslibrary", isDirectory: true),
        withIntermediateDirectories: false
    )
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("inside-link"),
        withDestinationURL: root.appendingPathComponent("inside.txt")
    )
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("outside-link"),
        withDestinationURL: outside
    )
    let service = try makeService(root: root)
    defer { Task { await service.runtimeDidStop() } }

    let roots = try await service.listRoots(packageID: sharedFolderTestPackage)
    #expect(roots.count == 1)
    #expect(roots[0].id == "documents")
    #expect(roots[0].access == .readWrite)
    #expect(roots[0].isAvailable)

    var names = Set<String>()
    var pageCount = 0
    var page = try await service.queryChildren(
        packageID: sharedFolderTestPackage,
        rootID: "documents",
        path: "",
        pageSize: 1
    )
    while true {
        pageCount += 1
        #expect(pageCount <= 3)
        names.formUnion(page.entries.map(\.name))
        guard !page.nextPageToken.isEmpty else { break }
        page = try await service.queryChildren(
            packageID: sharedFolderTestPackage,
            rootID: "documents",
            path: "",
            pageToken: page.nextPageToken,
            pageSize: 1
        )
    }
    #expect(names == ["visible.txt", "another.txt", "inside.txt"])

    await expectIntegrationFailure(.pathRejected(.outsideRoot)) {
        _ = try await service.stat(
            packageID: sharedFolderTestPackage,
            rootID: "documents",
            path: "../outside/secret.txt"
        )
    }
    await expectIntegrationFailure(.pathRejected(.outsideRoot)) {
        _ = try await service.stat(
            packageID: sharedFolderTestPackage,
            rootID: "documents",
            path: root.appendingPathComponent("visible.txt").path
        )
    }
    await expectIntegrationFailure(.pathRejected(.hidden)) {
        _ = try await service.stat(
            packageID: sharedFolderTestPackage,
            rootID: "documents",
            path: ".hidden"
        )
    }
    await expectIntegrationFailure(.pathRejected(.hidden)) {
        _ = try await service.stat(
            packageID: sharedFolderTestPackage,
            rootID: "documents",
            path: "Nested.app"
        )
    }
    await expectIntegrationFailure(.pathRejected(.outsideRoot)) {
        _ = try await service.stat(
            packageID: sharedFolderTestPackage,
            rootID: "documents",
            path: "outside-link/secret.txt"
        )
    }
    await expectIntegrationFailure(.pathRejected(.notRegularFile)) {
        _ = try await service.stat(
            packageID: sharedFolderTestPackage,
            rootID: "documents",
            path: "inside-link"
        )
    }
    await expectIntegrationFailure(.invalidRequest) {
        _ = try await service.queryChildren(
            packageID: sharedFolderTestPackage,
            rootID: "documents",
            path: "",
            pageToken: "forged"
        )
    }
}

@Test func sharedFolderServiceChecksPackageAccessAndRootReadOnlyMode() async throws {
    let temporary = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: temporary.parent) }
    try FileManager.default.createDirectory(at: temporary.root, withIntermediateDirectories: true)
    try Data("read me".utf8).write(to: temporary.root.appendingPathComponent("read.txt"))
    let service = try makeService(root: temporary.root, rootAccess: .readWrite)
    try await service.replacePackageAccess([
        sharedFolderTestPackage: ["documents": .readWrite],
        readOnlyTestPackage: ["documents": .readOnly],
    ])
    defer { Task { await service.runtimeDidStop() } }

    let opened = try await service.openFile(
        packageID: readOnlyTestPackage,
        rootID: "documents",
        path: "read.txt",
        mode: .read
    )
    let data = try await service.readRange(
        packageID: readOnlyTestPackage,
        handle: opened.handle,
        offset: 0,
        length: 64
    )
    #expect(String(data: data, encoding: .utf8) == "read me")

    await expectIntegrationFailure(.readOnly) {
        _ = try await service.openFile(
            packageID: readOnlyTestPackage,
            rootID: "documents",
            path: "read.txt",
            mode: .write
        )
    }
    await expectIntegrationFailure(.packageAccessDenied) {
        _ = try await service.readRange(
            packageID: sharedFolderTestPackage,
            handle: opened.handle,
            offset: 0,
            length: 1
        )
    }
    await expectIntegrationFailure(.invalidRequest) {
        _ = try await service.readRange(
            packageID: readOnlyTestPackage,
            handle: opened.handle,
            offset: 0,
            length: SharedFolderService.maximumRangeBytes + 1
        )
    }
    await expectIntegrationFailure(.readOnly) {
        try await service.writeRange(
            packageID: readOnlyTestPackage,
            handle: opened.handle,
            offset: 0,
            data: Data([0x78])
        )
    }
    try await service.closeFile(packageID: readOnlyTestPackage, handle: opened.handle)
}

@Test func documentPickerCanBrowseMetadataButPackageContentNeedsAnAccessGrant() async throws {
    let temporary = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: temporary.parent) }
    try FileManager.default.createDirectory(at: temporary.root, withIntermediateDirectories: true)
    try Data("private bytes".utf8).write(to: temporary.root.appendingPathComponent("document.txt"))
    let ungrantedRoot = temporary.parent.appendingPathComponent("Unshared", isDirectory: true)
    try FileManager.default.createDirectory(at: ungrantedRoot, withIntermediateDirectories: true)

    let service = try SharedFolderService(
        roots: [
            SharedFolderRoot(
                id: "documents",
                title: "Test Shared",
                directoryURL: temporary.root,
                maximumAccess: .readWrite
            ),
            SharedFolderRoot(
                id: "unshared",
                title: "Not Shared",
                directoryURL: ungrantedRoot,
                maximumAccess: .readWrite
            ),
        ],
        packageAccess: [sharedFolderTestPackage: ["documents": .readWrite]]
    )
    defer { Task { await service.runtimeDidStop() } }

    let pickerRoots = try await service.listRoots(context: .documentPicker)
    #expect(pickerRoots.map(\.id) == ["documents"])
    #expect(pickerRoots[0].access == .readWrite)
    let page = try await service.queryChildren(
        context: .documentPicker,
        rootID: "documents",
        path: ""
    )
    #expect(page.entries.map(\.name) == ["document.txt"])

    await expectIntegrationFailure(.packageAccessDenied) {
        _ = try await service.openFile(
            packageID: "io.apkrun.ungranted",
            rootID: "documents",
            path: "document.txt",
            mode: .read
        )
    }
}

@Test func sharedFolderServiceEnforcesHandleLimitAndQuarantinesAndroidFiles() async throws {
    let temporary = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: temporary.parent) }
    try FileManager.default.createDirectory(at: temporary.root, withIntermediateDirectories: true)
    try Data("handle".utf8).write(to: temporary.root.appendingPathComponent("handle.txt"))
    let service = try makeService(root: temporary.root)
    defer { Task { await service.runtimeDidStop() } }

    var handles: [UInt64] = []
    for _ in 0..<SharedFolderService.maximumOpenHandlesPerPackage {
        let opened = try await service.openFile(
            packageID: sharedFolderTestPackage,
            rootID: "documents",
            path: "handle.txt",
            mode: .read
        )
        handles.append(opened.handle)
    }
    await expectIntegrationFailure(.resourceExhausted) {
        _ = try await service.openFile(
            packageID: sharedFolderTestPackage,
            rootID: "documents",
            path: "handle.txt",
            mode: .read
        )
    }
    for handle in handles {
        try await service.closeFile(packageID: sharedFolderTestPackage, handle: handle)
    }

    let created = try await service.createDocument(
        packageID: sharedFolderTestPackage,
        rootID: "documents",
        parentPath: "",
        name: "android-created.txt"
    )
    #expect(created.name == "android-created.txt")
    let createdURL = temporary.root.appendingPathComponent(created.path)
    let quarantineSize = createdURL.path.withCString {
        getxattr(
            $0,
            "com.apple.quarantine",
            nil,
            0,
            0,
            0
        )
    }
    #expect(quarantineSize > 0)

    let writable = try await service.openFile(
        packageID: sharedFolderTestPackage,
        rootID: "documents",
        path: created.path,
        mode: .readWrite
    )
    try await service.writeRange(
        packageID: sharedFolderTestPackage,
        handle: writable.handle,
        offset: 0,
        data: Data("hello".utf8)
    )
    let writtenData = try await service.readRange(
        packageID: sharedFolderTestPackage,
        handle: writable.handle,
        offset: 0,
        length: 5
    )
    #expect(String(data: writtenData, encoding: .utf8) == "hello")
    try await service.closeFile(packageID: sharedFolderTestPackage, handle: writable.handle, synchronize: true)

    let existingFile = temporary.root.appendingPathComponent("existing.txt")
    try Data("before".utf8).write(to: existingFile)
    let writableExisting = try await service.openFile(
        packageID: sharedFolderTestPackage,
        rootID: "documents",
        path: "existing.txt",
        mode: .write
    )
    let existingQuarantineSize = existingFile.path.withCString {
        getxattr($0, "com.apple.quarantine", nil, 0, 0, 0)
    }
    #expect(existingQuarantineSize > 0)
    try await service.closeFile(
        packageID: sharedFolderTestPackage,
        handle: writableExisting.handle
    )

    await service.runtimeDidStop()
    await expectIntegrationFailure(.transferFailed) {
        _ = try await service.listRoots(packageID: sharedFolderTestPackage)
    }
}

@Test func sharedFolderServiceReportsMissingRootsWithoutOpeningPaths() async throws {
    let temporary = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: temporary.parent) }
    let missing = temporary.root
    let service = try makeService(root: missing)

    let roots = try await service.listRoots(packageID: sharedFolderTestPackage)
    #expect(roots.count == 1)
    #expect(!roots[0].isAvailable)
    await expectIntegrationFailure(.folderUnavailable(.missing, name: "Test Shared")) {
        _ = try await service.queryChildren(
            packageID: sharedFolderTestPackage,
            rootID: "documents",
            path: ""
        )
    }
    await service.runtimeDidStop()
}

private func makeTemporaryFolder() throws -> (parent: URL, root: URL) {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    return (parent, parent.appendingPathComponent("Shared", isDirectory: true))
}

private func makeService(
    root: URL,
    rootAccess: SharedFolderAccess = .readWrite
) throws -> SharedFolderService {
    try SharedFolderService(
        roots: [
            SharedFolderRoot(
                id: "documents",
                title: "Test Shared",
                directoryURL: root,
                maximumAccess: rootAccess
            )
        ],
        packageAccess: [sharedFolderTestPackage: ["documents": .readWrite]]
    )
}

private func expectIntegrationFailure(
    _ expected: IntegrationFailure,
    operation: () async throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    do {
        try await operation()
        Issue.record("Expected \(expected.qualifiedCode).", sourceLocation: sourceLocation)
    } catch let failure as IntegrationFailure {
        #expect(failure == expected, sourceLocation: sourceLocation)
    } catch {
        Issue.record("Expected \(expected.qualifiedCode), received \(error).", sourceLocation: sourceLocation)
    }
}
