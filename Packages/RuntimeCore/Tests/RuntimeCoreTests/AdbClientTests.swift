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
        #expect(error == .commandTimedOut(command: "shell", seconds: 1))
        #expect(error.qualifiedCode == "runtime.adbCommandTimedOut")
    }
}

@Test(.timeLimit(.minutes(1)))
func adbClientEndsEveryTimedOutCommandWhileOthersHoldTheirPipesOpen() async throws {
    // Each sleeping command keeps its two pipes open until it exits. Reading those pipes must not hold the
    // Swift concurrency pool, or the timers that end these commands could not run and each one would last
    // its full 30 seconds (#015).
    let fake = try FakeADB()
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())
    let started = ContinuousClock.now
    let timedOut = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
        for _ in 0..<32 {
            group.addTask {
                do {
                    _ = try await client.shell("sleep-forever", timeout: .seconds(2))
                    return false
                } catch let failure as AdbFailure {
                    return failure == .commandTimedOut(command: "shell", seconds: 2)
                } catch {
                    return false
                }
            }
        }
        var count = 0
        for await ended in group where ended {
            count += 1
        }
        return count
    }
    #expect(timedOut == 32)
    #expect(ContinuousClock.now - started < .seconds(20))
}

@Test(.timeLimit(.minutes(1)))
func adbClientNamesTheHelperThatTimedOut() async throws {
    let fake = try FakeADB()
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())

    do {
        _ = try await client.getprop("sleep.prop", timeout: .milliseconds(300))
        Issue.record("A getprop past its timeout must throw.")
    } catch {
        #expect(error == .commandTimedOut(command: "getprop", seconds: 1))
    }
    #expect(await client.shellInvocationCount == 1)
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
              "-s 127.0.0.1:6520 shell getprop sleep.prop") exec sleep 30 ;;
              "-s 127.0.0.1:6520 shell getprop "*) echo "1"; exit 0 ;;
              "-s 127.0.0.1:6520 shell logcat -d")
                yes "APKRUN-TEST line of logcat output that is long enough to fill a pipe" | head -c 300000
                exit 0 ;;
              "-s 127.0.0.1:6520 shell sleep-forever") exec sleep 30 ;;
              "-s 127.0.0.1:6520 shell reboot -p") exit 0 ;;
              "-s 127.0.0.1:6520 shell exit-7") exit 7 ;;
              "-s 127.0.0.1:6520 install -r "*) echo "Performing Streamed Install"; echo "Success"; exit 0 ;;
              "-s 127.0.0.1:6520 uninstall io.apkrun.fixture.hellotext") echo "Success"; exit 0 ;;
              "-s 127.0.0.1:6520 uninstall io.apkrun.absent")
                echo "Failure [DELETE_FAILED_INTERNAL_ERROR]"; exit 1 ;;
              "-s 127.0.0.1:6520 shell pm list packages --show-versioncode io.apkrun.fixture.hellotext")
                echo "package:io.apkrun.fixture.hellotext versionCode:1"; exit 0 ;;
              "-s 127.0.0.1:6520 shell dumpsys package io.apkrun.fixture.hellotext")
                echo "  Package [io.apkrun.fixture.hellotext] (e3e9947):"
                echo "    versionCode=1 minSdk=29 targetSdk=37"
                echo "    versionName=1.0"
                exit 0 ;;
              "-s 127.0.0.1:6520 shell am start -W -n io.apkrun.fixture.hellotext/.MainActivity")
                rm -f "$dir/stopped"
                printf 'Starting: Intent { cmp=io.apkrun.fixture.hellotext/.MainActivity }\nStatus: ok\nLaunchState: COLD\n'
                exit 0 ;;
              "-s 127.0.0.1:6520 shell pidof io.apkrun.fixture.hellotext")
                if [ -f "$dir/stopped" ]; then exit 1; fi
                echo 3456; exit 0 ;;
              "-s 127.0.0.1:6520 shell dumpsys activity activities")
                if [ -f "$dir/unknown-dump" ]; then echo "no activity section here"; exit 0; fi
                if [ -f "$dir/stopped" ]; then
                  echo "    Resumed: ActivityRecord{244065368 u0 com.android.launcher3/.uioverrides.QuickstepLauncher t11}"
                else
                  echo "    Resumed: ActivityRecord{247806208 u0 io.apkrun.fixture.hellotext/.MainActivity t12}"
                fi
                exit 0 ;;
              "-s 127.0.0.1:6520 shell am force-stop io.apkrun.fixture.hellotext")
                touch "$dir/stopped"; exit 0 ;;
              "-s 127.0.0.1:6520 shell am start -W -n io.apkrun.fixture.hellotext/.Missing")
                echo "Error: Activity class {io.apkrun.fixture.hellotext/io.apkrun.fixture.hellotext.Missing} does not exist."
                exit 0 ;;
              "-s 127.0.0.1:6520 shell pidof io.apkrun.broken") echo "garbage"; exit 1 ;;
              "-s 127.0.0.1:6520 shell pidof io.apkrun.empty") echo ""; exit 0 ;;
              "-s 127.0.0.1:6520 shell pidof io.apkrun.transport") echo "error: closed" >&2; exit 1 ;;
              "-s 127.0.0.1:6520 shell am force-stop io.apkrun.stuck") echo "failed"; exit 1 ;;
              "-s 127.0.0.1:6520 shell dmesg")
                if [ -f "$dir/dmesg-denied" ]; then echo "dmesg: klogctl: Operation not permitted" >&2; exit 1; fi
                cat "$dir/dmesg"; exit 0 ;;
              "-s 127.0.0.1:6520 root")
                if [ -f "$dir/user-build" ]; then echo "adbd cannot run as root in production builds"; exit 1; fi
                echo "restarting adbd as root"; exit 0 ;;
              "-s 127.0.0.1:6520 shell id -u") echo 0; exit 0 ;;
              *"/sys/class/drm/card*-*"*) cat "$dir/drm"; exit 0 ;;
              *"/sys/bus/virtio/devices/*"*) cat "$dir/virtio"; exit 0 ;;
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

    /// The dumpsys reply has no resumed-activity line.
    func markUnknownDump() throws {
        try "unknown\n".write(to: directory.appendingPathComponent("unknown-dump"), atomically: true, encoding: .utf8)
    }

    /// The transport stays offline until the client disconnects it.
    func markTransportStale() throws {
        try "stale\n".write(to: directory.appendingPathComponent("stale"), atomically: true, encoding: .utf8)
    }

    func setDeviceState(_ state: String) throws {
        try "\(state)\n".write(to: directory.appendingPathComponent("state"), atomically: true, encoding: .utf8)
    }

    /// Writes the reply that the fake prints for a command, such as `dmesg` or `drm`.
    func setFile(_ name: String, contents: String) throws {
        try contents.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// The kernel log is restricted, so `dmesg` exits 1, as a user build does.
    func markDmesgDenied() throws {
        try setFile("dmesg-denied", contents: "")
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

@Test(.timeLimit(.minutes(1)))
func adbClientReadsTheKernelLogWithDmesg() async throws {
    let fake = try FakeADB()
    try fake.setFile("dmesg", contents: "[    1.000000] virtio_gpu virtio0: [drm] number of scanouts: 16\n")
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())

    let log = try await client.dmesg()

    #expect(log.contains("number of scanouts: 16"))
    #expect(try fake.calls() == ["-s 127.0.0.1:6520 shell dmesg"])
}

@Test(.timeLimit(.minutes(1)))
func adbClientReportsARestrictedKernelLogAsACommandFailure() async throws {
    // A user build may restrict the kernel log to root. The caller then falls back to the console (#021).
    let fake = try FakeADB()
    try fake.markDmesgDenied()
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())

    do {
        _ = try await client.dmesg()
        Issue.record("A restricted kernel log must not read as an empty log.")
    } catch {
        #expect(error == .commandFailed(command: "dmesg", status: 1))
    }
}

