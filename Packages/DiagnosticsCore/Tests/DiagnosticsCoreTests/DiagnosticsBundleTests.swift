import Foundation
import XCTest

@testable import DiagnosticsCore

/// T1 tests for the report archive writer and the logcat filter
/// (diagnostics.md §8).
final class DiagnosticsBundleTests: XCTestCase {

    private func makeOptions() -> DiagnosticsOptions {
        DiagnosticsOptions(
            createdBy: "cli", mode: "full",
            reportID: "0123456789abcdef0123456789abcdef",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000))
    }

    private func makeContext() -> DiagnosticsSummaryContext {
        DiagnosticsSummaryContext(
            statusLine: "Android failed to start",
            remediation: "Open APKRun and use Restart Runtime.",
            buildLine: "APKRun 1.0 (1000) · apkrund 1.0 (1000) · image b417 · agent 1.0 (1000)",
            healthRows: ["✕ runtime.boot Runtime boots"],
            recentProblems: ["2026-09-30 10:15:02 runtime.adbConnectTimeout op 07ac9d1e"],
            appsLine: "Apps: 2 installed — com.farmerbb.notepad, org.lineageos.eleven",
            guestMissingReason: "Android was not running",
            operationID: "d1d834fe00000000")
    }

    /// The archive inflates with `ditto -x -k` and carries the redacted files
    /// plus summary.txt and manifest.json at the §8.2 root.
    func testWriterProducesReadableZip() throws {
        let builder = DiagnosticsBundleBuilder()
        try builder.add("host/environment.json", text: "{\"app\":\"com.example\"}")
        try builder.add("host/health.txt", text: "serial AB123456 home /Users/alice")
        builder.omit("guest/logcat.txt", reason: "guestAgentUnavailable")

        let identity = RedactionIdentity(
            homeDirectory: "/Users/alice",
            userName: "alice", fullUserName: "Alice Example",
            computerName: "Alice's MacBook", localHostName: "alice-mac")
        let redactor = Redactor(identity: identity)
        let writer = DiagnosticsBundleWriter(
            redactor: redactor, options: makeOptions(), build: "1.0 (1000)")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let result = try writer.write(
            bundle: builder, summaryContext: makeContext(), to: handle)
        try handle.close()

        XCTAssertTrue(result.summary.hasPrefix("APKRun Diagnostics Report"))
        XCTAssertTrue(result.summary.contains("✕ runtime.boot"))
        XCTAssertTrue(result.summary.contains("Not collected"))

        let unzip = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-out-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: unzip) }
        try FileManager.default.createDirectory(
            at: unzip, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", url.path, unzip.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let stamp = DiagnosticsBundleWriter.directoryStamp(makeOptions().createdAt)
        let root = unzip.appendingPathComponent("APKRun-Diagnostics-\(stamp)")
        let manifestData = try Data(
            contentsOf: root.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(
            DiagnosticsManifest.self, from: manifestData)
        XCTAssertEqual(manifest.format, 1)
        XCTAssertEqual(manifest.reportID, makeOptions().reportID)
        XCTAssertEqual(manifest.mode, "full")
        XCTAssertEqual(manifest.createdBy, "cli")
        XCTAssertEqual(manifest.redactionRulesVersion, 1)
        XCTAssertTrue(manifest.files.contains { $0.path == "host/environment.json" })
        XCTAssertTrue(manifest.files.contains { $0.path == "summary.txt" })
        // The manifest cannot hash itself.
        XCTAssertEqual(manifest.files.count, 3)
        XCTAssertEqual(
            manifest.omitted.first?.reason, "guestAgentUnavailable")

        let health = try String(
            contentsOf: root.appendingPathComponent("host/health.txt"),
            encoding: .utf8)
        XCTAssertTrue(health.contains("~/"), health)
        XCTAssertFalse(health.contains("/Users/alice"))
    }

    /// `summary.txt` matches the §8.3 layout.
    func testSummaryLayout() throws {
        let text = DiagnosticsBundleWriter.summary(
            options: makeOptions(), context: makeContext())
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        XCTAssertEqual(lines.first, "APKRun Diagnostics Report")
        XCTAssertTrue(lines[1].hasPrefix("Created "))
        XCTAssertTrue(lines[1].contains("01234567"))
        XCTAssertTrue(lines.contains("Status: Android failed to start"))
        XCTAssertTrue(lines.contains("  Suggested: Open APKRun and use Restart Runtime."))
        XCTAssertTrue(
            lines.contains("Health: 1 failure(s), 0 warning(s) (see host/health.txt)"))
        XCTAssertTrue(lines.contains("Recent problems (last 7 days, from logs)"))
        XCTAssertTrue(lines.contains("Privacy"))
        XCTAssertTrue(
            lines.contains("  Omitted: guest logs (Android was not running)."))
    }

    /// Re-scan after redaction drops the file with `redactionFailed`.
    func testRescanDropsFileOnKnownSecret() throws {
        let builder = DiagnosticsBundleBuilder()
        // A secret that survives the pattern scan (short marker not matching
        // any L4 rule) is caught by the known-secret re-scan.
        try builder.add("host/x.txt", text: "data s3cr3t-token end")
        let identity = RedactionIdentity(
            homeDirectory: "/Users/alice",
            userName: "alice", fullUserName: "Alice",
            computerName: "Mac", localHostName: "mac",
            knownSecrets: ["s3cr3t-token"])
        let redactor = Redactor(identity: identity)
        let writer = DiagnosticsBundleWriter(
            redactor: redactor, options: makeOptions(), build: "b")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let result = try writer.write(
            bundle: builder, summaryContext: makeContext(), to: handle)
        try handle.close()
        XCTAssertTrue(
            result.omitted.contains {
                $0.item == "host/x.txt" && $0.reason == "redactionFailed"
            })
    }

    /// The builder refuses paths outside the tree and non-text payloads.
    func testBuilderValidation() throws {
        let builder = DiagnosticsBundleBuilder()
        XCTAssertThrowsError(try builder.add("../escape.txt", text: "x"))
        XCTAssertThrowsError(try builder.add("/abs.txt", text: "x"))
        XCTAssertThrowsError(try builder.add("a\\b.txt", text: "x"))
        XCTAssertThrowsError(try builder.add("dir/binary.bin", text: "x"))
        XCTAssertNoThrow(try builder.add("guest/crashes/x.ips", text: "{}"))
        XCTAssertNoThrow(try builder.add("host/health.txt", text: "x"))
        XCTAssertNoThrow(try builder.add("logs/app.log", text: "x"))
        XCTAssertNoThrow(try builder.add("x.jsonl", text: "{}"))
    }

    /// The logcat filter keeps system UIDs and APKRun tags and trims app
    /// noise to fatal-exception blocks (diagnostics.md §8.3).
    func testLogcatFilter() throws {
        let line = { (uid: Int, level: String, tag: String, message: String) in
            "2026-09-30 10:15:02.000  1234  1235  \(uid) \(level) \(tag): \(message)"
        }
        let input = [
            line(1000, "I", "system_server", "system line kept"),
            line(10001, "D", "someapp", "app noise dropped"),
            line(10001, "I", "apkrun.guestd", "agent line kept"),
            line(10001, "E", "AndroidRuntime", "FATAL EXCEPTION: main"),
            line(10001, "E", "AndroidRuntime", "Process: com.crash, PID: 1234"),
            line(10001, "E", "AndroidRuntime", "java.lang.RuntimeException: boom"),
            line(10001, "D", "otherapp", "back to noise"),
        ].joined(separator: "\n")

        let filtered = LogcatFilter.filter(input, includeAll: false)
        XCTAssertTrue(filtered.contains("system line kept"))
        XCTAssertTrue(filtered.contains("agent line kept"))
        XCTAssertTrue(filtered.contains("FATAL EXCEPTION"))
        XCTAssertTrue(filtered.contains("java.lang.RuntimeException"))
        XCTAssertFalse(filtered.contains("app noise dropped"))
        XCTAssertFalse(filtered.contains("back to noise"))

        // --include-logcat keeps everything.
        XCTAssertEqual(LogcatFilter.filter(input, includeAll: true), input)
    }
}
