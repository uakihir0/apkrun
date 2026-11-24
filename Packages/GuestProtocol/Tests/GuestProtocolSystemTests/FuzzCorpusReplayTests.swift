import Foundation
import GuestProtocolTestSupport
import XCTest

/// Replays the `guest-frame-swift` seed corpus (test-strategy.md §7.2, #92).
final class FuzzCorpusReplayTests: XCTestCase {
    func testGuestFrameCorpus() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // GuestProtocolSystemTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // GuestProtocol
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Tests/Fixtures/fuzz/guest-frame-swift")
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let bytes = try Data(contentsOf: file)
            bytes.withUnsafeBytes { buffer in
                GuestProtocolFuzzEntries.guestFrame(
                    buffer.bindMemory(to: UInt8.self))
            }
        }
    }
}
