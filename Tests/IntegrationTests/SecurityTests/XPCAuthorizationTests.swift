import Foundation
import XCTest

/// Exercises the LaunchAgent's production XPC code-signing boundary with a different signed executable.
final class XPCAuthorizationTests: XCTestCase {
    private static let integrationSuite = "cli-xpc"

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["APKRUN_INTEGRATION_SUITE"] == Self.integrationSuite else {
            throw XCTSkip("The XPC authorization check runs in the AndroidStock `cli-xpc` test-plan configurations.")
        }
    }

    func testDifferentCodeSignatureCannotUseRuntimeXPC() throws {
        let trustedCLI = try Self.cliURL()
        let trustedStatus = try Self.runCLI(trustedCLI)
        XCTAssertEqual(trustedStatus.status, 0, trustedStatus.failureDescription)
        XCTAssertTrue(trustedStatus.stdout.contains("\"owner\""), trustedStatus.failureDescription)

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-xpc-authorization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let unauthorizedCLI = temporaryDirectory.appendingPathComponent("apkrun")
        try FileManager.default.copyItem(at: trustedCLI, to: unauthorizedCLI)
        if ProcessInfo.processInfo.environment["APKRUN_TEST_EXPECT_PRODUCTION_OWNER"] == "1" {
            let signingIdentity = try Self.signingIdentity(for: trustedCLI)
            try Self.sign(unauthorizedCLI, with: signingIdentity)
        } else {
            try Self.signAdHoc(unauthorizedCLI)
        }

        let unauthorizedStatus = try Self.runCLI(unauthorizedCLI)
        XCTAssertNotEqual(
            unauthorizedStatus.status,
            0,
            "A separately signed executable unexpectedly used the runtime XPC service.\n"
                + unauthorizedStatus.failureDescription
        )
        let rejection = try JSONDecoder().decode(
            RuntimeErrorEnvelope.self,
            from: Data(unauthorizedStatus.stdout.utf8)
        )
        XCTAssertEqual(
            rejection.error.code,
            "runtime.serviceUnavailable",
            "The XPC listener did not reject the alternate code signature as expected.\n"
                + unauthorizedStatus.failureDescription
        )

        let recoveredTrustedStatus = try Self.runCLI(trustedCLI)
        XCTAssertEqual(
            recoveredTrustedStatus.status,
            0,
            "The trusted client could not use XPC after the rejected connection.\n"
                + recoveredTrustedStatus.failureDescription
        )
    }

    private struct CLIResult {
        let status: Int32
        let stdout: String
        let stderr: String

        var failureDescription: String {
            "CLI exited \(status).\nstdout:\n\(stdout)\nstderr:\n\(stderr)"
        }
    }

    private struct RuntimeErrorEnvelope: Decodable {
        struct Body: Decodable {
            let code: String
        }

        let error: Body
    }

    private static func cliURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let configuredPath =
            environment["APKRUN_TEST_CLI"]
            ?? Bundle.main.object(forInfoDictionaryKey: "APKRUN_TEST_CLI") as? String
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/APKRun Dev.app/Contents/Resources/bin/apkrun")
            .path
        let path = configuredPath.flatMap { $0.isEmpty ? nil : $0 } ?? defaultPath
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw HarnessError.missingExecutable(path)
        }
        return URL(fileURLWithPath: path)
    }

    private static func signAdHoc(_ executable: URL) throws {
        let result = try Self.run(
            "/usr/bin/codesign",
            arguments: [
                "--force",
                "--sign", "-",
                "--identifier", "io.apkrun.test.unauthorized",
                "--timestamp=none",
                executable.path,
            ],
            timeout: 30
        )
        guard result.status == 0 else {
            throw HarnessError.commandFailed("Could not create the ad-hoc test signature", result.failureDescription)
        }

        let verification = try Self.run(
            "/usr/bin/codesign",
            arguments: ["--verify", "--strict", executable.path],
            timeout: 30
        )
        guard verification.status == 0 else {
            throw HarnessError.commandFailed(
                "The ad-hoc test executable signature is invalid", verification.failureDescription)
        }
    }

    private static func signingIdentity(for trustedExecutable: URL) throws -> String {
        let signature = try Self.run(
            "/usr/bin/codesign",
            arguments: ["--display", "--verbose=4", trustedExecutable.path],
            timeout: 30
        )
        guard signature.status == 0 else {
            throw HarnessError.commandFailed(
                "Could not inspect the trusted CLI signature",
                signature.failureDescription
            )
        }
        let teamIdentifier = (signature.stdout + signature.stderr)
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("TeamIdentifier=") })
            .map { String($0.dropFirst("TeamIdentifier=".count)) }
            .flatMap { $0 == "not set" ? nil : $0 }

        let identities = try Self.run(
            "/usr/bin/security",
            arguments: ["find-identity", "-v", "-p", "codesigning"],
            timeout: 30
        )
        guard identities.status == 0 else {
            throw HarnessError.commandFailed(
                "Could not find a valid code-signing identity",
                identities.failureDescription
            )
        }
        let matchingIdentity = (identities.stdout + identities.stderr)
            .split(separator: "\n")
            .first { line in
                guard line.contains("\"") else { return false }
                guard let teamIdentifier else { return true }
                return line.contains("(\(teamIdentifier))")
            }
            .flatMap { line -> String? in
                guard let closingParenthesis = line.firstIndex(of: ")") else { return nil }
                return line[line.index(after: closingParenthesis)...]
                    .split(whereSeparator: \.isWhitespace)
                    .first
                    .map(String.init)
            }
        guard let matchingIdentity else {
            throw HarnessError.missingSigningIdentity(teamIdentifier)
        }
        return matchingIdentity
    }

    private static func sign(_ executable: URL, with identity: String) throws {
        let result = try Self.run(
            "/usr/bin/codesign",
            arguments: [
                "--force",
                "--sign", identity,
                "--identifier", "io.apkrun.test.unauthorized",
                "--timestamp=none",
                executable.path,
            ],
            timeout: 30
        )
        guard result.status == 0 else {
            throw HarnessError.commandFailed(
                "Could not create the alternate test signature",
                result.failureDescription
            )
        }

        let verification = try Self.run(
            "/usr/bin/codesign",
            arguments: ["--verify", "--strict", executable.path],
            timeout: 30
        )
        guard verification.status == 0 else {
            throw HarnessError.commandFailed(
                "The test executable signature is invalid", verification.failureDescription)
        }

        let signature = try Self.run(
            "/usr/bin/codesign",
            arguments: ["--display", "--verbose=4", executable.path],
            timeout: 30
        )
        let signatureOutput = signature.stdout + signature.stderr
        guard signature.status == 0,
            signatureOutput.contains("Identifier=io.apkrun.test.unauthorized"),
            signatureOutput.contains("TeamIdentifier="),
            !signatureOutput.contains("TeamIdentifier=not set")
        else {
            throw HarnessError.commandFailed(
                "The alternate test signature has no valid team identity",
                signature.failureDescription
            )
        }
    }

    private static func runCLI(_ executable: URL) throws -> CLIResult {
        try Self.run(executable.path, arguments: ["runtime", "status", "--json"], timeout: 90)
    }

    private static func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> CLIResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
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
            throw HarnessError.timedOut(executable, arguments)
        }
        process.waitUntilExit()

        return CLIResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private enum HarnessError: Error, CustomStringConvertible {
        case commandFailed(String, String)
        case missingExecutable(String)
        case missingSigningIdentity(String?)
        case timedOut(String, [String])

        var description: String {
            switch self {
            case .commandFailed(let message, let output):
                "\(message).\n\(output)"
            case .missingExecutable(let path):
                "The installed daemon-backed CLI is missing or not executable: \(path)."
            case .missingSigningIdentity(let teamIdentifier):
                if let teamIdentifier {
                    "No valid code-signing identity for team \(teamIdentifier) is available in the keychain."
                } else {
                    "No valid code-signing identity is available in the keychain."
                }
            case .timedOut(let executable, let arguments):
                "Timed out running \(executable) \(arguments.joined(separator: " "))."
            }
        }
    }
}
