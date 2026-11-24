import Foundation
import UpdateCoreTestSupport
import XCTest

/// Replays the `direct-manifest`, `fdroid-index`, and `github-releases`
/// seed corpora (test-strategy.md §7.2, #92).
final class FuzzCorpusReplayTests: XCTestCase {
    private func corpusFiles(_ target: String) throws -> [URL] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // UpdateCoreSystemTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // UpdateCore
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Tests/Fixtures/fuzz/\(target)")
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.isEmpty, "\(target) corpus must not be empty")
        return files
    }

    func testDirectManifestCorpus() throws {
        for file in try corpusFiles("direct-manifest") {
            try Data(contentsOf: file).withUnsafeBytes { buffer in
                UpdateCoreFuzzEntries.directManifest(
                    buffer.bindMemory(to: UInt8.self))
            }
        }
    }

    func testFDroidIndexCorpus() throws {
        for file in try corpusFiles("fdroid-index") {
            try Data(contentsOf: file).withUnsafeBytes { buffer in
                UpdateCoreFuzzEntries.fdroidIndex(
                    buffer.bindMemory(to: UInt8.self))
            }
        }
    }

    func testGitHubReleasesCorpus() throws {
        for file in try corpusFiles("github-releases") {
            try Data(contentsOf: file).withUnsafeBytes { buffer in
                UpdateCoreFuzzEntries.githubReleases(
                    buffer.bindMemory(to: UInt8.self))
            }
        }
    }
}
