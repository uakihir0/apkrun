import Foundation
import RuntimeCore

/// `apkrun dev adb [<args>…]`: the developer's adb against the development Android (cli.md §5; #015).
///
/// APKRun does not ship adb. The command first connects the endpoint, so that adb knows the
/// device, and then runs `adb -s 127.0.0.1:6520 <arguments>` with the terminal attached. A connect
/// that fails here is not an error of its own: adb prints the reason, and the exit status is passed through.
public struct DevAdb: Sendable {
    /// Creates the command runner.
    public init() {}

    /// Runs adb with `arguments` and returns its exit status.
    ///
    /// Throws `executableMissing` when neither `$ANDROID_HOME/platform-tools/adb` nor `adb` on `PATH` exists.
    public func run(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws(AdbFailure) -> Int32 {
        let executable = try AdbClient.resolveExecutable(environment: environment)
        let client = AdbClient(executable: executable)
        try? await client.connect(timeout: .seconds(2))
        return try client.runAttached(arguments)
    }
}
