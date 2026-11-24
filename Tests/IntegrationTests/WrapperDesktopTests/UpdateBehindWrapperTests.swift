import Foundation
import XCTest

/// #50 T2 (issues/M07-mac-app-wrappers.md): steps 2–4 of the G9 flow against a
/// real daemon and the lab Mac's TCC state — install HelloUpdate V1 with an
/// automatic provider, wrap it, stage and install V2 after the app quits, and
/// run V2 from the unchanged wrapper (`data HELLO`). One test per provider:
/// the LocalProvider (`local:` repo) and the Direct test service
/// (`update-server.py`, update-system.md §3.4).
///
/// Runs only under the `WrapperDesktop` integration configuration:
/// `APKRUN_WRAPPERDESKTOP_CLI` names the CLI, `APKRUN_UBW_V1_APK` and
/// `APKRUN_UBW_UPDATE_REPO` stage the fixture and its `local:` repo,
/// `APKRUN_UBW_ADB` gives logcat markers, and `APKRUN_UBW_UPDATE_SERVER`
/// names the `update-server.py` script for the Direct case. Suites clean up
/// `~/Applications` (test-strategy.md §3.9).
final class UpdateBehindWrapperTests: XCTestCase {

    private static let package = "io.apkrun.fixture.helloupdate"
    private static let bundleId = "io.apkrun.android.io.apkrun.fixture.helloupdate"
    private static let appName = "HelloUpdate.app"

    private var userApplications: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["APKRUN_WRAPPERDESKTOP_CLI"] != nil else {
            throw XCTSkip("APKRUN_WRAPPERDESKTOP_CLI is not set; the suite runs on a lab Mac.")
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(
            at: userApplications.appendingPathComponent(Self.appName))
        try super.tearDownWithError()
    }

    private func cli() throws -> String {
        try XCTUnwrap(ProcessInfo.processInfo.environment["APKRUN_WRAPPERDESKTOP_CLI"])
    }

    private func input(_ name: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            throw XCTSkip("the T2 staging sets \(name)")
        }
        return value
    }

    /// The LocalProvider reads the repo directory `update policy` names.
    func testLocalProviderUpdateBehindUnchangedWrapper() async throws {
        let provider = "local:\(try input("APKRUN_UBW_UPDATE_REPO"))"
        try await runScenario(provider: provider)
    }

    /// The Direct test service synthesizes the manifest update-system.md §3.4
    /// describes; the provider spec is the manifest URL of version 2.
    func testDirectProviderUpdateBehindUnchangedWrapper() async throws {
        let serverScript = try input("APKRUN_UBW_UPDATE_SERVER")
        let repo = try input("APKRUN_UBW_UPDATE_REPO")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [serverScript, "--port", "0", repo]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        defer { process.terminate() }
        // The server prints `update-server.py: <base> serving <root>` on one
        // line; wait for it and parse the port.
        let lineData = out.fileHandleForReading.availableData
        let line = String(data: lineData, encoding: .utf8) ?? ""
        var base = ""
        if let match = line.range(
            of: #"update-server\.py: (http://\S+)"#, options: .regularExpression)
        {
            base = String(line[match].dropFirst("update-server.py: ".count))
        }
        XCTAssertFalse(base.isEmpty, "update-server.py never printed its base URL")
        let provider = "direct:\(base)/local/\(Self.package)/2/manifest.json"
        try await runScenario(provider: provider)
    }

    /// Steps 2–4: V1 installs with the provider, the wrapper runs V1, a
    /// user-initiated update stages V2 while it runs, quitting installs V2,
    /// and the same bundle runs V2 with V1's data.
    private func runScenario(provider: String) async throws {
        executionTimeAllowance = 1800
        let cli = try cli()
        let v1 = try input("APKRUN_UBW_V1_APK")
        let adb = try input("APKRUN_UBW_ADB")
        let app = userApplications.appendingPathComponent(Self.appName)
        try? FileManager.default.removeItem(at: app)

        // Step 2.
        _ = try run(
            cli,
            [
                "install", v1, "--yes",
                "--provider", provider,
                "--updates", "automatic",
            ], timeout: 600)
        _ = try run(cli, ["wrap", Self.package, "--output", userApplications.path], timeout: 600)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: app.path),
            "wrapper missing at \(app.path)")
        let hashesBefore = try hashList(app)
        _ = try run("/usr/bin/open", [app.path], timeout: 30)
        try await waitForMarker("version 1", adb: adb, within: 300)

        // Step 3.
        let updateOutput = try run(cli, ["update", Self.package], timeout: 600)
        XCTAssertTrue(
            updateOutput.contains("will update when \(Self.package) quits"), updateOutput)
        _ = try run(
            "/usr/bin/osascript",
            ["-e", "tell application id \"\(Self.bundleId)\" to quit"], timeout: 60)
        let installDeadline = Date().addingTimeInterval(120)
        var version = try installedVersion(cli)
        while version != 2, Date() < installDeadline {
            try await Task.sleep(for: .seconds(2))
            version = try installedVersion(cli)
        }
        XCTAssertEqual(version, 2, "V2 did not install after the wrapper quit")

        // Step 4.
        _ = try run("/usr/bin/open", [app.path], timeout: 30)
        try await waitForMarker("data HELLO", adb: adb, within: 300)
        try await waitForMarker("version 2", adb: adb, within: 60)
        XCTAssertEqual(
            try hashList(app), hashesBefore,
            "the update changed the wrapper bundle")
        _ = try run(
            "/usr/bin/codesign",
            ["--verify", "--deep", "--strict", "--all-architectures", app.path])
    }

    private func installedVersion(_ cli: String) throws -> Int {
        let info = try run(cli, ["info", Self.package])
        guard let match = info.range(of: #"\((\d+)\)"#, options: .regularExpression),
            let code = Int(info[match].dropFirst().dropLast())
        else {
            XCTFail("no version code in `apkrun info` output: \(info)")
            return -1
        }
        return code
    }

    /// The file-hash list of wrapper.md §9.1 via find+shasum — contents only.
    private func hashList(_ app: URL) throws -> String {
        try run(
            "/bin/sh",
            [
                "-c",
                "find '\(app.path)' -type f -print0 | sort -z "
                    + "| xargs -0 shasum -a 256 | sort -k2",
            ], timeout: 120)
    }

    private func waitForMarker(_ marker: String, adb: String, within seconds: TimeInterval)
        async throws
    {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let log = try run(adb, ["logcat", "-d", "-s", "APKRUN-FIXTURE"], timeout: 60)
            if log.contains(marker) { return }
            try await Task.sleep(for: .seconds(5))
        }
        XCTFail("the fixture never logged `\(marker)`")
    }

    private func run(_ tool: String, _ args: [String], timeout: TimeInterval = 60) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        return String(
            data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
