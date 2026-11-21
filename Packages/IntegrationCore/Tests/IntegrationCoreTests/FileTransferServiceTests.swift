import Foundation
import RuntimeAPI
import XCTest

@testable import IntegrationCore

/// T0 of FileTransferService: drop limits, the `.files` policy gate, and the
/// export offer flow (desktop-integration.md §6.2–§6.3).
final class FileTransferServiceTests: XCTestCase {
    private let app = RuntimePackageID(rawValue: "io.fixture.hello")!
    private let sessionID = UUID()

    /// A channel that records its calls; everything succeeds.
    private final class FakeChannel: FileTransferChannel, @unchecked Sendable {
        var imports: [(RuntimePackageID, Int, [ImportFileInfo])] = []
        var resolves: [(String, Bool)] = []
        var result = ImportResult(contentURIs: ["content://x/1"], disposition: "shared")

        func sendImport(
            package: RuntimePackageID, displayID: Int,
            handles: [FileHandle], infos: [ImportFileInfo]
        ) async throws(IntegrationFailure) -> ImportResult {
            imports.append((package, displayID, infos))
            return result
        }

        func resolveExport(
            offerID: String, package: RuntimePackageID, accept: Bool, writeTo: FileHandle?
        ) async throws(IntegrationFailure) {
            resolves.append((offerID, accept))
        }
    }

    private func makeService(
        channel: FakeChannel, filesOn: String? = "true"
    ) -> (FileTransferService, UnsafeSendableBox<[FileExportOffer]>) {
        let offers = UnsafeSendableBox<[FileExportOffer]>([])
        let settings = UnsafeSendableBox<[String: String?]>(
            filesOn.map { ["files": $0] } ?? [:])
        let policy = IntegrationPolicy(
            source: IntegrationSettingsSource(
                packageValue: { kind, _ in settings.value[kind.rawValue] ?? nil },
                globalEnabled: { _ in true }))
        let svc = FileTransferService(
            policy: policy, channel: channel,
            onExportOffered: { _, offer in offers.value.append(offer) })
        return (svc, offers)
    }

    private func infos(_ names: [(String, Int64)]) -> [ImportFileInfo] {
        names.enumerated().map {
            ImportFileInfo(fileIndex: $0.offset, name: $0.element.0, size: $0.element.1, uti: "public.data")
        }
    }

    // MARK: Limits (§6.2)

    func testTooManyFiles() async throws {
        let channel = FakeChannel()
        let (svc, _) = makeService(channel: channel)
        let many = infos((0..<21).map { ("f\($0)", 10) })
        do {
            _ = try await svc.importFiles(
                sessionID: sessionID, package: app, displayID: 0,
                handles: [], infos: many, windowIsKey: true)
            XCTFail("expected tooManyFiles")
        } catch IntegrationFailure.tooManyFiles(let count, let limit) {
            XCTAssertEqual(count, 21)
            XCTAssertEqual(limit, 20)
        }
        XCTAssertTrue(channel.imports.isEmpty)
    }

    func testFileTooLarge() async throws {
        let channel = FakeChannel()
        let (svc, _) = makeService(channel: channel)
        do {
            _ = try await svc.importFiles(
                sessionID: sessionID, package: app, displayID: 0,
                handles: [],
                infos: infos([("big.iso", FileTransferService.fileByteLimit + 1)]),
                windowIsKey: true)
            XCTFail("expected fileTooLarge")
        } catch IntegrationFailure.fileTooLarge(let name, _) {
            XCTAssertEqual(name, "big.iso")
        }
    }

    func testTotalTooLarge() async throws {
        let channel = FakeChannel()
        let (svc, _) = makeService(channel: channel)
        let two = FileTransferService.fileByteLimit
        do {
            _ = try await svc.importFiles(
                sessionID: sessionID, package: app, displayID: 0,
                handles: [],
                infos: infos([("a", two), ("b", two), ("c", two)]),
                windowIsKey: true)
            XCTFail("expected fileTooLarge for the drop total")
        } catch IntegrationFailure.fileTooLarge {}
    }

    // MARK: Policy

    func testFilesOffRefusesDrop() async throws {
        let channel = FakeChannel()
        let (svc, _) = makeService(channel: channel, filesOn: "false")
        do {
            _ = try await svc.importFiles(
                sessionID: sessionID, package: app, displayID: 0,
                handles: [], infos: infos([("n.txt", 1)]), windowIsKey: true)
            XCTFail("expected disabled")
        } catch IntegrationFailure.disabled(let kind, _) {
            XCTAssertEqual(kind, .files)
        }
        XCTAssertTrue(channel.imports.isEmpty)
    }

