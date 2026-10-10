import DiagnosticsCore
import Foundation

/// What one VM test run owns: its APKRUN home and its developer ADB port (test-strategy §3.10).
///
/// Two runs on one Mac collide on fixed paths and on the default ADB port. A run gets its own home, a
/// directory under `/tmp` named with its full UUID. Its instance, console sockets, logs, and captures are
/// then its own, because the product derives them from the home. The root is short on purpose: a developer
/// console socket path must fit `sockaddr_un`, and a `$TMPDIR` root does not.
///
/// The ADB port is read from `APKRUN_TEST_ADB_PORT`. xcodebuild passes that to the test process as
/// `TEST_RUNNER_APKRUN_TEST_ADB_PORT`. When the variable is unset or empty, the port is `0`, and the kernel
/// chooses a free loopback port, which the supervisor reports.
public struct VMRunResources: Equatable, Sendable {
    /// The environment variable that sets the developer ADB port of a run.
    public static let adbPortVariable = "APKRUN_TEST_ADB_PORT"
    /// The longest socket path `sockaddr_un` holds, without its terminating NUL (`DevConsoleSocketServer`).
    public static let maximumSocketPathBytes = 103
    private static let homePrefix = "/tmp/apkrun-vm-"

    /// The run's root, which is its APKRUN home.
    public let home: URL
    /// The developer ADB port: `0` for a kernel-chosen port, otherwise the port the environment asked for.
    public let adbHostPort: UInt16

    /// The resources of the run with `runID`. Nothing is created on disk.
    public init(runID: UUID, adbHostPort: UInt16) {
        home = URL(fileURLWithPath: Self.homePrefix + runID.uuidString.lowercased(), isDirectory: true)
        self.adbHostPort = adbHostPort
    }

    /// A new run with a new ID and an ADB port from `environment`, with its home created as a private
    /// directory. The port is checked before anything is created.
    public static func new(environment: [String: String]) throws -> VMRunResources {
        let port = try adbHostPort(environment: environment)
        let resources = VMRunResources(runID: UUID(), adbHostPort: port)
        try FileManager.default.createDirectory(
            at: resources.home,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return resources
    }

    /// The developer ADB port that `environment` asks for. Unset or empty means `0`. Anything else must be a
    /// decimal port number from 0 to 65535. A malformed value is an error, never a silent default.
    public static func adbHostPort(environment: [String: String]) throws(VMRunResourcesFailure) -> UInt16 {
        guard let value = environment[adbPortVariable], !value.isEmpty else {
            return 0
        }
        guard value.allSatisfy({ $0.isASCII && $0.isNumber }), let port = UInt16(value) else {
            throw .invalidADBPort(value)
        }
        return port
    }

    /// Where the run keeps an artifact that must outlive the home, such as the G2 reference capture. It is a
    /// sibling of the home, so removing the home does not remove it.
    public var captureDirectory: URL {
        URL(fileURLWithPath: home.path + "-capture", isDirectory: true)
    }

    /// The paths of the run, derived by the product's own `APKRunPaths` from the home.
    public var paths: APKRunPaths {
        APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": home.path])
    }

    /// The developer console socket of `name` (`hvc0` or `hvc1`) in this run, as `DevConsoleSocketServer` names it.
    public func consoleSocketPath(_ name: String) -> String {
        paths.devConsoleDirectory.appendingPathComponent("\(name).sock").path
    }
}

/// Why a test run cannot take its resources from the environment.
public enum VMRunResourcesFailure: Error, Equatable, Sendable {
    /// `APKRUN_TEST_ADB_PORT` is not a decimal port number from 0 to 65535.
    case invalidADBPort(String)
}
