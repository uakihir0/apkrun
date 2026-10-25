import APKStoreCore
import Foundation
import RuntimeCore

/// The stock-image package channel.
///
/// Package identity and metadata come from the Guest Agent's PackageManager-backed operations. ADB is used only for
/// PackageInstaller installation and the Android uninstall command, through RuntimeCore's narrow helpers.
public struct ADBStoreAgentChannel: StoreAgentChannel {
    private let agent: any ADBStoreGuestAgent
    private let adb: any ADBStoreADBClient

    /// The stock image supports PackageInstaller installs and PackageManager metadata queries.
    ///
    /// Downgrade reinstall is available only when the caller has verified `ro.debuggable=1`.
    public let capabilities: StoreCapabilities
    /// PackageManager changes reported by the Guest Agent while the channel is active.
    public let packageEvents: AsyncStream<StorePackageEvent>

    private let packageEventRelayTask: Task<Void, Never>
    private let packageEventContinuation: AsyncStream<StorePackageEvent>.Continuation
    /// Creates a channel using the active Guest Agent and ADB client for one Android runtime.
    public init(agent: DevelopmentGuestAgent, adb: AdbClient) {
        self.init(
            agent: agent,
            adb: adb,
            capabilities: [.install, .metadata]
        )
    }

    /// Creates a channel and advertises downgrade reinstall only when Android confirms it is a debuggable image.
    ///
    /// If the property query fails, the channel remains usable for normal installs and omits downgrade capability.
    public static func connectedToCurrentImage(agent: DevelopmentGuestAgent, adb: AdbClient) async -> Self {
        let isDebuggable = (try? await adb.getprop("ro.debuggable")) == "1"
        let capabilities: StoreCapabilities =
            isDebuggable ? [.install, .metadata, .downgradeReinstall] : [.install, .metadata]
        return Self(agent: agent, adb: adb, capabilities: capabilities)
    }

    init(
        agent: any ADBStoreGuestAgent,
        adb: any ADBStoreADBClient,
        capabilities: StoreCapabilities
    ) {
        self.agent = agent
        self.adb = adb
        self.capabilities = capabilities
        let events = AsyncStream.makeStream(
            of: StorePackageEvent.self,
            bufferingPolicy: .bufferingNewest(1_024)
        )
        packageEvents = events.stream
        packageEventContinuation = events.continuation
        let runtimeEvents = agent.makePackageEventStream()
        packageEventRelayTask = Task {
            for await event in runtimeEvents {
                guard let packageID = PackageID(rawValue: event.packageID.rawValue) else {
                    continue
                }
                events.continuation.yield(
                    StorePackageEvent(
                        packageID: packageID,
                        kind: Self.packageEventKind(event.kind),
                        versionCode: event.versionCode
                    )
                )
            }
            events.continuation.finish()
        }
    }

    /// Stops relaying Guest Agent events and finishes this channel's event stream.
    public func close() async {
        packageEventRelayTask.cancel()
        packageEventContinuation.finish()
        await packageEventRelayTask.value
    }

    /// Installs the requested package set, then verifies PackageManager reports the exact package and version.
    public func install(_ request: StoreInstallRequest, files: [URL]) async throws -> StorePackageInfo {
        guard !files.isEmpty else {
            throw ADBStoreAgentChannelFailure.emptyInstallSet
        }
        guard !request.allowDowngrade || capabilities.contains(.downgradeReinstall) else {
            throw ADBStoreAgentChannelFailure.downgradeNotSupported
        }

        try await agent.installMultiple(apks: files, allowDowngrade: request.allowDowngrade)

        guard let installed = try await agent.storePackageInfo(request.packageID.rawValue) else {
            throw ADBStoreAgentChannelFailure.packageNotInstalled(request.packageID)
        }
        let info = try Self.packageInfo(installed)
        guard info.packageID == request.packageID else {
            throw ADBStoreAgentChannelFailure.packageMismatch(expected: request.packageID, actual: info.packageID)
        }
        guard info.versionCode == request.versionCode else {
            throw ADBStoreAgentChannelFailure.versionMismatch(
                package: request.packageID,
                expected: request.versionCode,
                actual: info.versionCode
            )
        }
        return info
    }

    /// Uninstalls a package, retaining app data when requested.
    public func uninstall(_ package: PackageID, keepData: Bool) async throws {
        try await adb.uninstall(packageName: package.rawValue, keepData: keepData)
    }

    /// Reads the package through Guest Agent `QueryPackage`; `nil` means PackageManager says it is not installed.
    public func packageInfo(_ package: PackageID) async throws -> StorePackageInfo? {
        guard let info = try await agent.storePackageInfo(package.rawValue) else {
            return nil
        }
        let result = try Self.packageInfo(info)
        guard result.packageID == package else {
            throw ADBStoreAgentChannelFailure.packageMismatch(expected: package, actual: result.packageID)
        }
        return result
    }

