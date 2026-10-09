import Foundation
import RuntimeCore
import Testing

@testable import RuntimeHost

/// `apkrun dev adb` runs the developer's adb against 127.0.0.1:6520 and passes the exit status
/// through (cli.md §5; #015 T0). A fake adb in a temporary directory records its arguments.
@Test(.timeLimit(.minutes(1)))
func devAdbConnectsThenPassesTheExitStatusThrough() async throws {
    let fake = try FakeSDK()

    let status = try await DevAdb().run(
        arguments: ["shell", "exit-7"],
        environment: ["ANDROID_HOME": fake.sdk.path, "PATH": "/nonexistent"]
    )

    #expect(status == 7)
    let calls = try fake.calls()
    #expect(calls.first == "connect 127.0.0.1:6520")
    #expect(calls.last == "-s 127.0.0.1:6520 shell exit-7")
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

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-015-devadb-\(UUID().uuidString)", isDirectory: true)
        sdk = root.appendingPathComponent("sdk", isDirectory: true)
        let tools = sdk.appendingPathComponent("platform-tools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let script = """
            #!/bin/sh
            printf '%s\\n' "$*" >> '\(root.path)/calls.log'
            case "$*" in
              "connect 127.0.0.1:6520") echo "connected to 127.0.0.1:6520"; exit 0 ;;
              *"get-state") echo device; exit 0 ;;
              "-s 127.0.0.1:6520 shell exit-7") exit 7 ;;
              "-s 127.0.0.1:6520 devices") echo "List of devices attached"; exit 0 ;;
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