@Test(.timeLimit(.minutes(1)))
func adbClientRestartsAdbdAsRootAndChecksTheUid() async throws {
    let fake = try FakeADB()
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())

    try await client.restartAsRoot(timeout: .seconds(5))

    let calls = try fake.calls()
    #expect(calls.first == "-s 127.0.0.1:6520 root")
    #expect(calls.last == "-s 127.0.0.1:6520 shell id -u")
    #expect(await client.shellInvocationCount == 1)
}

@Test(.timeLimit(.minutes(1)))
func adbClientReportsARootRequestThatAUserBuildRefuses() async throws {
    let fake = try FakeADB()
    try fake.setFile("user-build", contents: "")
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())

    do {
        try await client.restartAsRoot(timeout: .seconds(5))
        Issue.record("A user build must refuse adb root.")
    } catch {
        #expect(error == .commandFailed(command: "root", status: 1))
    }
}

@Test(.timeLimit(.minutes(1)))
func adbClientReadsEveryDRMConnectorAndItsStatus() async throws {
    let fake = try FakeADB()
    try fake.setFile("drm", contents: "card0-Virtual-1 connected\ncard0-Virtual-2 disconnected\n")
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())

    let connectors = try await client.drmConnectors()

    #expect(
        connectors == [
            AdbDRMConnector(name: "card0-Virtual-1", status: .connected),
            AdbDRMConnector(name: "card0-Virtual-2", status: .disconnected),
        ]
    )
}

