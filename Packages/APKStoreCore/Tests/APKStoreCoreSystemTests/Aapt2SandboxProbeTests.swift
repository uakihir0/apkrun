import APKStoreCoreTestSupport
import Foundation
import XCTest

@testable import APKStoreCore

/// Replays the `apk-signing-block` and `aapt2-badging` seed corpora
/// (test-strategy.md §7.2, #92) and probes the aapt2 sandbox-exec profile
/// (security-model.md §9 SR-06): writes and networking must be denied, reads
/// of the tool, the staged APK, and the ticket directory allowed.
final class Aapt2SandboxProbeTests: XCTestCase {
    private func corpusFiles(_ target: String) throws -> [URL] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // APKStoreCoreSystemTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // APKStoreCore
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Tests/Fixtures/fuzz/\(target)")
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.isEmpty, "\(target) corpus must not be empty")
        return files
    }

    func testSigningBlockCorpus() throws {
        for file in try corpusFiles("apk-signing-block") {
            try Data(contentsOf: file).withUnsafeBytes { buffer in
                APKStoreCoreFuzzEntries.apkSigningBlock(
                    buffer.bindMemory(to: UInt8.self))
            }
        }
    }

    func testAapt2BadgingCorpus() throws {
        for file in try corpusFiles("aapt2-badging") {
            try Data(contentsOf: file).withUnsafeBytes { buffer in
                APKStoreCoreFuzzEntries.aapt2Badging(
                    buffer.bindMemory(to: UInt8.self))
            }
        }
    }

    /// T1 probe of `APKInspector.sandboxProfile` — every probe is a
    /// `sandbox-exec -p <profile> /bin/sh -c <command>` run checked by exit
    /// code. Requires /usr/bin/sandbox-exec (present on every macOS).
    func testAapt2SandboxProfileDeniesWritesAndNetwork() throws {
        let sandbox = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        guard FileManager.default.isExecutableFile(atPath: sandbox.path) else {
            throw XCTSkip("sandbox-exec missing")
        }
        let tool = URL(fileURLWithPath: "/usr/bin/true")
        let ticket = FileManager.default.temporaryDirectory
            .appendingPathComponent("aapt2-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: ticket, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ticket) }
        let apk = ticket.appendingPathComponent("app.apk")
        try Data("PK".utf8).write(to: apk)
        let profile = APKInspector.sandboxProfile(
            tool: tool, apk: apk, importDirectory: ticket)

        func probe(_ command: String) -> Int32 {
            let process = Process()
            process.executableURL = sandbox
            process.arguments = ["-p", profile, "/bin/sh", "-c", command]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        // Reads the profile allows must succeed.
        XCTAssertEqual(probe("cat '\(tool.path)' > /dev/null"), 0, "tool read")
        XCTAssertEqual(probe("cat '\(apk.path)' > /dev/null"), 0, "APK read")
        // Writes outside the ticket directory and any network use must fail.
        XCTAssertNotEqual(probe("touch /tmp/apkrun-sandbox-probe"), 0, "/tmp write")
        XCTAssertNotEqual(probe("echo x > '$HOME/probe'"), 0, "home write")
        XCTAssertNotEqual(
            probe("/usr/bin/nc -z 127.0.0.1 22 </dev/null"), 0, "loopback net")
    }
}
