import APKStoreCore
import DiagnosticsCore
import Foundation
import RuntimeAPI
import UpdateCore

/// The daemon's update service (update-system.md). It owns the `Updates/`
/// state and history stores, the provider `UpdateCoordinator`, and a host-side
/// `PackageStore` for records and settings. It never starts Android; update
/// work only reads provider metadata and stages artifacts on disk.
public actor EmbeddedUpdateService {
    private let paths: APKRunPaths
    private let fileManager = FileManager.default
    private let store: PackageStore
    private let stateStore: UpdateStateStore
    private let coordinator: UpdateCoordinator
    private let credentials = KeychainProviderCredentials()
    private var isOpen = false

    /// Creates an update service rooted at APKRun's data directory.
    public init(
        paths: APKRunPaths = APKRunPaths(allowingHomeOverride: true),
        developerModeEnabled: @escaping @Sendable () -> Bool = { false },
        checkIntervalHours: @escaping @Sendable () -> Int = { 6 },
        guestFacts: @escaping @Sendable () -> GuestFacts = { GuestFacts() }
    ) {
        self.paths = paths
        store = PackageStore(
            packagesDirectory: paths.packagesDirectory,
            inspector: { apk in try await APKInspector().inspect(apk) },
            fileManager: .default
        )
        stateStore = UpdateStateStore(directory: paths.updatesDirectory)
        coordinator = UpdateCoordinator(
            store: store,
            stateStore: stateStore,
            developerModeEnabled: developerModeEnabled,
            checkIntervalHours: checkIntervalHours(),
            guestFacts: guestFacts
        )
    }

    /// Opens the package store; safe to call on every request.
    public func open() async throws {
        guard !isOpen else { return }
        try await store.open()
        isOpen = true
    }

    /// The provider context for a check (update-system.md §4.1).
    public func providerContext(userInitiated: Bool) -> ProviderContext {
        ProviderContext(
            http: URLSessionUpdateHTTPClient(),
            cache: FileProviderCache(root: paths.updatesDirectory.appendingPathComponent("cache", isDirectory: true)),
            credentials: credentials,
            userInitiated: userInitiated
        )
    }

    /// Runs a check for every package ID (update-system.md §5). The outcome is
    /// per package; a failing package never fails the batch.
    public func checkPackages(
        _ packageIDs: [PackageID],
        context: ProviderContext
    ) async -> [UpdateCheckResult] {
        var results: [UpdateCheckResult] = []
        for packageID in packageIDs {
            let outcome = await coordinator.check(
                packageID, trigger: .userInitiated, context: context)
            guard let wireID = RuntimePackageID(rawValue: packageID.rawValue) else { continue }
            switch outcome {
            case .upToDate:
                results.append(UpdateCheckResult(packageID: wireID, outcome: .upToDate))
            case .available(let candidate):
                results.append(
                    UpdateCheckResult(
                        packageID: wireID, outcome: .available(Self.wireCandidate(candidate))))
            case .failed(let failure):
                results.append(
                    UpdateCheckResult(
                        packageID: wireID,
                        outcome: .failed(Self.catalogError(for: failure))))
            }
        }
        return results
    }

    /// Every managed package whose record authority is `apkrun`.
    public func managedPackageIDs() async throws -> [PackageRecord] {
        try await store.listManagedPackages()
    }

    /// `listUpdates`: the per-package status rows of runtime-api.md §9.2.
    public func listUpdates() async throws -> [PackageUpdateStatus] {
        let records = try await store.listManagedPackages()
        var statuses: [PackageUpdateStatus] = []
        for record in records {
            statuses.append(try await status(for: record))
        }
        return statuses
    }

    /// One package's status.
    public func status(for record: PackageRecord) async throws -> PackageUpdateStatus {
        let state = await stateStore.state(for: record.packageId)
        let phase = await coordinator.phase(for: record.packageId)
        let settings = try? await store.packageSettings(for: record.packageId)
        guard let wireID = RuntimePackageID(rawValue: record.packageId.rawValue) else {
            throw UpdateFailure.validation(detail: "stored package id is not a wire id")
        }
        return PackageUpdateStatus(
            packageID: wireID,
            choice: Self.choice(authority: record.updateAuthority, mode: settings?.updateMode),
            authority: record.updateAuthority.rawValue,
            provider: record.updateProvider.map { Self.providerSummary($0, credentials: credentials) },
            phase: phase.map(Self.wirePhase),
            candidate: state?.candidate.map {
                WireUpdateCandidate(
                    versionCode: $0.versionCode,
                    versionName: $0.versionName,
                    provider: $0.provider.rawValue)
            },
            lastCheckAt: state?.lastCheckAt,
            nextCheckAt: state?.nextCheckAt,
            consecutiveFailures: state?.consecutiveFailures ?? 0,
            waiting: []
        )
    }

    /// `updateHistory` (update-system.md §10.2).
    public func updateHistory(
        packageID: PackageID?,
        limit: Int
    ) async throws -> [RuntimeAPI.UpdateHistoryEntry] {
        try await stateStore.history(packageID: packageID, limit: limit).map {
            guard let wireID = RuntimePackageID(rawValue: $0.packageID.rawValue) else {
                throw UpdateFailure.validation(detail: "stored package id is not a wire id")
            }
            return RuntimeAPI.UpdateHistoryEntry(
                time: $0.time,
                packageID: wireID,
                from: $0.from,
                to: $0.to,
                provider: $0.provider?.rawValue,
                trigger: $0.trigger.rawValue,
                outcome: $0.outcome,
                failure: nil,
                phaseDurationsMs: $0.phaseDurationsMs
            )
        }
    }

    /// `setUpdatePolicy` (update-system.md §2.3, cli.md §4.3): the settings
    /// `update.mode` is written before `metadata.json` so a crash never turns
    /// automatic updates on without the record change.
    public func setUpdatePolicy(
        packageID: PackageID,
        policy: UpdatePolicy
    ) async throws -> PackageRecord {
        guard
            let record = try await store.listManagedPackages()
                .first(where: { $0.packageId == packageID })
        else {
            throw PackageStoreFailure.packageNotFound
        }
        if record.updateAuthority == .googlePlay || record.updateAuthority == .external {
            throw UpdateFailure.authorityDoesNotAllowUpdates
        }

        let provider: UpdateProviderRef?
        let removeProvider: Bool
        switch policy.provider {
        case .keep:
            provider = nil
            removeProvider = false
        case .remove:
            provider = nil
            removeProvider = true
        case .set(let spec):
            provider = try Self.providerRef(for: spec)
            removeProvider = false
        }

        let effectiveProvider = removeProvider ? nil : (provider ?? record.updateProvider)
        let authority: UpdateAuthority
        switch (policy.choice, policy.provider) {
        case (.manual, _):
            authority = .manual
        case (_, .remove):
            authority = .manual
        case (.automatic, _), (.notifyOnly, _):
            guard effectiveProvider != nil else {
                throw UpdateFailure.providerNotConfigured
            }
            authority = .apkrun
        }

        try await store.setUpdateMode(for: packageID, mode: Self.settingsMode(for: policy.choice))
        try await store.setUpdatePolicy(
            for: packageID, authority: authority,
            provider: provider, removeProvider: removeProvider)
        guard
            let updated = try await store.listManagedPackages()
                .first(where: { $0.packageId == packageID })
        else {
            throw PackageStoreFailure.packageNotFound
        }
        return updated
    }

    /// The `settings.json` `update.mode` a wire choice maps to.
    private static func settingsMode(for choice: UpdateChoice) -> String {
        switch choice {
        case .automatic: "automatic"
        case .notifyOnly: "notifyOnly"
        case .manual: "manual"
        }
    }

    /// A wire provider spec parsed into a stored provider reference
    /// (runtime-api.md §9.2). #38 only ships `local`; the other kinds land
    /// with their providers (#51, #52, #53).
    static func providerRef(for spec: ProviderSpec) throws -> UpdateProviderRef {
        guard let colon = spec.spec.firstIndex(of: ":") else {
            throw UpdateFailure.providerMetadataInvalid(detail: "provider spec has no scheme")
        }
        let scheme = spec.spec[..<colon]
        let rest = spec.spec[spec.spec.index(after: colon)...]
        switch scheme {
        case "local":
            guard let bookmark = spec.bookmark else {
                throw UpdateFailure.providerMetadataInvalid(
                    detail: "local provider needs a security-scoped bookmark")
            }
            return UpdateProviderRef(
                type: .local,
                configuration: .local(
                    path: String(rest),
                    bookmark: bookmark.base64EncodedString()))
        case "direct", "fdroid", "github":
            // Direct (#51), F-Droid (#52), GitHub (#53).
            throw UpdateFailure.providerNotConfigured
        default:
            throw UpdateFailure.providerMetadataInvalid(
                detail: "unknown provider scheme \"\(scheme)\"")
        }
    }

    /// The wire `UpdateChoice` a record and its settings mode describe. Only
    /// `apkrun` and `manual` authorities carry a choice (update-system.md §2.2).
    static func choice(authority: UpdateAuthority, mode: String?) -> UpdateChoice? {
        switch authority {
        case .googlePlay, .external:
            return nil
        case .manual:
            return .manual
        case .apkrun:
            switch mode {
            case "notifyOnly": return .notifyOnly
            case "manual": return .manual
            default: return .automatic
            }
        }
    }

    /// The `ProviderSummary` a stored reference produces; never carries a token.
    static func providerSummary(
        _ ref: UpdateProviderRef,
        credentials: any ProviderCredentials
    ) -> ProviderSummary {
        switch ref.configuration {
        case .local(let path, _):
            return ProviderSummary(type: ref.type.rawValue, label: path)
        case .direct(let url):
            return ProviderSummary(type: ref.type.rawValue, label: url)
        case .fdroid(let repository, _):
            return ProviderSummary(type: ref.type.rawValue, label: repository)
        case .github(let repository, _, let channel):
            return ProviderSummary(
                type: ref.type.rawValue,
                label: repository,
                channel: channel.rawValue,
                hasToken: credentials.token(for: "io.apkrun.provider.github") != nil)
        }
    }

    /// The wire phase an internal phase maps to; unknown phases stay unknown.
    static func wirePhase(_ phase: UpdatePhase) -> WireUpdatePhase {
        switch phase {
        case .checking: .checking
        case .available(let candidate): .available(wireCandidate(candidate))
        case .downloading(let progress): .downloading(progress: progress)
        case .validating: .validating
        case .staged: .staged
        case .installing: .installing
        case .healthChecking: .healthChecking
        case .rollingBack(let reason):
            .rollingBack(reason: String(describing: reason))
        case .completed(let outcome): .completed(wireOutcome(outcome))
        }
    }

    /// The wire outcome of a completed run (state-machines.md §6).
    static func wireOutcome(_ outcome: UpdateOutcome) -> WireUpdateOutcome {
        switch outcome {
        case .updated(let from, let to):
            .updated(from: from, to: to)
        case .rolledBack(let reason):
            .rolledBack(reason: String(describing: reason))
        case .keptAfterFailedHealthCheck(let reason):
            .keptAfterFailedHealthCheck(reason: String(describing: reason))
        case .skipped(let reason):
            .skipped(reason: reason.name, error: nil)  // SkipReason.name is UpdateCore-internal
        }
    }

    /// The wire candidate of a provider candidate (runtime-api.md §9.2).
    static func wireCandidate(_ candidate: UpdateCandidate) -> WireUpdateCandidate {
        WireUpdateCandidate(
            versionCode: candidate.declaredVersionCode,
            versionName: candidate.declaredVersionName,
            provider: candidate.provider.type.rawValue,
            releaseNotes: candidate.releaseNotes,
            publishedAt: candidate.publishedAt,
            downloadBytes: candidate.artifacts.reduce(into: Int64(0)) { total, artifact in
                if let size = artifact.size { total += size }
            })
    }

    /// A catalog error for `UpdateCheckResult.failed` (runtime-api.md §9.2);
    /// the message comes from the catalog.
    static func catalogError(for error: any Error) -> WireError {
        let wireError = Self.wireError(for: error)
        return WireError(domain: wireError.domain, code: wireError.code)
    }

    /// A wire error of an update or store failure (runtime-api.md §9.3).
    static func wireError(for error: any Error) -> RuntimeWireError {
        if let wireError = error as? RuntimeWireError {
            return wireError
        }
        if let failure = error as? UpdateFailure {
            return RuntimeWireError(
                domain: "update",
                code: failure.errorCode,
                message: Self.message(for: failure))
        }
        return EmbeddedPackageService.wireError(for: error)
    }

    /// A user-facing message per failure code.
    private static func message(for failure: UpdateFailure) -> String {
        switch failure {
        case .providerUnreachable(let reason):
            "The update provider cannot be reached: \(reason)."
        case .providerHTTPStatus(let status):
            "The update provider answered HTTP \(status)."
        case .providerRateLimited:
            "The update provider is rate-limiting requests."
        case .providerMetadataInvalid(let detail):
            "The update provider metadata is invalid: \(detail)."
        case .providerSignatureInvalid(let detail):
            "The update signature check failed: \(detail)."
        case .noCompatibleArtifact(let reason):
            "The update provider has no compatible artifact (\(reason.rawValue))."
        case .ambiguousAsset(let detail):
            "The update provider offers more than one matching asset: \(detail)."
        case .providerNotConfigured:
            "No update provider is configured for this package."
        case .downloadFailed(let reason):
            "The update download failed: \(reason)."
        case .hashMismatch(let artifact):
            "The downloaded artifact \(artifact) does not match its declared hash."
        case .tooLarge(let bytes, let limit):
            "The update is \(bytes) bytes, above the \(limit)-byte limit."
        case .validation(let detail):
            "The update did not pass validation: \(detail)."
        case .authorityDoesNotAllowUpdates:
            "This package's update authority does not allow APKRun updates."
        case .installFailed(let detail):
            "The update install failed: \(detail)."
        case .healthCheckFailed(let detail):
            "The updated app failed its health check: \(detail)."
        case .rollbackFailed(let detail):
            "The update rollback failed: \(detail)."
        case .cancelled:
            "The update was cancelled."
        }
    }
}

