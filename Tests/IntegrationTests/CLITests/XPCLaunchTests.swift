import Foundation
import RuntimeAPI
import XCTest

/// CLI launch checks against the installed runtime through the daemon-backed CLI.
///
/// The Debug test uses the daemon-backed CLI embedded in the installed `APKRun Dev.app`; build that app with
/// `APKRUN_CLI_TRAITS=` so the CLI is signed with the exact cdhash trusted by its LaunchAgent. The Debug
/// LaunchAgent must inherit `APKRUN_TEST_HEADLESS_LAUNCH=1`; setting it in the test plan only affects the test
/// process and does not change an already registered daemon. Run under the dedicated test user because the CLI
/// uses the installed runtime data root. The Release configuration points to the production CLI and checks
/// `owner: apkrund`.
final class XPCLaunchTests: XCTestCase {
    private static let helloTextPackage = "io.apkrun.fixture.hellotext"
    private static let integrationSuite = "cli-xpc"

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["APKRUN_INTEGRATION_SUITE"] == Self.integrationSuite else {
            throw XCTSkip("The XPC CLI checks run in the AndroidStock `cli-xpc` test-plan configuration.")
        }
    }

    /// Installs the fixture through XPC, then verifies launch survives the launching CLI process.
    func testHelloTextRemainsRunningAfterLaunchCLIExits() throws {
        guard ProcessInfo.processInfo.environment["APKRUN_TEST_PRODUCTION_OWNER_ONLY"] != "1" else {
            throw XCTSkip("The production-owner configuration tests only the Release XPC identity.")
        }
        let target = try Self.cliTarget()
        try Self.requireDaemonBackedCLI(target)
        let fixtureAPK = try Self.fixtureAPK()

        let previousStatus = try Self.runCLI(target, arguments: ["status", "--json"])
        XCTAssertEqual(previousStatus.status, 0, previousStatus.failureDescription)
        let previousEnvelope = try Self.decode(StatusEnvelope.self, from: previousStatus.stdout)
        if previousEnvelope.result.sessions.contains(where: { $0.packageID.rawValue == Self.helloTextPackage }) {
            let staleSession = try Self.runCLI(target, arguments: ["stop", Self.helloTextPackage])
            XCTAssertEqual(staleSession.status, 0, staleSession.failureDescription)
        }
        defer {
            _ = try? Self.runCLI(target, arguments: ["stop", Self.helloTextPackage])
            _ = try? Self.runCLI(
                target,
                arguments: ["uninstall", Self.helloTextPackage, "--yes"],
                timeout: 600
            )
        }

        let install = try Self.runCLI(
            target,
            arguments: ["install", fixtureAPK.path, "--yes", "--json"],
            timeout: 900
        )
        XCTAssertEqual(install.status, 0, install.failureDescription)
        let installEnvelope = try Self.decode(InstallEnvelope.self, from: install.stdout)
        XCTAssertEqual(installEnvelope.result.packageID.rawValue, Self.helloTextPackage)

        let launch = try Self.runCLI(
            target,
            arguments: ["launch", Self.helloTextPackage, "--json"],
            timeout: 600
        )
        XCTAssertEqual(launch.status, 0, launch.failureDescription)

        let launchEnvelope = try Self.decode(LaunchEnvelope.self, from: launch.stdout)
        XCTAssertEqual(launchEnvelope.result.packageID, Self.helloTextPackage)
        XCTAssertEqual(launchEnvelope.result.state, "running")

        let status = try Self.runCLI(target, arguments: ["status", "--json"])
        XCTAssertEqual(status.status, 0, status.failureDescription)
        let statusEnvelope = try Self.decode(StatusEnvelope.self, from: status.stdout)
        let helloTextSession = try XCTUnwrap(
            statusEnvelope.result.sessions.first { $0.packageID.rawValue == Self.helloTextPackage },
            "The follow-up CLI process did not find an open HelloText session."
        )
        XCTAssertEqual(helloTextSession.state, .running)

        let runtimeStatus = try Self.runtimeStatus(using: target)
        XCTAssertEqual(runtimeStatus.runtimeState, "ready")
        XCTAssertTrue(
            ["apkrund", "apkrun-dev"].contains(runtimeStatus.owner),
            "Unexpected runtime owner reported by `apkrun runtime status --json`: \(runtimeStatus.owner)"
        )
    }

    /// The production-owner check reads the CLI's actual JSON output, so Debug evidence cannot count as acceptance.
    func testRuntimeStatusReportsProductionOwner() throws {
        let target = try Self.cliTarget()
        try Self.requireDaemonBackedCLI(target)
        let status = try Self.runtimeStatus(using: target)
        let expectsProductionOwner =
            ProcessInfo.processInfo.environment["APKRUN_TEST_EXPECT_PRODUCTION_OWNER"] == "1"
        if expectsProductionOwner {
            XCTAssertEqual(status.owner, "apkrund")
        } else {
            XCTAssertTrue(
                ["apkrund", "apkrun-dev"].contains(status.owner),
                "Unexpected runtime owner reported by `apkrun runtime status --json`: \(status.owner)"
            )
            if status.owner != "apkrund" {
                throw XCTSkip(
                    "The Debug runtime owner is \(status.owner); this run does not verify production ownership.")
            }
        }
    }

    // MARK: - CLI process

    private struct CLIResult {
        let status: Int32
        let stdout: String
        let stderr: String

        var failureDescription: String {
            "CLI exited \(status).\nstdout:\n\(stdout)\nstderr:\n\(stderr)"
        }
    }

    private struct InstallEnvelope: Decodable {
        struct Result: Decodable {
            let packageID: RuntimePackageID
        }

        let result: Result
    }

    private struct LaunchEnvelope: Decodable {
        struct Result: Decodable {
            let packageID: String
            let state: String
        }

        let result: Result
    }

    private struct StatusEnvelope: Decodable {
        struct Result: Decodable {
            let status: RuntimeHostStatus
            let sessions: [SessionSummary]
        }

        let result: Result
    }

    private struct RuntimeStatusEnvelope: Decodable {
        struct Result: Decodable {
            let owner: String
            let runtimeState: String
        }

        let result: Result
    }

    private struct RuntimeStatus {
        let owner: String
        let runtimeState: String
    }

    private static func cliTarget() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let installedCLI = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/APKRun Dev.app/Contents/Resources/bin/apkrun")
        let configuredPath =
            environment["APKRUN_TEST_CLI"]
            ?? Bundle.main.object(forInfoDictionaryKey: "APKRUN_TEST_CLI") as? String
        let executable = configuredPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? installedCLI

        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            let message =
                "The daemon-backed CLI is missing or not executable at \(executable.path). "
                + "Install the Debug app with APKRUN_CLI_TRAITS=, or configure APKRUN_TEST_CLI "
                + "for the Release production CLI."
            throw CLIHarnessError.missingExecutable(message)
        }

        return executable
    }

    private static func fixtureAPK() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let path =
            environment["APKRUN_FIXTURE_APK"]
            ?? Bundle.main.object(forInfoDictionaryKey: "APKRUN_FIXTURE_APK") as? String
        guard let path, !path.isEmpty, FileManager.default.isReadableFile(atPath: path) else {
            let message =
                "APKRUN_FIXTURE_APK must point to a readable HelloText APK staged outside the checkout "
                + "(see docs/05-development/environment-setup.md §4)."
            throw CLIHarnessError.missingFixture(message)
        }
        return URL(fileURLWithPath: path)
    }

    /// The daemon-backed InstallCommand exposes `--detach`; the EmbeddedRuntime package installer does not.
    private static func requireDaemonBackedCLI(_ executable: URL) throws {
        let help = try Self.runCLI(executable, arguments: ["install", "--help"])
        guard help.status == 0, help.stdout.contains("--detach") else {
            throw CLIHarnessError.notDaemonBackedCLI(executable.path, help.failureDescription)
        }
    }

    private static func runtimeStatus(using executable: URL) throws -> RuntimeStatus {
        let result = try Self.runCLI(executable, arguments: ["runtime", "status", "--json"])
        XCTAssertEqual(result.status, 0, result.failureDescription)
        let envelope = try Self.decode(RuntimeStatusEnvelope.self, from: result.stdout)
        return RuntimeStatus(owner: envelope.result.owner, runtimeState: envelope.result.runtimeState)
    }

    private static func runCLI(
        _ executable: URL,
        arguments: [String],
        timeout: TimeInterval = 90
    ) throws -> CLIResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            _ = exited.wait(timeout: .now() + 5)
            throw CLIHarnessError.timedOut(arguments)
        }
        process.waitUntilExit()

        return CLIResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from text: String) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(text.utf8))
    }

    private enum CLIHarnessError: Error, CustomStringConvertible {
        case missingExecutable(String)
        case missingFixture(String)
        case notDaemonBackedCLI(String, String)
        case timedOut([String])

        var description: String {
            switch self {
            case .missingExecutable(let message), .missingFixture(let message):
                message
            case .notDaemonBackedCLI(let path, let output):
                "\(path) is not the daemon-backed CLI (its `install` command must expose `--detach`).\n\(output)"
            case .timedOut(let arguments):
                "The CLI command timed out: apkrun \(arguments.joined(separator: " "))."
            }
        }
    }
}
