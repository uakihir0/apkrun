import Foundation
import RuntimeAPI
import XCTest

@testable import IntegrationCore

/// T0 of SharedFolderService against a real temporary root
/// (desktop-integration.md §6.4, guest-protocol.md §7.5).
final class SharedFolderServiceTests: XCTestCase {
    private var rootURL: URL!
    private var secondURL: URL!
    /// Mutable test state the Sendable source closures read.
    private final class Box: @unchecked Sendable {
        var roots: [SharedFolderRoot] = []
        var settings: [RuntimePackageID: String] = [:]
    }
    private let box = Box()
    private var roots: [SharedFolderRoot] {
        get { box.roots }
        set { box.roots = newValue }
    }
    private var settings: [RuntimePackageID: String] {
        get { box.settings }
        set { box.settings = newValue }
    }

    private let app = RuntimePackageID(rawValue: "io.fixture.hello")!

    override func setUp() async throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-share-\(UUID().uuidString)")
        secondURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-share2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)
        try "hello".write(
            to: rootURL.appendingPathComponent("note.txt"), atomically: true,
            encoding: .utf8)
        try Data(count: 64).write(to: rootURL.appendingPathComponent("blob.bin"))
        try "hidden".write(
            to: rootURL.appendingPathComponent(".secret"), atomically: true,
            encoding: .utf8)
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "nested".write(
            to: rootURL.appendingPathComponent("sub/deep.txt"), atomically: true,
            encoding: .utf8)
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("Fake.app"), withIntermediateDirectories: true)
        // A symlink that escapes the root must never be followed (§6.4).
        try FileManager.default.createSymbolicLink(
            atPath: rootURL.appendingPathComponent("escape").path,
            withDestinationPath: "/etc/hosts")
        box.roots = [
            SharedFolderRoot(
                rootID: "shared", title: "Shared", url: rootURL, maxAccess: .readWrite),
            SharedFolderRoot(
                rootID: "docs", title: "Docs", url: secondURL, maxAccess: .readOnly),
        ]
        box.settings = [app: "readWrite"]
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: rootURL)
        try? FileManager.default.removeItem(at: secondURL)
    }

    private func service() -> SharedFolderService {
        let box = box
        return SharedFolderService(
            source: SharedFolderService.Source(
                roots: { box.roots },
                valueForPackage: { box.settings[$0] ?? "off" }))
    }

    // MARK: Roots

    func testListRootsForPackage() async throws {
        let list = try await service().listRoots(package: app)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].rootID, "shared")
        XCTAssertEqual(list[0].access, .readWrite)
        XCTAssertEqual(list[1].access, .readOnly)  // capped by the root
        XCTAssertTrue(list[0].available)
        XCTAssertGreaterThan(list[0].bytesFree, 0)
    }

    func testListRootsSkipsPackagesWithoutAccess() async throws {
        let other = RuntimePackageID(rawValue: "io.other.app")!
        let list = try await service().listRoots(package: other)
        XCTAssertTrue(list.isEmpty)
    }

    func testDocumentsUIListsNamesOnly() async throws {
        let ui = RuntimePackageID(rawValue: SharedFolderService.documentsUIPackage)!
        let list = try await service().listRoots(package: ui)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].access, .readOnly)
        // Browsing never opens content.
        await assertDenied {
            try await service().openFile(package: ui, rootID: "shared", path: "note.txt", mode: .read)
        }
    }

    func testPackageSettingCapsRootAccess() async throws {
        box.settings[app] = "readOnly"
        let list = try await service().listRoots(package: app)
        XCTAssertEqual(list[0].access, .readOnly)
    }

    // MARK: Listing and stat

    func testQueryChildrenFiltersHiddenAndPackages() async throws {
        let page = try await service().queryChildren(
            package: app, rootID: "shared", path: "", pageToken: "")
        let names = page.entries.map(\.name)
        XCTAssertTrue(names.contains("note.txt"))
        XCTAssertTrue(names.contains("sub"))
        XCTAssertFalse(names.contains(".secret"))
        XCTAssertFalse(names.contains("Fake.app"))
        XCTAssertFalse(names.contains("escape"))  // symlink is not regular
        XCTAssertEqual(page.nextPageToken, "")
    }

    func testStatDocInfo() async throws {
        let info = try await service().stat(package: app, rootID: "shared", path: "note.txt")
        XCTAssertEqual(info.size, 5)
        XCTAssertEqual(info.mimeType, "text/plain")
        XCTAssertFalse(info.isDirectory)
        let dir = try await service().stat(package: app, rootID: "shared", path: "sub")
        XCTAssertTrue(dir.isDirectory)
    }

    func testStatRootItself() async throws {
        let info = try await service().stat(package: app, rootID: "shared", path: "")
        XCTAssertTrue(info.isDirectory)
        XCTAssertEqual(info.name, "Shared")
    }

    // MARK: Path confinement (§6.4 rules 2–3)

    func testOutsideRootIsRejected() async throws {
        await assertDenied {
            try await service().stat(package: app, rootID: "shared", path: "../escape")
        }
        await assertDenied {
            try await service().stat(package: app, rootID: "shared", path: "sub/../../etc/hosts")
        }
        await assertDenied {
            try await service().stat(package: app, rootID: "shared", path: "/etc/hosts")
        }
    }

    func testHiddenPathIsRejected() async throws {
        await assertDenied {
            try await service().stat(package: app, rootID: "shared", path: ".secret")
        }
        await assertDenied {
            try await service().stat(package: app, rootID: "shared", path: "Fake.app/Contents/x")
        }
    }

    func testSymlinkCanNeverLeaveTheRoot() async throws {
        await assertDenied {
            try await service().openFile(
                package: app, rootID: "shared", path: "escape", mode: .read)
        }
    }

    func testPackageWithoutAccessIsDenied() async throws {
        let other = RuntimePackageID(rawValue: "io.other.app")!
        await assertDenied {
            try await service().stat(package: other, rootID: "shared", path: "note.txt")
        }
    }

    // MARK: Open / read / write / close

    func testReadRange() async throws {
        let svc = service()
        let (handle, size) = try await svc.openFile(
            package: app, rootID: "shared", path: "note.txt", mode: .read)
        XCTAssertEqual(size, 5)
        let data = try await svc.readRange(handle: handle, offset: 0, length: 4)
        XCTAssertEqual(String(data: data, encoding: .utf8), "hell")
        let tail = try await svc.readRange(handle: handle, offset: 4, length: 8)
        XCTAssertEqual(tail, Data("o".utf8))
        try await svc.closeFile(handle: handle, fsync: false)
    }

    func testReadOverLimitRejected() async throws {
        let svc = service()
        let (handle, _) = try await svc.openFile(
            package: app, rootID: "shared", path: "blob.bin", mode: .read)
        await assertFailureCode(.invalidArgument) {
            try await svc.readRange(handle: handle, offset: 0, length: 2_000_000)
        }
        try await svc.closeFile(handle: handle, fsync: false)
    }

    func testWriteRangeNeedsReadWrite() async throws {
        try "x".write(
            to: secondURL.appendingPathComponent("edit.txt"), atomically: true,
            encoding: .utf8)
        await assertDenied {
            try await service().openFile(
                package: app, rootID: "docs", path: "edit.txt", mode: .write)
        }
    }

    func testWriteMarksFileQuarantined() async throws {
        let svc = service()
        try "x".write(
            to: secondURL.appendingPathComponent("edit.txt"), atomically: true,
            encoding: .utf8)
        box.roots[1] = SharedFolderRoot(
            rootID: "docs", title: "Docs", url: secondURL, maxAccess: .readWrite)
        let (handle, _) = try await svc.openFile(
            package: app, rootID: "docs", path: "edit.txt", mode: .readWrite)
        try await svc.writeRange(handle: handle, offset: 1, data: Data("y".utf8))
        try await svc.closeFile(handle: handle, fsync: true)
        var value = [CChar](repeating: 0, count: 512)
        let length = getxattr(
            secondURL.appendingPathComponent("edit.txt").path, "com.apple.quarantine",
            &value, value.count, 0, 0)
        XCTAssertGreaterThan(length, 0)
        XCTAssertEqual(
            String(
                data: FileManager.default.contents(atPath: secondURL.appendingPathComponent("edit.txt").path) ?? Data(),
                encoding: .utf8),
            "xy")
    }

    // MARK: Create / delete / rename

    func testCreateDocumentMakesNameUnique() async throws {
        let svc = service()
        let first = try await svc.createDocument(
            package: app, rootID: "shared", parentPath: "", name: "note.txt", isDirectory: false)
        XCTAssertEqual(first.name, "note (1).txt")
        let second = try await svc.createDocument(
            package: app, rootID: "shared", parentPath: "", name: "note.txt", isDirectory: false)
        XCTAssertEqual(second.name, "note (2).txt")
    }

    func testCreateNeedsReadWrite() async throws {
        await assertDenied {
            try await service().createDocument(
                package: app, rootID: "docs", parentPath: "", name: "n.txt", isDirectory: false)
        }
    }

    func testDeleteAndRename() async throws {
        let svc = service()
        let renamed = try await svc.renameDocument(
            package: app, rootID: "shared", path: "note.txt", newName: "renamed.txt")
        XCTAssertEqual(renamed.name, "renamed.txt")
        try await svc.deleteDocument(package: app, rootID: "shared", path: "renamed.txt")
        await assertFailureCode(.notFound) {
            try await svc.stat(package: app, rootID: "shared", path: "renamed.txt")
        }
    }

    // MARK: Limits

    func testHandleLimitPerPackage() async throws {
        let svc = service()
        var opened: [UInt64] = []
        for _ in 0..<SharedFolderService.handlesPerPackage {
            let (h, _) = try await svc.openFile(
                package: app, rootID: "shared", path: "note.txt", mode: .read)
            opened.append(h)
        }
        await assertFailureCode(.resourceExhausted) {
            try await svc.openFile(
                package: app, rootID: "shared", path: "note.txt", mode: .read)
        }
        await svc.closeAll()
    }

    func testNameSanitizing() {
        XCTAssertEqual(SharedFolderService.sanitizedName("a/b:c.txt"), "a-b-c.txt")
        XCTAssertEqual(SharedFolderService.sanitizedName("  .hidden  "), "hidden")
        XCTAssertNil(SharedFolderService.sanitizedName("..."))
        XCTAssertEqual(
            SharedFolderService.nameWithExtension("file", mimeType: "image/png"),
            "file.png")
        XCTAssertEqual(
            SharedFolderService.nameWithExtension("file.txt", mimeType: "text/plain"),
            "file.txt")
    }

    // MARK: Helpers

    private func assertDenied<T>(
        file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> T
    ) async {
        do {
            _ = try await body()
            XCTFail("expected SharedFolderFailure", file: file, line: line)
        } catch let failure as SharedFolderFailure {
            XCTAssertNotNil(failure.failure, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    private func assertFailureCode<T>(
        _ code: SharedFolderFailure.Code, file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> T
    ) async {
        do {
            _ = try await body()
            XCTFail("expected SharedFolderFailure.\(code)", file: file, line: line)
        } catch let failure as SharedFolderFailure {
            XCTAssertEqual(failure.code, code, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}
