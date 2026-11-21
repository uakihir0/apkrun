import Foundation
import XCTest

/// Gate G7 (roadmap.md §2, test-strategy.md §5): HelloUpdate V1 updates itself
/// to V2 through the gentle-update pipeline — V2 stages while the app runs,
/// installs within 30 s after the session ends, and the reopened V2 still
/// reads V1's data (`data HELLO`).
///
/// It runs in the `G7` configuration of AcceptanceTests.xctestplan, driven by
/// the CLI of the Debug APKRun.app that scripts/run-gate.sh stages, against the
/// custom image. The CLI output and the read package records go to
/// APKRUN_G7_ARTIFACTS, outside the repository.
final class G7GentleUpdateTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        let environment = ProcessInfo.processInfo.environment
        let selected = environment["APKRUN_ACCEPTANCE_SUITE"] == "g7"
        if environment["APKRUN_G7_REQUIRED"] == "1" {
            guard selected else {
                throw XCTSkip("The G7 check runs in the G7 test-plan configuration.")
            }
            return
        }
        guard selected else {
            throw XCTSkip("The G7 check runs in the G7 test-plan configuration.")
        }
    }

    /// The inputs scripts/run-gate.sh stages for the gate.
    private struct Inputs {
        let cli: URL
        let app: URL
        let v1: URL
        let v2: URL
        let updateRepo: URL
        let artifacts: URL
        let adb: URL
    }

    private static func inputs() throws -> Inputs {
        func required(_ name: String) throws -> URL {
            guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
                throw XCTSkip("run-gate.sh G7 sets \(name)")
            }
            return URL(fileURLWithPath: value)
        }
        return Inputs(
            cli: try required("APKRUN_G7_CLI"),
            app: try required("APKRUN_G7_APP"),
            v1: try required("APKRUN_G7_V1_APK"),
            v2: try required("APKRUN_G7_V2_APK"),
            updateRepo: try required("APKRUN_G7_UPDATE_REPO"),
            artifacts: try required("APKRUN_G7_ARTIFACTS"),
            adb: try required("APKRUN_G7_ADB")
        )
    }

    private static let package = "io.apkrun.fixture.helloupdate"

    func testV1UpdatesToV2WhenTheAppQuits() async throws {
        executionTimeAllowance = 1800
        let inputs = try Self.inputs()
        try FileManager.default.createDirectory(at: inputs.artifacts, withIntermediateDirectories: true)

        // The daemon runs as the per-user LaunchAgent (#32), as in G8.
        try await run(
            inputs.app.appendingPathComponent("Contents/MacOS/APKRun"),
            ["--register-runtime"])

        // Install V1 and give it the local update repo as its automatic
        // provider (update-system.md §2.1, §4.1).
        try await run(inputs.cli, ["install", inputs.v1.path, "--yes"])
        try await run(
            inputs.cli,
            [
                "update", "policy", Self.package, "--mode", "automatic",
                "--provider", "local:\(inputs.updateRepo.path)",
            ])
        XCTAssertEqual(try await installedVersion(inputs: inputs), 1)

        // V1 running: a user-initiated `apkrun update` stages V2 and reports
        // that it waits for the app to quit (update-system.md §7.3).
        try await run(inputs.cli, ["launch", Self.package])
        let updateOutput = try await output(inputs.cli.path, ["update", Self.package])
        XCTAssertTrue(
            updateOutput.contains("will update when \(Self.package) quits"), updateOutput)

        // While the session stays open the gate never opens: V2 must not
        // install. T2 owns the 10-minute dwell; the gate holds a bounded
        // window to catch an install racing the staging.
        let dwellDeadline = Date().addingTimeInterval(90)
        while Date() < dwellDeadline {
            XCTAssertEqual(
                try await installedVersion(inputs: inputs), 1,
                "the update installed while the app was open")
            try await Task.sleep(for: .seconds(5))
        }

        // Quitting opens the gate: V2 installs within 30 s of the session end
        // (update-system.md §7.2), and the staged install is reported.
        try await run(inputs.cli, ["stop", Self.package])
        let installDeadline = Date().addingTimeInterval(60)
        var version = try await installedVersion(inputs: inputs)
        while version != 2, Date() < installDeadline {
            try await Task.sleep(for: .seconds(2))
            version = try await installedVersion(inputs: inputs)
        }
        XCTAssertEqual(version, 2, "V2 did not install within 60 s of the app quitting")

        // Reopening launches V2, which still reads the data V1 wrote
        // (`data HELLO`) and reports its new version (fixture contract,
        // test-strategy.md §4.3); its first frame is the H4 evidence.
        try await run(inputs.cli, ["launch", Self.package])
        let markerDeadline = Date().addingTimeInterval(120)
        var markerSeen = false
        while !markerSeen, Date() < markerDeadline {
            let log = try await output(inputs.adb.path, ["logcat", "-d", "-s", "APKRUN-FIXTURE"])
            if log.contains("data HELLO"), log.contains("version 2") {
                markerSeen = true
                break
            }
            try await Task.sleep(for: .seconds(5))
        }
        XCTAssertTrue(markerSeen, "the reopened V2 never logged `data HELLO`/`version 2`")

        try updateOutput.write(
            to: inputs.artifacts.appendingPathComponent("update-output.txt"),
            atomically: true, encoding: .utf8)
        try await run(inputs.cli, ["stop", Self.package])
    }

    /// `apkrun info <package>` prints `Version: <name> (<code>)`
    /// (PackageQueryCommands). The guest's own version check backs it: the
    /// record and Android must agree on V2 before the test moves on.
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

    private func run(_ executable: URL, _ arguments: [String]) async throws {
        _ = try await output(executable.path, arguments)
    }

    private func output(_ executable: String, _ arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "G7GentleUpdateTests", code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(executable) \(arguments.joined(separator: " ")) failed: \(text)"
                ])
        }
        return text
    }
}
