import DiagnosticsCore
import Foundation
import Testing

@testable import RuntimeCore

/// The ADB helpers of the Guest Agent and the provisioner's decisions, run against a fake adb (guest-components.md
/// §3.1, §3.2; #072 T0).

/// A fake `adb` that records each call and answers the ones the Guest Agent uses. The state of the fake (the installed
/// version, whether the agent runs, and whether the next install is refused) lives in files in its directory.
private final class FakeGuestADB: @unchecked Sendable {
    let directory: URL
    let executable: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-072-adb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("adb")
        let script = """
            #!/bin/sh
            dir='\(directory.path)'
            printf '%s\\n' "$*" >> "$dir/calls.log"
            case "$*" in
              "-s 127.0.0.1:6520 forward tcp:0 localabstract:apkrun-guestd-control") echo 43001; exit 0 ;;
              "-s 127.0.0.1:6520 forward --remove tcp:43001") exit 0 ;;
              "-s 127.0.0.1:6520 forward --list")
                printf '127.0.0.1:6520 tcp:43001 localabstract:apkrun-guestd-control\\n'
                printf '127.0.0.1:6520 tcp:5555 localabstract:other\\n'
                exit 0 ;;
              "-s 127.0.0.1:6520 shell pm list packages --show-versioncode io.apkrun.guest")
                v=$(cat "$dir/version" 2>/dev/null || echo 1000)
                echo "package:io.apkrun.guest versionCode:$v"
                exit 0 ;;
              "-s 127.0.0.1:6520 install -r -t "*)
                if [ -f "$dir/refuse-install" ]; then
                  rm -f "$dir/refuse-install"
                  echo "adb: failed to install: Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]"
                  exit 1
                fi
                echo "Performing Streamed Install"; echo "Success"; exit 0 ;;
              "-s 127.0.0.1:6520 uninstall io.apkrun.guest") echo "Success"; exit 0 ;;
              "-s 127.0.0.1:6520 shell pidof apkrun_guestd")
                if [ -f "$dir/running" ]; then echo 2121; exit 0; fi
                exit 1 ;;
              "-s 127.0.0.1:6520 shell kill 2121") rm -f "$dir/running"; exit 0 ;;
              *"app_process"*) touch "$dir/running"; exit 0 ;;
              *) exit 0 ;;
            esac
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    var calls: [String] {
        let text = (try? String(contentsOf: directory.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    func setInstalledVersion(_ version: Int) throws {
        try String(version).write(to: directory.appendingPathComponent("version"), atomically: true, encoding: .utf8)
    }

    func setRunning(_ running: Bool) throws {
        let flag = directory.appendingPathComponent("running")
        if running {
            try Data().write(to: flag)
        } else {
            try? FileManager.default.removeItem(at: flag)
        }
    }

    func refuseNextInstall() throws {
        try Data().write(to: directory.appendingPathComponent("refuse-install"))
    }
}

private func bundle(version: Int) -> GuestAgentBundle {
    GuestAgentBundle(
        apk: URL(fileURLWithPath: "/tmp/apkrun-072-missing/apkrun-guest.apk"),
        packageName: "io.apkrun.guest",
        versionCode: version,
        versionName: "test"
    )
}

@Test(.timeLimit(.minutes(1)))
func forwardReturnsThePortAdbChoseAndRemovesItAgain() async throws {
    let fake = try FakeGuestADB()
    let client = AdbClient(executable: fake.executable)
    let port = try await client.forward(remote: "localabstract:apkrun-guestd-control")
    #expect(port == 43001)
    let forwards = try await client.forwardList()
    #expect(forwards.contains(AdbForward(local: "tcp:43001", remote: "localabstract:apkrun-guestd-control")))
    try await client.forwardRemove(port: port)
    #expect(fake.calls.contains("-s 127.0.0.1:6520 forward --remove tcp:43001"))
}

@Test(.timeLimit(.minutes(1)))
func aForwardToAnythingButAGuestSocketIsRefused() async throws {
    let fake = try FakeGuestADB()
    let client = AdbClient(executable: fake.executable)
    do {
        _ = try await client.forward(remote: "tcp:8080")
        Issue.record("a forward to a non-socket target was started")
    } catch let failure as AdbFailure {
        #expect(failure == .invalidArgument(command: "forward"))
    }
}

@Test(.timeLimit(.minutes(1)))
func startGuestAgentRunsTheDocumentedAppProcessCommand() async throws {
    let fake = try FakeGuestADB()
    let client = AdbClient(executable: fake.executable)
    try await client.startGuestAgent(packageName: "io.apkrun.guest")
    let started = fake.calls.first { $0.contains("app_process") } ?? ""
    #expect(started.contains("setsid nohup app_process -Dapkrun.mode=development / --nice-name=apkrun_guestd"))
    #expect(started.contains("io.apkrun.guest.daemon.Main"))
}

@Test(.timeLimit(.minutes(1)))
func aMatchingVersionIsNotInstalledAgain() async throws {
    let fake = try FakeGuestADB()
    try fake.setInstalledVersion(1000)
    let provisioner = GuestAgentProvisioner(
        adb: AdbClient(executable: fake.executable),
        bundle: bundle(version: 1000)
    )
    try await provisioner.installIfNeeded()
    #expect(!fake.calls.contains { $0.contains(" install ") })
}

@Test(.timeLimit(.minutes(1)))
func aDifferentVersionIsInstalledWithTheTestOnlyFlag() async throws {
    let fake = try FakeGuestADB()
    try fake.setInstalledVersion(999)
    let provisioner = GuestAgentProvisioner(
        adb: AdbClient(executable: fake.executable),
        bundle: bundle(version: 1000)
    )
    try await provisioner.installIfNeeded()
    #expect(fake.calls.contains { $0.hasPrefix("-s 127.0.0.1:6520 install -r -t ") })
}

@Test(.timeLimit(.minutes(1)))
func anOlderBundleReplacesANewerInstalledAgentByRemovingIt() async throws {
    let fake = try FakeGuestADB()
    try fake.setInstalledVersion(1001)
    let provisioner = GuestAgentProvisioner(
        adb: AdbClient(executable: fake.executable),
        bundle: bundle(version: 1000)
    )
    try await provisioner.installIfNeeded()
    let calls = fake.calls
    let uninstall = calls.firstIndex(of: "-s 127.0.0.1:6520 uninstall io.apkrun.guest")
    let install = calls.firstIndex { $0.hasPrefix("-s 127.0.0.1:6520 install -r -t ") }
    #expect(uninstall != nil && install != nil)
    if let uninstall, let install {
        #expect(uninstall < install)
    }
}

@Test(.timeLimit(.minutes(1)))
func aSignerMismatchRemovesTheInstalledAgentBeforeInstalling() async throws {
    let fake = try FakeGuestADB()
    try fake.setInstalledVersion(999)
    try fake.refuseNextInstall()
    let provisioner = GuestAgentProvisioner(
        adb: AdbClient(executable: fake.executable),
        bundle: bundle(version: 1000)
    )
    try await provisioner.installIfNeeded()
    let installs = fake.calls.filter { $0.contains(" install -r -t ") }
    let uninstallIndex = fake.calls.firstIndex(of: "-s 127.0.0.1:6520 uninstall io.apkrun.guest")
    #expect(installs.count == 2)
    #expect(uninstallIndex != nil)
}

@Test(.timeLimit(.minutes(1)))
func startingReplacesARunningAgentFirst() async throws {
    let fake = try FakeGuestADB()
    try fake.setRunning(true)
    let provisioner = GuestAgentProvisioner(
        adb: AdbClient(executable: fake.executable),
        bundle: bundle(version: 1000)
    )
    try await provisioner.startAgent()
    let calls = fake.calls
    let kill = calls.firstIndex(of: "-s 127.0.0.1:6520 shell kill 2121")
    let start = calls.firstIndex { $0.contains("app_process") }
    #expect(kill != nil && start != nil)
    if let kill, let start {
        #expect(kill < start)
    }
}
