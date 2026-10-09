import DiagnosticsCore
import Foundation
import Testing

@testable import RuntimeCore

/// Command lines, parsing, and error mapping of `AdbClient`, run against a fake adb script (#015 T0).
/// The script lives in a temporary directory, outside ~/Documents.
@Test(.timeLimit(.minutes(1)))
func adbClientConnectsAndChecksTheDeviceState() async throws {
    let fake = try FakeADB()
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())

    try await client.connect(timeout: .seconds(5))

    #expect(
        try fake.calls() == [
            "disconnect 127.0.0.1:6520",
            "connect 127.0.0.1:6520",
            "-s 127.0.0.1:6520 get-state",
        ]
    )
    #expect(await client.shellInvocationCount == 0)
}

@Test(.timeLimit(.minutes(1)))
func adbClientRetriesWhileTheEndpointRefusesTheConnection() async throws {
    let fake = try FakeADB()
    try fake.setConnectFailures(2)
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())

    try await client.connect(timeout: .seconds(10))

    #expect(try fake.calls().filter { $0 == "connect 127.0.0.1:6520" }.count == 3)
}

@Test(.timeLimit(.minutes(1)))
func adbClientDropsAStaleTransportBeforeConnecting() async throws {
    // A transport left by an earlier boot reports "already connected" but stays offline until it is
    // dropped. The client must disconnect first, or it can never reach the device.
    let fake = try FakeADB()
    try fake.markTransportStale()
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())

    try await client.connect(timeout: .seconds(5))

    #expect(try fake.calls().first == "disconnect 127.0.0.1:6520")
}

@Test(.timeLimit(.minutes(1)))
func adbClientFailsWhenTheDeviceNeverLeavesOffline() async throws {
    let fake = try FakeADB()
    try fake.setDeviceState("offline")
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())

    do {
        try await client.connect(timeout: .seconds(1))
        Issue.record("A device that stays offline must not count as connected.")
    } catch {
        #expect(error == .connectionUnavailable)
    }
}

@Test(.timeLimit(.minutes(1)))
func adbClientGetpropReturnsTheTrimmedValueAndCountsTheShell() async throws {
    let fake = try FakeADB()
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())

    let boot = try await client.getprop("sys.boot_completed")
    let unset = try await client.getprop("unset.prop")

    #expect(boot == "1")
    #expect(unset == "")
    #expect(
        try fake.calls() == [
            "-s 127.0.0.1:6520 shell getprop sys.boot_completed",
            "-s 127.0.0.1:6520 shell getprop unset.prop",
        ]
    )
    #expect(await client.shellInvocationCount == 2)
}

@Test(.timeLimit(.minutes(1)))
func adbClientReportsANonzeroStatusWithoutItsOutput() async throws {
    let fake = try FakeADB()
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())

    do {
        _ = try await client.getprop("broken.prop")
        Issue.record("A failed getprop must throw.")
    } catch {
        #expect(error == .commandFailed(command: "getprop", status: 3))
        #expect(error.qualifiedCode == "runtime.adbCommandFailed")
        #expect(!String(describing: error).contains("error text"))
    }
}

@Test(.timeLimit(.minutes(1)))
func adbClientRefusesPropertyNamesThatCouldAddShellSyntax() async throws {
    let fake = try FakeADB()
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())

    do {
        _ = try await client.getprop("sys.boot_completed; reboot")
        Issue.record("A property name with shell syntax must be refused.")
    } catch {
        #expect(error == .invalidArgument(command: "getprop"))
    }
    #expect(try fake.calls().isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func adbClientTerminatesACommandThatRunsPastItsTimeout() async throws {
    let fake = try FakeADB()
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())

    do {
        _ = try await client.shell("sleep-forever", timeout: .milliseconds(300))
        Issue.record("A command past its timeout must throw.")
    } catch {
        #expect(error == .commandTimedOut(command: "shell", seconds: 0))
        #expect(error.qualifiedCode == "runtime.adbCommandTimedOut")
    }
}

@Test(.timeLimit(.minutes(1)))
func adbClientReadsLargeLogcatOutputWithoutBlockingOnThePipe() async throws {
    let fake = try FakeADB()
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())

    let log = try await client.logcatDump(timeout: .seconds(20))

    #expect(log.utf8.count > 250_000)
    #expect(log.hasPrefix("APKRUN-TEST line"))
}

@Test(.timeLimit(.minutes(1)))
func adbClientPowersOffWithRebootPAndReturnsTheReply() async throws {
    let fake = try FakeADB()
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())

    let reply = try await client.rebootPowerOff()

    #expect(reply.status == 0)
    #expect(try fake.calls() == ["-s 127.0.0.1:6520 shell reboot -p"])
}

@Test(.timeLimit(.minutes(1)))
func adbClientPassesTheShellExitStatusThrough() async throws {
    let fake = try FakeADB()
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())

    let reply = try await client.shell("exit-7")

    #expect(reply.status == 7)
    #expect(reply.output == "")
}

