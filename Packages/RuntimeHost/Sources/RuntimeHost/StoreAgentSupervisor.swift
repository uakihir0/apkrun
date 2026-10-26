import APKStoreCore
import DiagnosticsCore
import Foundation
import RuntimeAPI
import RuntimeCore

protocol StoreAgentDisconnectionEventSource: Sendable {
    var disconnectionEvents: AsyncStream<Void> { get }
}

/// APKStoreCore adapter for RuntimeCore's protocol-facing Store Agent client.
///
/// Package policy and records remain in APKStoreCore. GuestProtocol messages and guest transport handling stay in
/// RuntimeCore; this adapter translates between the two modules' value types.
public actor StoreAgentSupervisor: StoreAgentChannel, StoreAgentDisconnectionEventSource {
    /// Largest artifact chunk accepted by the Store Agent protocol.
    public static let maximumChunkSize = GuestStoreAgentClient.maximumChunkSize
    /// Largest individual APK artifact supported by Android PackageInstaller.
    public static let maximumArtifactSize = GuestStoreAgentClient.maximumArtifactSize
    /// How long the host waits without progress while sending an artifact.
    public static let artifactStallTimeout = GuestStoreAgentClient.artifactStallTimeout
    /// Maximum wait for the Store Agent to report a final install outcome.
    public static let defaultInstallOutcomeTimeout = GuestStoreAgentClient.defaultInstallOutcomeTimeout
    /// Keepalive cadence and unanswered-ping limit interval.
    public static let defaultKeepaliveInterval = GuestStoreAgentClient.defaultKeepaliveInterval

    /// Package lifecycle changes observed from the Store Agent.
    public nonisolated let packageEvents: AsyncStream<StorePackageEvent>
    /// Emits when the active Store Agent session is lost.
    public nonisolated let disconnectionEvents: AsyncStream<Void>

    /// Capabilities negotiated on the current Store Agent session.
    public nonisolated var capabilities: StoreCapabilities {
        let runtime = client.capabilities
        var result: StoreCapabilities = []
        if runtime.contains(.install) { result.insert(.install) }
        if runtime.contains(.metadata) { result.insert(.metadata) }
        if runtime.contains(.inspect) { result.insert(.inspect) }
        return result
    }

    /// Whether both Store Agent connections are usable.
    public nonisolated var isConnected: Bool {
        client.isConnected
    }

    private let client: GuestStoreAgentClient
    private let eventAdapterTask: Task<Void, Never>

    /// Creates a lazy APKStoreCore channel over RuntimeCore's Store Agent client.
    public init(
        transport: any RuntimeGuestTransport,
        hostVersion: String = "dev",
        logSink: (any LogSink)? = nil,
        installOutcomeTimeout: Duration = GuestStoreAgentClient.defaultInstallOutcomeTimeout,
        keepaliveInterval: Duration = GuestStoreAgentClient.defaultKeepaliveInterval
    ) {
        let client = GuestStoreAgentClient(
            transport: transport,
            hostVersion: hostVersion,
            logSink: logSink,
            installOutcomeTimeout: installOutcomeTimeout,
            keepaliveInterval: keepaliveInterval
        )
        self.client = client
        disconnectionEvents = client.disconnectionEvents

        let events = AsyncStream.makeStream(
            of: StorePackageEvent.self,
            bufferingPolicy: .bufferingNewest(1_024)
        )
        packageEvents = events.stream
        let guestEvents = client.packageEvents
        eventAdapterTask = Task {
            for await event in guestEvents {
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

    /// Opens and handshakes both Store Agent connections before returning.
    public static func connect(
        transport: any RuntimeGuestTransport,
        hostVersion: String = "dev",
        logSink: (any LogSink)? = nil,
        installOutcomeTimeout: Duration = GuestStoreAgentClient.defaultInstallOutcomeTimeout,
        keepaliveInterval: Duration = GuestStoreAgentClient.defaultKeepaliveInterval
    ) async throws -> StoreAgentSupervisor {
        let client = try await GuestStoreAgentClient.connect(
            transport: transport,
            hostVersion: hostVersion,
            logSink: logSink,
            installOutcomeTimeout: installOutcomeTimeout,
            keepaliveInterval: keepaliveInterval
        )
        return StoreAgentSupervisor(client: client)
    }

    private init(client: GuestStoreAgentClient) {
        self.client = client
        disconnectionEvents = client.disconnectionEvents

        let events = AsyncStream.makeStream(
            of: StorePackageEvent.self,
            bufferingPolicy: .bufferingNewest(1_024)
        )
        packageEvents = events.stream
        let guestEvents = client.packageEvents
        eventAdapterTask = Task {
            for await event in guestEvents {
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

    /// Inspects APK metadata using the Android archive parser.
    public func inspect(_ artifacts: [StoreArtifactSpec], files: [URL]) async throws -> StoreArchiveInfo {
        let runtime = try await client.inspect(artifacts.map(Self.runtimeArtifact), files: files)
        return try Self.archiveInfo(runtime)
    }

    /// Installs an APK set and verifies the PackageManager result.
    public func install(_ request: StoreInstallRequest, files: [URL]) async throws -> StorePackageInfo {
        let runtime = try Self.runtimeInstallRequest(request)
        return try Self.packageInfo(await client.install(runtime, files: files))
    }

    /// Installs the APK set and forwards the cancellation boundary to the guest commit request.
    public func install(
        _ request: StoreInstallRequest,
        files: [URL],
        beforeCommit: @escaping @Sendable () async throws -> Void
    ) async throws -> StorePackageInfo {
        let runtime = try Self.runtimeInstallRequest(request)
        return try Self.packageInfo(
            await client.install(runtime, files: files, beforeCommit: beforeCommit)
        )
    }

    /// Uninstalls a package through Android's PackageInstaller.
    public func uninstall(_ package: PackageID, keepData: Bool) async throws {
        try await client.uninstall(Self.runtimePackageID(package), keepData: keepData)
    }

    /// Returns PackageManager metadata, or nil when the package is absent.
    public func packageInfo(_ package: PackageID) async throws -> StorePackageInfo? {
        guard let result = try await client.packageInfo(Self.runtimePackageID(package)) else {
            return nil
        }
        return try Self.packageInfo(result)
    }

    /// Lists packages using the requested filter.
    public func listPackages(_ filter: StorePackageFilter) async throws -> [StorePackageSummary] {
        let runtimeFilter: RuntimeStorePackageFilter
        switch filter {
        case .launchable: runtimeFilter = .launchable
        case .userInstalled: runtimeFilter = .userInstalled
        case .all: runtimeFilter = .all
        }
        return try await client.listPackages(runtimeFilter).map { summary in
            guard let packageID = PackageID(rawValue: summary.packageID.rawValue) else {
                throw StoreAgentSupervisorFailure.invalidRuntimePackageID(summary.packageID.rawValue)
            }
            return StorePackageSummary(
                packageID: packageID,
                displayName: summary.displayName,
                versionCode: summary.versionCode,
                launchable: summary.launchable,
                userInstalled: summary.userInstalled
            )
        }
    }

    /// Lists full metadata for packages installed for the current Android user.
    public func listManagedPackages() async throws -> [StorePackageInfo] {
        try await client.listManagedPackages().map(Self.packageInfo)
    }

    /// Closes the event adapter and both Store Agent connections.
    public func close() async {
        eventAdapterTask.cancel()
        await client.close()
    }

    private static func runtimePackageID(_ package: PackageID) throws -> RuntimePackageID {
        guard let runtimeID = RuntimePackageID(rawValue: package.rawValue) else {
            throw StoreAgentSupervisorFailure.invalidRuntimePackageID(package.rawValue)
        }
        return runtimeID
    }

    private static func runtimeArtifact(_ artifact: StoreArtifactSpec) -> RuntimeStoreArtifactSpec {
        RuntimeStoreArtifactSpec(
            name: artifact.name,
            size: artifact.size,
            sha256: artifact.sha256.hexValue
        )
    }

    private static func runtimeInstallRequest(_ request: StoreInstallRequest) throws -> RuntimeStoreInstallRequest {
        let mode: RuntimeStoreInstallRequest.Mode
        switch request.mode {
        case .installNew: mode = .installNew
        case .update: mode = .update
        case .reinstall: mode = .reinstall
        }
        return RuntimeStoreInstallRequest(
            packageID: try runtimePackageID(request.packageID),
            versionCode: request.versionCode,
            allowDowngrade: request.allowDowngrade,
            mode: mode,
            expectedSignerDigests: request.expectedSignerDigests.map(\.hexValue),
            artifacts: request.artifacts.map(runtimeArtifact)
        )
    }

    private static func archiveInfo(_ archive: RuntimeStoreArchiveInfo) throws -> StoreArchiveInfo {
        StoreArchiveInfo(
            packageID: try storePackageID(archive.packageID),
            versionCode: archive.versionCode,
            versionName: archive.versionName,
            splitNames: archive.splitNames,
            nativeABIs: archive.nativeABIs,
            minSDK: archive.minSDK,
            targetSDK: archive.targetSDK,
            signingDigests: try storeDigests(archive.signingDigests, package: archive.packageID.rawValue),
            signingSchemeVersion: archive.signingSchemeVersion
        )
    }

    private static func packageInfo(_ info: RuntimeStorePackageInfo) throws -> StorePackageInfo {
        StorePackageInfo(
            packageID: try storePackageID(info.packageID),
            displayName: info.displayName,
            versionCode: info.versionCode,
            versionName: info.versionName,
            enabled: info.enabled,
            launchableComponent: info.launchableComponent,
            installerPackage: try info.installerPackage.map(storePackageID),
            firstInstallTime: info.firstInstallTime,
            lastUpdateTime: info.lastUpdateTime,
            targetSDK: info.targetSDK,
            minSDK: info.minSDK,
            signingDigests: try storeDigests(info.signingDigests, package: info.packageID.rawValue),
            signingLineage: try storeDigests(info.signingLineage, package: info.packageID.rawValue),
            signingSchemeVersion: info.signingSchemeVersion,
            updateOwner: try info.updateOwner.map(storePackageID),
            initiatingPackage: try info.initiatingPackage.map(storePackageID),
            splitNames: info.splitNames,
            nativeABIs: info.nativeABIs,
            suspended: info.suspended,
            requestedPermissionsCount: info.requestedPermissionsCount
        )
    }

    private static func storePackageID(_ package: RuntimePackageID) throws -> PackageID {
        guard let packageID = PackageID(rawValue: package.rawValue) else {
            throw StoreAgentSupervisorFailure.invalidRuntimePackageID(package.rawValue)
        }
        return packageID
    }

    private static func storeDigests(_ values: [String], package: String) throws -> [SHA256Digest] {
        try values.map { hex in
            guard let digest = SHA256Digest(hex: hex) else {
                throw StoreAgentSupervisorFailure.invalidSigningDigest(package: package)
            }
            return digest
        }
    }

    private static func packageEventKind(_ kind: RuntimeStorePackageEvent.Kind) -> StorePackageEvent.Kind {
        switch kind {
        case .added: .added
        case .replaced: .replaced
        case .removed: .removed
        case .changed: .changed
        }
    }
}

/// Compatibility name for errors raised by the RuntimeCore Store Agent client.
/// Failures reported by RuntimeCore's Store Agent client.
public typealias StoreAgentSupervisorFailure = RuntimeStoreAgentFailure
