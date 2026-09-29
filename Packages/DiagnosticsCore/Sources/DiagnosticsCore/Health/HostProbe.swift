import Foundation

#if canImport(CoreFoundation)
    import CoreFoundation
#endif
#if canImport(Darwin)
    import Darwin
#endif
#if canImport(Security)
    import Security
#endif
#if canImport(ServiceManagement)
    import ServiceManagement
#endif

/// Supplies wall-clock timestamps to diagnostics without coupling tests to global time.
public protocol DiagnosticsClock: Sendable {
    /// The current wall-clock time.
    var now: Date { get }
}

/// The production wall clock.
public struct SystemDiagnosticsClock: DiagnosticsClock {
    /// Creates a clock backed by the system wall clock.
    public init() {}

    /// The current system date.
    public var now: Date { Date() }
}

/// A macOS version tuple that can be compared without parsing display strings.
public struct HostOSVersion: Codable, Equatable, Sendable, Comparable, CustomStringConvertible {
    /// The major macOS version.
    public let major: Int

    /// The minor macOS version.
    public let minor: Int

    /// The patch macOS version.
    public let patch: Int

    /// Creates a comparable macOS version tuple.
    public init(major: Int, minor: Int, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Compares versions in major, minor, then patch order.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// The dotted numeric version.
    public var description: String {
        "\(major).\(minor).\(patch)"
    }
}

/// Filesystem facts for the volume containing APKRun's data root.
public struct HostVolumeInfo: Codable, Equatable, Sendable {
    /// Whether the volume uses APFS.
    public let isAPFS: Bool

    /// Available bytes on the volume.
    public let availableBytes: Int64

    /// Creates volume information, clamping negative capacity to zero.
    public init(isAPFS: Bool, availableBytes: Int64) {
        self.isAPFS = isAPFS
        self.availableBytes = max(0, availableBytes)
    }
}

/// Build numbers read from the installed APKRun components.
public struct HostComponentBuilds: Codable, Equatable, Sendable {
    /// The embedded daemon build, if installed.
    public let daemon: String?

    /// The embedded CLI build, if installed.
    public let cli: String?

    /// The embedded launcher build, if installed.
    public let launcher: String?

    /// Creates a snapshot of the installed component build numbers.
    public init(daemon: String?, cli: String?, launcher: String?) {
        self.daemon = daemon
        self.cli = cli
        self.launcher = launcher
    }

    /// Returns the first missing or mismatched component in installation order.
    public func firstMismatch(from expectedBuild: String) -> HostComponentBuildMismatch? {
        [
            ("apkrund", daemon),
            ("apkrun", cli),
            ("APKRunLauncher", launcher),
        ]
        .first(where: { $0.1 != expectedBuild })
        .map {
            HostComponentBuildMismatch(
                component: $0.0,
                foundBuild: $0.1 ?? "missing"
            )
        }
    }
}

/// The first installed component whose build does not match the app.
public struct HostComponentBuildMismatch: Codable, Equatable, Sendable {
    /// The component's installed name.
    public let component: String

    /// Its installed build number, or `missing` when absent.
    public let foundBuild: String

    /// Creates a description of one mismatched component.
    public init(component: String, foundBuild: String) {
        self.component = component
        self.foundBuild = foundBuild
    }
}

/// Registration state for the per-user background service.
public enum HostRuntimeRegistration: String, Codable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
}

/// The only boundary through which host-specific system facts enter health checks.
public protocol HostProbe: Sendable {
    /// Whether this process runs natively on Apple silicon.
    func supportsAppleSilicon() async -> Bool

    /// The host macOS version.
    func macOSVersion() async -> HostOSVersion

    /// Whether the host exposes the required hypervisor support.
    func supportsHypervisor() async -> Bool

    /// Whether the containing app is installed in an Applications directory.
    func applicationIsInApplications() async -> Bool

    /// Whether the containing app passes the platform signature check.
    func applicationSignatureIsValid() async -> Bool

    /// Build numbers reported by the installed APKRun components.
    func componentBuilds() async -> HostComponentBuilds

    /// APFS status and available bytes for the volume containing a path.
    func dataVolumeInfo(at path: URL) async -> HostVolumeInfo

    /// The host's physical memory size in bytes.
    func physicalMemoryBytes() async -> UInt64

    /// The registration state of a per-user runtime service.
    func runtimeRegistration(label: String) async -> HostRuntimeRegistration
}

/// The production implementation of `HostProbe`.
public struct SystemHostProbe: HostProbe {
    /// Creates a probe backed by macOS system APIs.
    public init() {}

    /// Checks that the process is native arm64 and not translated by Rosetta.
    public func supportsAppleSilicon() async -> Bool {
        sysctlInteger("hw.optional.arm64") == 1
            && sysctlInteger("sysctl.proc_translated") == 0
    }

    /// Reads the operating system version from process information.
    public func macOSVersion() async -> HostOSVersion {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return HostOSVersion(
            major: version.majorVersion,
            minor: version.minorVersion,
            patch: version.patchVersion
        )
    }

    /// Checks whether the host reports hypervisor support.
    public func supportsHypervisor() async -> Bool {
        sysctlInteger("kern.hv_support") == 1
    }