    func testDropFromBackgroundWindowRefused() async throws {
        let channel = FakeChannel()
        let (svc, _) = makeService(channel: channel)
        do {
            _ = try await svc.importFiles(
                sessionID: sessionID, package: app, displayID: 0,
                handles: [], infos: infos([("n.txt", 1)]), windowIsKey: false)
            XCTFail("expected disabled")
        } catch IntegrationFailure.disabled {}
    }

    func testImportReachesChannel() async throws {
        let channel = FakeChannel()
        let (svc, _) = makeService(channel: channel)
        let result = try await svc.importFiles(
            sessionID: sessionID, package: app, displayID: 7,
            handles: [], infos: infos([("a.txt", 3)]), windowIsKey: true)
        XCTAssertEqual(channel.imports.count, 1)
        XCTAssertEqual(channel.imports[0].1, 7)
        XCTAssertFalse(result.savedToDownloads)
    }

    // MARK: Export offers (§6.3)

    private func offer(_ id: String) -> FileExportOffer {
        FileExportOffer(
            offerID: id, sessionID: sessionID, sourcePackage: app,
            name: "report.pdf", size: 100, type: "application/pdf")
    }

    func testOfferGoesToSessionWindow() async throws {
        let channel = FakeChannel()
        let (svc, offers) = makeService(channel: channel)
        try await svc.exportOffered(offer("o1"), hasSession: true)
        XCTAssertEqual(offers.value.count, 1)
        XCTAssertEqual(offers.value.first?.offerID, "o1")
        XCTAssertTrue(channel.resolves.isEmpty)
    }

    func testOfferWithoutSessionDeclined() async throws {
        let channel = FakeChannel()
        let (svc, offers) = makeService(channel: channel)
        try await svc.exportOffered(offer("o2"), hasSession: false)
        XCTAssertTrue(offers.value.isEmpty)
        XCTAssertEqual(channel.resolves.map { "\($0.0):\($0.1)" }, ["o2:false"])
    }

    func testOfferDeniedByPolicyDeclined() async throws {
        let channel = FakeChannel()
        let (svc, offers) = makeService(channel: channel, filesOn: "false")
        try await svc.exportOffered(offer("o3"), hasSession: true)
        XCTAssertTrue(offers.value.isEmpty)
        XCTAssertEqual(channel.resolves.map { "\($0.0):\($0.1)" }, ["o3:false"])
    }

    func testAcceptExportWritesThroughChannel() async throws {
        let channel = FakeChannel()
        let (svc, _) = makeService(channel: channel)
        try await svc.exportOffered(offer("o4"), hasSession: true)
        try await svc.acceptExport(
            offerID: "o4", sessionID: sessionID, callerPackageID: app, writeTo: nil)
        XCTAssertEqual(channel.resolves.map { "\($0.0):\($0.1)" }, ["o4:false"])
    }

    func testWrongPackageCannotAnswer() async throws {
        let channel = FakeChannel()
        let (svc, _) = makeService(channel: channel)
        try await svc.exportOffered(offer("o5"), hasSession: true)
        let thief = RuntimePackageID(rawValue: "io.other.app")!
        do {
            try await svc.acceptExport(
                offerID: "o5", sessionID: sessionID, callerPackageID: thief,
                writeTo: nil)
            XCTFail("expected promptTimedOut")
        } catch IntegrationFailure.promptTimedOut {}
        // The real session can still answer.
        try await svc.acceptExport(
            offerID: "o5", sessionID: sessionID, callerPackageID: app, writeTo: nil)
        XCTAssertEqual(channel.resolves.map { "\($0.0):\($0.1)" }, ["o5:false"])
    }

    func testDiscardOffersForSession() async throws {
        let channel = FakeChannel()
        let (svc, _) = makeService(channel: channel)
        try await svc.exportOffered(offer("o6"), hasSession: true)
        await svc.discardOffers(of: sessionID)
        do {
            try await svc.acceptExport(
                offerID: "o6", sessionID: sessionID, callerPackageID: app,
                writeTo: nil)
            XCTFail("expected promptTimedOut")
        } catch IntegrationFailure.promptTimedOut {}
    }
}

/// A lock-free mutable box for @Sendable test captures.
final class UnsafeSendableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