@Test(.timeLimit(.minutes(1)))
func adbClientRefusesADRMReplyThatIsNotAConnectorList() async throws {
    // A glob that matched nothing prints the pattern itself, which must not read as a connector.
    let fake = try FakeADB()
    try fake.setFile("drm", contents: "card*-* \n")
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())

    do {
        _ = try await client.drmConnectors()
        Issue.record("An unmatched DRM glob is an unexpected reply.")
    } catch {
        #expect(error == .unexpectedOutput(command: "drm"))
    }
}

@Test(.timeLimit(.minutes(1)))
func adbClientReadsVirtioDevicesWithTheirIDAndDriver() async throws {
    let fake = try FakeADB()
    try fake.setFile("virtio", contents: "virtio0 device=0x0010 driver=virtio_gpu\nvirtio1 device= driver=\n")
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())

    let devices = try await client.virtioDevices()

    #expect(
        devices == [
            AdbVirtioDevice(name: "virtio0", deviceID: 16, driver: "virtio_gpu"),
            AdbVirtioDevice(name: "virtio1", deviceID: nil, driver: nil),
        ]
    )
}

@Test func drmConnectorParserAcceptsOnlyConnectorLines() {
    #expect(
        AdbOutputParser.drmConnectors("card0-Virtual-1 connected\n")
            == [AdbDRMConnector(name: "card0-Virtual-1", status: .connected)]
    )
    #expect(AdbOutputParser.drmConnectors("card0-Virtual-1 bogus\n") == nil)
    #expect(AdbOutputParser.drmConnectors("card0 connected\n") == nil)
    #expect(AdbOutputParser.drmConnectors("card*-* \n") == nil)
    #expect(AdbOutputParser.drmConnectors("") == [])
}

@Test func virtioParserReadsHexDeviceIDsOnly() {
    // The `device` attribute is hexadecimal (`0x%04x`), so a decimal value is refused.
    #expect(
        AdbOutputParser.virtioDevices("virtio0 device=0x0010 driver=virtio_gpu\n")
            == [AdbVirtioDevice(name: "virtio0", deviceID: 16, driver: "virtio_gpu")]
    )
    #expect(AdbOutputParser.virtioDevices("virtio0 device=16 driver=virtio_gpu\n") == nil)
    #expect(AdbOutputParser.virtioDevices("*\n") == nil)
}

@Test(.timeLimit(.minutes(1)))
func adbClientInstallsUninstallsAndReadsThePackageThroughAdb() async throws {
    let fake = try FakeADB()
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())
    let apk = URL(fileURLWithPath: "/tmp/apkrun-015-fake/HelloText.apk")

    try await client.install(apk: apk)
    try await client.uninstall(packageName: "io.apkrun.fixture.hellotext")
    let listing = try await client.listPackages(matching: "io.apkrun.fixture.hellotext")
    let metadata = try await client.dumpsysPackage("io.apkrun.fixture.hellotext")

    #expect(
        try fake.calls() == [
            "-s 127.0.0.1:6520 install -r /tmp/apkrun-015-fake/HelloText.apk",
            "-s 127.0.0.1:6520 uninstall io.apkrun.fixture.hellotext",
            "-s 127.0.0.1:6520 shell pm list packages --show-versioncode io.apkrun.fixture.hellotext",
            "-s 127.0.0.1:6520 shell dumpsys package io.apkrun.fixture.hellotext",
        ]
    )
    #expect(listing == [AdbPackageListing(name: "io.apkrun.fixture.hellotext", versionCode: 1)])
    #expect(metadata == AdbPackageMetadata(versionCode: 1, versionName: "1.0", minSdk: 29, targetSdk: 37))
    // The install and uninstall commands are adb commands, not shell commands.
    #expect(await client.shellInvocationCount == 2)
}

@Test(.timeLimit(.minutes(1)))
func adbClientReportsAnUninstallThatAndroidRefuses() async throws {
    let fake = try FakeADB()
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())

    do {
        try await client.uninstall(packageName: "io.apkrun.absent")
        Issue.record("An uninstall that Android refuses must throw.")
    } catch {
        #expect(error == .packageRejected(command: "uninstall", reason: "DELETE_FAILED_INTERNAL_ERROR"))
        #expect(error.qualifiedCode == "runtime.adbPackageRejected")
    }
}

