import DiagnosticsCore
import Foundation

/// The result of one `adb shell` command.
public struct AdbShellReply: Equatable, Sendable {
    /// What the command printed on standard output.
    public var output: String
    /// What the command printed on standard error.
    public var errorOutput: String
    /// The command's exit status, which adb passes through from the device (adb 1.0.36 and later).
    public var status: Int32

    /// Creates a reply.
    public init(output: String, errorOutput: String = "", status: Int32) {
        self.output = output
        self.errorOutput = errorOutput
        self.status = status
    }
}

/// The host's ADB client for the developer's Android (#015; cli.md §5; android-image.md §7.3).
///
/// APKRun does not ship adb. The client runs the developer's `platform-tools/adb`, found under
/// `$ANDROID_HOME` and then on `PATH`, and it talks only to the development endpoint
/// `127.0.0.1:6520`, which `VsockLoopbackForwarder` opens in developer mode.
///
/// Every command line is built inside one of the helper methods below. `shellInvocationCount`
/// counts `adb shell` runs, so tests can check that production paths stop using ADB shell commands
/// (guest-protocol.md §15, #034).
public actor AdbClient {
    /// The development endpoint: adbd on vsock 5555, reached through the loopback forwarder.
    public static let developmentEndpoint = "127.0.0.1:6520"

    /// The adb executable this client runs.
    public nonisolated let executable: URL
    /// The `host:port` endpoint that every command addresses with `-s`.
    public nonisolated let endpoint: String
    /// The number of `adb shell` commands this client has started.
    public private(set) var shellInvocationCount = 0

    private let logger: APKLogger
    private let commandTimeout: Duration = .seconds(10)

    /// Creates a client for `executable`, addressing `endpoint`.
    public init(
        executable: URL,
        endpoint: String = AdbClient.developmentEndpoint,
        logSink: (any LogSink)? = nil
    ) {
        self.executable = executable
        self.endpoint = endpoint
        logger = APKLogger(category: RuntimeLogCategory.adb, sink: logSink)
    }

    /// Finds the adb executable: `$ANDROID_HOME/platform-tools/adb` first, then `adb` on `PATH`.
    public static func resolveExecutable(environment: [String: String]) throws(AdbFailure) -> URL {
        let fileManager = FileManager.default
        if let root = environment["ANDROID_HOME"], !root.isEmpty {
            let candidate = URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent("platform-tools", isDirectory: true)
                .appendingPathComponent("adb")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true).appendingPathComponent("adb")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw .executableMissing
    }

    /// Connects to the endpoint and waits until the device is in the `device` state.
    ///
    /// Each attempt runs `adb disconnect`, `adb connect`, and `adb get-state`, and none of them may run past
    /// the deadline. Attempts are spaced by a backoff that starts at 250 ms and doubles up to 2 s. A TCP
    /// connection alone is not enough: adbd may still be starting, which leaves the device `offline`.
    public func connect(timeout: Duration = .seconds(30)) async throws(AdbFailure) {
        let deadline = ContinuousClock.now + timeout
        var delay = Duration.milliseconds(250)
        while true {
            if !Task.isCancelled, ContinuousClock.now < deadline, await attemptConnect(until: deadline) {
                logger.info("ADB connected to \(endpoint, .public)")
                return
            }
            guard ContinuousClock.now < deadline, !Task.isCancelled else {
                logger.error(
                    "ADB did not reach \(endpoint, .public) before the deadline",
                    errorCode: AdbFailure.connectionUnavailable.qualifiedCode
                )
                throw .connectionUnavailable
            }
            let remaining = deadline - ContinuousClock.now
            try? await Task.sleep(for: min(delay, remaining))
            delay = min(delay * 2, .seconds(2))
        }
    }

    /// Runs `getprop <name>` and returns its value without the trailing newline. An unset property is "".
    public func getprop(_ name: String, timeout: Duration? = nil) async throws(AdbFailure) -> String {
        guard Self.isPropertyName(name) else {
            throw .invalidArgument(command: "getprop")
        }
        let reply = try await runShell(label: "getprop", "getprop \(name)", timeout: timeout ?? commandTimeout)
        guard reply.status == 0 else {
            throw .commandFailed(command: "getprop", status: reply.status)
        }
        return reply.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs one command through the device's shell (`adb shell <command>`).
    ///
    /// Each call counts once in `shellInvocationCount`, even when it fails. Use a named helper where
    /// one exists: the helpers keep the command lines in one place (M01 #015 step 3).
    public func shell(_ command: String, timeout: Duration? = nil) async throws(AdbFailure) -> AdbShellReply {
        try await runShell(label: "shell", command, timeout: timeout ?? commandTimeout)
    }

    /// Runs `logcat -d` and returns the buffered log. The buffer can be large, so the timeout is longer.
    public func logcatDump(timeout: Duration = .seconds(30)) async throws(AdbFailure) -> String {
        let reply = try await runShell(label: "logcat", "logcat -d", timeout: timeout)
        guard reply.status == 0 else {
            throw .commandFailed(command: "logcat", status: reply.status)
        }
        return reply.output
    }

    /// Asks Android to power off with `reboot -p`. The connection usually drops while the reply is read,
    /// so the reply is returned as it is and a dropped connection is not an error here.
    public func rebootPowerOff(timeout: Duration = .seconds(5)) async throws(AdbFailure) -> AdbShellReply {
        try await runShell(label: "reboot", "reboot -p", timeout: timeout)
    }

    /// Installs an APK with `adb install -r`. adb installs through the device's PackageInstaller session
    /// (package-store.md §6.1), so no APK is copied into an Android package directory (FR-PKG-01).
    public func install(apk: URL, timeout: Duration = .seconds(180)) async throws(AdbFailure) {
        let result = try await runDeviceCommand("install", arguments: ["install", "-r", apk.path], timeout: timeout)
        try Self.requirePackageSuccess(result, command: "install")
    }

    /// Uninstalls `packageName` with `adb uninstall`.
    public func uninstall(packageName: String, timeout: Duration = .seconds(60)) async throws(AdbFailure) {
        guard Self.isPackageName(packageName) else {
            throw .invalidArgument(command: "uninstall")
        }
        let result = try await runDeviceCommand(
            "uninstall",
            arguments: ["uninstall", packageName],
            timeout: timeout
        )
        try Self.requirePackageSuccess(result, command: "uninstall")
    }

    /// Lists the packages whose names contain `filter`, with their versionCode (`pm list packages --show-versioncode`).
    /// An empty filter lists every package.
    public func listPackages(matching filter: String = "") async throws(AdbFailure) -> [AdbPackageListing] {
        guard filter.isEmpty || Self.isPackageName(filter) else {
            throw .invalidArgument(command: "pm")
        }
        let command =
            filter.isEmpty
            ? "pm list packages --show-versioncode"
            : "pm list packages --show-versioncode \(filter)"
        let reply = try await runShell(label: "pm", command, timeout: commandTimeout)
        guard reply.status == 0 else {
            throw .commandFailed(command: "pm", status: reply.status)
        }
        return AdbOutputParser.packageListings(reply.output)
    }

    /// Reads the metadata of an installed package from `dumpsys package <name>`.
    public func dumpsysPackage(_ packageName: String) async throws(AdbFailure) -> AdbPackageMetadata {
        guard Self.isPackageName(packageName) else {
            throw .invalidArgument(command: "dumpsys")
        }
        let reply = try await runShell(label: "dumpsys", "dumpsys package \(packageName)", timeout: commandTimeout)
        guard reply.status == 0 else {
            throw .commandFailed(command: "dumpsys", status: reply.status)
        }
        guard let metadata = AdbOutputParser.packageMetadata(reply.output, packageName: packageName) else {
            throw .unexpectedOutput(command: "dumpsys")
        }
        return metadata
    }

    /// Reads an install or uninstall result from both streams, because adb prints a rejection on standard error.
    private static func requirePackageSuccess(_ result: AdbProcessResult, command: String) throws(AdbFailure) {
        switch AdbOutputParser.packageReply(result.standardOutput + "\n" + result.standardError) {
        case .failure(let reason):
            throw .packageRejected(command: command, reason: reason)
        case .success where result.status == 0:
            return
        case .success, .unknown:
            if result.status != 0 {
                throw .commandFailed(command: command, status: result.status)
            }
            throw .unexpectedOutput(command: command)
        }
    }

    /// Package names are dot-separated identifiers, such as `io.apkrun.fixture.hellotext`.
    private static func isPackageName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2
            && parts.allSatisfy { part in
                guard let first = part.first, first.isASCII, first.isLetter else {
                    return false
                }
                return part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
            }
    }

    /// Runs `adb -s <endpoint> <arguments>` with the developer's terminal attached, and returns its exit status.
    ///
    /// `apkrun dev adb` uses this. adb's output goes straight to the terminal, so the status is
    /// the only result.
    public nonisolated func runAttached(_ arguments: [String]) throws(AdbFailure) -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-s", endpoint] + arguments
        do {
            try process.run()
        } catch {
            throw .launchFailed
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// One connect attempt. It first drops any transport that the adb server still holds for the
    /// endpoint: after an earlier boot, `adb connect` answers "already connected" and the old transport
    /// stays `offline`, so only a fresh transport can reach the device. Each step gets the time left
    /// before `deadline`, and no step starts after it.
    private func attemptConnect(until deadline: ContinuousClock.Instant) async -> Bool {
        _ = try? await AdbProcess.run(
            executable: executable,
            arguments: ["disconnect", endpoint],
            command: "disconnect",
            timeout: remainingTime(until: deadline)
        )
        guard ContinuousClock.now < deadline else {
            return false
        }
        guard
            let connected = try? await AdbProcess.run(
                executable: executable,
                arguments: ["connect", endpoint],
                command: "connect",
                timeout: remainingTime(until: deadline)
            ),
            connected.status == 0,
            connected.standardOutput.contains("connected to \(endpoint)")
        else {
            return false
        }
        guard ContinuousClock.now < deadline else {
            return false
        }
        guard
            let state = try? await AdbProcess.run(
                executable: executable,
                arguments: ["-s", endpoint, "get-state"],
                command: "get-state",
                timeout: remainingTime(until: deadline)
            )
        else {
            return false
        }
        return state.status == 0 && state.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "device"
    }

    /// The time left before `deadline`, at least 100 ms so that a process always gets a chance to answer.
    private func remainingTime(until deadline: ContinuousClock.Instant) -> Duration {
        max(.milliseconds(100), min(commandTimeout, deadline - ContinuousClock.now))
    }

    /// Runs one `adb shell` command, counted in `shellInvocationCount`, and names it `label` in errors.
    private func runShell(label: String, _ command: String, timeout: Duration) async throws(AdbFailure) -> AdbShellReply
    {
        shellInvocationCount += 1
        let result = try await runDeviceCommand(
            label,
            arguments: ["shell", command],
            timeout: timeout
        )
        return AdbShellReply(
            output: result.standardOutput,
            errorOutput: result.standardError,
            status: result.status
        )
    }

    private func runDeviceCommand(
        _ command: String,
        arguments: [String],
        timeout: Duration
    ) async throws(AdbFailure) -> AdbProcessResult {
        try await AdbProcess.run(
            executable: executable,
            arguments: ["-s", endpoint] + arguments,
            command: command,
            timeout: timeout
        )
    }

    /// Property names are letters, digits, dots, and underscores. Anything else is refused, so a
    /// name can never add shell syntax to a command.
    private static func isPropertyName(_ name: String) -> Bool {
        !name.isEmpty
            && name.allSatisfy { character in
                character.isASCII && (character.isLetter || character.isNumber || character == "." || character == "_")
            }
    }
}