@Test(.timeLimit(.minutes(1)))
func adbClientRunsAttachedCommandsWithTheEndpointAndReturnsTheStatus() throws {
    let fake = try FakeADB()
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())

    let status = try client.runAttached(["shell", "exit-7"])

    #expect(status == 7)
    #expect(try fake.calls() == ["-s 127.0.0.1:6520 shell exit-7"])
}

@Test(.timeLimit(.minutes(1)))
func adbResolutionPrefersAndroidHomeThenPath() throws {
    let root = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sdk = root.appendingPathComponent("sdk", isDirectory: true)
    let sdkTools = sdk.appendingPathComponent("platform-tools", isDirectory: true)
    let pathDirectory = root.appendingPathComponent("path", isDirectory: true)
    try FileManager.default.createDirectory(at: sdkTools, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: pathDirectory, withIntermediateDirectories: true)
    let sdkAdb = sdkTools.appendingPathComponent("adb")
    let pathAdb = pathDirectory.appendingPathComponent("adb")
    try writeExecutable(at: sdkAdb)
    try writeExecutable(at: pathAdb)

    let fromHome = try AdbClient.resolveExecutable(environment: [
        "ANDROID_HOME": sdk.path,
        "PATH": pathDirectory.path,
    ])
    #expect(fromHome.path == sdkAdb.path)

    let fromPath = try AdbClient.resolveExecutable(environment: [
        "ANDROID_HOME": root.appendingPathComponent("missing").path,
        "PATH": "/nonexistent:\(pathDirectory.path)",
    ])
    #expect(fromPath.path == pathAdb.path)

    do {
        _ = try AdbClient.resolveExecutable(environment: ["PATH": "/nonexistent"])
        Issue.record("Resolution without any adb must fail.")
    } catch {
        #expect(error == .executableMissing)
        #expect(error.qualifiedCode == "runtime.adbExecutableMissing")
    }
}

/// A temporary directory holding a fake `adb` that logs its arguments and answers the commands the
/// tests use. Each test gets its own directory.
private final class FakeADB: @unchecked Sendable {
    let directory: URL
    let executable: URL

    init() throws {
        directory = try makeScratchDirectory()
        executable = directory.appendingPathComponent("adb")
        let script = """
            #!/bin/sh
            dir='\(directory.path)'
            printf '%s\\n' "$*" >> "$dir/calls.log"
            case "$*" in
              "connect 127.0.0.1:6520")
                if [ -s "$dir/connect-failures" ]; then
                  left=$(cat "$dir/connect-failures")
                  if [ "$left" -gt 0 ]; then
                    echo $((left - 1)) > "$dir/connect-failures"
                    echo "cannot connect to 127.0.0.1:6520: Connection refused"
                    exit 1
                  fi
                fi
                echo "connected to 127.0.0.1:6520"
                exit 0 ;;
              "disconnect 127.0.0.1:6520") touch "$dir/disconnected"; exit 0 ;;
              *"get-state")
                if [ -f "$dir/state" ]; then cat "$dir/state"; exit 0; fi
                if [ -f "$dir/stale" ] && [ ! -f "$dir/disconnected" ]; then echo offline; exit 0; fi
                echo device
                exit 0 ;;
              "-s 127.0.0.1:6520 shell getprop unset.prop") echo ""; exit 0 ;;
              "-s 127.0.0.1:6520 shell getprop broken.prop") echo "error text"; exit 3 ;;
              "-s 127.0.0.1:6520 shell getprop "*) echo "1"; exit 0 ;;
              "-s 127.0.0.1:6520 shell logcat -d")
                yes "APKRUN-TEST line of logcat output that is long enough to fill a pipe" | head -c 300000
                exit 0 ;;
              "-s 127.0.0.1:6520 shell sleep-forever") exec sleep 30 ;;
              "-s 127.0.0.1:6520 shell reboot -p") exit 0 ;;
              "-s 127.0.0.1:6520 shell exit-7") exit 7 ;;
              *) echo "unexpected: $*" >&2; exit 2 ;;
            esac
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The argument vectors the fake received, one line each.
    func calls() throws -> [String] {
        let url = directory.appendingPathComponent("calls.log")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    func setConnectFailures(_ count: Int) throws {
        try "\(count)\n".write(
            to: directory.appendingPathComponent("connect-failures"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// The transport stays offline until the client disconnects it.
    func markTransportStale() throws {
        try "stale\n".write(to: directory.appendingPathComponent("stale"), atomically: true, encoding: .utf8)
    }

    func setDeviceState(_ state: String) throws {
        try "\(state)\n".write(to: directory.appendingPathComponent("state"), atomically: true, encoding: .utf8)
    }
}

private func makeScratchDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-015-adb-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeExecutable(at url: URL) throws {
    try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

/// Keeps the client's log entries out of the shared unified log during tests.
private struct SilentLogSink: LogSink {
    func isEnabled(for level: LogLevel) -> Bool {
        false
    }

    func write(_ entry: LogEntry) {}
}