    /// Checks whether the app bundle resides in a system or user Applications folder.
    public func applicationIsInApplications() async -> Bool {
        guard let appURL = applicationBundleURL else {
            return false
        }
        let path = appURL.standardizedFileURL.path
        guard !appURL.pathComponents.contains("AppTranslocation") else {
            return false
        }
        let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true).path
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL
            .path
        return path == systemApplications || path.hasPrefix(systemApplications + "/")
            || path == userApplications || path.hasPrefix(userApplications + "/")
    }

    /// Checks the containing app's nested code and designated requirement.
    public func applicationSignatureIsValid() async -> Bool {
        #if canImport(Security)
            guard let appURL = applicationBundleURL else {
                return false
            }
            var staticCode: SecStaticCode?
            guard SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
                let staticCode
            else {
                return false
            }
            var designatedRequirement: SecRequirement?
            guard
                SecCodeCopyDesignatedRequirement(
                    staticCode,
                    SecCSFlags(),
                    &designatedRequirement
                ) == errSecSuccess, let designatedRequirement
            else {
                return false
            }
            let flags = SecCSFlags(rawValue: kSecCSCheckNestedCode)
            return SecStaticCodeCheckValidity(
                staticCode,
                flags,
                designatedRequirement
            ) == errSecSuccess
        #else
            return false
        #endif
    }

    /// Reads embedded build numbers from the main app's daemon, CLI, and launcher.
    public func componentBuilds() async -> HostComponentBuilds {
        guard let appURL = applicationBundleURL else {
            return HostComponentBuilds(daemon: nil, cli: nil, launcher: nil)
        }
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let daemonURL = contents.appendingPathComponent("Helpers/apkrund")
        let cliURL = contents.appendingPathComponent("Resources/bin/apkrun")
        let launcherURL = contents.appendingPathComponent("Helpers/APKRunLauncher.app", isDirectory: true)
        let daemon = embeddedBuildNumber(at: daemonURL)
        let cli = embeddedBuildNumber(at: cliURL)
        let launcher =
            Bundle(url: launcherURL)?
            .object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return HostComponentBuilds(daemon: daemon, cli: cli, launcher: launcher)
    }

    /// Reads filesystem type and available capacity for the nearest existing ancestor.
    public func dataVolumeInfo(at path: URL) async -> HostVolumeInfo {
        #if canImport(Darwin)
            var volumeURL = path.standardizedFileURL
            while !FileManager.default.fileExists(atPath: volumeURL.path) {
                let parentURL = volumeURL.deletingLastPathComponent()
                guard parentURL != volumeURL else {
                    return HostVolumeInfo(isAPFS: false, availableBytes: 0)
                }
                volumeURL = parentURL
            }
            var info = statfs()
            guard volumeURL.path.withCString({ statfs($0, &info) }) == 0 else {
                return HostVolumeInfo(isAPFS: false, availableBytes: 0)
            }
            let available = Int64(info.f_bavail).multipliedReportingOverflow(by: Int64(info.f_bsize))
            let fileSystemName = withUnsafeBytes(of: &info.f_fstypename) {
                String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            return HostVolumeInfo(
                isAPFS: fileSystemName == "apfs",
                availableBytes: available.overflow ? Int64.max : max(0, available.partialValue)
            )
        #else
            return HostVolumeInfo(isAPFS: false, availableBytes: 0)
        #endif
    }

    /// Returns the physical memory size reported by the host.
    public func physicalMemoryBytes() async -> UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    /// Checks whether the per-user service is enabled or awaits approval.
    public func runtimeRegistration(label: String) async -> HostRuntimeRegistration {
        if Bundle.main.bundleURL.pathExtension == "app" {
            #if canImport(ServiceManagement)
                let plistName = "\(label).plist"
                switch SMAppService.agent(plistName: plistName).status {
                case .enabled:
                    return .enabled
                case .requiresApproval:
                    return .requiresApproval
                case .notRegistered, .notFound:
                    return .notRegistered
                @unknown default:
                    return .notRegistered
                }
            #endif
        }
        let uid = getuid()
        return await launchctlPrintSucceeds(
            target: "gui/\(uid)/\(label)"
        ) ? .enabled : .notRegistered
    }

    private var applicationBundleURL: URL? {
        var candidate = Bundle.main.bundleURL.standardizedFileURL
        while candidate.path != "/" {
            if candidate.pathExtension == "app" {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    private func sysctlInteger(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return nil
        }
        return value
    }

    private func embeddedBuildNumber(at url: URL) -> String? {
        #if canImport(Security)
            var staticCode: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
                let staticCode
            else {
                return nil
            }
            var signingInformation: CFDictionary?
            guard
                SecCodeCopySigningInformation(
                    staticCode,
                    SecCSFlags(),
                    &signingInformation
                ) == errSecSuccess,
                let signingInformation,
                let codeInformation = signingInformation as? [String: Any],
                let infoPlist = codeInformation[kSecCodeInfoPList as String] as? [String: Any]
            else {
                return nil
            }
            return infoPlist["CFBundleVersion"] as? String
        #else
            return nil
        #endif
    }

    private func launchctlPrintSucceeds(target: String) async -> Bool {
        let runner = HostProbeProcessRunner()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                runner.run(
                    executable: URL(fileURLWithPath: "/bin/launchctl"),
                    arguments: ["print", target]
                ) == 0
            }
            .value
        } onCancel: {
            runner.cancel()
        }
    }
}

private final class HostProbeProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancellationRequested = false

    func run(executable: URL, arguments: [String]) -> Int32? {
        let candidate = Process()
        candidate.executableURL = executable
        candidate.arguments = arguments
        candidate.standardOutput = FileHandle.nullDevice
        candidate.standardError = FileHandle.nullDevice

        lock.lock()
        guard !cancellationRequested else {
            lock.unlock()
            return nil
        }
        process = candidate
        lock.unlock()

        do {
            try candidate.run()
        } catch {
            return nil
        }

        lock.lock()
        let shouldTerminate = cancellationRequested
        lock.unlock()
        if shouldTerminate, candidate.isRunning {
            candidate.terminate()
        }

        candidate.waitUntilExit()
        return candidate.terminationStatus
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let runningProcess = process
        lock.unlock()

        if let runningProcess, runningProcess.isRunning {
            runningProcess.terminate()
        }
    }
}
