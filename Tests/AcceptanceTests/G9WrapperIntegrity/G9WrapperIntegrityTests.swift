import Foundation
import WrapperCore
import XCTest

/// Gate G9 (roadmap.md §2, test-strategy.md §5): HelloUpdate V1 runs from its
/// Mac app, the gentle-update pipeline stages and installs V2 after the app
/// quits, and the reopened `HelloUpdate.app` — unchanged and not re-signed —
/// runs V2 with V1's data (`data HELLO`). The file hash list and the cdhash
/// before and after the update must be identical, and the deep check of
/// wrapper.md §9.1 must still pass.
///
/// It runs in the `G9` configuration of AcceptanceTests.xctestplan, driven by
/// the CLI of the Debug APKRun.app that scripts/run-gate.sh stages, against
/// the custom image. The hash list and the update output go to
/// APKRUN_G9_ARTIFACTS, outside the repository.
final class G9WrapperIntegrityTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        let environment = ProcessInfo.processInfo.environment
        let selected = environment["APKRUN_ACCEPTANCE_SUITE"] == "g9"
        if environment["APKRUN_G9_REQUIRED"] == "1" {
            guard selected else {
                throw XCTSkip("The G9 check runs in the G9 test-plan configuration.")
            }
            return
        }
        guard selected else {
            throw XCTSkip("The G9 check runs in the G9 test-plan configuration.")
        }
    }

    /// The inputs scripts/run-gate.sh stages for the gate.
    private struct Inputs {
        let cli: URL
        let app: URL
        let v1: URL
        let updateRepo: URL
        let artifacts: URL
        let adb: URL
    }

    private static func inputs() throws -> Inputs {
        func required(_ name: String) throws -> URL {
            guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
                throw XCTSkip("run-gate.sh G9 sets \(name)")
            }
            return URL(fileURLWithPath: value)
        }
        return Inputs(
            cli: try required("APKRUN_G9_CLI"),
            app: try required("APKRUN_G9_APP"),
            v1: try required("APKRUN_G9_V1_APK"),
            updateRepo: try required("APKRUN_G9_UPDATE_REPO"),
            artifacts: try required("APKRUN_G9_ARTIFACTS"),
            adb: try required("APKRUN_G9_ADB")
        )
    }

    private static let package = "io.apkrun.fixture.helloupdate"
    private static let appName = "HelloUpdate.app"

    func testUpdateBehindUnchangedWrapper() async throws {
        executionTimeAllowance = 1800
        let inputs = try Self.inputs()
        try FileManager.default.createDirectory(at: inputs.artifacts, withIntermediateDirectories: true)
        let wrapper = inputs.artifacts.appendingPathComponent(Self.appName)

        // The daemon runs as the per-user LaunchAgent (#32), as in G8.
        try await run(
            inputs.app.appendingPathComponent("Contents/MacOS/APKRun"),
            ["--register-runtime"])

        // Step 2: install V1 in automatic mode with the local update repo as
        // its provider, and generate the wrapper (roadmap.md §2 G9).
        try await run(
            inputs.cli,
            [
                "install", inputs.v1.path, "--yes",
                "--provider", "local:\(inputs.updateRepo.path)",
                "--updates", "automatic",
            ])
        let v1 = try await installedVersion(inputs: inputs)
        XCTAssertEqual(v1, 1)
        try await run(inputs.cli, ["wrap", Self.package, "--output", inputs.artifacts.path])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: wrapper.path),
            "wrapper missing at \(wrapper.path)")

        // The V1 fingerprint: file hash list, cdhash, and the deep check of
        // wrapper.md §9.1 (all-architecture strict signature).
        let hashesV1 = try WrapperFileHashes.compute(bundleURL: wrapper)
        XCTAssertFalse(hashesV1.isEmpty, "the hash list is empty")
        let cdhashV1 = try await cdhash(of: wrapper, inputs: inputs)
        try await run(
            "/usr/bin/codesign",
            ["--verify", "--deep", "--strict", "--all-architectures", wrapper.path])
        try serialize(hashesV1, to: inputs.artifacts.appendingPathComponent("hashes-v1.json"))
        try cdhashV1.write(
            to: inputs.artifacts.appendingPathComponent("cdhash-v1.txt"),
            atomically: true, encoding: .utf8)

        // V1 runs from the wrapper and writes HELLO; its marker is logged.
        try await run("/usr/bin/open", [wrapper.path])
        try await waitForMarker("version 1", inputs: inputs, within: 300)

        // Step 3: a user-initiated update stages V2 while the app runs and
        // reports that it waits for the app to quit (update-system.md §7.3).
        let updateOutput = try await output(inputs.cli.path, ["update", Self.package])
        XCTAssertTrue(
            updateOutput.contains("will update when \(Self.package) quits"), updateOutput)
        try updateOutput.write(
            to: inputs.artifacts.appendingPathComponent("update-output.txt"),
            atomically: true, encoding: .utf8)
        let stillV1 = try await installedVersion(inputs: inputs)
        XCTAssertEqual(stillV1, 1, "the update installed while the app was open")

        // Quitting HelloUpdate.app opens the gate: V2 installs with no user
        // action (update-system.md §7.2).
        try await run(
            "/usr/bin/osascript",
            ["-e", #"tell application id "io.apkrun.android.\#(Self.package)" to quit"#])
        let installDeadline = Date().addingTimeInterval(120)
        var version = try await installedVersion(inputs: inputs)
        while version != 2, Date() < installDeadline {
            try await Task.sleep(for: .seconds(2))
            version = try await installedVersion(inputs: inputs)
        }
        XCTAssertEqual(version, 2, "V2 did not install after the wrapper quit")

        // Step 4: the same wrapper runs V2, which reads V1's data
        // (`data HELLO`, test-strategy.md §4.3). No `codesign` ran on the
        // bundle: the file hash list and the cdhash equal the V1 values.
        try await run("/usr/bin/open", [wrapper.path])
        try await waitForMarker("data HELLO", inputs: inputs, within: 300)
        try await waitForMarker("version 2", inputs: inputs, within: 60)

        let hashesV2 = try WrapperFileHashes.compute(bundleURL: wrapper)
        XCTAssertEqual(hashesV2, hashesV1, "the update changed the wrapper bundle")
        try serialize(hashesV2, to: inputs.artifacts.appendingPathComponent("hashes-v2.json"))
        let cdhashV2 = try await cdhash(of: wrapper, inputs: inputs)
        XCTAssertEqual(cdhashV2, cdhashV1, "the update re-signed the wrapper")
        try await run(
            "/usr/bin/codesign",
            ["--verify", "--deep", "--strict", "--all-architectures", wrapper.path])

        try await run(inputs.cli, ["stop", Self.package])
    }

    /// `apkrun info <package>` prints `Version: <name> (<code>)`, as in G7.
    private func installedVersion(inputs: Inputs) async throws -> Int {
        let info = try await output(inputs.cli.path, ["info", Self.package])
        guard let match = info.range(of: #"\((\d+)\)"#, options: .regularExpression),
            let code = Int(info[match].dropFirst().dropLast())
        else {
            XCTFail("no version code in `apkrun info` output: \(info)")
            return -1
        }
        return code
    }

    /// `codesign -dv --verbose=4` prints `CDHash=<40 hex>` on stderr.
    private func cdhash(of wrapper: URL, inputs: Inputs) async throws -> String {
        let text = try await output(
            "/usr/bin/codesign", ["-dv", "--verbose=4", wrapper.path], stderrIsOutput: true)
        guard let match = text.range(of: #"CDHash=([0-9a-f]{40})"#, options: .regularExpression)
        else {
            XCTFail("no CDHash in `codesign -dv` output: \(text)")
            return ""
        }
        return String(text[match].dropFirst("CDHash=".count))
    }

    /// Waits for the fixture's logcat marker (test-strategy.md §4.3).
    private func waitForMarker(_ marker: String, inputs: Inputs, within seconds: TimeInterval)
        async throws
    {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let log = try await output(inputs.adb.path, ["logcat", "-d", "-s", "APKRUN-FIXTURE"])
            if log.contains(marker) { return }
            try await Task.sleep(for: .seconds(5))
        }
        XCTFail("the fixture never logged `\(marker)`")
    }

    private func serialize(_ hashes: [WrapperFileHash], to url: URL) throws {
        struct Row: Encodable {
            let path: String
            let sha256: String
        }
        let data = try JSONEncoder().encode(hashes.map { Row(path: $0.path, sha256: $0.sha256) })
        try data.write(to: url)
    }

    private func run(_ executable: URL, _ arguments: [String]) async throws {
        _ = try await output(executable.path, arguments)
    }

    private func run(_ executable: String, _ arguments: [String]) async throws {
        _ = try await output(executable, arguments)
    }

    private func output(
        _ executable: String, _ arguments: [String], stderrIsOutput: Bool = false
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = stderrIsOutput ? out : err
        try process.run()
        process.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "G9WrapperIntegrityTests", code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(executable) \(arguments.joined(separator: " ")) failed: \(text)"
                ])
        }
        return text
    }
}
