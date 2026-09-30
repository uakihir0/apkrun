import Foundation
import XCTest

final class LinuxGuestArtifactDirectoryTests: XCTestCase {
    func testArtifactDirectoryRejectsDocumentsPathsBeforeFollowingThem() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-artifact-path-\(UUID().uuidString)", isDirectory: true)
        let home = temporaryRoot.appendingPathComponent("home", isDirectory: true)
        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        let alias = home.appendingPathComponent("documents-alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: documents,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: documents)

        XCTAssertThrowsError(
            try LinuxGuestHarness.resolvedArtifactDirectory(
                documents.appendingPathComponent("linux-guest", isDirectory: true),
                homeDirectory: home
            )
        )
        XCTAssertThrowsError(
            try LinuxGuestHarness.resolvedArtifactDirectory(
                alias.appendingPathComponent("linux-guest", isDirectory: true),
                homeDirectory: home
            )
        )
        let escapedAlias =
            home
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("../documents-alias/linux-guest", isDirectory: true)
        XCTAssertThrowsError(
            try LinuxGuestHarness.resolvedArtifactDirectory(
                escapedAlias,
                homeDirectory: home
            )
        )
        let resolvedTemporaryDirectory = try LinuxGuestHarness.resolvedArtifactDirectory(
            home.appendingPathComponent("temporary/linux-guest", isDirectory: true),
            homeDirectory: home
        )
        XCTAssertTrue(resolvedTemporaryDirectory.path.hasSuffix("/home/temporary/linux-guest"))
    }

    func testDocumentsSubpathsAndSymlinkAliasesAreContained() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-artifact-path-\(UUID().uuidString)", isDirectory: true)
        let home = temporaryRoot.appendingPathComponent("home", isDirectory: true)
        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        let alias = home.appendingPathComponent("documents-alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: documents,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: documents)

        XCTAssertTrue(
            LinuxGuestHarness.isWithin(
                documents.appendingPathComponent("linux-guest", isDirectory: true),
                directory: documents
            )
        )
        XCTAssertTrue(
            LinuxGuestHarness.isWithin(
                alias.appendingPathComponent("linux-guest", isDirectory: true),
                directory: documents
            )
        )
        XCTAssertTrue(
            LinuxGuestHarness.isLexicallyWithin(
                documents.appendingPathComponent("linux-guest", isDirectory: true),
                directory: documents
            )
        )
        XCTAssertFalse(
            LinuxGuestHarness.isLexicallyWithin(
                home.appendingPathComponent("Documents-build", isDirectory: true),
                directory: documents
            )
        )
        XCTAssertFalse(
            LinuxGuestHarness.isWithin(
                home.appendingPathComponent("Documents-build", isDirectory: true),
                directory: documents
            )
        )
    }

    func testDefaultArtifactDirectoryRejectsSymlinkIntoDocuments() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-artifact-default-\(UUID().uuidString)", isDirectory: true)
        let home = temporaryRoot.appendingPathComponent("home", isDirectory: true)
        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        let defaultDirectory = temporaryRoot.appendingPathComponent("default", isDirectory: true)
        try FileManager.default.createDirectory(
            at: documents,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createSymbolicLink(
            at: defaultDirectory,
            withDestinationURL: documents
        )

        XCTAssertThrowsError(
            try LinuxGuestHarness.selectedArtifactDirectory(
                configuredDirectory: nil,
                defaultDirectory: defaultDirectory,
                homeDirectory: home
            )
        )
    }
}