/// `GET` through `URLSession` (update-system.md §4.1).
public struct URLSessionUpdateHTTPClient: UpdateHTTPClient {
    /// Creates a client.
    public init() {}

    /// Performs a GET request.
    public func get(_ url: URL, headers: [String: String]) async throws(UpdateFailure) -> HTTPResponse {
        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (body, response): (Data, URLResponse)
        do {
            (body, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UpdateFailure.providerUnreachable(reason: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UpdateFailure.providerUnreachable(reason: "not an HTTP response")
        }
        return HTTPResponse(
            status: http.statusCode,
            body: body,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
    }
}

/// The on-disk provider cache under `Updates/cache/<key>/` (§4.1).
public struct FileProviderCache: ProviderCache {
    /// The cache root.
    public let root: URL

    /// Creates a cache rooted at `root`.
    public init(root: URL) {
        self.root = root
    }

    /// Returns the cache directory for `key`, creating it when needed.
    public func directory(forKey key: String) throws -> URL {
        let directory = root.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// Keychain storage for provider tokens (update-system.md §4.6). Tokens are
/// generic-password items with `kSecAttrService` naming the provider service.
public struct KeychainProviderCredentials: ProviderCredentials {
    /// Creates the Keychain accessor.
    public init() {}

    /// Returns the stored token for a service name, when one exists.
    public func token(for service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "token",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Stores, replaces (`""` deletes), or keeps (`nil`) a token.
    public func setToken(_ token: String?, for service: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "token",
        ]
        guard let token else { return }
        if token.isEmpty {
            SecItemDelete(base as CFDictionary)
            return
        }
        let data = Data(token.utf8)
        if self.token(for: service) != nil {
            SecItemUpdate(
                base as CFDictionary,
                [kSecValueData as String: data] as CFDictionary)
        } else {
            var item = base
            item[kSecValueData as String] = data
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

extension RuntimeHost {
    /// The lazily created update service (update-system.md).
    func updateServiceInstance() -> EmbeddedUpdateService {
        if let updateService { return updateService }
        let service = EmbeddedUpdateService(
            paths: paths,
            developerModeEnabled: { [weak self] in
                guard let self else { return false }
                return GlobalSettings.load(from: self.paths.settingsFile).developerEnabled
            },
            checkIntervalHours: {
                Self.updatesCheckIntervalHours()
            }
        )
        updateService = service
        return service
    }

    /// `updates.checkIntervalHours` (configuration.md §2.7), default 6.
    static func updatesCheckIntervalHours() -> Int {
        guard let data = try? Data(contentsOf: APKRunPaths(allowingHomeOverride: true).settingsFile),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let updates = object["updates"] as? [String: Any],
            let hours = updates["checkIntervalHours"] as? Int,
            hours > 0
        else {
            return 6
        }
        return hours
    }

    /// `checkForUpdates` (runtime-api.md §9.1): a long operation that checks
    /// each selected package and reports per-package results.
    public func checkForUpdates(
        packages requestedIDs: [RuntimePackageID]?,
        checkOnly: Bool,
        operationID: RuntimeAPI.OperationID,
        requestPayload: Data,
        clientKind: RuntimeClientKind
    ) async throws(RuntimeWireError) -> (OperationHandle, [UpdateCheckResult]) {
        let service = updateServiceInstance()
        do {
            try await service.open()
        } catch {
            throw EmbeddedPackageService.wireError(for: error)
        }

        let records: [PackageRecord]
        do {
            records = try await service.managedPackageIDs()
        } catch {
            throw EmbeddedUpdateService.wireError(for: error)
        }
        var selected: [PackageID] = []
        var preResults: [UpdateCheckResult] = []
        if let requestedIDs {
            for wireID in requestedIDs {
                guard let packageID = PackageID(rawValue: wireID.rawValue),
                    records.contains(where: { $0.packageId == packageID })
                else {
                    preResults.append(
                        UpdateCheckResult(
                            packageID: wireID,
                            outcome: .failed(
                                WireError(domain: "store", code: "store.packageNotFound"))))
                    continue
                }
                selected.append(packageID)
            }
        } else {
            selected = records.filter { $0.updateAuthority == .apkrun }.map(\.packageId)
        }

        let handle = OperationHandle(operationID: operationID, kind: .updateCheck)
        let snapshot = OperationSnapshot(
            operationID: operationID,
            kind: .updateCheck,
            packageID: selected.first.flatMap { RuntimePackageID(rawValue: $0.rawValue) },
            requestFingerprint: RuntimeOperationRequestFingerprint.make(from: requestPayload),
            clientKind: clientKind,
            startedAt: Date(),
            progress: OperationProgress(stage: "checking", message: "Checking for updates…")
        )
        trackedOperations[operationID] = RuntimeTrackedOperation(
            handle: handle,
            requestPayload: requestPayload,
            snapshot: snapshot,
            isCancellable: false,
            task: nil
        )
        eventHub.publishOperationEvent(.started(snapshot), operationID: operationID)

        let results = await service.checkPackages(
            selected, context: service.providerContext(userInitiated: true))
        let all = preResults + results
        let failures = all.filter { result in
            if case .failed = result.outcome { return true }
            return false
        }
        if failures.count == all.count, !all.isEmpty {
            // Every check failed: the operation still completed; per-package
            // failures are reported in results (cli.md §4.3).
        }
        finishOperation(operationID, result: .succeeded(.none))
        return (handle, all)
    }

    /// `listUpdates` (runtime-api.md §9.1).
    public func listUpdates() async throws(RuntimeWireError) -> [PackageUpdateStatus] {
        let service = updateServiceInstance()
        do {
            try await service.open()
            return try await service.listUpdates()
        } catch {
            throw EmbeddedUpdateService.wireError(for: error)
        }
    }

    /// `updateHistory` (runtime-api.md §9.1).
    public func updateHistory(
        packageID wireID: RuntimePackageID?,
        limit: Int
    ) async throws(RuntimeWireError) -> [RuntimeAPI.UpdateHistoryEntry] {
        let service = updateServiceInstance()
        do {
            try await service.open()
            let packageID = wireID.flatMap { PackageID(rawValue: $0.rawValue) }
            if let wireID, packageID == nil {
                throw RuntimeWireError.store(
                    "packageNotFound",
                    message: "The package is not managed by APKRun.",
                    remediation: "Use `apkrun list` to see managed packages.")
            }
            return try await service.updateHistory(packageID: packageID, limit: limit)
        } catch let wireError as RuntimeWireError {
            throw wireError
        } catch {
            throw EmbeddedUpdateService.wireError(for: error)
        }
    }

    /// `setUpdatePolicy` (runtime-api.md §9.1, cli.md §4.3).
    public func setUpdatePolicy(
        packageID wireID: RuntimePackageID,
        policy: UpdatePolicy
    ) async throws(RuntimeWireError) -> PackageUpdateStatus {
        let service = updateServiceInstance()
        do {
            try await service.open()
        } catch {
            throw EmbeddedPackageService.wireError(for: error)
        }
        guard let packageID = PackageID(rawValue: wireID.rawValue) else {
            throw .store(
                "packageNotFound",
                message: "The package is not managed by APKRun.",
                remediation: "Use `apkrun list` to see managed packages.")
        }
        do {
            let record = try await service.setUpdatePolicy(packageID: packageID, policy: policy)
            return try await service.status(for: record)
        } catch {
            throw EmbeddedUpdateService.wireError(for: error)
        }
    }
}