@Test(.timeLimit(.minutes(1)))
func adbClientRefusesPackageNamesThatAreNotIdentifiers() async throws {
    let fake = try FakeADB()
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())

    do {
        try await client.uninstall(packageName: "io.apkrun; reboot")
        Issue.record("A package name with shell syntax must be refused.")
    } catch {
        #expect(error == .invalidArgument(command: "uninstall"))
    }
    #expect(try fake.calls().isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func adbClientStartsReadsAndStopsTheActivity() async throws {
    let fake = try FakeADB()
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())
    let component = "io.apkrun.fixture.hellotext/.MainActivity"

    try await client.startActivity(component: component)
    let pid = try await client.pidof("io.apkrun.fixture.hellotext")
    let resumed = try await client.dumpsysActivities()
    try await client.forceStop("io.apkrun.fixture.hellotext")
    let pidAfterStop = try await client.pidof("io.apkrun.fixture.hellotext")
    let resumedAfterStop = try await client.dumpsysActivities()

    #expect(pid == 3456)
    #expect(resumed.resumedComponent == component)
    #expect(pidAfterStop == nil)
    #expect(resumedAfterStop.resumedComponent == "com.android.launcher3/.uioverrides.QuickstepLauncher")
    #expect(
        try fake.calls() == [
            "-s 127.0.0.1:6520 shell am start -W -n io.apkrun.fixture.hellotext/.MainActivity",
            "-s 127.0.0.1:6520 shell pidof io.apkrun.fixture.hellotext",
            "-s 127.0.0.1:6520 shell dumpsys activity activities",
            "-s 127.0.0.1:6520 shell am force-stop io.apkrun.fixture.hellotext",
            "-s 127.0.0.1:6520 shell pidof io.apkrun.fixture.hellotext",
            "-s 127.0.0.1:6520 shell dumpsys activity activities",
        ]
    )
    // pidof and dumpsys are shell commands, so each one is counted.
    #expect(await client.shellInvocationCount == 6)
}

@Test(.timeLimit(.minutes(1)))
func adbClientRefusesComponentsThatAreNotActivityNames() async throws {
    let fake = try FakeADB()
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())

    do {
        try await client.startActivity(component: "io.apkrun.fixture.hellotext/.Outer$Inner")
        Issue.record("A component with a $ must be refused: the device shell would expand it.")
    } catch {
        #expect(error == .invalidArgument(command: "am start"))
    }
    #expect(try fake.calls().isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func adbClientRejectsAnAmStartThatDidNotStartTheActivity() async throws {
    let fake = try FakeADB()
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())

    do {
        try await client.startActivity(component: "io.apkrun.fixture.hellotext/.Missing")
        Issue.record("An am start that reports a missing class must throw.")
    } catch {
        #expect(error == .unexpectedOutput(command: "am start"))
    }
}

@Test(.timeLimit(.minutes(1)))
func pidofReportsABrokenConnectionAsAFailureNotAsNoProcess() async throws {
    // A dropped endpoint makes adb exit 1 with an error on standard error. That is not "no process".
    let fake = try FakeADB()
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())

    do {
        _ = try await client.pidof("io.apkrun.transport")
        Issue.record("A pidof that fails through adb must throw.")
    } catch {
        #expect(error == .commandFailed(command: "pidof", status: 1))
    }
    do {
        _ = try await client.pidof("io.apkrun.broken")
        Issue.record("A pidof with output and status 1 must throw.")
    } catch {
        #expect(error == .commandFailed(command: "pidof", status: 1))
    }
}

@Test(.timeLimit(.minutes(1)))
func pidofWithASilentSuccessIsAnUnexpectedReply() async throws {
    let fake = try FakeADB()
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())

    do {
        _ = try await client.pidof("io.apkrun.empty")
        Issue.record("A pidof that exits 0 with no pid must throw.")
    } catch {
        #expect(error == .unexpectedOutput(command: "pidof"))
    }
}

@Test(.timeLimit(.minutes(1)))
func forceStopNamesAFailedAmCommand() async throws {
    let fake = try FakeADB()
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())

    do {
        try await client.forceStop("io.apkrun.stuck")
        Issue.record("An am force-stop that exits 1 must throw.")
    } catch {
        #expect(error == .commandFailed(command: "am force-stop", status: 1))
    }
}

@Test(.timeLimit(.minutes(1)))
func dumpsysActivitiesRejectsADumpThatNamesNoResumedActivity() async throws {
    let fake = try FakeADB()
    try fake.markUnknownDump()
    let client = AdbClient(executable: fake.executable, logSink: SilentLogSink())

    do {
        _ = try await client.dumpsysActivities()
        Issue.record("A dump without a resumed-activity line must throw.")
    } catch {
        #expect(error == .unexpectedOutput(command: "dumpsys"))
    }
}
