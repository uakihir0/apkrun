import Foundation
import GraphicsCoreTestSupport
import XCTest

/// Replays the `virtio-gpu-request` and `resource-table` seed corpora
/// (test-strategy.md §7.2, #92): every seed must return through a typed
/// error — a trap is a finding.
final class FuzzCorpusReplayTests: XCTestCase {
    private func corpusFiles(_ target: String) throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // GraphicsCoreSystemTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // GraphicsCore
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repo root
        let directory =
            root
            .appendingPathComponent("Tests/Fixtures/fuzz/\(target)")
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.isEmpty, "\(target) corpus must not be empty")
        return files
    }

    func testVirtioGPURequestCorpus() throws {
        for file in try corpusFiles("virtio-gpu-request") {
            let bytes = try Data(contentsOf: file)
            bytes.withUnsafeBytes { buffer in
                let input = buffer.bindMemory(to: UInt8.self)
                GraphicsCoreFuzzEntries.virtioGPURequest(input)
            }
        }
    }

    func testResourceTableCorpus() throws {
        for file in try corpusFiles("resource-table") {
            let bytes = try Data(contentsOf: file)
            bytes.withUnsafeBytes { buffer in
                let input = buffer.bindMemory(to: UInt8.self)
                GraphicsCoreFuzzEntries.resourceTable(input)
            }
        }
    }
}
