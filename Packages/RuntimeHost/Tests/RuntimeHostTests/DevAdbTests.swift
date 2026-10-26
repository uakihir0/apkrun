import Foundation
import RuntimeCore
import Testing

@testable import RuntimeHost

/// `apkrun dev adb` runs the developer's adb against 127.0.0.1:6520 and passes the exit status
/// through (cli.md §5; #16 T0). A fake adb in a temporary directory records its arguments.
@Test(.timeLimit(.minutes(1)))
func devAdbConnectsThenPassesTheExitStatusThrough() async throws {
    let fake = try FakeSDK(transportAbsent: true)

    let status = try await DevAdb().run(
        arguments: ["shell", "exit-7"],
        environment: ["ANDROID_HOME": fake.sdk.path, "PATH": "/nonexistent"]
    )

    #expect(status == 7)
    let calls = try fake.calls()
    #expect(calls.contains("connect 127.0.0.1:6520"))
    #expect(calls.last == "-s 127.0.0.1:6520 shell exit-7")
}

/// A running boot holds the Guest Agent's forwards on the endpoint's transport. `apkrun dev adb` must not drop that
/// transport, so it must not disconnect or connect when the endpoint already reports `device` (#25).
@Test(.timeLimit(.minutes(1)))
func devAdbLeavesAHealthyTransportAlone() async throws {
    let fake = try FakeSDK()

    let status = try await DevAdb().run(
        arguments: ["shell", "exit-7"],
        environment: ["ANDROID_HOME": fake.sdk.path, "PATH": "/nonexistent"]
    )

    #expect(status == 7)
    let calls = try fake.calls()
    #expect(!calls.contains("disconnect 127.0.0.1:6520"))
    #expect(!calls.contains("connect 127.0.0.1:6520"))
    #expect(calls.last == "-s 127.0.0.1:6520 shell exit-7")
}

@Test(.timeLimit(.minutes(1)))
func devAdbUsesTheSelectedLoopbackPort() async throws {
    let hostPort: UInt16 = 49_321
    let fake = try FakeSDK(transportAbsent: true, hostPort: hostPort)

    let status = try await DevAdb().run(
        arguments: ["shell", "exit-7"],
        hostPort: hostPort,
        environment: ["ANDROID_HOME": fake.sdk.path, "PATH": "/nonexistent"]
    )

    #expect(status == 7)
    let calls = try fake.calls()
    #expect(calls.contains("connect 127.0.0.1:49321"))
    #expect(calls.last == "-s 127.0.0.1:49321 shell exit-7")
}

@Test(.timeLimit(.minutes(1)))
func devAdbReturnsZeroWhenAdbSucceeds() async throws {
    let fake = try FakeSDK()

    let status = try await DevAdb().run(
        arguments: ["devices"],
        environment: ["ANDROID_HOME": fake.sdk.path, "PATH": "/nonexistent"]
    )

    #expect(status == 0)
}

@Test(.timeLimit(.minutes(1)))
func devAdbNamesTheMissingAdbAsAnExecutableFailure() async throws {
    do {
        _ = try await DevAdb().run(
            arguments: ["devices"],
            environment: ["ANDROID_HOME": "/nonexistent", "PATH": "/nonexistent"]
        )
        Issue.record("Without adb the command must fail.")
    } catch {
        #expect(error == .executableMissing)
    }
}

/// A temporary SDK whose `platform-tools/adb` logs its arguments and answers the few commands used here.
private final class FakeSDK: @unchecked Sendable {
    let root: URL
    let sdk: URL

    /// `transportAbsent` makes the endpoint unknown to the adb server until the first `connect`, as on a fresh boot.
    init(transportAbsent: Bool = false, hostPort: UInt16 = 6520) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-015-devadb-\(UUID().uuidString)", isDirectory: true)
        sdk = root.appendingPathComponent("sdk", isDirectory: true)
        let tools = sdk.appendingPathComponent("platform-tools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        if transportAbsent {
            try Data().write(to: root.appendingPathComponent("absent"))
        }
        let endpoint = "127.0.0.1:\(hostPort)"
        let script = """
            #!/bin/sh
            dir='\(root.path)'
            endpoint='\(endpoint)'
            printf '%s\\n' "$*" >> "$dir/calls.log"
            case "$*" in
              "connect $endpoint") touch "$dir/connected"; echo "connected to $endpoint"; exit 0 ;;
              "disconnect $endpoint") rm -f "$dir/connected"; exit 0 ;;
              *"get-state")
                if [ -f "$dir/absent" ] && [ ! -f "$dir/connected" ]; then
                  echo "error: device '$endpoint' not found" >&2; exit 1
                fi
                echo device; exit 0 ;;
              "-s $endpoint shell exit-7") exit 7 ;;
              "-s $endpoint devices") echo "List of devices attached"; exit 0 ;;
              *) echo "unexpected: $*" >&2; exit 2 ;;
            esac
            """
        let adb = tools.appendingPathComponent("adb")
        try script.write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func calls() throws -> [String] {
        try String(contentsOf: root.appendingPathComponent("calls.log"), encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
    }
}
