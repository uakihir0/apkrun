import APKStoreCore
import Darwin
import DiagnosticsCore
import Foundation
import RuntimeAPI
import RuntimeCore
import UpdateCore
import WrapperCore

typealias PackageMutationBoundary = @Sendable () async throws(RuntimeWireError) -> Void

struct RuntimePackageInstallResult: Sendable {
    let summary: RuntimePackageSummary
    let change: PackageChange
    let cleanupDeferred: Bool

    init(
        summary: RuntimePackageSummary,
        previousVersionCode: RuntimeVersionCode?,
        restoredRetainedData: Bool,
        cleanupDeferred: Bool = false
    ) {
        self.summary = summary
        self.cleanupDeferred = cleanupDeferred
        if let previousVersionCode, !restoredRetainedData {
            change = .updated(summary, from: previousVersionCode)
        } else {
            change = .installed(summary)
        }
    }
}

struct RuntimePackageUninstallResult: Sendable {
    let change: PackageChange?
    let cleanupDeferred: Bool
}

/// The embedded RuntimeAPI implementation for APK imports and package management.
///
/// Import previews are host-only and work before Android starts. Guest-dependent operations
/// use the RuntimeHost store adapter attached by `DevBoot` after Android becomes ready.
public actor EmbeddedPackageService: RuntimeService {
    private let paths: APKRunPaths
    private let fileManager = FileManager.default
    private let inspector: PackageStore.Inspector
    private let runtimeAccess: AttachedStoreRuntimeAccess
    /// Shared with `EmbeddedUpdateService` so a single store owns ticket cleanup.
    public let store: PackageStore
    private var sessionService: any RuntimeSessionService
    private let hostFreeSpace: @Sendable (URL) -> Int64

    private var isOpen = false
    private var openTask: Task<Void, Error>?
    private var runtimeAttached = false
    private var importPreviews: [UUID: RuntimeImportPreview] = [:]
    private var packageMutationsInProgress = Set<String>()
    private var packageStoreMutationsInProgress = Set<String>()
    private var packageLaunchesInProgress: [String: Int] = [:]

    /// Creates an embedded package service rooted at APKRun's persistent package directory.
    public init(
        paths: APKRunPaths = APKRunPaths(allowingHomeOverride: true),
        inspector: @escaping PackageStore.Inspector = { apk in try await APKInspector().inspect(apk) },
        hostFreeSpace: (@Sendable (URL) -> Int64)? = nil,
        sessionService: (any RuntimeSessionService)? = nil,
        importVerifier: @escaping PackageStore.ImportVerifier = PackageStore.strictImportVerifier,
        runtimeAccess: (any StoreRuntimeAccess)? = nil
    ) {
        self.paths = paths
        self.inspector = inspector
        self.hostFreeSpace = hostFreeSpace ?? Self.availableHostSpace
        self.sessionService = sessionService ?? EmbeddedRuntimeService()
        self.runtimeAttached = runtimeAccess != nil
        let runtimeAccess = AttachedStoreRuntimeAccess(initial: runtimeAccess)
        self.runtimeAccess = runtimeAccess
        store = PackageStore(
            packagesDirectory: paths.packagesDirectory,
            runtimeAccess: runtimeAccess,
            inspector: inspector,
            fileManager: .default,
            importVerifier: importVerifier
        )
    }

    /// Opens the package journal and loads managed package records without starting Android.
    public func open() async throws(RuntimeWireError) {
        do {
            try await ensureOpen()
        } catch {
            throw Self.wireError(for: error)
        }
    }

    /// Attaches a ready development runtime and recovers guest-dependent package transactions.
    ///
    /// ADB is resolved here so CLI clients do not need to import RuntimeCore or locate tools.
    public func attachRuntime(
        context: DevelopmentRuntimeContext,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        startRuntimeIfNeeded: Bool = true,
        recoverPendingTransactions: Bool = true,
        refreshInventoryAfterAttach: Bool = true
    ) async throws(RuntimeWireError) {
        do {
            try await ensureOpen()
            let adbExecutable = try AdbClient.resolveExecutable(environment: environment)
            let access = DevelopmentStoreRuntimeAccess(
                supervisor: context.supervisor,
                adbExecutable: adbExecutable,
                instanceStore: context.instanceStore,
                image: context.image,
                logSink: context.diagnostics.logSink,
                startRuntimeIfNeeded: startRuntimeIfNeeded
            )
            guard let guestAgent = await context.supervisor.developmentGuestAgent else {
                throw DevelopmentStoreRuntimeAccessFailure.guestAgentUnavailable
            }
            if let windowSessionService = await context.makeSessionService() {
                sessionService = windowSessionService
            } else if let embeddedSessionService = sessionService as? EmbeddedRuntimeService {
                await embeddedSessionService.attachGuestAgent(guestAgent)
            }
            await runtimeAccess.attach(access)
            runtimeAttached = true
            if recoverPendingTransactions {
                try await store.recoverPendingTransactions()
            }
            if refreshInventoryAfterAttach {
                try? await refreshAndroidInventory()
            }
        } catch {
            throw Self.wireError(for: error)
        }
    }

    /// Detaches the live guest channel while preserving cached package inventory.
    public func detachRuntime() async {
        await runtimeAccess.detach()
        runtimeAttached = false
    }

    /// Reuses the daemon's session owner when package operations run over XPC.
    /// Routes store-rendered icon changes to the caller's sink (package-store.md §10.2).
    func setIconChangeHandler(_ handler: @escaping @Sendable (PackageID) async -> Void) async {
        await store.setIconChangeHandler { packageID in await handler(packageID) }
    }

    /// The store-rendered icon set for a package: the manifest and the layer
    /// PNGs under `Packages/<id>/icon/` (wrapper.md §8.2 `rendered`).
    public func renderedIconLayers(for packageID: RuntimePackageID) async
        -> (manifest: PackageIconManifest, layers: [StoreIconLayer])?
    {
        guard let storeID = PackageID(rawValue: packageID.rawValue),
            let manifest = await store.iconManifest(for: storeID),
            let directory = await store.iconDirectory(for: storeID)
        else { return nil }
        var layers: [StoreIconLayer] = []
        for role in StoreIconRole.allCases {
            guard let png = try? Data(contentsOf: directory.appendingPathComponent("\(role.rawValue).png"))
            else { continue }
            layers.append(StoreIconLayer(role: role, png: png))
        }
        guard !layers.isEmpty else { return nil }
        return (manifest, layers)
    }

    func setSessionService(_ sessionService: any RuntimeSessionService) {
        self.sessionService = sessionService
    }

    /// Refreshes managed package labels after the guest applies a new locale.
    /// Wrapper registry entries keep the same label so validation flags the
    /// wrapper for refresh instead of silently keeping the old name.
    func refreshLocaleDependentPackageLabels(registry: WrapperRegistry) async throws(RuntimeWireError) {
        do {
            try await ensureOpen()
            _ = try await refreshAndroidInventory()
            // Registry sync must catch every drift, not just names Android
            // reported differently this refresh — an APK update can write the
            // new label straight into the record, which never shows as changed.
            for record in try await store.listManagedPackages() {
                let runtimeID = try Self.runtimePackageID(record.packageId)
                if let entry = await registry.entry(packageID: runtimeID),
                    entry.displayName != record.displayName
                {
                    try await registry.setDisplayName(
                        bundleID: entry.bundleId, displayName: record.displayName)
                }
            }
        } catch {
            throw Self.wireError(for: error)
        }
    }

    /// Launches an installed package in the embedded runtime through the Guest Agent.
    public func launch(_ request: RuntimeLaunchRequest) async throws(RuntimeWireError) -> RuntimeLaunchResult {
        let packageID = request.packageID.rawValue
        try beginPackageLaunch(packageID)
        defer { finishPackageLaunch(packageID) }
        return try await sessionService.launch(request)
    }

    /// Stops the package's task, force-stopping through Android when no session exists.
    public func terminate(_ request: RuntimeTerminateRequest) async throws(RuntimeWireError) -> RuntimeTerminateResult {
        try await sessionService.terminate(request)
    }

    /// Copies and inspects the indexed APK file handles without starting Android.
    public func importPackage(
        _ request: RuntimeImportPackageRequest,
        files: [FileHandle]
    ) async throws(RuntimeWireError) -> RuntimeImportPreview {
        do {
            try await ensureOpen()
            let staged = try stage(request.files, from: files)
            defer { try? fileManager.removeItem(at: staged.directory) }

            let preview = try await store.importPackage(
                files: staged.files,
                origin: Self.storeImportOrigin(request.origin)
            )
            let relation = try await relation(for: preview)
            var result = try Self.runtimePreview(from: preview, relation: relation)
            result.suggestedProvider = fdroidProviderSuggestion(for: result)
            importPreviews[preview.ticket] = result
            return result
        } catch {
            throw Self.wireError(for: error)
        }
    }

    /// The `importBootstrap` op of an approved portable wrapper's launcher
    /// (wrapper-json.md §3.4). `entry` passed B1 in the caller; B2–B8 run here
    /// in order and the first failure decides.
    public func importBootstrap(
        entry: WrapperRegistryEntry,
        wrapperDocument: WrapperDocument,
        bootstrapJSON: Data,
        files: [FileHandle]
    ) async throws(RuntimeWireError) -> RuntimePackageSummary {
        do {
            try await ensureOpen()
            guard let packageID = PackageID(rawValue: entry.packageId) else {
                throw RuntimeHost.wrapperWireError(for: .bootstrapInvalid(.malformed))
            }
            // B2: only a first install or a retained-data reinstall may import.
            let isFirstRecord = try await firstBootstrapRecord(for: packageID)
            // B3: the document must fit 64 KiB, parse, carry formatVersion 1,
            // and satisfy §3.5.
            guard bootstrapJSON.count <= BootstrapDocument.maximumDocumentBytes,
                let document = try? BootstrapDocumentCodec.decode(bootstrapJSON),
                (try? BootstrapDocumentCodec.validate(document)) != nil
            else {
                throw RuntimeHost.wrapperWireError(for: .bootstrapInvalid(.malformed))
            }
            // A contradictory `updates` block is a malformed payload, checked
            // before anything installs (wrapper-json.md §2.4).
            if wrapperDocument.updates?.authority == .apkrun,
                wrapperDocument.updates?.provider == nil
            {
                throw RuntimeHost.wrapperWireError(for: .bootstrapInvalid(.malformed))
            }
            // B4: the bootstrap must name the wrapper's package.
            guard document.packageId == entry.packageId else {
                throw RuntimeHost.wrapperWireError(for: .bootstrapInvalid(.packageMismatch))
            }
            // B5: one file handle per `files` item.
            guard files.count == document.files.count else {
                throw RuntimeHost.wrapperWireError(for: .bootstrapInvalid(.malformed))
            }
            let sources = document.files.enumerated().map {
                RuntimeImportSourceFile(fileIndex: $0.offset, name: $0.element.name)
            }
            let staged = try stage(sources, from: files)
            defer { try? fileManager.removeItem(at: staged.directory) }
            let preview = try await store.importPackage(
                files: staged.files, bootstrapBundleID: entry.bundleId)
            do {
                // B5–B7 compare the verified set — computed from the copied
                // bytes — against the document; the document is never trusted.
                let set = preview.artifactSet
                guard set.files.count == document.files.count else {
                    throw WrapperFailure.bootstrapInvalid(.malformed)
                }
                for (artifact, declared) in zip(set.files, document.files) {
                    guard artifact.name == declared.name else {
                        throw WrapperFailure.bootstrapInvalid(.malformed)
                    }
                    guard artifact.size == declared.size,
                        declared.sha256 == "sha256:" + artifact.sha256.hexValue
                    else {
                        throw WrapperFailure.bootstrapInvalid(.hashMismatch)
                    }
                }
                // B6: the set digest of the copied files equals `setDigest`.
                guard "sha256:" + set.setDigest.hexValue == document.setDigest else {
                    throw WrapperFailure.bootstrapInvalid(.hashMismatch)
                }
                // B7: the inspected APKs carry the declared identity, and the
                // verified signer set equals `signers`.
                guard set.packageID.rawValue == document.packageId,
                    set.versionCode == document.versionCode,
                    document.signers
                        == set.signerDigests.map { "sha256:" + $0.hexValue }.sorted()
                else {
                    throw WrapperFailure.bootstrapInvalid(.packageMismatch)
                }
            } catch let failure as WrapperFailure {
                try? await store.discardImport(ticket: preview.ticket)
                throw RuntimeHost.wrapperWireError(for: failure)
            } catch {
                try? await store.discardImport(ticket: preview.ticket)
                throw error
            }
            // B8: the ticket path runs the store's own install checks (for
            // example the downgrade refusal when Android kept newer data).
            guard let ticket = RuntimeImportTicket(rawValue: preview.ticket.uuidString.lowercased()) else {
                throw Self.wireError(for: PackageStoreFailure.importTicketNotFound)
            }
            let result = try await installImportedWithChange(
                RuntimeInstallImportedRequest(ticket: ticket, options: RuntimeInstallOptions()))
            // wrapper.json `updates` supplies the initial authority, mode, and
            // provider (wrapper-json.md §3.3).
            if let updates = wrapperDocument.updates {
                let choice: UpdateChoice = updates.mode == .notifyOnly ? .notifyOnly : .automatic
                try await store.setUpdateMode(
                    for: packageID, mode: UpdatePolicyRules.settingsMode(for: choice))
                try await store.setUpdatePolicy(
                    for: packageID,
                    authority: updates.authority == .apkrun ? .apkrun : .manual,
                    provider: updates.provider.flatMap(Self.providerRef(for:)),
                    requireProvider: true)
            }
            // `window` and `integration` are first-record settings (§3.3).
            if isFirstRecord {
                var patch: [String: String?] = [:]
                if let window = wrapperDocument.window {
                    if let mode = window.mode {
                        patch["window.mode"] =
                            mode == .standard
                            ? "secondaryDisplay" : "primaryDisplayCompatibility"
                    }
                    if let width = window.defaultWidth {
                        patch["window.defaultWidth"] = String(width)
                    }
                    if let height = window.defaultHeight {
                        patch["window.defaultHeight"] = String(height)
                    }
                    if let resizable = window.resizable {
                        patch["window.resizable"] = resizable ? "true" : "false"
                    }
                }
                if let integration = wrapperDocument.integration {
                    // A wrapper this Mac did not generate is capped by this
                    // Mac's `integrations.defaults.*`: it can turn an
                    // integration off or down, never on or up
                    // (configuration.md §3.3, wrapper.md §3).
                    let capped = entry.approval == .user
                    let defaults =
                        capped
                        ? GlobalSettings.load(from: paths.settingsFile)
                            .integrationsDefaults
                        : [:]
                    func cap(
                        _ value: String, key: String, order: [String], fallback: String
                    ) -> String {
                        guard capped else { return value }
                        let ceiling = defaults[key] ?? fallback
                        guard let rank = order.firstIndex(of: value),
                            let bound = order.firstIndex(of: ceiling)
                        else { return ceiling }
                        return rank <= bound ? value : ceiling
                    }
                    let boolOrder = ["false", "true"]
                    if let clipboard = integration.clipboard {
                        patch["integrations.clipboard"] = cap(
                            clipboard ? "true" : "false",
                            key: "clipboard", order: boolOrder, fallback: "true")
                    }
                    if let notifications = integration.notifications {
                        patch["integrations.notifications"] = cap(
                            notifications ? "true" : "false",
                            key: "notifications", order: boolOrder, fallback: "true")
                    }
                    if let links = integration.links {
                        patch["integrations.links"] = cap(
                            links.rawValue, key: "links",
                            order: ["android", "ask", "mac"], fallback: "ask")
                    }
                    if let files = integration.files {
                        patch["integrations.files"] = cap(
                            files ? "true" : "false",
                            key: "files", order: boolOrder, fallback: "true")
                    }
                    if let sharedFolders = integration.sharedFolders {
                        patch["integrations.sharedFolders"] = cap(
                            sharedFolders.rawValue, key: "sharedFolders",
                            order: ["off", "readOnly", "readWrite"], fallback: "off")
                    }
                    if let microphone = integration.microphone {
                        patch["integrations.microphone"] = cap(
                            microphone ? "true" : "false",
                            key: "microphone", order: boolOrder, fallback: "false")
                    }
                }
                if !patch.isEmpty {
                    _ = try await store.updatePackageSettings(packageID, patch: patch)
                }
            }
            return result.summary
        } catch {
            throw Self.wireError(for: error)
        }
    }

    /// Whether no record exists for the package — the bootstrap import then
    /// creates it and applies wrapper.json's first-record settings. A record
    /// whose state is not `uninstalledKeepingData` fails B2.
    private func firstBootstrapRecord(for packageID: PackageID) async throws -> Bool {
        guard
            let record = try await store.listManagedPackages()
                .first(where: { $0.packageId == packageID })
        else {
            return true
        }
        guard record.state == .uninstalledKeepingData else {
            throw RuntimeHost.wrapperWireError(for: .bootstrapNotAllowed(.alreadyInstalled))
        }
        return false
    }

    /// Maps a parsed wrapper.json provider to the store's provider reference
    /// (wrapper-json.md §2.4). `local` is never stored in wrapper.json, so it
    /// never reaches the record.
    private static func providerRef(for provider: WrapperUpdateProvider) -> UpdateProviderRef? {
        switch provider.configuration {
        case .direct(let url):
            return UpdateProviderRef(
                type: .direct, configuration: .direct(url: url))
        case .fdroid(let repository, let fingerprint):
            return UpdateProviderRef(
                type: .fdroid,
                configuration: .fdroid(repository: repository, fingerprint: fingerprint))
        case .github(let repository, let assetPattern, let channel):
            return UpdateProviderRef(
                type: .github,
                configuration: .github(
                    repository: repository, assetPattern: assetPattern,
                    channel: GitHubReleaseChannel(rawValue: channel) ?? .stable))
        }
    }

    /// Drops an import ticket and its private APK copies without starting Android.
    public func discardImport(
        _ request: RuntimeDiscardImportRequest
    ) async throws(RuntimeWireError) {
        do {
            try await ensureOpen()
            guard let ticket = UUID(uuidString: request.ticket.rawValue) else {
                throw PackageStoreFailure.importTicketNotFound
            }
            try await store.discardImport(ticket: ticket)
            importPreviews.removeValue(forKey: ticket)
        } catch {
            throw Self.wireError(for: error)
        }
    }

    /// Marks every managed package as needing a reinstall on a new userdata generation
    /// (package-store.md §9.2, runtime-daemon.md §9.5). Returns the managed package IDs that
    /// must be reinstalled from their retained artifacts.
    public func markForUserdataReset() async throws(RuntimeWireError) -> [RuntimePackageID] {
        do {
            try await ensureOpen()
            return try await store.markForUserdataReset()
                .compactMap { RuntimePackageID(rawValue: $0.rawValue) }
        } catch {
            throw Self.wireError(for: error)
        }
    }

    /// Managed packages still waiting for a reinstall after a userdata reset or restore.
    /// The records stay marked when a reinstall could not run, so a later boot retries them.
    public func pendingReinstalls() async throws(RuntimeWireError) -> [RuntimePackageID] {
        do {
            try await ensureOpen()
            return try await store.listManagedPackages().compactMap { record in
                switch record.state {
                case .needsReinstall, .broken(.reinstallFailed):
                    return RuntimePackageID(rawValue: record.packageId.rawValue)
                default:
                    return nil
                }
            }
        } catch {
            throw Self.wireError(for: error)
        }
    }

    /// The stored `integrations.*` settings of a package
    /// (package-metadata-json.md §3); nil for unmanaged or unconfigured ones.
    func packageIntegrationSettings(for packageID: String) async throws -> PackageSettings? {
        try await ensureOpen()
        guard let id = PackageID(rawValue: packageID) else {
            return nil
        }
        return try await store.packageSettings(for: id)
    }

    /// The stored `settings.json` of a package on the wire (host-ui.md §7).
    public func packageSettings(
        for packageID: RuntimePackageID
    ) async throws(RuntimeWireError) -> PackageSettingsWire? {
        do {
            try await ensureOpen()
            guard let id = PackageID(rawValue: packageID.rawValue) else {
                throw PackageStoreFailure.packageNotFound
            }
            let settings = try await store.packageSettings(for: id) ?? PackageSettings()
            return wireSettings(settings)
        } catch {
            throw Self.wireError(for: error)
        }
    }

    /// Resolves every §3.1 key for the wire (configuration.md §3.2):
    /// global switches of `settings.json` win, then the stored value,
    /// then a compatibility recommendation (#91), then the default.
    private func wireSettings(_ settings: PackageSettings) -> PackageSettingsWire {
        let global = GlobalSettings.load(from: paths.settingsFile)
        let resolver = PackageSettingsResolver(
            globalIntegrationsEnabled: global.integrationsEnabled)
        let entries = PackageSettingsSchema.keys.map { key -> PackageSettingWire in
            let stored = settings.value(key.name)
            let recommended = resolver.isRecommended(key.name, in: settings)
            let forcedOff =
                key.name.hasPrefix("integrations.")
                && global.integrationsEnabled[String(key.name.dropFirst("integrations.".count))]
                    == false
            let source =
                forcedOff
                ? "globalSwitch"
                : stored != nil
                    ? "user"
                    : recommended
                        ? "recommended" : "default"
            var allowed: [String]?
            switch key.kind {
            case .word(let words): allowed = words
            case .flag: allowed = ["true", "false"]
            default: break
            }
            return PackageSettingWire(
                key: key.name,
                value: resolver.effectiveValue(for: key.name, in: settings),
                source: source,
                appliesLive: key.appliesLive,
                stored: stored,
                allowed: allowed)
        }
        return PackageSettingsWire(
            groups: settings.groups, recommended: resolver.recommendations, entries: entries)
    }

    /// Applies a `settings.json` patch and returns the stored settings
    /// (host-ui.md §7, `updatePackageSettings`).
    public func updatePackageSettings(
        _ request: RuntimeUpdatePackageSettingsRequest
    ) async throws(RuntimeWireError) -> PackageSettingsWire {
        do {
            try await ensureOpen()
            guard let id = PackageID(rawValue: request.packageID.rawValue) else {
                throw PackageStoreFailure.packageNotFound
            }
            var patch: [String: String?] = [:]
            for (key, value) in request.patch.set {
                patch[key] = value
            }
            for key in request.patch.clear {
                // `[String: String?]` deletes on `= nil`; `.some(nil)` keeps the
                // clear instruction for the store.
                patch[key] = .some(nil)
            }
            let settings = try await store.updatePackageSettings(id, patch: patch)
            return wireSettings(settings)
        } catch {
            throw Self.wireError(for: error)
        }
    }

    /// The `current/` artifact directory of a managed package (collision-aware; §9.5).
    public func artifactCurrentDirectory(
        for packageID: RuntimePackageID
    ) async throws(RuntimeWireError) -> URL {
        do {
            try await ensureOpen()
            guard let id = PackageID(rawValue: packageID.rawValue) else {
                throw PackageStoreFailure.packageNotFound
            }
            return try await store.artifactCurrentDirectory(packageID: id)
        } catch {
            throw Self.wireError(for: error)
        }
    }

    /// Installs a new import, restores a retained-data package, or updates a managed package.
    public func installImported(
        _ request: RuntimeInstallImportedRequest
    ) async throws(RuntimeWireError) -> RuntimePackageSummary {
        try await installImportedWithChange(request).summary
    }

    /// Resolves the package for a pending install ticket without starting Android.
    func packageIDForInstall(_ request: RuntimeInstallImportedRequest) async throws(RuntimeWireError)
        -> RuntimePackageID
    {
        do {
            try await ensureOpen()
            guard let ticket = UUID(uuidString: request.ticket.rawValue) else {
                throw EmbeddedPackageServiceFailure.invalidTicket
            }
            // An invalid `--provider` spec fails before anything installs
            // (cli.md §4.2): parsing it later would leave the APK installed
            // while the command reports an error.
            let requestedProviderRef: UpdateProviderRef?
            do {
                requestedProviderRef = try request.options.provider.map(
                    UpdatePolicyRules.providerRef(for:))
            } catch {
                throw Self.wireError(for: error)
            }
            let packageID = try await store.packageIDForImportTicket(ticket)
            guard let runtimePackageID = RuntimePackageID(rawValue: packageID.rawValue) else {
                throw EmbeddedPackageServiceFailure.invalidTicket
            }
            return runtimePackageID
        } catch {
            throw Self.wireError(for: error)
        }
    }

    /// Installs an import and reports the store change that occurred.
    func installImportedWithChange(
        _ request: RuntimeInstallImportedRequest,
        beforeStoreMutation: PackageMutationBoundary? = nil,
        requiresReinstallMark: Bool = false
    ) async throws(RuntimeWireError) -> RuntimePackageInstallResult {
        do {
            try await ensureOpen()
            // A `--provider` install attaches the provider after the store
            // commit; `apkrun` authority without one stays refused (§2.4).
            guard
                request.options.authority == .manual
                    || (request.options.authority == .apkrun && request.options.provider != nil)
            else {
                throw EmbeddedPackageServiceFailure.unsupportedUpdateAuthority
            }
            guard !request.options.createWrapper else {
                throw EmbeddedPackageServiceFailure.wrapperCreationUnavailable
            }
            guard let ticket = UUID(uuidString: request.ticket.rawValue) else {
                throw EmbeddedPackageServiceFailure.invalidTicket
            }
            // An invalid `--provider` spec fails before anything installs
            // (cli.md §4.2): parsing it later would leave the APK installed
            // while the command reports an error.
            let requestedProviderRef: UpdateProviderRef?
            do {
                requestedProviderRef = try request.options.provider.map(
                    UpdatePolicyRules.providerRef(for:))
            } catch {
                throw Self.wireError(for: error)
            }
            let packageID = try await store.packageIDForImportTicket(ticket)
            guard let runtimePackageID = RuntimePackageID(rawValue: packageID.rawValue) else {
                throw EmbeddedPackageServiceFailure.invalidTicket
            }
            try beginPackageMutation(runtimePackageID.rawValue)
            defer { finishPackageMutation(runtimePackageID.rawValue) }
            try await waitForPackageLaunches(runtimePackageID.rawValue)
            guard let sessionHandling = sessionService as? any PackageMutationSessionHandling else {
                throw Self.packageSessionStateUnavailableError
            }
            guard !(await sessionHandling.hasActiveSession(packageID: runtimePackageID)) else {
                throw Self.packageInUseError
            }

            let outcome: PackageInstallOutcome
            if let preview = importPreviews[ticket] {
                if case .otherSigner = preview.relation {
                    throw EmbeddedPackageServiceFailure.signerMismatch
                }
            }

            if let preview = importPreviews[ticket] {
                if case .uninstalledWithData = preview.relation {
                    outcome = try await store.installImportedWithOutcome(
                        ticket: ticket,
                        beforeGuestInstall: beforeStoreMutation,
                        requiresReinstallMark: requiresReinstallMark
                    )
                } else if case .newPackage = preview.relation {
                    outcome = try await store.installImportedWithOutcome(
                        ticket: ticket,
                        beforeGuestInstall: beforeStoreMutation,
                        requiresReinstallMark: requiresReinstallMark
                    )
                } else {
                    outcome = try await store.reinstallWithOutcome(
                        ticket: ticket,
                        beforeGuestInstall: beforeStoreMutation,
                        requiresReinstallMark: requiresReinstallMark
                    )
                }
            } else {
                // The ticket may have been restored from disk after a restart. PackageStore
                // safely permits first installs and retained-data reinstalls in this case.
                outcome = try await store.installImportedWithOutcome(
                    ticket: ticket,
                    beforeGuestInstall: beforeStoreMutation,
                    requiresReinstallMark: requiresReinstallMark
                )
            }
            importPreviews[ticket] = nil
            // §2.4: the install flags land on the record whenever the user
            // asked for them — a provider spec or a `--updates` mode. With
            // no provider, the stored one is kept; `--updates manual` keeps
            // authority `manual` and the provider stored unused.
            if requestedProviderRef != nil || request.options.updateMode != nil {
                let mode = UpdatePolicyRules.settingsMode(
                    for: request.options.updateMode ?? .automatic)
                // `--updates manual` demotes to manual; a provider spec
                // promotes to apkrun. A mode-only flag leaves the stored
                // authority alone, so reinstalling `--updates notify` on a
                // package with a configured provider keeps APKRun checking.
                let authority: UpdateAuthority? =
                    if request.options.updateMode == .manual {
                        .manual
                    } else if requestedProviderRef != nil {
                        .apkrun
                    } else {
                        nil
                    }
                try await store.setUpdateMode(for: packageID, mode: mode)
                try await store.setUpdatePolicy(
                    for: packageID,
                    authority: authority,
                    provider: requestedProviderRef,
                    requireProvider: request.options.authority == .apkrun)
            }
            try? await refreshAndroidInventory()
            let summary = try Self.summary(from: outcome.record)
            return RuntimePackageInstallResult(
                summary: summary,
                previousVersionCode: outcome.previousVersionCode,
                restoredRetainedData: outcome.restoredRetainedData,
                cleanupDeferred: outcome.cleanupDeferred
            )
        } catch {
            throw Self.wireError(for: error)
        }
    }

    /// Uninstalls a managed package, retains its data when requested, or forgets its record.
    public func uninstallPackage(
        _ request: RuntimeUninstallPackageRequest
    ) async throws(RuntimeWireError) {
        _ = try await uninstallPackageWithChange(request)
    }

    /// Uninstalls through Android or forgets the host record, preserving the event distinction.
    func uninstallPackageWithChange(
        _ request: RuntimeUninstallPackageRequest,
        beforeStoreMutation: PackageMutationBoundary? = nil
    ) async throws(RuntimeWireError) -> RuntimePackageUninstallResult {
        guard !request.options.forget || !request.options.keepData else {
            throw .runtime(
                "malformedRequest",
                message: "A package cannot be forgotten while retaining its Android data.",
                remediation: "Choose either `--forget` or `--keep-data`, not both."
            )
        }
        do {
            try await ensureOpen()
            guard let packageID = PackageID(rawValue: request.packageID.rawValue) else {
                throw EmbeddedPackageServiceFailure.invalidPackageID
            }
            if request.options.forget {
                try beginPackageMutation(request.packageID.rawValue, blocksLaunches: false)
                defer { finishPackageMutation(request.packageID.rawValue) }
                try await store.forget(
                    packageID: packageID,
                    beforeForget: beforeStoreMutation
                )
                return RuntimePackageUninstallResult(change: nil, cleanupDeferred: false)
            } else {
                try beginPackageMutation(request.packageID.rawValue)
                defer { finishPackageMutation(request.packageID.rawValue) }
                try await waitForPackageLaunches(request.packageID.rawValue)
                guard let sessionHandling = sessionService as? any PackageMutationSessionHandling else {
                    throw Self.packageSessionStateUnavailableError
                }
                let outcome = try await store.uninstallWithOutcome(
                    packageID: packageID,
                    keepData: request.options.keepData,
                    beforeUninstall: {
                        try await sessionHandling.endSessionForPackageUninstall(
                            RuntimeTerminateRequest(packageID: request.packageID)
                        )
                    },
                    beforeGuestUninstall: {
                        try await beforeStoreMutation?()
                    }
                )
                try? await refreshAndroidInventory()
                return RuntimePackageUninstallResult(
                    change: .removed(request.packageID, keptData: outcome.keptData),
                    cleanupDeferred: outcome.cleanupDeferred
                )
            }
        } catch {
            throw Self.wireError(for: error)
        }
    }

    /// Reinstalls a `broken` package from its retained `current/` artifacts
    /// (package-store.md §11.1) and returns the change to publish. The caller
    /// starts Android first; `repairPackage` itself never launches the runtime.
    public func repairPackage(
        _ request: RuntimePackageRequest
    ) async throws(RuntimeWireError) -> PackageChange {
        do {
            try await ensureOpen()
            guard let packageID = PackageID(rawValue: request.packageID.rawValue) else {
                throw EmbeddedPackageServiceFailure.invalidPackageID
            }
            let records = try await store.listManagedPackages()
            guard let record = records.first(where: { $0.packageId == packageID }) else {
                throw PackageStoreFailure.packageNotFound
            }
            guard case .broken = record.state else {
                throw Self.notRepairableError
            }
            let current = try await store.artifactCurrentDirectory(packageID: packageID)
            let names =
                try fileManager.contentsOfDirectory(atPath: current.path)
                .filter { $0.hasSuffix(".apk") }
                .sorted()
            guard !names.isEmpty else { throw Self.repairArtifactsMissingError }
            var handles: [FileHandle] = []
            var sourceFiles: [RuntimeImportSourceFile] = []
            for (index, name) in names.enumerated() {
                guard
                    let handle = try? FileHandle(
                        forReadingFrom: current.appendingPathComponent(name))
                else {
                    for handle in handles { try? handle.close() }
                    throw Self.repairArtifactsMissingError
                }
                handles.append(handle)
                sourceFiles.append(RuntimeImportSourceFile(fileIndex: index, name: name))
            }
            defer {
                for handle in handles { try? handle.close() }
            }
            let preview = try await importPackage(
                RuntimeImportPackageRequest(files: sourceFiles, origin: .cli),
                files: handles
            )
            let result = try await installImportedWithChange(
                RuntimeInstallImportedRequest(ticket: preview.ticket))
            return result.change
        } catch let error as RuntimeWireError {
            throw error
        } catch {
            throw Self.wireError(for: error)
        }
    }

    private static let notRepairableError = RuntimeWireError.store(
        "notRepairable",
        message: "The package is not marked broken.",
        remediation: "Repair applies only to a package APKRun lists as broken.")

    private static let repairArtifactsMissingError = RuntimeWireError.store(
        "notRepairable",
        message: "APKRun has no retained APKs to reinstall.",
        remediation: "Uninstall the package, then install it from a new APK file.")

    private static let packageInUseError = RuntimeWireError.store(
        "packageInUse",
        message: "The app still has an open APKRun window.",
        remediation: "Close the app window, then retry the install."
    )

    private static let packageSessionStateUnavailableError = RuntimeWireError.runtime(
        "serviceUnavailable",
        message: "APKRun couldn't check whether the app has an open window.",
        remediation: "Restart the APKRun background service, then retry."
    )

    private func beginPackageMutation(
        _ packageID: String,
        blocksLaunches: Bool = true
    ) throws(RuntimeWireError) {
        guard packageStoreMutationsInProgress.insert(packageID).inserted else {
            throw Self.packageOperationInProgressError
        }
        if blocksLaunches {
            packageMutationsInProgress.insert(packageID)
        }
    }

    private func finishPackageMutation(_ packageID: String) {
        packageStoreMutationsInProgress.remove(packageID)
        packageMutationsInProgress.remove(packageID)
    }

    private func beginPackageLaunch(_ packageID: String) throws(RuntimeWireError) {
        guard !packageMutationsInProgress.contains(packageID) else {
            throw Self.packageOperationInProgressError
        }
        packageLaunchesInProgress[packageID, default: 0] += 1
    }

    private func finishPackageLaunch(_ packageID: String) {
        guard let count = packageLaunchesInProgress[packageID] else { return }
        if count <= 1 {
            packageLaunchesInProgress[packageID] = nil
        } else {
            packageLaunchesInProgress[packageID] = count - 1
        }
    }

    private func waitForPackageLaunches(_ packageID: String) async throws(RuntimeWireError) {
        while packageLaunchesInProgress[packageID, default: 0] > 0 {
            guard !Task.isCancelled else {
                throw Self.cancelledOperationError
            }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                throw Self.cancelledOperationError
            }
        }
    }

    private static let packageOperationInProgressError = RuntimeWireError.store(
        "operationInProgress",
        message: "APKRun is already changing this app's package state.",
        remediation: "Wait for the package operation to finish, then try again."
    )

    private static let cancelledOperationError = RuntimeWireError.runtime(
        "cancelled",
        message: "The package operation was cancelled."
    )

    /// Lists managed records, optionally merging Android's current PackageManager inventory.
    public func listPackages(
        _ request: RuntimeListPackagesRequest
    ) async throws(RuntimeWireError) -> RuntimePackageListResult {
        do {
            try await ensureOpen()
            let records = try await store.listManagedPackages()
            var packages: [String: RuntimePackageSummary] = [:]
            for record in records {
                packages[record.packageId.rawValue] = try Self.summary(from: record)
            }
            let recordIssues = try await store.listPackageRecordIssues()
            let issuesByPackage = Dictionary(
                uniqueKeysWithValues: recordIssues.map { ($0.packageID.rawValue, $0) }
            )
            for issue in recordIssues {
                guard let wireID = RuntimePackageID(rawValue: issue.packageID.rawValue) else { continue }
                packages[issue.packageID.rawValue] = RuntimePackageSummary(
                    packageID: wireID,
                    displayName: issue.packageID.rawValue,
                    versionCode: nil,
                    state: .broken("metadataUnreadable"),
                    managed: true
                )
            }

            var source: RuntimePackageListSource = .managedRecords
            var observedAt: Date?
            if request.filter == .all {
                let guestPackages: [StorePackageSummary]
                if runtimeAttached {
                    do {
                        guestPackages = try await runtimeAccess.withStoreAgent(UUID()) { channel in
                            try await channel.listPackages(.all)
                        }
                        let savedSnapshot = try? await store.saveLastKnownAndroidInventory(guestPackages)
                        source = .liveAndroid
                        observedAt = savedSnapshot?.observedAt ?? Date()
                    } catch let failure as DevelopmentStoreRuntimeAccessFailure
                        where failure == .runtimeNotReady
                    {
                        (guestPackages, source, observedAt) = try await cachedAndroidInventory()
                    }
                } else {
                    (guestPackages, source, observedAt) = try await cachedAndroidInventory()
                }
                let observedPackageIDs = Set(guestPackages.map { $0.packageID.rawValue })
                for guest in guestPackages {
                    let packageID = guest.packageID.rawValue
                    if var managed = packages[packageID] {
                        // Android is authoritative for the current installed version and label.
                        managed.displayName = guest.displayName
                        if issuesByPackage[packageID] == nil {
                            managed.versionCode = guest.versionCode
                            managed.state = .installed
                        }
                        packages[packageID] = managed
                    } else if let wireID = RuntimePackageID(rawValue: packageID) {
                        packages[packageID] = RuntimePackageSummary(
                            packageID: wireID,
                            displayName: guest.displayName,
                            versionCode: guest.versionCode,
                            state: .installed,
                            managed: false,
                            updateAuthority: .external
                        )
                    }
                }
                if source != .noAndroidInventory {
                    for packageID in Array(packages.keys) {
                        guard var managed = packages[packageID],
                            managed.managed,
                            managed.state == .installed,
                            !observedPackageIDs.contains(packageID)
                        else {
                            continue
                        }
                        managed.state = .broken("removedInAndroid")
                        packages[packageID] = managed
                    }
                }
            }
            return RuntimePackageListResult(
                packages: packages.values.sorted { $0.packageID < $1.packageID },
                source: source,
                observedAt: observedAt
            )
        } catch {
            throw Self.wireError(for: error)
        }
    }

    /// Returns the persisted record and the current artifact metadata for a managed package.
    public func packageInfo(
        _ request: RuntimePackageRequest
    ) async throws(RuntimeWireError) -> RuntimePackageDetails {
        do {
            try await ensureOpen()
            guard let packageID = PackageID(rawValue: request.packageID.rawValue) else {
                throw EmbeddedPackageServiceFailure.invalidPackageID
            }
            if let issue = try await store.packageRecordIssue(for: packageID) {
                throw PackageStoreFailure.metadataUnreadable(packageID, detail: issue.detail)
            }
            let records = try await store.listManagedPackages()
            guard let record = records.first(where: { $0.packageId == packageID }) else {
                guard let summary = try await unmanagedPackageSummary(for: packageID) else {
                    throw PackageStoreFailure.packageNotFound
                }
                return RuntimePackageDetails(summary: summary, files: [], artifactBytes: 0)
            }

            let artifactSet: ArtifactSet?
            if record.artifacts.current == nil {
                artifactSet = nil
            } else {
                artifactSet = try currentArtifactSet(for: packageID)
            }
            let files =
                try artifactSet?.files.map(Self.runtimeArtifact)
                ?? []
            let bytes = record.artifacts.current?.size ?? 0
            return RuntimePackageDetails(
                summary: try Self.summary(from: record),
                files: files,
                artifactBytes: bytes,
                staged: record.artifacts.staged.map {
                    RuntimeStagedArtifact(
                        versionCode: $0.versionCode,
                        versionName: $0.versionName,
                        size: $0.size,
                        fileCount: $0.fileCount,
                        origin: $0.origin.type.rawValue)
                },
                previous: record.artifacts.previous.map {
                    RuntimeArtifactSlot(
                        versionCode: $0.versionCode,
                        versionName: $0.versionName,
                        size: $0.size,
                        fileCount: $0.fileCount)
                }
            )
        } catch {
            throw Self.wireError(for: error)
        }
    }

    /// Adopts a package Android has but APKRun does not manage (package-store.md §9.3).
    ///
    /// The live Store Agent supplies the package facts; the runtime must be attached and Android
    /// must report the package for adoption to succeed.
    public func adoptPackage(
        _ request: RuntimeAdoptPackageRequest
    ) async throws(RuntimeWireError) -> RuntimePackageSummary {
        do {
            try await ensureOpen()
            guard let packageID = PackageID(rawValue: request.packageID.rawValue) else {
                throw EmbeddedPackageServiceFailure.invalidPackageID
            }
            guard runtimeAttached else { throw PackageStoreFailure.runtimeUnavailable }
            let record = try await store.adoptPackage(packageID: packageID)
            return try Self.summary(from: record)
        } catch {
            throw Self.wireError(for: error)
        }
    }

    private func ensureOpen() async throws {
        if isOpen {
            return
        }
        if let openTask {
            try await openTask.value
            isOpen = true
            return
        }

        let store = self.store
        let stagingRoot = paths.packagesDirectory.appendingPathComponent(".client-imports", isDirectory: true)
        let fileManager = FileManager.default
        let task = Task {
            try await store.open()
            try Self.removeStaleStagingDirectories(
                at: stagingRoot,
                olderThan: Self.stagingLifetime,
                fileManager: fileManager
            )
        }
        openTask = task
        do {
            try await task.value
            isOpen = true
            openTask = nil
        } catch {
            openTask = nil
            throw error
        }
    }

    private func cachedAndroidInventory() async throws
        -> (packages: [StorePackageSummary], source: RuntimePackageListSource, observedAt: Date?)
    {
        if let snapshot = try await store.lastKnownAndroidInventory() {
            return (snapshot.packages, .cachedAndroid, snapshot.observedAt)
        }
        return ([], .noAndroidInventory, nil)
    }

    private func unmanagedPackageSummary(for packageID: PackageID) async throws -> RuntimePackageSummary? {
        let packages: [StorePackageSummary]
        if runtimeAttached {
            do {
                packages = try await runtimeAccess.withStoreAgent(UUID()) { channel in
                    try await channel.listPackages(.all)
                }
                _ = try? await store.saveLastKnownAndroidInventory(packages)
            } catch let failure as DevelopmentStoreRuntimeAccessFailure where failure == .runtimeNotReady {
                packages = try await store.lastKnownAndroidInventory()?.packages ?? []
            }
        } else {
            packages = try await store.lastKnownAndroidInventory()?.packages ?? []
        }

        guard let package = packages.first(where: { $0.packageID == packageID }) else {
            return nil
        }
        return RuntimePackageSummary(
            packageID: try Self.runtimePackageID(package.packageID),
            displayName: package.displayName,
            versionCode: package.versionCode,
            state: .installed,
            managed: false,
            updateAuthority: .external
        )
    }

    private func stage(
        _ sources: [RuntimeImportSourceFile],
        from handles: [FileHandle]
    ) throws -> StagedImport {
        guard !sources.isEmpty, sources.count <= Self.maximumAPKCount, sources.count == handles.count else {
            throw EmbeddedPackageServiceFailure.invalidFileCount
        }

        var indexes = Set<Int>()
        for source in sources {
            guard source.fileIndex >= 0, source.fileIndex < handles.count,
                indexes.insert(source.fileIndex).inserted,
                Self.isSafeSourceName(source.name)
            else {
                throw EmbeddedPackageServiceFailure.invalidSourceFile
            }
        }
        guard indexes == Set(handles.indices) else {
            throw EmbeddedPackageServiceFailure.invalidSourceFile
        }
        for handle in handles {
            var fileInfo = stat()
            guard Darwin.fstat(handle.fileDescriptor, &fileInfo) == 0,
                fileInfo.st_mode & S_IFMT == S_IFREG
            else {
                throw EmbeddedPackageServiceFailure.invalidSourceFile
            }
        }

        let root = paths.packagesDirectory.appendingPathComponent(".client-imports", isDirectory: true)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw EmbeddedPackageServiceFailure.stagingIO
        }

        var stagedFiles: [URL] = []
        var totalBytes: Int64 = 0
        var lastDirectoryTouch = Date()
        do {
            for (position, source) in sources.enumerated() {
                let fileDirectory = directory.appendingPathComponent(
                    "file-\(position)",
                    isDirectory: true
                )
                try fileManager.createDirectory(
                    at: fileDirectory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                let destination = fileDirectory.appendingPathComponent(source.name)
                guard
                    fileManager.createFile(
                        atPath: destination.path,
                        contents: nil,
                        attributes: [.posixPermissions: 0o600]
                    )
                else {
                    throw EmbeddedPackageServiceFailure.stagingIO
                }

                let output = try FileHandle(forWritingTo: destination)
                defer { try? output.close() }
                var fileBytes: Int64 = 0
                while true {
                    try Task.checkCancellation()
                    var bytes = [UInt8](repeating: 0, count: Self.copyChunkSize)
                    let bytesRead = bytes.withUnsafeMutableBytes { buffer in
                        Darwin.pread(
                            handles[source.fileIndex].fileDescriptor,
                            buffer.baseAddress,
                            buffer.count,
                            off_t(fileBytes)
                        )
                    }
                    if bytesRead < 0, errno == EINTR {
                        continue
                    }
                    guard bytesRead >= 0 else {
                        throw EmbeddedPackageServiceFailure.stagingIO
                    }
                    guard bytesRead > 0 else {
                        break
                    }
                    let chunk = Data(bytes.prefix(bytesRead))
                    let count = Int64(chunk.count)
                    let (newFileBytes, fileOverflow) = fileBytes.addingReportingOverflow(count)
                    let (newTotalBytes, totalOverflow) = totalBytes.addingReportingOverflow(count)
                    guard !fileOverflow, newFileBytes <= Self.maximumAPKFileSize else {
                        throw EmbeddedPackageServiceFailure.apkFileTooLarge
                    }
                    guard !totalOverflow, newTotalBytes <= Self.maximumImportSetSize else {
                        throw EmbeddedPackageServiceFailure.importSetTooLarge
                    }
                    try ensureStagingSpace(forNextChunk: count)
                    try output.write(contentsOf: chunk)
                    fileBytes = newFileBytes
                    totalBytes = newTotalBytes
                    let now = Date()
                    if now.timeIntervalSince(lastDirectoryTouch) >= Self.stagingTouchInterval {
                        try fileManager.setAttributes([.modificationDate: now], ofItemAtPath: directory.path)
                        lastDirectoryTouch = now
                    }
                }
                guard fileBytes > 0 else {
                    throw EmbeddedPackageServiceFailure.emptySourceFile
                }
                try output.synchronize()
                stagedFiles.append(destination)
            }
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
        return StagedImport(directory: directory, files: stagedFiles)
    }

    private func ensureStagingSpace(forNextChunk chunkBytes: Int64) throws {
        let (minimumFreeBytes, overflow) = chunkBytes.addingReportingOverflow(Self.importSpaceReserve)
        guard !overflow else {
            throw EmbeddedPackageServiceFailure.stagingIO
        }
        let available = hostFreeSpace(paths.packagesDirectory)
        guard available >= minimumFreeBytes else {
            throw PackageStoreFailure.insufficientHostSpace(
                needed: minimumFreeBytes,
                available: available
            )
        }
    }

    private static func removeStaleStagingDirectories(
        at root: URL,
        olderThan lifetime: TimeInterval,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: root.path) else {
            return
        }
        let items = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let cutoff = Date().addingTimeInterval(-lifetime)
        for item in items {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true,
                let modifiedAt = values?.contentModificationDate,
                modifiedAt < cutoff
            else {
                continue
            }
            try fileManager.removeItem(at: item)
        }
    }

    /// Maps the store's §4.7 classification onto the wire enum.
    private func relation(for preview: PackageImportPreview) async throws -> RuntimeImportRelation {
        switch preview.relation {
        case .newPackage:
            return .newPackage
        case .sameAsInstalled:
            return .sameAsInstalled
        case .reinstallSameVersion:
            return .reinstallSameVersion
        case .update(let from):
            return .update(from: from)
        case .downgrade(let from):
            return .downgrade(from: from)
        case .otherSigner:
            return .otherSigner
        case .uninstalledWithData(let versionCode):
            return .uninstalledWithData(versionCode)
        }
    }

    private func currentArtifactSet(for packageID: PackageID) throws -> ArtifactSet? {
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: paths.packagesDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw EmbeddedPackageServiceFailure.artifactMetadataUnavailable
        }

        for child in children
        where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let artifactURL =
                child
                .appendingPathComponent("current", isDirectory: true)
                .appendingPathComponent("artifact.json")
            guard let data = try? Data(contentsOf: artifactURL),
                let artifact = try? JSONDecoder().decode(ArtifactSet.self, from: data)
            else {
                continue
            }
            if artifact.packageID == packageID {
                return artifact
            }
        }
        throw EmbeddedPackageServiceFailure.artifactMetadataUnavailable
    }

    private static func runtimePreview(
        from preview: PackageImportPreview,
        relation: RuntimeImportRelation
    ) throws -> RuntimeImportPreview {
        guard let ticket = RuntimeImportTicket(rawValue: preview.ticket.uuidString.lowercased()) else {
            throw EmbeddedPackageServiceFailure.invalidTicket
        }
        return RuntimeImportPreview(
            ticket: ticket,
            packageID: try runtimePackageID(preview.packageID),
            displayName: preview.displayName,
            versionCode: preview.versionCode,
            versionName: preview.versionName,
            signerDigests: try preview.artifactSet.signerDigests.map { digest in
                guard let runtimeDigest = RuntimeSHA256Digest(rawValue: digest.rawValue) else {
                    throw EmbeddedPackageServiceFailure.artifactMetadataUnavailable
                }
                return runtimeDigest
            },
            files: try preview.artifactSet.files.map(runtimeArtifact),
            excludedSplits: preview.excludedSplits,
            relation: relation,
            warnings: preview.warnings.map { warning in
                switch warning {
                case .missingHardwareFeature(let feature): .missingHardwareFeature(feature: feature)
                case .certificateOnlyVerification: .certificateOnlyVerification
                case .debuggable: .debuggable
                case .lowTargetSDK(let target): .lowTargetSDK(target: target)
                }
            }
        )
    }

    /// The §4.7 Add-sheet suggestion: the cached main-repository index names
    /// the package and a version carries the imported signer, so `fdroid` is
    /// offered — off by default until the user enables it. Reads only the
    /// on-disk cache; it never fetches.
    private func fdroidProviderSuggestion(for preview: RuntimeImportPreview) -> String? {
        // No suggestion for a package another authority manages or one the
        // signer comparison already rejects.
        guard preview.relation != .otherSigner else { return nil }
        let hex = SHA256Digest(data: Data(FDroidProvider.mainRepository.utf8)).hexValue
        let indexFile =
            paths.updatesDirectory
            .appendingPathComponent("cache/fdroid/\(hex.prefix(16))/index.json")
        guard let data = try? Data(contentsOf: indexFile),
            data.count <= FDroidIndexReader.indexByteLimit,
            let packageID = PackageID(rawValue: preview.packageID.rawValue),
            let packages = try? FDroidIndexReader().packages(in: data, keep: [packageID]),
            let fdroidPackage = packages[packageID]
        else {
            return nil
        }
        let imported = Set(preview.signerDigests.map { $0.rawValue.lowercased() })
        guard !imported.isEmpty else { return nil }
        for version in fdroidPackage.versions.values {
            guard let signer = version.manifest.signer?.sha256 else { continue }
            let digests = Set(signer.map { "sha256:\($0.lowercased())" })
            if digests == imported { return "fdroid" }
        }
        return nil
    }

    private static func storeImportOrigin(_ origin: RuntimeImportOrigin) -> ImportOrigin {
        switch origin {
        case .addFlow: .addFlow
        case .document: .document
        case .dropOnHome: .dropOnHome
        case .cli: .cli
        case .wrap: .wrap
        }
    }

    private static func runtimeArtifact(_ artifact: ArtifactFile) throws -> RuntimeArtifactFile {
        guard let sha256 = RuntimeSHA256Digest(rawValue: artifact.sha256.rawValue) else {
            throw EmbeddedPackageServiceFailure.artifactMetadataUnavailable
        }
        return RuntimeArtifactFile(
            name: artifact.name,
            splitName: artifact.splitName,
            size: artifact.size,
            sha256: sha256
        )
    }

    @discardableResult
    private func refreshAndroidInventory() async throws -> [PackageID] {
        guard runtimeAttached else { return [] }
        let packages = try await runtimeAccess.withStoreAgent(UUID()) { channel in
            try await channel.listPackages(.all)
        }
        _ = try await store.saveLastKnownAndroidInventory(packages)
        return try await store.updateManagedDisplayNames(from: packages)
    }

    private static func summary(from record: PackageRecord) throws -> RuntimePackageSummary {
        return RuntimePackageSummary(
            packageID: try runtimePackageID(record.packageId),
            displayName: record.displayName,
            versionCode: record.versionCode,
            versionName: record.versionName,
            state: runtimeState(record.state),
            managed: true,
            updateAuthority: RuntimeUpdateAuthority(rawValue: record.updateAuthority.rawValue) ?? .manual
        )
    }

    private static func runtimePackageID(_ packageID: PackageID) throws -> RuntimePackageID {
        guard let wireID = RuntimePackageID(rawValue: packageID.rawValue) else {
            throw EmbeddedPackageServiceFailure.invalidPackageID
        }
        return wireID
    }

    private static func runtimeState(_ state: PackageState) -> RuntimePackageState {
        switch state {
        case .installed:
            .installed
        case .uninstalledKeepingData:
            .uninstalledKeepingData
        case .needsReinstall(let reason):
            .broken("needsReinstall.\(reason.rawValue)")
        case .broken(let reason):
            switch reason {
            case .removedInAndroid: .broken("removedInAndroid")
            case .signerChanged: .broken("signerChanged")
            case .artifactMissing: .broken("artifactMissing")
            case .reinstallFailed(let error): .broken("\(error.domain).\(error.code)")
            case .rollbackFailed: .broken("rollbackFailed")
            }
        }
    }

    private static func isSafeSourceName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && name.utf8.count <= 200
            && !name.contains("/")
            && !name.contains("\\")
            && !name.unicodeScalars.contains(where: { $0.value == 0 })
    }

    static func wireError(for error: any Error) -> RuntimeWireError {
        if let wireError = error as? RuntimeWireError {
            return wireError
        }
        if let failure = error as? PackageStoreFailure {
            switch failure {
            case .notOpen:
                return .store(
                    "notOpen", message: "The package store is not ready.", remediation: "Retry the operation.")
            case .invalidImport:
                return .store(
                    "invalidImport", message: "The APK import is empty or unreadable.",
                    remediation: "Choose a readable APK file.")
            case .tooManyImportFiles:
                return .store(
                    "tooManyImportFiles", message: "The split APK set contains too many files.",
                    remediation: "Choose one APK set with at most 256 files.")
            case .apkFileTooLarge:
                return .store("apkFileTooLarge", message: "An APK exceeds the 2 GiB per-file limit.")
            case .importSetTooLarge:
                return .store("importSetTooLarge", message: "The APK set exceeds the 8 GiB import limit.")
            case .insufficientHostSpace(let needed, let available):
                return .store(
                    "insufficientHostSpace",
                    message:
                        "The APK import needs \(needed) bytes of free disk space; \(available) bytes are available.",
                    remediation: "Free disk space and retry the import."
                )
            case .invalidSplitSet, .importPackageMismatch, .importVersionMismatch, .duplicateSplitName,
                .unsafeSplitName:
                return .store(
                    "invalidSplitSet", message: "The APK files do not form a consistent split set.",
                    remediation: "Select the base APK and all matching split APKs.")
            case .packageAlreadyManaged:
                return .store(
                    "packageAlreadyManaged", message: "This package is already managed by APKRun.",
                    remediation: "The package needs no adoption. See it with `apkrun list`.")
            case .packageAlreadyInstalled:
                return .store(
                    "packageAlreadyInstalled", message: "This package is already installed.",
                    remediation: "Import a newer APK or uninstall the package first.")
            case .packageNotFound:
                return .store(
                    "packageNotFound", message: "The package is not managed by APKRun.",
                    remediation: "Use `apkrun list` to see managed packages.")
            case .uninstallDataUnverified(let packageID):
                return .store(
                    "uninstallDataUnverified",
                    message: "APKRun couldn't confirm the requested app-data outcome for \(packageID.rawValue).",
                    remediation:
                        "Inspect Android's installed-package list with `apkrun list --all`. To discard APKRun's record and stored APKs without asserting an Android app-data outcome, run `apkrun uninstall \(packageID.rawValue) --forget`."
                )
            case .operationInProgress:
                return .store(
                    "operationInProgress", message: "Another package operation is already running for this app.",
                    remediation: "Wait for it to finish, then retry.")
            case .providerNotConfigured:
                return RuntimeWireError(
                    domain: "update",
                    code: "update.providerNotConfigured",
                    message: "Automatic updates need a configured update provider.",
                    remediation: "Set a provider with `apkrun update policy <package> --provider <spec>`.")
            case .authorityDoesNotAllowUpdates:
                return RuntimeWireError(
                    domain: "update",
                    code: "update.authorityDoesNotAllowUpdates",
                    message: "This package's update authority does not allow APKRun updates.",
                    remediation: "Set the authority with `apkrun update authority <package> apkrun`.")
            case .importTicketNotFound, .importTicketExpired, .importTicketChanged:
                return .store(
                    "importTicketExpired", message: "The APK preview is no longer valid.",
                    remediation: "Import the APK files again.")
            case .runtimeUnavailable:
                return .runtime(
                    "runtimeUnavailable", message: "Android is not available for this package operation.",
                    remediation: "Start the Android runtime and retry.")
            case .guestPackageMismatch, .guestVersionMismatch:
                return .store(
                    "guestPackageMismatch",
                    message: "Android installed a package version that did not match the inspected APK.",
                    remediation: "Check the APK set and retry.")
            case .downgradeRefused(let installed, let candidate):
                return .store(
                    "downgradeRefused",
                    message:
                        "Version \(candidate) is older than installed version \(installed).",
                    remediation: "Choose a newer APK, or uninstall the app first."
                )
            case .signerMismatch(let packageID):
                return .store(
                    "signerMismatch",
                    message:
                        "The APK for \(packageID.rawValue) is signed by a different key than the installed app.",
                    remediation:
                        "Install the APK signed by the same key, or uninstall the app first (its data is removed)."
                )
            case .downgradeReinstallUnavailable:
                return .store(
                    "downgradeUnavailable", message: "This Android image does not support package downgrades.")
            case .journalUnreadable:
                return .store(
                    "journalUnreadable",
                    message: "APKRun's package history is damaged; package changes are disabled.",
                    remediation: "Run `apkrun doctor` and report the store journal problem."
                )
            case .metadataUnreadable(let packageID, _):
                return .store(
                    "metadataUnreadable",
                    message: "APKRun can't read its records for \(packageID.rawValue).",
                    remediation:
                        "If a newer version of APKRun was used before, install that version again. Otherwise report the problem."
                )
            case .androidInventoryUnreadable:
                return .store(
                    "androidInventoryUnreadable",
                    message: "APKRun can't read its last-known Android package list.",
                    remediation: "Start Android to refresh the package list. If the problem continues, report it."
                )
            case .unsupportedJournalVersion(let version):
                return .store(
                    "unsupportedJournalVersion", message: "The package journal uses unsupported version \(version).")
            case .unreadablePackageRecord:
                return .store(
                    "unreadablePackageRecord", message: "A package record could not be read.",
                    remediation: "Run `apkrun doctor` for details.")
            case .packageInUse(let packageID):
                return .store(
                    "packageInUse", message: "\(packageID.rawValue) is in use.",
                    remediation: "Close the app's windows and try the update again.")
            case .stagedUpdateMissing:
                return .store(
                    "stagedUpdateMissing", message: "No verified update is staged for this package.",
                    remediation: "Run `apkrun update check` to download and stage an update first.")
            case .rollbackUnavailable(let reason):
                switch reason {
                case .noPreviousSet:
                    return .store(
                        "rollbackUnavailable",
                        message: "No previous APK set is retained for this package.",
                        remediation: "Rollback is possible only after an update.")
                case .noMechanism:
                    return .store(
                        "rollbackUnavailable",
                        message: "Android cannot roll this package back automatically.",
                        remediation:
                            "Retry with `apkrun rollback <package> --allow-data-loss` to reinstall the previous version (its app data is deleted)."
                    )
                }
            case .rollbackFailed(let detail):
                return RuntimeWireError(
                    domain: "update",
                    code: "update.rollbackFailed",
                    message: "The update rollback failed: \(detail).",
                    remediation:
                        "Repair the app with `apkrun repair <package>` or uninstall and install it again.")
            case .unknownSettingKey(let key):
                return RuntimeWireError(
                    domain: "store", code: "store.unknownSetting",
                    message: "There is no app setting named \(key).",
                    remediation:
                        "List the app's settings with: apkrun settings <package> list",
                    parameters: ["key": key])
            case .invalidSettingValue(let key, let allowed):
                return RuntimeWireError(
                    domain: "store", code: "store.invalidSettingValue",
                    message: "\(key) can't be set to that value.",
                    remediation: "Allowed values: \(allowed).",
                    parameters: ["key": key, "allowed": allowed])
            case .io:
                return .store(
                    "storageIO", message: "APKRun could not read or write package data.",
                    remediation: "Check disk space and permissions, then retry.")
            }
        }
        if let failure = error as? StoreFailure {
            // The wire code is the `store.*` error-catalog code without its prefix;
            // keep messages in sync with ErrorsCatalog `store` entries (§10).
            let code = String(failure.errorCode.dropFirst("store.".count))
            switch failure {
            case .unsupportedContainer(let kind):
                return .store(
                    code, message: "APKRun can't add this kind of file (\(kind.rawValue)).",
                    remediation:
                        "APKRun can add .apk, .apks, .xapk, and .apkm files, and .zip files that contain only APKs."
                )
            case .unreadableArchive:
                return .store(
                    code, message: "This file couldn't be read. It may be damaged or incomplete.",
                    remediation: "Download the file again.")
            case .archiveLimitExceeded(let limit):
                return .store(
                    code, message: "This file contains more than APKRun can safely unpack (\(limit.rawValue)).")
            case .expansionFilesNotSupported:
                return .store(
                    code,
                    message: "This file includes expansion files (OBB), which APKRun doesn't support yet.",
                    remediation: "Get a build of the app without expansion files.")
            case .notAnAPK(let file):
                return .store(
                    code, message: "\(file) isn't an Android app (APK).",
                    remediation: "Choose the app's .apk, .apks, .xapk, or .apkm file.")
            case .missingBase:
                return .store(
                    code, message: "The base APK is missing from this set.",
                    remediation: "Add the base APK too, or use the complete .apks, .xapk, or .apkm file.")
            case .multipleBases:
                return .store(
                    code, message: "This set contains more than one base APK.",
                    remediation: "Add the APKs of one app version only.")
            case .duplicateSplit(let split):
                return .store(
                    code, message: "The split \(split) appears more than once.",
                    remediation: "Add each split APK only once.")
            case .inconsistentSplits:
                return .store(
                    code, message: "The APKs in this set don't belong together.",
                    remediation: "Add the APKs of one app version from one source.")
            case .incompleteSplitSet(let missing):
                return .store(
                    code,
                    message: "This set is missing parts that the app needs: \(missing.joined(separator: ", ")).",
                    remediation: "Use the complete .apks, .xapk, or .apkm file of the app.")
            case .unsignedAPK(let file):
                return .store(
                    code, message: "\(file) isn't signed.",
                    remediation: "Android installs only signed apps. Get a signed copy from the app's developer.")
            case .invalidSignature(let file, _):
                return .store(
                    code, message: "The signature of \(file) isn't valid.",
                    remediation:
                        "The file may have been changed after signing. Download it again from the app's developer.")
            case .legacySignatureNotAllowed(let targetSdk):
                return .store(
                    code,
                    message:
                        "This app uses an old signature format that Android doesn't accept for apps that target API \(targetSdk).",
                    remediation: "Get a newer build of the app from its developer.")
            case .unsupportedABI(let found, let supported):
                return .store(
                    code,
                    message:
                        "This app is built only for \(found.joined(separator: ", ")), but Android in APKRun needs \(supported.joined(separator: ", ")).",
                    remediation: "Get a build of the app for \(supported.joined(separator: ", ")).")
            case .minSdkTooHigh(let required, let guest):
                return .store(
                    code,
                    message: "This app needs Android API \(required) or later. Android in APKRun has API \(guest).",
                    remediation: "Update Android, or get an older build of the app.")
            case .targetSdkTooLow(let target, let floor):
                return .store(
                    code,
                    message:
                        "This app targets API \(target). Android in APKRun installs only apps that target API \(floor) or later.",
                    remediation: "Get a newer build of the app from its developer.")
            case .reservedPackage(let packageID):
                return .store(
                    code,
                    message: "\(packageID.rawValue) is part of Android or APKRun and can't be added as an app.",
                    remediation: "No action is needed.")
            case .tooLarge(let bytes, let limit):
                return .store(
                    code, message: "This app is too large (\(bytes) bytes; the limit is \(limit) bytes).",
                    remediation: "Get a smaller build of the app, for example one for fewer device types.")
            case .resourcesArscNotAligned(let file):
                return .store(
                    code,
                    message:
                        "\(file) isn't packaged the way Android requires for apps that target API 30 or later.",
                    remediation: "Get a build of the app made with current Android build tools from its developer.")
            case .io:
                return .store(
                    code, message: "This file couldn't be read. It may be damaged or incomplete.",
                    remediation: "Download the file again.")
            }
        }
        if let failure = error as? APKInspectionFailure {
            switch failure {
            case .inputNotReadable:
                return .store(
                    "apkUnreadable", message: "The APK file could not be read.",
                    remediation: "Choose a complete, readable APK file.")
            case .aapt2NotFound:
                return .store(
                    "aapt2Unavailable", message: "APKRun could not find aapt2 to inspect the APK.",
                    remediation: "Install Android SDK Build Tools or use an APKRun build with bundled tools.")
            case .aapt2LaunchFailed, .aapt2TimedOut, .aapt2OutputTooLarge, .aapt2Failed:
                return .store(
                    "apkInspectionFailed", message: "APK inspection failed.",
                    remediation: "Verify that the APK is valid, then retry.")
            case .packageMetadataMissing, .invalidPackageID, .invalidVersionCode, .invalidSDKValue, .invalidSplitSet:
                return .store(
                    "apkMetadataInvalid", message: "The APK metadata is missing or invalid.",
                    remediation: "Choose a valid Android APK.")
            case .io:
                return .store(
                    "apkInspectionIO", message: "APKRun could not stage the APK for inspection.",
                    remediation: "Check disk space and permissions, then retry.")
            }
        }
        if let failure = error as? DevelopmentStoreRuntimeAccessFailure {
            switch failure {
            case .runtimeNotReady:
                return .runtime(
                    "runtimeNotReady",
                    message: "Android is not ready for a live package query.",
                    remediation: "Start Android and retry if you need a current package inventory."
                )
            case .guestAgentUnavailable:
                return .runtime(
                    "guestAgentUnavailable", message: "The Android Guest Agent is unavailable.",
                    remediation: "Boot an APKRun development image that includes the Guest Agent.")
            case .adbForwarderUnavailable:
                return .runtime(
                    "adbUnavailable", message: "The Android ADB forwarder is unavailable.",
                    remediation: "Check the development runtime and ADB setup, then retry.")
            }
        }
        if error is AdbFailure {
            return .runtime(
                "adbUnavailable", message: "APKRun could not communicate with Android over ADB.",
                remediation: "Check the development runtime and ADB setup, then retry.")
        }
        if let failure = error as? EmbeddedPackageServiceFailure {
            switch failure {
            case .invalidFileCount:
                return .store("invalidImport", message: "Choose between 1 and 256 APK files.")
            case .invalidSourceFile:
                return .store(
                    "invalidSourceFile", message: "The import request contains an invalid file index or name.")
            case .emptySourceFile:
                return .store(
                    "emptySourceFile", message: "An APK file is empty.", remediation: "Choose a complete APK file.")
            case .apkFileTooLarge:
                return .store("apkFileTooLarge", message: "An APK exceeds the 2 GiB per-file limit.")
            case .importSetTooLarge:
                return .store("importSetTooLarge", message: "The APK set exceeds the 8 GiB import limit.")
            case .stagingIO:
                return .store(
                    "stagingIO", message: "APKRun could not stage the APK files.",
                    remediation: "Check disk space and permissions, then retry.")
            case .unsupportedUpdateAuthority:
                return .store(
                    "unsupportedUpdateAuthority",
                    message: "This embedded package service supports manual update authority only.")
            case .wrapperCreationUnavailable:
                return .store(
                    "wrapperCreationUnavailable",
                    message: "Wrapper creation is not available in this package operation.")
            case .invalidTicket:
                return .store(
                    "invalidImportTicket", message: "The APK preview ticket is invalid.",
                    remediation: "Import the APK files again.")
            case .signerMismatch:
                return .store(
                    "signerMismatch",
                    message: "The APK is signed by a different certificate than the installed package.",
                    remediation: "Use an APK signed by the same developer.")
            case .runtimeNotAttached:
                return .runtime(
                    "runtimeUnavailable",
                    message: "Android package inventory is unavailable until a runtime is attached.",
                    remediation: "Start the Android runtime or list managed packages only.")
            case .invalidPackageID:
                return .store("invalidPackageID", message: "The package identifier is invalid.")
            case .artifactMetadataUnavailable:
                return .store(
                    "artifactMetadataUnavailable", message: "The stored APK metadata is missing or unreadable.",
                    remediation: "Reimport the APK files to restore package artifacts.")
            }
        }
        return .runtime(
            "packageOperationFailed",
            message: "The package operation failed.",
            remediation: "Retry the operation. If it keeps failing, run `apkrun doctor`."
        )
    }

    private static let maximumAPKCount = 256
    private static let maximumAPKFileSize: Int64 = 2 * 1_024 * 1_024 * 1_024
    private static let maximumImportSetSize: Int64 = 8 * 1_024 * 1_024 * 1_024
    private static let copyChunkSize = 1_024 * 1_024
    private static let importSpaceReserve: Int64 = 2 * 1_024 * 1_024 * 1_024
    private static let stagingLifetime: TimeInterval = 24 * 60 * 60
    private static let stagingTouchInterval: TimeInterval = 5 * 60

    private static func availableHostSpace(_ directory: URL) -> Int64 {
        if let available = try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage {
            return available
        }
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory.path),
            let available = attributes[.systemFreeSize] as? NSNumber
        else {
            return 0
        }
        return available.int64Value
    }
}

private struct StagedImport {
    var directory: URL
    var files: [URL]
}

private enum EmbeddedPackageServiceFailure: Error {
    case invalidFileCount
    case invalidSourceFile
    case emptySourceFile
    case apkFileTooLarge
    case importSetTooLarge
    case stagingIO
    case unsupportedUpdateAuthority
    case wrapperCreationUnavailable
    case invalidTicket
    case signerMismatch
    case runtimeNotAttached
    case invalidPackageID
    case artifactMetadataUnavailable
}

private actor AttachedStoreRuntimeAccess: StoreRuntimeAccess {
    private var access: (any StoreRuntimeAccess)?

    init(initial access: (any StoreRuntimeAccess)? = nil) {
        self.access = access
    }

    func attach(_ access: any StoreRuntimeAccess) {
        self.access = access
    }

    func detach() {
        access = nil
    }

    func withStoreAgent<T: Sendable>(
        _ operation: UUID,
        _ body: @Sendable (any StoreAgentChannel) async throws -> T
    ) async throws -> T {
        guard let access else {
            throw PackageStoreFailure.runtimeUnavailable
        }
        return try await access.withStoreAgent(operation, body)
    }

    func userdataGeneration() async -> UUID? {
        await access?.userdataGeneration()
    }
}