    /// Lists packages through Guest Agent `ListPackages`, never by parsing `pm list packages` output.
    public func listPackages(_ filter: StorePackageFilter) async throws -> [StorePackageSummary] {
        let guestFilter: GuestPackageFilter
        switch filter {
        case .launchable:
            guestFilter = .launchable
        case .userInstalled:
            guestFilter = .userInstalled
        case .all:
            guestFilter = .all
        }

        return try await agent.listStorePackages(filter: guestFilter).map { summary in
            guard let packageID = PackageID(rawValue: summary.package) else {
                throw ADBStoreAgentChannelFailure.invalidPackageID(summary.package)
            }
            guard summary.versionCode >= 0 else {
                throw ADBStoreAgentChannelFailure.invalidVersionCode(package: summary.package)
            }
            return StorePackageSummary(
                packageID: packageID,
                displayName: summary.label.isEmpty ? summary.package : summary.label,
                versionCode: summary.versionCode,
                launchable: summary.launchable,
                userInstalled: summary.userInstalled
            )
        }
    }

    private static func packageInfo(_ guest: GuestPackageMetadata) throws -> StorePackageInfo {
        guard let packageID = PackageID(rawValue: guest.package) else {
            throw ADBStoreAgentChannelFailure.invalidPackageID(guest.package)
        }
        guard guest.versionCode >= 0 else {
            throw ADBStoreAgentChannelFailure.invalidVersionCode(package: guest.package)
        }
        guard guest.targetSDK >= 0, guest.minSDK >= 0 else {
            throw ADBStoreAgentChannelFailure.invalidSDK(package: guest.package)
        }

        let installerPackage: PackageID?
        if guest.installerPackage.isEmpty {
            installerPackage = nil
        } else if let installer = PackageID(rawValue: guest.installerPackage) {
            installerPackage = installer
        } else {
            throw ADBStoreAgentChannelFailure.invalidInstallerPackage(guest.installerPackage)
        }

        let signingDigests = try guest.signingSHA256.map { bytes -> SHA256Digest in
            guard bytes.count == 32 else {
                throw ADBStoreAgentChannelFailure.invalidSigningDigest(package: guest.package)
            }
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            guard let digest = SHA256Digest(hex: hex) else {
                throw ADBStoreAgentChannelFailure.invalidSigningDigest(package: guest.package)
            }
            return digest
        }

        return StorePackageInfo(
            packageID: packageID,
            displayName: guest.label.isEmpty ? guest.package : guest.label,
            versionCode: guest.versionCode,
            versionName: guest.versionName.isEmpty ? nil : guest.versionName,
            enabled: guest.enabled,
            launchableComponent: guest.launchableComponent.isEmpty ? nil : guest.launchableComponent,
            installerPackage: installerPackage,
            firstInstallTime: Self.date(milliseconds: guest.firstInstallTimeMs),
            lastUpdateTime: Self.date(milliseconds: guest.lastUpdateTimeMs),
            targetSDK: Int(guest.targetSDK),
            minSDK: Int(guest.minSDK),
            signingDigests: signingDigests
        )
    }

    private static func packageEventKind(_ kind: RuntimeStorePackageEvent.Kind) -> StorePackageEvent.Kind {
        switch kind {
        case .added: .added
        case .replaced: .replaced
        case .removed: .removed
        case .changed: .changed
        }
    }

    private static func date(milliseconds: Int64) -> Date? {
        guard milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }
}

/// Narrow testing seam for the Guest Agent operations used by the stock-image channel.
protocol ADBStoreGuestAgent: Sendable {
    func makePackageEventStream() -> AsyncStream<RuntimeStorePackageEvent>
    func installMultiple(apks: [URL], allowDowngrade: Bool) async throws(AdbFailure)
    func storePackageInfo(_ package: String) async throws(GuestAgentFailure) -> GuestPackageMetadata?
    func listStorePackages(filter: GuestPackageFilter) async throws(GuestAgentFailure) -> [GuestPackageSummary]
}

/// Narrow testing seam for package removal through RuntimeCore's ADB helper.
protocol ADBStoreADBClient: Sendable {
    func uninstall(packageName: String, keepData: Bool) async throws(AdbFailure)
}

extension DevelopmentGuestAgent: ADBStoreGuestAgent {}

extension AdbClient: ADBStoreADBClient {
    func uninstall(packageName: String, keepData: Bool) async throws(AdbFailure) {
        try await uninstall(packageName: packageName, keepData: keepData, timeout: .seconds(60))
    }
}

/// Failures detected while reconciling the stock image's Guest Agent response with an install request.
public enum ADBStoreAgentChannelFailure: Error, Equatable, Sendable {
    case emptyInstallSet
    case downgradeNotSupported
    case packageNotInstalled(PackageID)
    case packageMismatch(expected: PackageID, actual: PackageID)
    case versionMismatch(package: PackageID, expected: VersionCode, actual: VersionCode)
    case invalidPackageID(String)
    case invalidVersionCode(package: String)
    case invalidSDK(package: String)
    case invalidInstallerPackage(String)
    case invalidSigningDigest(package: String)
}
