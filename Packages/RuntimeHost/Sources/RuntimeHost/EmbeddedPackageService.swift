import APKStoreCore
import DiagnosticsCore
import Foundation
import RuntimeAPI
import RuntimeCore

/// The embedded RuntimeAPI implementation for APK imports and package management.
///
/// Import previews are host-only and work before Android starts. Guest-dependent operations
/// use the RuntimeHost store adapter attached by `DevBoot` after Android becomes ready.
public actor EmbeddedPackageService: RuntimeService {
    private let paths: APKRunPaths
    private let fileManager = FileManager.default
    private let inspector: PackageStore.Inspector
    private let runtimeAccess: AttachedStoreRuntimeAccess
    private let store: PackageStore
    private let sessionService: EmbeddedRuntimeService
    private let hostFreeSpace: @Sendable (URL) -> Int64

    private var isOpen = false
    private var openTask: Task<Void, Error>?
    private var runtimeAttached = false
    private var importPreviews: [UUID: RuntimeImportPreview] = [:]

    /// Creates an embedded package service rooted at APKRun's persistent package directory.
    public init(
        paths: APKRunPaths = APKRunPaths(allowingHomeOverride: true),
        inspector: @escaping PackageStore.Inspector = { apk in try await APKInspector().inspect(apk) },
        hostFreeSpace: (@Sendable (URL) -> Int64)? = nil
    ) {
        self.paths = paths
        self.inspector = inspector
        self.hostFreeSpace = hostFreeSpace ?? Self.availableHostSpace
        let runtimeAccess = AttachedStoreRuntimeAccess()
        self.runtimeAccess = runtimeAccess
        sessionService = EmbeddedRuntimeService()
        store = PackageStore(
            packagesDirectory: paths.packagesDirectory,
            runtimeAccess: runtimeAccess,
            inspector: inspector,
            fileManager: .default
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
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws(RuntimeWireError) {
        do {
            try await ensureOpen()
            let adbExecutable = try AdbClient.resolveExecutable(environment: environment)
            let access = DevelopmentStoreRuntimeAccess(
                supervisor: context.supervisor,
                adbExecutable: adbExecutable,
                instanceStore: context.instanceStore,
                image: context.image,
                logSink: context.diagnostics.logSink
            )
            guard let guestAgent = await context.supervisor.developmentGuestAgent else {
                throw DevelopmentStoreRuntimeAccessFailure.guestAgentUnavailable
            }
            await runtimeAccess.attach(access)
            runtimeAttached = true
            await sessionService.attachGuestAgent(guestAgent)
            try await store.recoverPendingTransactions()
        } catch {
            throw Self.wireError(for: error)
        }
    }

    /// Launches an installed package in the embedded runtime through the Guest Agent.
    public func launch(_ request: RuntimeLaunchRequest) async throws(RuntimeWireError) -> RuntimeLaunchResult {
        try await sessionService.launch(request)
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
            let result = try Self.runtimePreview(from: preview, relation: relation)
            importPreviews[preview.ticket] = result
            return result
        } catch {
            throw Self.wireError(for: error)
        }
    }

    /// Installs a new import, restores a retained-data package, or updates a managed package.
    public func installImported(
        _ request: RuntimeInstallImportedRequest
    ) async throws(RuntimeWireError) -> RuntimePackageSummary {
        do {
            try await ensureOpen()
            guard request.options.authority == .manual else {
                throw EmbeddedPackageServiceFailure.unsupportedUpdateAuthority
            }
            guard !request.options.createWrapper else {
                throw EmbeddedPackageServiceFailure.wrapperCreationUnavailable
            }
            guard let ticket = UUID(uuidString: request.ticket.rawValue) else {
                throw EmbeddedPackageServiceFailure.invalidTicket
            }

            let record: PackageRecord
            if let preview = importPreviews[ticket] {
                if case .downgrade = preview.relation, !request.options.allowDowngrade {
                    throw EmbeddedPackageServiceFailure.downgradeRequiresExplicitApproval
                }
                if case .otherSigner = preview.relation {
                    throw EmbeddedPackageServiceFailure.signerMismatch
                }

                if case .uninstalledWithData = preview.relation {
                    record = try await store.installImported(ticket: ticket)
                } else if case .newPackage = preview.relation {
                    record = try await store.installImported(ticket: ticket)
                } else {
                    let allowDowngrade: Bool
                    if case .downgrade = preview.relation {
                        allowDowngrade = request.options.allowDowngrade
                    } else {
                        allowDowngrade = false
                    }
                    record = try await store.reinstall(
                        ticket: ticket,
                        allowDowngrade: allowDowngrade
                    )
                }
            } else {
                // The ticket may have been restored from disk after a restart. PackageStore
                // safely permits first installs and retained-data reinstalls in this case.
                record = try await store.installImported(ticket: ticket)
            }
            importPreviews[ticket] = nil
            return try Self.summary(from: record)
        } catch {
            throw Self.wireError(for: error)
        }
    }

    /// Uninstalls a managed package, retains its data when requested, or forgets its record.
    public func uninstallPackage(
        _ request: RuntimeUninstallPackageRequest
    ) async throws(RuntimeWireError) {
        do {
            try await ensureOpen()
            guard let packageID = PackageID(rawValue: request.packageID.rawValue) else {
                throw EmbeddedPackageServiceFailure.invalidPackageID
            }
            if request.options.forget {
                try await store.forget(packageID: packageID)
            } else {
                try await store.uninstall(packageID: packageID, keepData: request.options.keepData)
            }
        } catch {
            throw Self.wireError(for: error)
        }
    }

    /// Lists managed records, optionally merging Android's current PackageManager inventory.
    public func listPackages(
        _ request: RuntimeListPackagesRequest
    ) async throws(RuntimeWireError) -> [RuntimePackageSummary] {
        do {
            try await ensureOpen()
            let records = try await store.listManagedPackages()
            var packages: [String: RuntimePackageSummary] = [:]
            for record in records {
                packages[record.packageId.rawValue] = try Self.summary(from: record)
            }

            if request.filter == .all {
                guard runtimeAttached else {
                    throw EmbeddedPackageServiceFailure.runtimeNotAttached
                }
                let managedPackages = packages
                packages.removeAll(keepingCapacity: true)
                let guestPackages = try await runtimeAccess.withStoreAgent(UUID()) { channel in
                    try await channel.listPackages(.all)
                }
                for guest in guestPackages {
                    let packageID = guest.packageID.rawValue
                    if var managed = managedPackages[packageID] {
                        // Android is authoritative for the current installed version and label.
                        managed.displayName = guest.displayName
                        managed.versionCode = guest.versionCode
                        managed.state = .installed
                        packages[packageID] = managed
                    } else if let wireID = RuntimePackageID(rawValue: packageID) {
                        packages[packageID] = RuntimePackageSummary(
                            packageID: wireID,
                            displayName: guest.displayName,
                            versionCode: guest.versionCode,
                            state: .installed,
                            managed: false
                        )
                    }
                }
            }
            return packages.values.sorted { $0.packageID < $1.packageID }
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
            guard let record = try await store.listManagedPackages().first(where: { $0.packageId == packageID }) else {
                throw PackageStoreFailure.packageNotFound
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
                artifactBytes: bytes
            )
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

    private func stage(
        _ sources: [RuntimeImportSourceFile],
        from handles: [FileHandle]
    ) throws -> StagedImport {
        guard !sources.isEmpty, sources.count <= Self.maximumAPKCount else {
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
                    guard let chunk = try handles[source.fileIndex].read(upToCount: Self.copyChunkSize),
                        !chunk.isEmpty
                    else {
                        break
                    }
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

    private func relation(for preview: PackageImportPreview) async throws -> RuntimeImportRelation {
        let records = try await store.listManagedPackages()
        guard let record = records.first(where: { $0.packageId == preview.packageID }) else {
            return .newPackage
        }
        if record.state == .uninstalledKeepingData {
            return .uninstalledWithData(record.versionCode)
        }
        if !preview.artifactSet.signerDigests.isEmpty,
            !record.signingCertificates.isEmpty,
            preview.artifactSet.signerDigests != record.signingCertificates
        {
            return .otherSigner
        }
        if preview.versionCode < record.versionCode {
            return .downgrade(from: record.versionCode)
        }
        if preview.versionCode > record.versionCode {
            return .update(from: record.versionCode)
        }
        if preview.artifactSet.setDigest == record.artifacts.current?.setDigest {
            if record.state == .installed {
                return .sameAsInstalled
            }
            return .reinstallSameVersion
        }
        return .reinstallSameVersion
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
            files: try preview.artifactSet.files.map(runtimeArtifact),
            relation: relation,
            warnings: [.signingNotChecked]
        )
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

    private static func wireError(for error: any Error) -> RuntimeWireError {
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
                    remediation: "Check whether the app's data is present in Android before retrying or reinstalling."
                )
            case .operationInProgress:
                return .store(
                    "operationInProgress", message: "Another package operation is already running for this app.",
                    remediation: "Wait for it to finish, then retry.")
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
            case .downgradeReinstallUnavailable:
                return .store(
                    "downgradeUnavailable", message: "This Android image does not support package downgrades.")
            case .journalUnreadable:
                return .store(
                    "journalUnreadable",
                    message: "APKRun's package history is damaged; package changes are disabled.",
                    remediation: "Run `apkrun doctor` and report the store journal problem."
                )
            case .unsupportedJournalVersion(let version):
                return .store(
                    "unsupportedJournalVersion", message: "The package journal uses unsupported version \(version).")
            case .unreadablePackageRecord:
                return .store(
                    "unreadablePackageRecord", message: "A package record could not be read.",
                    remediation: "Run `apkrun doctor` for details.")
            case .io:
                return .store(
                    "storageIO", message: "APKRun could not read or write package data.",
                    remediation: "Check disk space and permissions, then retry.")
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
            case .downgradeRequiresExplicitApproval:
                return .store(
                    "downgradeRequiresApproval", message: "This APK is older than the installed version.",
                    remediation: "Use a package flow that explicitly confirms downgrades.")
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
    case downgradeRequiresExplicitApproval
    case signerMismatch
    case runtimeNotAttached
    case invalidPackageID
    case artifactMetadataUnavailable
}

private actor AttachedStoreRuntimeAccess: StoreRuntimeAccess {
    private var access: (any StoreRuntimeAccess)?

    func attach(_ access: any StoreRuntimeAccess) {
        self.access = access
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
