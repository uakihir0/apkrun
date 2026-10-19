import CryptoKit
import Darwin
import Foundation

/// A preview produced from private copies of one APK or a split APK set.
public struct PackageImportPreview: Codable, Sendable, Equatable {
    /// The durable import-ticket identifier.
    public let ticket: UUID
    /// The Android package name read from the base APK.
    public let packageID: PackageID
    /// The host-preview label from the base APK.
    public let displayName: String
    /// The Android long version code read from the APK set.
    public let versionCode: VersionCode
    /// The display-only Android version name.
    public let versionName: String?
    /// The canonical, content-addressed artifact description.
    public let artifactSet: ArtifactSet
    /// The original file names, without parent paths.
    public let sourceFileNames: [String]
}

/// Failures detected by the package store itself.
public enum PackageStoreFailure: Error, Equatable, Sendable {
    case notOpen
    case invalidImport
    case tooManyImportFiles
    case apkFileTooLarge
    case importSetTooLarge
    case insufficientHostSpace(needed: Int64, available: Int64)
    case invalidSplitSet
    case importPackageMismatch
    case importVersionMismatch
    case duplicateSplitName
    case unsafeSplitName
    case packageAlreadyInstalled
    case packageNotFound
    case uninstallDataUnverified(PackageID)
    case operationInProgress
    case importTicketNotFound
    case importTicketExpired
    case importTicketChanged
    case runtimeUnavailable
    case guestPackageMismatch
    case guestVersionMismatch
    case downgradeReinstallUnavailable
    case unsupportedJournalVersion(Int)
    case journalUnreadable
    case metadataUnreadable(PackageID, detail: String)
    case androidInventoryUnreadable
    case unreadablePackageRecord
    case io
}

/// Owns package artifacts, records, and the transaction journal.
///
/// `packagesDirectory` is the APKRun `Packages/` directory. Supplying it directly keeps tests
/// isolated and lets RuntimeHost use `APKRunPaths` without making APKStoreCore depend on
/// DiagnosticsCore.
public actor PackageStore {
    /// Async host-side APK metadata reader, injected to keep package import testable.
    public typealias Inspector = @Sendable (URL) async throws -> APKFacts

    /// Debug-only transaction hook used by crash-recovery tests and fault injection.
    public typealias FaultInjector = @Sendable (_ kind: String, _ step: String) throws -> Void

    private struct TicketManifest: Codable, Sendable {
        var preview: PackageImportPreview
        var createdAt: Date
        var facts: [PersistedAPKFacts]
        var origin: ImportOrigin?
    }

    private struct PackageIDEnvelope: Decodable {
        var packageId: PackageID
    }

    private struct AndroidInventorySnapshot: Codable, Sendable {
        var schemaVersion: Int
        var observedAt: Date
        var packages: [StorePackageSummary]
    }

    private struct PersistedAPKFacts: Codable, Sendable {
        var packageID: PackageID
        var versionCode: VersionCode
        var versionName: String?
        var splitName: String?
        var displayName: String
        var minSDK: Int
        var targetSDK: Int
        var nativeABIs: [String]

        init(_ facts: APKFacts) {
            packageID = facts.packageID
            versionCode = facts.versionCode
            versionName = facts.versionName
            splitName = facts.splitName
            displayName = facts.displayName
            minSDK = facts.minSDK
            targetSDK = facts.targetSDK
            nativeABIs = facts.nativeABIs
        }

        var apkFacts: APKFacts {
            APKFacts(
                packageID: packageID,
                versionCode: versionCode,
                versionName: versionName,
                splitName: splitName,
                displayName: displayName,
                minSDK: minSDK,
                targetSDK: targetSDK,
                nativeABIs: nativeABIs
            )
        }
    }

    private struct JournalEntry: Codable, Sendable {
        var v: Int
        var seq: Int64
        var txn: String
        var at: Date
        var op: String
        var kind: String?
        var package: String?
        var dir: String?
        var from: VersionCode?
        var to: VersionCode?
        var androidWasInstalled: Bool? = nil
        var androidInstalledVersion: VersionCode? = nil
        var androidLastUpdateTime: Date? = nil
        var setDigest: String?
        var ticket: String?
        var keepData: Bool?
        var step: String?
        var reason: String?
    }

    private struct JournalTransaction: Sendable {
        var begin: JournalEntry
        var lastStep: String?
    }

    private struct JournalReadResult {
        var entries: [JournalEntry]
        var issue: String?
        var isReadOnly: Bool
    }

    private let packagesDirectory: URL
    private let inspector: Inspector
    private let runtimeAccess: (any StoreRuntimeAccess)?
    private let faultInjector: FaultInjector
    private let fileManager: FileManager
    private let clock: @Sendable () -> Date
    private let hostFreeSpace: @Sendable (URL) -> Int64

    private var importsLockURL: URL {
        packagesDirectory.appendingPathComponent(".imports.lock")
    }

    private var mutationLockURL: URL {
        packagesDirectory.appendingPathComponent(".mutation.lock")
    }

    private var records: [PackageID: PackageRecord] = [:]
    private var directories: [PackageID: String] = [:]
    private var unreadableRecords: [PackageID: String] = [:]
    private var tickets: [UUID: TicketManifest] = [:]
    private var activeTickets = Set<UUID>()
    private var transactions: [String: JournalTransaction] = [:]
    private var operationsInProgress = Set<PackageID>()
    private var sequence: Int64 = 0
    private var opened = false
    private var isReadOnly = false

    /// Creates a store rooted at a caller-selected `Packages/` directory.
    public init(
        packagesDirectory: URL,
        runtimeAccess: (any StoreRuntimeAccess)? = nil,
        inspector: @escaping Inspector = { apk in try await APKInspector().inspect(apk) },
        fileManager: FileManager = .default,
        clock: @escaping @Sendable () -> Date = { Date() },
        hostFreeSpace: (@Sendable (URL) -> Int64)? = nil,
        faultInjector: FaultInjector? = nil
    ) {
        self.packagesDirectory = packagesDirectory
        self.runtimeAccess = runtimeAccess
        self.inspector = inspector
        self.fileManager = fileManager
        self.clock = clock
        self.hostFreeSpace = hostFreeSpace ?? { Self.availableHostSpace($0) }
        self.faultInjector = faultInjector ?? Self.environmentFaultInjector
    }

    /// The readable journal issue found during the last `open()`, such as a torn final line.
    public private(set) var journalIssue: String?

    /// Loads records, recovers host-only operations, and restores unexpired import tickets.
    public func open() async throws {
        try createDirectory(packagesDirectory)

        let importsLock = try await acquireLock(at: importsLockURL)
        defer { _ = Darwin.close(importsLock) }
        let mutationLock = try await acquireLock(at: mutationLockURL)
        defer { _ = Darwin.close(mutationLock) }

        let journal = try withJournalLock { try readJournal() }
        sequence = journal.entries.last?.seq ?? 0
        journalIssue = journal.issue
        isReadOnly = journal.isReadOnly
        transactions = Self.transactions(from: journal.entries)
        if !isReadOnly {
            try createDirectory(trashDirectory)
        }
        try loadRecords()
        if !isReadOnly {
            try recoverHostOnlyTransactions()
            try loadRecords()
            try loadTicketsAndCleanScratch()
        }
        opened = true
    }

    /// Copies, hashes, and inspects APK inputs without starting Android.
    ///
    /// Each source is copied into a private temporary directory before inspection. The returned
    /// ticket refers only to the private incoming set, so callers may release their source files.
    public func importPackage(
        files: [URL],
        origin: ImportOrigin? = nil
    ) async throws -> PackageImportPreview {
        try requireWritable()
        let importsLock = try await acquireLock(at: importsLockURL)
        defer { _ = Darwin.close(importsLock) }
        guard !files.isEmpty else { throw PackageStoreFailure.invalidImport }
        guard files.count <= Self.maximumAPKCount else {
            throw PackageStoreFailure.tooManyImportFiles
        }

        var expectedSourceBytes: Int64 = 0
        for source in files {
            guard source.isFileURL,
                let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true,
                let fileSize = values.fileSize,
                fileSize > 0
            else {
                throw PackageStoreFailure.invalidImport
            }
            guard Int64(fileSize) <= Self.maximumAPKFileSize else {
                throw PackageStoreFailure.apkFileTooLarge
            }
            let (sum, overflow) = expectedSourceBytes.addingReportingOverflow(Int64(fileSize))
            guard !overflow, sum <= Self.maximumImportSetSize else {
                throw PackageStoreFailure.importSetTooLarge
            }
            expectedSourceBytes = sum
        }
        try requireHostSpace(for: expectedSourceBytes * 2 + Self.importSpaceReserve)

        let ticket = UUID()
        let scratch =
            packagesDirectory
            .appendingPathComponent(".imports", isDirectory: true)
            .appendingPathComponent(ticket.uuidString, isDirectory: true)
        try createDirectory(scratch)
        defer { try? fileManager.removeItem(at: scratch) }

        var stagedURLs: [URL] = []
        var sourceNames: [String] = []
        var copiedSourceBytes: Int64 = 0
        for (index, source) in files.enumerated() {
            let safeName = Self.safeSourceFileName(source.lastPathComponent)
            let destination = scratch.appendingPathComponent("input-\(index).apk")
            do {
                let copiedBytesBeforeFile = copiedSourceBytes
                let remainingExpected = max(0, expectedSourceBytes - copiedBytesBeforeFile)
                try copyBoundedFile(
                    from: source,
                    to: destination,
                    maximumBytes: Self.maximumAPKFileSize,
                    totalBytesAlreadyCopied: copiedSourceBytes,
                    totalBytesLimit: Self.maximumImportSetSize,
                    requiredFreeSpaceAfterWrite: { copiedAfterWrite in
                        let copiedFromThisFile = copiedAfterWrite - copiedBytesBeforeFile
                        let unstagedExpected = max(0, remainingExpected - copiedFromThisFile)
                        let stagedSetEstimate = max(expectedSourceBytes, copiedAfterWrite + unstagedExpected)
                        return unstagedExpected + stagedSetEstimate + Self.importSpaceReserve
                    },
                    didCopy: { copied in
                        copiedSourceBytes += copied
                    }
                )
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            } catch let failure as PackageStoreFailure {
                throw failure
            } catch {
                throw PackageStoreFailure.io
            }
            stagedURLs.append(destination)
            sourceNames.append(safeName)
        }

        var facts: [APKFacts] = []
        for stagedURL in stagedURLs {
            facts.append(try await inspector(stagedURL))
        }
        let baseFacts = try Self.validateSplitFacts(facts)
        let mutationLock = try await acquireLock(at: mutationLockURL)
        defer { _ = Darwin.close(mutationLock) }
        try reloadRecordsPreservingImportDirectories()
        if let detail = unreadableRecords[baseFacts.packageID] {
            throw PackageStoreFailure.metadataUnreadable(baseFacts.packageID, detail: detail)
        }
        let packageDirectoryName = directoryName(for: baseFacts.packageID)
        let packageDirectory = packagesDirectory.appendingPathComponent(packageDirectoryName, isDirectory: true)
        let incoming =
            packageDirectory
            .appendingPathComponent("incoming", isDirectory: true)
            .appendingPathComponent(ticket.uuidString, isDirectory: true)
        try requireHostSpace(for: copiedSourceBytes + Self.importSpaceReserve)
        try createDirectory(incoming)
        directories[baseFacts.packageID] = packageDirectoryName

        var artifactFiles: [ArtifactFile] = []
        let ordered = zip(stagedURLs, facts).sorted { lhs, rhs in
            switch (lhs.1.splitName, rhs.1.splitName) {
            case (nil, .some): return true
            case (.some, nil): return false
            case (nil, nil): return false
            case (.some(let lhs), .some(let rhs)): return lhs < rhs
            }
        }
        do {
            for (sourceURL, itemFacts) in ordered {
                let name: String
                if let splitName = itemFacts.splitName {
                    guard Self.isSafeSplitName(splitName) else {
                        throw PackageStoreFailure.unsafeSplitName
                    }
                    name = "split_\(splitName).apk"
                } else {
                    name = "base.apk"
                }
                let destination = incoming.appendingPathComponent(name)
                try copyBoundedFile(
                    from: sourceURL,
                    to: destination,
                    maximumBytes: Self.maximumAPKFileSize,
                    totalBytesAlreadyCopied: artifactFiles.reduce(Int64(0)) { $0 + $1.size },
                    totalBytesLimit: Self.maximumImportSetSize,
                    requiredFreeSpaceAfterWrite: { copiedAfterWrite in
                        let pendingBytes = max(0, copiedSourceBytes - copiedAfterWrite)
                        return pendingBytes + Self.importSpaceReserve
                    }
                )
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                let (size, digest) = try Self.hashFile(at: destination)
                artifactFiles.append(
                    ArtifactFile(name: name, splitName: itemFacts.splitName, size: size, sha256: digest)
                )
            }
        } catch let failure as PackageStoreFailure {
            try? fileManager.removeItem(at: incoming)
            throw failure
        } catch {
            try? fileManager.removeItem(at: incoming)
            throw PackageStoreFailure.io
        }
        artifactFiles.sort {
            if $0.splitName == nil { return true }
            if $1.splitName == nil { return false }
            return ($0.splitName ?? "") < ($1.splitName ?? "")
        }

        let digest: SHA256Digest
        do {
            digest = try ArtifactSet.computeSetDigest(for: artifactFiles)
        } catch {
            try? fileManager.removeItem(at: incoming)
            throw PackageStoreFailure.invalidSplitSet
        }
        let artifactSet = ArtifactSet(
            packageID: baseFacts.packageID,
            versionCode: baseFacts.versionCode,
            versionName: baseFacts.versionName,
            files: artifactFiles,
            setDigest: digest,
            signerDigests: [],
            lineage: [],
            inspection: InspectionProvenance(
                aapt2Version: "unknown",
                verifierVersion: "apk-inspector-v0",
                inspectedAt: clock(),
                hostChecksPerformed: [
                    "packageMetadata",
                    "versionCode",
                    "splitSet",
                    "sha256",
                    "signature:notPerformed",
                ]
            )
        )
        let preview = PackageImportPreview(
            ticket: ticket,
            packageID: baseFacts.packageID,
            displayName: baseFacts.displayName,
            versionCode: baseFacts.versionCode,
            versionName: baseFacts.versionName,
            artifactSet: artifactSet,
            sourceFileNames: sourceNames
        )
        let manifest = TicketManifest(
            preview: preview,
            createdAt: clock(),
            facts: facts.map(PersistedAPKFacts.init),
            origin: origin
        )
        do {
            try writeJSON(manifest, to: incoming.appendingPathComponent("ticket.json"))
            try writeJSON(artifactSet, to: incoming.appendingPathComponent("artifact.json"))
        } catch {
            try? fileManager.removeItem(at: incoming)
            throw PackageStoreFailure.io
        }
        tickets[ticket] = manifest
        activeTickets.insert(ticket)
        return preview
    }

    /// Installs a new package or reinstalls a retained-data package from an import ticket.
    public func installImported(ticket: UUID) async throws -> PackageRecord {
        try requireWritable()
        guard let manifest = try verifiedTicket(ticket) else {
            throw PackageStoreFailure.importTicketNotFound
        }
        if let existing = records[manifest.preview.packageID] {
            guard existing.state == .uninstalledKeepingData else {
                throw PackageStoreFailure.packageAlreadyInstalled
            }
            return try await performInstall(manifest, kind: "reinstall", from: existing.versionCode)
        }
        return try await performInstall(manifest, kind: "firstInstall", from: nil)
    }

    /// Reinstalls the package in a ticket over its current version.
    public func reinstall(ticket: UUID, allowDowngrade: Bool = false) async throws -> PackageRecord {
        try requireWritable()
        guard let manifest = try verifiedTicket(ticket) else {
            throw PackageStoreFailure.importTicketNotFound
        }
        guard let existing = records[manifest.preview.packageID] else {
            throw PackageStoreFailure.packageNotFound
        }
        guard Self.canReinstall(existing.state) else {
            throw PackageStoreFailure.packageNotFound
        }
        return try await performInstall(
            manifest,
            kind: "reinstall",
            from: existing.versionCode,
            allowDowngrade: allowDowngrade
        )
    }

    /// Uninstalls a package, optionally retaining its Android app data and package record.
    public func uninstall(packageID: PackageID, keepData: Bool = false) async throws {
        try requireWritable()
        guard let runtimeAccess else { throw PackageStoreFailure.runtimeUnavailable }
        guard operationsInProgress.insert(packageID).inserted else {
            throw PackageStoreFailure.operationInProgress
        }
        defer { operationsInProgress.remove(packageID) }

        let mutationLock = try await acquireLock(at: mutationLockURL)
        defer { _ = Darwin.close(mutationLock) }
        try reloadRecordsPreservingImportDirectories()
        if let detail = unreadableRecords[packageID] {
            throw PackageStoreFailure.metadataUnreadable(packageID, detail: detail)
        }
        guard let record = records[packageID] else { throw PackageStoreFailure.packageNotFound }

        let operation = UUID()
        let transaction = Self.makeTransactionID(at: clock())
        let directory = directories[packageID] ?? directoryName(for: packageID)
        try append(
            JournalEntry(
                v: 1,
                seq: 0,
                txn: transaction,
                at: clock(),
                op: "begin",
                kind: "uninstall",
                package: packageID.rawValue,
                dir: directory,
                from: record.versionCode,
                to: nil,
                androidWasInstalled: nil,
                androidInstalledVersion: nil,
                androidLastUpdateTime: nil,
                setDigest: record.artifacts.current?.setDigest.rawValue,
                ticket: nil,
                keepData: keepData,
                step: nil,
                reason: nil
            )
        )
        try injectFault(kind: "uninstall", step: "begin")
        try appendStep(transaction, kind: "uninstall", step: "guestUninstallRequested")
        do {
            try await runtimeAccess.withStoreAgent(operation) { channel in
                try await channel.uninstall(packageID, keepData: keepData)
            }
        } catch let uninstallFailure {
            let guestPackage: StorePackageInfo?
            do {
                guestPackage = try await queryPackage(packageID, through: runtimeAccess)
            } catch {
                // Leave the guest request pending when the runtime cannot answer.
                throw uninstallFailure
            }
            if guestPackage == nil {
                try appendAbort(transaction, reason: "uninstallDataUnverified")
                throw PackageStoreFailure.uninstallDataUnverified(packageID)
            }
            try appendAbort(transaction, reason: "guestUninstallFailed")
            throw uninstallFailure
        }
        try injectFault(kind: "uninstall", step: "guestUninstallRequested")
        try appendStep(transaction, kind: "uninstall", step: "guestUninstalled")
        try injectFault(kind: "uninstall", step: "guestUninstalled")
        try finishUninstall(
            transaction: transaction,
            packageID: packageID,
            directory: directory,
            keepData: keepData
        )
    }

    /// Removes APKRun's record and artifacts without issuing an Android uninstall.
    public func forget(packageID: PackageID) async throws {
        try requireWritable()
        guard operationsInProgress.insert(packageID).inserted else {
            throw PackageStoreFailure.operationInProgress
        }
        defer { operationsInProgress.remove(packageID) }

        let mutationLock = try await acquireLock(at: mutationLockURL)
        defer { _ = Darwin.close(mutationLock) }
        try reloadJournalState()
        guard !isReadOnly else { throw PackageStoreFailure.journalUnreadable }
        try reloadRecordsPreservingImportDirectories()
        if let detail = unreadableRecords[packageID] {
            throw PackageStoreFailure.metadataUnreadable(packageID, detail: detail)
        }
        guard records[packageID] != nil else { throw PackageStoreFailure.packageNotFound }

        let resolvesUnverifiedUninstall = !ambiguousUninstallTransactionIDs(for: packageID).isEmpty

        let transaction = Self.makeTransactionID(at: clock())
        let directory = directories[packageID] ?? directoryName(for: packageID)
        try append(
            JournalEntry(
                v: 1,
                seq: 0,
                txn: transaction,
                at: clock(),
                op: "begin",
                kind: "forget",
                package: packageID.rawValue,
                dir: directory,
                from: nil,
                to: nil,
                setDigest: nil,
                ticket: nil,
                keepData: nil,
                step: nil,
                reason: resolvesUnverifiedUninstall ? Self.forgetResolutionIntent : nil
            )
        )
        try injectFault(kind: "forget", step: "begin")
        if resolvesUnverifiedUninstall {
            try resolveAmbiguousUninstallTransactions(for: packageID)
            try injectFault(kind: "forget", step: "uninstallOutcomesResolved")
        }
        try finishForget(transaction: transaction, packageID: packageID, directory: directory, injectFaults: true)
    }

    /// Resolves guest-dependent transactions left by an interrupted process.
    ///
    /// This is deliberately separate from `open()`: opening the store remains usable without
    /// booting Android. RuntimeHost calls this after it has a ready Guest Agent.
    public func recoverPendingTransactions() async throws {
        try requireWritable()
        let mutationLock = try await acquireLock(at: mutationLockURL)
        defer { _ = Darwin.close(mutationLock) }
        try reloadJournalState()
        try reloadRecordsPreservingImportDirectories()
        guard !isReadOnly else { throw PackageStoreFailure.journalUnreadable }
        guard let runtimeAccess else {
            if transactions.values.contains(where: Self.needsGuestRecovery) {
                throw PackageStoreFailure.runtimeUnavailable
            }
            return
        }

        let pending = transactions.sorted { lhs, rhs in
            (lhs.value.begin.seq, lhs.key) < (rhs.value.begin.seq, rhs.key)
        }
        for (transactionID, transaction) in pending {
            guard let kind = transaction.begin.kind,
                let rawPackage = transaction.begin.package,
                let packageID = PackageID(rawValue: rawPackage),
                let directory = transaction.begin.dir
            else {
                continue
            }

            switch (kind, transaction.lastStep) {
            case ("firstInstall", "guestCommitRequested"), ("reinstall", "guestCommitRequested"),
                ("firstInstall", "guestInstalled"), ("reinstall", "guestInstalled"),
                ("firstInstall", "filesPromoted"), ("reinstall", "filesPromoted"):
                let info = try await queryPackage(packageID, through: runtimeAccess)
                guard let info, info.packageID == packageID, info.versionCode == transaction.begin.to else {
                    if transaction.lastStep == "guestInstalled" {
                        continue
                    }
                    try appendAbort(transactionID, reason: "guestVersionDidNotCommit")
                    if kind == "firstInstall", let ticket = transaction.begin.ticket.flatMap(UUID.init(uuidString:)) {
                        removeIncoming(ticket: ticket, packageID: packageID, directory: directory)
                    }
                    continue
                }
                if transaction.lastStep == "guestCommitRequested" {
                    guard Self.installCommitIsVisible(begin: transaction.begin, current: info) else {
                        if Self.packageMatchesPreInstallSnapshot(begin: transaction.begin, current: info) {
                            try appendAbort(transactionID, reason: "guestInstallDidNotCommit")
                            if kind == "firstInstall",
                                let ticket = transaction.begin.ticket.flatMap(UUID.init(uuidString:))
                            {
                                removeIncoming(ticket: ticket, packageID: packageID, directory: directory)
                            }
                        }
                        // Keep an ambiguous outcome pending. A matching package and version do
                        // not prove that this transaction installed the incoming APK set.
                        continue
                    }
                    try appendStep(transactionID, kind: kind, step: "guestInstalled", versionCode: info.versionCode)
                }
                try finishInstallRecovery(
                    transaction: transactionID,
                    kind: kind,
                    packageID: packageID,
                    directory: directory,
                    info: info,
                    ticket: transaction.begin.ticket.flatMap(UUID.init(uuidString:)),
                    userdataGeneration: await runtimeAccess.userdataGeneration() ?? UUID()
                )

            case ("uninstall", "guestUninstallRequested"):
                let info = try await queryPackage(packageID, through: runtimeAccess)
                if info != nil {
                    try appendAbort(transactionID, reason: "packageStillInstalled")
                } else {
                    // PackageManager absence cannot establish whether app data survived an
                    // interrupted uninstall. Keep the transaction, record, and APKs intact.
                    // Continue other recovery so PackageManager inventory remains inspectable;
                    // an explicit host-side forget can close this transaction without claiming
                    // the app-data outcome.
                    continue
                }

            case ("uninstall", "guestUninstalled"):
                try finishUninstall(
                    transaction: transactionID,
                    packageID: packageID,
                    directory: directory,
                    keepData: transaction.begin.keepData ?? false
                )

            case ("firstInstall", "metadataWritten"), ("reinstall", "metadataWritten"):
                try appendTerminal(transactionID, op: "commit")
                if let ticket = transaction.begin.ticket.flatMap(UUID.init(uuidString:)) {
                    tickets[ticket] = nil
                }
                try purgeTrash()

            default:
                continue
            }
        }
    }

    /// Returns the current managed records in package-name order.
    public func listManagedPackages() async throws -> [PackageRecord] {
        try requireOpen()
        let mutationLock = try await acquireLock(at: mutationLockURL)
        defer { _ = Darwin.close(mutationLock) }
        try reloadRecordsPreservingImportDirectories()
        return records.values.sorted { $0.packageId < $1.packageId }
    }

    /// Returns unreadable package metadata without making healthy records unavailable.
    public func listPackageRecordIssues() async throws -> [PackageRecordIssue] {
        try requireOpen()
        let mutationLock = try await acquireLock(at: mutationLockURL)
        defer { _ = Darwin.close(mutationLock) }
        try reloadRecordsPreservingImportDirectories()
        return unreadableRecords.map { PackageRecordIssue(packageID: $0.key, detail: $0.value) }
            .sorted { $0.packageID < $1.packageID }
    }

    /// Returns the metadata issue for one package, if its record is unreadable.
    public func packageRecordIssue(for packageID: PackageID) async throws -> PackageRecordIssue? {
        try requireOpen()
        let mutationLock = try await acquireLock(at: mutationLockURL)
        defer { _ = Darwin.close(mutationLock) }
        try reloadRecordsPreservingImportDirectories()
        guard let detail = unreadableRecords[packageID] else { return nil }
        return PackageRecordIssue(packageID: packageID, detail: detail)
    }

    /// Returns the last Android package inventory observed by a live runtime.
    public func lastKnownAndroidInventory() async throws -> StoreAndroidInventorySnapshot? {
        try requireOpen()
        let mutationLock = try await acquireLock(at: mutationLockURL)
        defer { _ = Darwin.close(mutationLock) }
        guard fileManager.fileExists(atPath: androidInventoryURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: androidInventoryURL)
            let snapshot = try Self.decoder().decode(AndroidInventorySnapshot.self, from: data)
            guard snapshot.schemaVersion == 1 else {
                throw PackageStoreFailure.androidInventoryUnreadable
            }
            return StoreAndroidInventorySnapshot(observedAt: snapshot.observedAt, packages: snapshot.packages)
        } catch let failure as PackageStoreFailure {
            throw failure
        } catch {
            throw PackageStoreFailure.androidInventoryUnreadable
        }
    }

    /// Persists a live Android package inventory for use while the runtime is stopped.
    public func saveLastKnownAndroidInventory(
        _ packages: [StorePackageSummary]
    ) async throws -> StoreAndroidInventorySnapshot {
        try requireOpen()
        var uniquePackages: [PackageID: StorePackageSummary] = [:]
        for package in packages {
            uniquePackages[package.packageID] = package
        }
        let snapshot = StoreAndroidInventorySnapshot(
            observedAt: clock(),
            packages: uniquePackages.values.sorted { $0.packageID < $1.packageID }
        )
        guard !isReadOnly else { return snapshot }
        let mutationLock = try await acquireLock(at: mutationLockURL)
        defer { _ = Darwin.close(mutationLock) }
        try writeJSON(
            AndroidInventorySnapshot(
                schemaVersion: 1,
                observedAt: snapshot.observedAt,
                packages: snapshot.packages
            ),
            to: androidInventoryURL
        )
        return snapshot
    }

    private var journalURL: URL {
        packagesDirectory.appendingPathComponent("journal.jsonl")
    }

    private var androidInventoryURL: URL {
        packagesDirectory.appendingPathComponent("android-inventory.json")
    }

    private var journalLockURL: URL {
        packagesDirectory.appendingPathComponent(".journal.lock")
    }

    private var trashDirectory: URL {
        packagesDirectory.appendingPathComponent(".trash", isDirectory: true)
    }

    private func performInstall(
        _ manifest: TicketManifest,
        kind: String,
        from: VersionCode?,
        allowDowngrade: Bool = false
    ) async throws -> PackageRecord {
        guard let runtimeAccess else { throw PackageStoreFailure.runtimeUnavailable }
        let preview = manifest.preview
        let packageID = preview.packageID
        guard operationsInProgress.insert(packageID).inserted else {
            throw PackageStoreFailure.operationInProgress
        }
        defer { operationsInProgress.remove(packageID) }
        let mutationLock = try await acquireLock(at: mutationLockURL)
        defer { _ = Darwin.close(mutationLock) }
        try reloadRecordsPreservingImportDirectories()
        if let detail = unreadableRecords[packageID] {
            throw PackageStoreFailure.metadataUnreadable(packageID, detail: detail)
        }
        let directory = directories[packageID] ?? directoryName(for: packageID)
        let incoming = incomingDirectory(packageID: packageID, directory: directory, ticket: preview.ticket)
        let current =
            packagesDirectory
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent("current", isDirectory: true)
        guard fileManager.fileExists(atPath: incoming.appendingPathComponent("artifact.json").path) else {
            throw PackageStoreFailure.importTicketNotFound
        }

        if kind == "firstInstall", records[packageID] != nil {
            throw PackageStoreFailure.packageAlreadyInstalled
        }
        if kind == "reinstall" {
            guard let existing = records[packageID],
                existing.state == .uninstalledKeepingData || Self.canReinstall(existing.state)
            else {
                throw PackageStoreFailure.packageNotFound
            }
            guard from == existing.versionCode else {
                throw PackageStoreFailure.guestVersionMismatch
            }
        }
        if let from, preview.versionCode < from, !allowDowngrade {
            throw PackageStoreFailure.guestVersionMismatch
        }

        let operationID = UUID()
        let previouslyInstalled = try await runtimeAccess.withStoreAgent(operationID) { channel in
            try await channel.packageInfo(packageID)
        }
        let transaction = Self.makeTransactionID(at: clock())
        let startedAt = clock()
        try append(
            JournalEntry(
                v: 1,
                seq: 0,
                txn: transaction,
                at: startedAt,
                op: "begin",
                kind: kind,
                package: packageID.rawValue,
                dir: directory,
                from: from,
                to: preview.versionCode,
                androidWasInstalled: previouslyInstalled != nil,
                androidInstalledVersion: previouslyInstalled?.versionCode,
                androidLastUpdateTime: previouslyInstalled?.lastUpdateTime,
                setDigest: preview.artifactSet.setDigest.rawValue,
                ticket: preview.ticket.uuidString,
                keepData: nil,
                step: nil,
                reason: nil
            )
        )
        try injectFault(kind: kind, step: "begin")
        try appendStep(transaction, kind: kind, step: "guestCommitRequested")
        try injectFault(kind: kind, step: "guestCommitRequested")

        let info: StorePackageInfo
        do {
            info = try await runtimeAccess.withStoreAgent(operationID) { channel in
                if allowDowngrade, let from, preview.versionCode < from,
                    !channel.capabilities.contains(.downgradeReinstall)
                {
                    throw PackageStoreFailure.downgradeReinstallUnavailable
                }
                return try await channel.install(
                    StoreInstallRequest(
                        packageID: packageID,
                        versionCode: preview.versionCode,
                        allowDowngrade: allowDowngrade
                    ),
                    files: Self.artifactURLs(in: incoming, set: preview.artifactSet)
                )
            }
        } catch {
            var committedInfo: StorePackageInfo?
            do {
                committedInfo = try await queryPackage(packageID, through: runtimeAccess)
            } catch {
                // The guest may have committed. Keep the journal and incoming artifacts so a
                // later recovery can query PackageManager and roll the host forward.
                throw error
            }
            if let committedInfo,
                committedInfo.packageID == packageID,
                committedInfo.versionCode == preview.versionCode,
                Self.installCommitIsVisible(
                    previouslyInstalled: previouslyInstalled,
                    current: committedInfo
                )
            {
                info = committedInfo
            } else if Self.packageMatchesPreInstallSnapshot(
                previouslyInstalled: previouslyInstalled,
                current: committedInfo
            ) || committedInfo?.versionCode != preview.versionCode {
                try appendAbort(transaction, reason: "guestInstallFailed")
                if kind == "firstInstall" {
                    removeIncoming(ticket: preview.ticket, packageID: packageID, directory: directory)
                }
                throw error
            } else {
                // A matching version alone cannot prove that an install committed: Android may
                // already have had an unmanaged package with that version. Keep the journal and
                // incoming APKs so a later PackageManager snapshot can resolve the transaction.
                throw error
            }
        }
        guard info.packageID == packageID else {
            try appendAbort(transaction, reason: "guestPackageMismatch")
            throw PackageStoreFailure.guestPackageMismatch
        }
        guard info.versionCode == preview.versionCode else {
            try appendAbort(transaction, reason: "guestVersionMismatch")
            throw PackageStoreFailure.guestVersionMismatch
        }
        try appendStep(transaction, kind: kind, step: "guestInstalled", versionCode: info.versionCode)
        try injectFault(kind: kind, step: "guestInstalled")

        try promoteIncoming(incoming: incoming, current: current, transaction: transaction, kind: kind)
        try appendStep(transaction, kind: kind, step: "filesPromoted")
        try injectFault(kind: kind, step: "filesPromoted")

        let generation = await runtimeAccess.userdataGeneration() ?? UUID()
        let record = makeRecord(
            manifest: manifest,
            info: info,
            generation: generation,
            existing: records[packageID],
            operationID: operationID,
            startedAt: startedAt,
            kind: kind
        )
        try writeRecord(record, directory: directory)
        try appendStep(transaction, kind: kind, step: "metadataWritten")
        try injectFault(kind: kind, step: "metadataWritten")
        try appendTerminal(transaction, op: "commit")
        try abortSupersededInstallTransactions(
            packageID: packageID,
            versionCode: preview.versionCode,
            setDigest: preview.artifactSet.setDigest,
            excluding: transaction
        )
        records[packageID] = record
        directories[packageID] = directory
        tickets[preview.ticket] = nil
        activeTickets.remove(preview.ticket)
        try? fileManager.removeItem(at: current.appendingPathComponent("ticket.json"))
        try injectFault(kind: kind, step: "commit")
        try purgeTrash()
        return record
    }

    private static func canReinstall(_ state: PackageState) -> Bool {
        switch state {
        case .installed, .needsReinstall(.userdataReset), .needsReinstall(.userdataRestored):
            return true
        case .broken(.removedInAndroid), .broken(.artifactMissing), .broken(.reinstallFailed):
            return true
        case .uninstalledKeepingData, .broken(.signerChanged):
            return false
        }
    }

    private func finishInstallRecovery(
        transaction: String,
        kind: String,
        packageID: PackageID,
        directory: String,
        info: StorePackageInfo,
        ticket ticketID: UUID?,
        userdataGeneration: UUID
    ) throws {
        let current =
            packagesDirectory
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent("current", isDirectory: true)
        guard let ticketID, let manifest = tickets[ticketID] else {
            // Same-version recovery without an incoming ticket can retain the existing current set.
            if kind == "reinstall",
                let currentRecord = records[packageID],
                currentRecord.versionCode == info.versionCode
            {
                let recovered = recordAfterGuestInstall(
                    currentRecord,
                    info: info,
                    generation: userdataGeneration,
                    operationID: UUID(),
                    startedAt: transactions[transaction]?.begin.at ?? clock(),
                    kind: kind,
                    setSummary: currentRecord.artifacts.current
                )
                try writeRecord(recovered, directory: directory)
                try appendStep(transaction, kind: kind, step: "metadataWritten")
                try appendTerminal(transaction, op: "commit")
                records[packageID] = recovered
                directories[packageID] = directory
                try? fileManager.removeItem(at: current.appendingPathComponent("ticket.json"))
            } else if kind == "firstInstall" {
                try appendAbort(transaction, reason: "incomingArtifactsMissing")
            }
            return
        }
        let incoming = incomingDirectory(packageID: packageID, directory: directory, ticket: ticketID)
        if fileManager.fileExists(atPath: incoming.path) {
            try promoteIncoming(incoming: incoming, current: current, transaction: transaction, kind: kind)
        } else {
            let artifactURL = current.appendingPathComponent("artifact.json")
            guard let data = try? Data(contentsOf: artifactURL),
                let promoted = try? Self.decoder().decode(ArtifactSet.self, from: data),
                promoted.packageID == manifest.preview.artifactSet.packageID,
                promoted.versionCode == manifest.preview.artifactSet.versionCode,
                promoted.setDigest == manifest.preview.artifactSet.setDigest
            else {
                throw PackageStoreFailure.importTicketNotFound
            }
        }
        if transactions[transaction]?.lastStep != "filesPromoted" {
            try appendStep(transaction, kind: kind, step: "filesPromoted")
        }
        let old = records[packageID]
        let recovered = makeRecord(
            manifest: manifest,
            info: info,
            generation: userdataGeneration,
            existing: old,
            operationID: UUID(),
            startedAt: transactions[transaction]?.begin.at ?? clock(),
            kind: kind
        )
        try writeRecord(recovered, directory: directory)
        try appendStep(transaction, kind: kind, step: "metadataWritten")
        try appendTerminal(transaction, op: "commit")
        try abortSupersededInstallTransactions(
            packageID: packageID,
            versionCode: manifest.preview.versionCode,
            setDigest: manifest.preview.artifactSet.setDigest,
            excluding: transaction
        )
        records[packageID] = recovered
        directories[packageID] = directory
        tickets[ticketID] = nil
        try? fileManager.removeItem(at: current.appendingPathComponent("ticket.json"))
        try purgeTrash()
    }

    private func finishUninstall(
        transaction: String,
        packageID: PackageID,
        directory: String,
        keepData: Bool
    ) throws {
        let packageDirectory = packagesDirectory.appendingPathComponent(directory, isDirectory: true)
        if keepData {
            let currentRecord = records[packageID]
            for slot in ["current", "previous", "staged"] {
                let source = packageDirectory.appendingPathComponent(slot, isDirectory: true)
                let target = trashDirectory.appendingPathComponent("\(transaction)-\(slot)", isDirectory: true)
                if fileManager.fileExists(atPath: source.path), !fileManager.fileExists(atPath: target.path) {
                    try moveItem(source, to: target)
                }
            }
            if transactions[transaction]?.lastStep != "filesRemoved" {
                try appendStep(transaction, kind: "uninstall", step: "filesRemoved")
            }
            guard var record = currentRecord else {
                try appendAbort(transaction, reason: "packageRecordMissing")
                return
            }
            record.state = .uninstalledKeepingData
            record.artifacts = ArtifactSlots(currentMatchesAndroid: false)
            record.updatedAt = clock()
            record.lastOperation = OperationSummary(
                kind: .uninstall,
                operationID: UUID(),
                startedAt: transactions[transaction]?.begin.at ?? clock(),
                finishedAt: clock(),
                fromVersionCode: record.versionCode,
                result: .succeeded
            )
            try writeRecord(record, directory: directory)
            records[packageID] = record
            if transactions[transaction]?.lastStep != "metadataWritten" {
                try appendStep(transaction, kind: "uninstall", step: "metadataWritten")
            }
        } else {
            let target = trashDirectory.appendingPathComponent("\(transaction)-package", isDirectory: true)
            if fileManager.fileExists(atPath: packageDirectory.path), !fileManager.fileExists(atPath: target.path) {
                try moveItem(packageDirectory, to: target)
            }
            if transactions[transaction]?.lastStep != "filesRemoved" {
                try appendStep(transaction, kind: "uninstall", step: "filesRemoved")
            }
            records[packageID] = nil
            directories[packageID] = nil
            if transactions[transaction]?.lastStep != "recordRemoved" {
                try appendStep(transaction, kind: "uninstall", step: "recordRemoved")
            }
        }
        try injectFault(kind: "uninstall", step: "filesRemoved")
        try appendTerminal(transaction, op: "commit")
        try purgeTrash()
    }

    private func makeRecord(
        manifest: TicketManifest,
        info: StorePackageInfo,
        generation: UUID,
        existing: PackageRecord?,
        operationID: UUID,
        startedAt: Date,
        kind: String
    ) -> PackageRecord {
        let set = manifest.preview.artifactSet
        let summary = ArtifactSlotSummary(
            versionCode: set.versionCode,
            versionName: set.versionName,
            setDigest: set.setDigest,
            size: set.files.reduce(0) { $0 + $1.size },
            fileCount: set.files.count
        )
        let android = AndroidPackageFacts(
            installerOfRecord: info.installerPackage,
            firstInstallTime: info.firstInstallTime,
            lastUpdateTime: info.lastUpdateTime,
            minSdk: info.minSDK,
            targetSdk: info.targetSDK,
            nativeAbis: manifest.facts.first(where: { $0.splitName == nil })?.nativeABIs ?? [],
            userdataGeneration: generation,
            lastSyncedAt: clock()
        )
        return PackageRecord(
            packageId: set.packageID,
            displayName: info.displayName,
            versionCode: info.versionCode,
            versionName: info.versionName,
            signingCertificates: info.signingDigests,
            signingLineage: [],
            installer: .apkrun,
            updateAuthority: .manual,
            state: .installed,
            artifacts: ArtifactSlots(current: summary, currentMatchesAndroid: true),
            android: android,
            source: existing?.source
                ?? PackageSource(
                    kind: .file,
                    at: startedAt,
                    origin: manifest.origin,
                    fileNames: manifest.preview.sourceFileNames,
                    container: .apk
                ),
            lastOperation: OperationSummary(
                kind: kind == "reinstall" ? .reinstall : .firstInstall,
                operationID: operationID,
                startedAt: startedAt,
                finishedAt: clock(),
                fromVersionCode: existing?.versionCode,
                toVersionCode: info.versionCode,
                result: .succeeded
            ),
            createdAt: existing?.createdAt ?? startedAt,
            updatedAt: clock()
        )
    }

    private func recordAfterGuestInstall(
        _ old: PackageRecord,
        info: StorePackageInfo,
        generation: UUID,
        operationID: UUID,
        startedAt: Date,
        kind: String,
        setSummary: ArtifactSlotSummary?
    ) -> PackageRecord {
        var record = old
        record.displayName = info.displayName
        record.versionCode = info.versionCode
        record.versionName = info.versionName
        record.signingCertificates = info.signingDigests
        record.state = .installed
        record.artifacts = ArtifactSlots(current: setSummary, currentMatchesAndroid: setSummary != nil)
        record.android = AndroidPackageFacts(
            installerOfRecord: info.installerPackage,
            firstInstallTime: info.firstInstallTime,
            lastUpdateTime: info.lastUpdateTime,
            minSdk: info.minSDK,
            targetSdk: info.targetSDK,
            nativeAbis: old.android.nativeAbis,
            userdataGeneration: generation,
            lastSyncedAt: clock()
        )
        record.lastOperation = OperationSummary(
            kind: kind == "reinstall" ? .reinstall : .firstInstall,
            operationID: operationID,
            startedAt: startedAt,
            finishedAt: clock(),
            fromVersionCode: old.versionCode,
            toVersionCode: info.versionCode,
            result: .succeeded
        )
        record.updatedAt = clock()
        return record
    }

    private func verifiedTicket(_ ticket: UUID) throws -> TicketManifest? {
        guard activeTickets.contains(ticket), let manifest = tickets[ticket] else { return nil }
        let packageID = manifest.preview.packageID
        guard
            clock().timeIntervalSince(manifest.createdAt) <= Self.importTicketLifetime
                || transactionTicketForRecovery(ticket: ticket, packageID: packageID)
        else {
            removeIncoming(ticket: ticket, packageID: packageID)
            tickets[ticket] = nil
            activeTickets.remove(ticket)
            throw PackageStoreFailure.importTicketExpired
        }
        let directory =
            directories[manifest.preview.packageID]
            ?? directoryName(for: manifest.preview.packageID)
        let incoming = incomingDirectory(
            packageID: manifest.preview.packageID,
            directory: directory,
            ticket: ticket
        )
        do {
            for artifact in manifest.preview.artifactSet.files {
                let file = incoming.appendingPathComponent(artifact.name)
                let (size, digest) = try Self.hashFile(at: file)
                guard size == artifact.size, digest == artifact.sha256 else {
                    throw PackageStoreFailure.importTicketChanged
                }
            }
        } catch let failure as PackageStoreFailure {
            throw failure
        } catch {
            throw PackageStoreFailure.importTicketChanged
        }
        return manifest
    }

    private func loadRecords() throws {
        records.removeAll(keepingCapacity: true)
        directories.removeAll(keepingCapacity: true)
        unreadableRecords.removeAll(keepingCapacity: true)
        let children = try fileManager.contentsOfDirectory(
            at: packagesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let metadataURL = child.appendingPathComponent("metadata.json")
            let directoryName = child.lastPathComponent
            let directoryPackageID = Self.packageID(fromDirectoryName: directoryName)
            guard fileManager.fileExists(atPath: metadataURL.path) else {
                if let packageID = directoryPackageID, Self.hasPersistedPackageData(in: child, fileManager: fileManager)
                {
                    unreadableRecords[packageID] = "missingMetadata"
                    directories[packageID] = directoryName
                }
                continue
            }
            let data: Data
            do {
                data = try Data(contentsOf: metadataURL)
            } catch {
                if let packageID = directoryPackageID {
                    unreadableRecords[packageID] = "unreadableMetadata"
                    directories[packageID] = directoryName
                }
                continue
            }

            let metadataPackageID =
                try? Self.decoder().decode(PackageIDEnvelope.self, from: data).packageId
            do {
                let record = try Self.decoder().decode(PackageRecord.self, from: data)
                if let directoryPackageID, directoryPackageID != record.packageId {
                    unreadableRecords[directoryPackageID] = "identityMismatch"
                    directories[directoryPackageID] = directoryName
                    continue
                }
                guard record.schemaVersion == 1, record.versionCode >= 0 else {
                    unreadableRecords[record.packageId] = Self.metadataIssueDetail(data)
                    directories[record.packageId] = directoryName
                    continue
                }
                records[record.packageId] = record
                directories[record.packageId] = directoryName
            } catch {
                // Preserve package identity when possible so writes cannot take the first-install
                // path or allocate a second directory over a record that needs a newer binary.
                if let packageID = directoryPackageID ?? metadataPackageID {
                    let detail =
                        directoryPackageID != nil && metadataPackageID != nil
                            && directoryPackageID != metadataPackageID
                        ? "identityMismatch"
                        : Self.metadataIssueDetail(data)
                    unreadableRecords[packageID] = detail
                    directories[packageID] = directoryName
                }
                continue
            }
        }
    }

    private func loadTicketsAndCleanScratch() throws {
        tickets.removeAll(keepingCapacity: true)
        activeTickets.removeAll(keepingCapacity: true)
        let scratch = packagesDirectory.appendingPathComponent(".imports", isDirectory: true)
        if fileManager.fileExists(atPath: scratch.path) {
            try? fileManager.removeItem(at: scratch)
        }
        let children = try fileManager.contentsOfDirectory(
            at: packagesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for packageDirectory in children
        where
            packageDirectory.lastPathComponent != ".trash"
            && (try? packageDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        {
            let incomingRoot = packageDirectory.appendingPathComponent("incoming", isDirectory: true)
            let incomingItems =
                fileManager.fileExists(atPath: incomingRoot.path)
                ? ((try? fileManager.contentsOfDirectory(
                    at: incomingRoot,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )) ?? [])
                : []
            let current = packageDirectory.appendingPathComponent("current", isDirectory: true)
            let candidates = incomingItems + (fileManager.fileExists(atPath: current.path) ? [current] : [])
            for candidate in candidates {
                let manifestURL = candidate.appendingPathComponent("ticket.json")
                guard let data = try? Data(contentsOf: manifestURL),
                    let manifest = try? Self.decoder().decode(TicketManifest.self, from: data)
                else {
                    if candidate.deletingLastPathComponent() == incomingRoot {
                        try? fileManager.removeItem(at: candidate)
                    } else if candidate == current {
                        try? fileManager.removeItem(at: manifestURL)
                    }
                    continue
                }
                guard
                    transactionTicketForRecovery(
                        ticket: manifest.preview.ticket,
                        packageID: manifest.preview.packageID
                    )
                else {
                    if candidate.deletingLastPathComponent() == incomingRoot {
                        try? fileManager.removeItem(at: candidate)
                    } else if candidate == current {
                        // A committed install can be interrupted just before removing this
                        // recovery-only manifest. The artifact set itself remains authoritative.
                        try? fileManager.removeItem(at: manifestURL)
                    }
                    continue
                }
                tickets[manifest.preview.ticket] = manifest
                activeTickets.insert(manifest.preview.ticket)
                directories[manifest.preview.packageID] = packageDirectory.lastPathComponent
            }
        }
    }

    private func recoverHostOnlyTransactions() throws {
        let pending = transactions.sorted { lhs, rhs in
            (lhs.value.begin.seq, lhs.key) < (rhs.value.begin.seq, rhs.key)
        }
        for (transaction, state) in pending {
            guard let kind = state.begin.kind,
                let package = state.begin.package,
                let packageID = PackageID(rawValue: package),
                let directory = state.begin.dir
            else {
                continue
            }
            switch kind {
            case "firstInstall", "reinstall", "uninstall":
                if state.lastStep == nil {
                    try appendAbort(transaction, reason: "interruptedBeforeGuestRequest")
                } else if kind == "uninstall", state.lastStep == "guestUninstalled" {
                    try finishUninstall(
                        transaction: transaction,
                        packageID: packageID,
                        directory: directory,
                        keepData: state.begin.keepData ?? false
                    )
                } else if kind == "uninstall",
                    ["filesRemoved", "metadataWritten", "recordRemoved"].contains(state.lastStep ?? "")
                {
                    try finishUninstall(
                        transaction: transaction,
                        packageID: packageID,
                        directory: directory,
                        keepData: state.begin.keepData ?? false
                    )
                } else if kind != "uninstall", state.lastStep == "metadataWritten" {
                    try appendTerminal(transaction, op: "commit")
                }
            case "forget":
                if state.begin.reason == Self.forgetResolutionIntent {
                    // The durable begin records the user's host-side choice before earlier
                    // ambiguous uninstall transactions are closed. Resume either half after a
                    // crash, then finish removing the APKRun record and artifacts.
                    try resolveAmbiguousUninstallTransactions(for: packageID)
                    try finishForget(
                        transaction: transaction,
                        packageID: packageID,
                        directory: directory,
                        injectFaults: false
                    )
                } else {
                    let trash = trashDirectory.appendingPathComponent("\(transaction)-package", isDirectory: true)
                    if fileManager.fileExists(atPath: trash.path) || state.lastStep != nil {
                        try finishForget(
                            transaction: transaction,
                            packageID: packageID,
                            directory: directory,
                            injectFaults: false
                        )
                    } else {
                        try appendAbort(transaction, reason: "interruptedBeforeFileMove")
                    }
                }
            default:
                continue
            }
        }
        try purgeTrash()
    }

    private func ambiguousUninstallTransactionIDs(for packageID: PackageID) -> [String] {
        transactions
            .filter { _, transaction in
                transaction.begin.kind == "uninstall"
                    && transaction.begin.package == packageID.rawValue
                    && transaction.lastStep == "guestUninstallRequested"
            }
            .sorted { lhs, rhs in lhs.value.begin.seq < rhs.value.begin.seq }
            .map(\.key)
    }

    private func resolveAmbiguousUninstallTransactions(for packageID: PackageID) throws {
        for transaction in ambiguousUninstallTransactionIDs(for: packageID) {
            // Forget is an explicit host-side choice. Aborting the incomplete transaction
            // records that choice without claiming whether Android retained the app data.
            try appendAbort(transaction, reason: "userChoseForgetWithUnverifiedUninstallOutcome")
        }
    }

    private func finishForget(
        transaction: String,
        packageID: PackageID,
        directory: String,
        injectFaults: Bool
    ) throws {
        let source = packagesDirectory.appendingPathComponent(directory, isDirectory: true)
        let target = trashDirectory.appendingPathComponent("\(transaction)-package", isDirectory: true)
        let sourceExists = fileManager.fileExists(atPath: source.path)
        let targetExists = fileManager.fileExists(atPath: target.path)
        guard !(sourceExists && targetExists) else { throw PackageStoreFailure.io }
        if sourceExists {
            try moveItem(source, to: target)
        }

        let lastStep = transactions[transaction]?.lastStep
        if lastStep != "filesRemoved" && lastStep != "recordRemoved" {
            try appendStep(transaction, kind: "forget", step: "filesRemoved")
            if injectFaults {
                try injectFault(kind: "forget", step: "filesRemoved")
            }
        }
        records[packageID] = nil
        directories[packageID] = nil
        if transactions[transaction]?.lastStep != "recordRemoved" {
            try appendStep(transaction, kind: "forget", step: "recordRemoved")
            if injectFaults {
                try injectFault(kind: "forget", step: "recordRemoved")
            }
        }
        try appendTerminal(transaction, op: "commit")
        try purgeTrash()
    }

    private func readJournal() throws -> JournalReadResult {
        guard fileManager.fileExists(atPath: journalURL.path) else {
            return JournalReadResult(entries: [], issue: nil, isReadOnly: false)
        }
        let data: Data
        do {
            data = try Data(contentsOf: journalURL)
        } catch {
            throw PackageStoreFailure.io
        }
        var entries: [JournalEntry] = []
        var offset = 0
        var previousSequence: Int64?
        var issue: String?
        var hasTornFinalLine = false
        while offset < data.count {
            guard let newline = data[offset...].firstIndex(of: 0x0A) else {
                issue = "torn final journal line"
                hasTornFinalLine = true
                break
            }
            let line = data[offset..<newline]
            guard !line.isEmpty,
                let entry = try? Self.decoder().decode(JournalEntry.self, from: Data(line))
            else {
                issue = "invalid journal line"
                break
            }
            guard entry.v == 1 else {
                issue = "unsupported journal version \(entry.v)"
                break
            }
            if let previousSequence {
                let (expectedSequence, overflow) = previousSequence.addingReportingOverflow(1)
                guard !overflow, entry.seq == expectedSequence else {
                    issue = "journal sequence gap"
                    break
                }
            } else if entry.seq != 1 {
                issue = "invalid journal sequence"
                break
            }
            guard entry.seq > 0 else {
                issue = "invalid journal sequence"
                break
            }
            entries.append(entry)
            previousSequence = entry.seq
            offset = newline + 1
        }
        if let issue {
            if hasTornFinalLine {
                let validPrefix = data.prefix(offset)
                do {
                    try Data(validPrefix).write(to: journalURL, options: .atomic)
                    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
                } catch {
                    throw PackageStoreFailure.io
                }
                return JournalReadResult(entries: entries, issue: issue, isReadOnly: false)
            }
            return JournalReadResult(entries: entries, issue: issue, isReadOnly: true)
        }
        return JournalReadResult(entries: entries, issue: nil, isReadOnly: false)
    }

    private func append(_ entry: JournalEntry) throws {
        try withJournalLock {
            try appendLocked(entry)
        }
    }

    private func reloadJournalState() throws {
        let journal = try withJournalLock { try readJournal() }
        sequence = journal.entries.last?.seq ?? 0
        journalIssue = journal.issue
        isReadOnly = journal.isReadOnly
        transactions = Self.transactions(from: journal.entries)
    }

    private func appendLocked(_ entry: JournalEntry) throws {
        let journal = try readJournal()
        guard !journal.isReadOnly else {
            isReadOnly = true
            journalIssue = journal.issue
            throw PackageStoreFailure.journalUnreadable
        }
        let currentSequence = journal.entries.last?.seq ?? 0
        var next = entry
        let (nextSequence, overflow) = currentSequence.addingReportingOverflow(1)
        guard !overflow else {
            isReadOnly = true
            journalIssue = "journal sequence exhausted"
            throw PackageStoreFailure.journalUnreadable
        }
        next.seq = nextSequence
        let data: Data
        do {
            var encoded = try Self.encoder().encode(next)
            encoded.append(0x0A)
            data = encoded
        } catch {
            throw PackageStoreFailure.io
        }
        let descriptor = Darwin.open(journalURL.path, O_WRONLY | O_CREAT | O_APPEND, mode_t(0o600))
        guard descriptor >= 0 else {
            throw PackageStoreFailure.io
        }
        defer { _ = Darwin.close(descriptor) }
        let writeResult = data.withUnsafeBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    return false
                }
                offset += written
            }
            return true
        }
        guard writeResult, Darwin.fcntl(descriptor, F_BARRIERFSYNC) == 0 else {
            throw PackageStoreFailure.io
        }
        sequence = nextSequence

        switch next.op {
        case "begin":
            transactions[next.txn] = JournalTransaction(begin: next, lastStep: nil)
        case "step":
            if var state = transactions[next.txn] {
                state.lastStep = next.step
                transactions[next.txn] = state
            }
        case "commit", "abort":
            transactions[next.txn] = nil
        default:
            break
        }
    }

    private func withJournalLock<T>(_ body: () throws -> T) throws -> T {
        let descriptor = Darwin.open(journalLockURL.path, O_RDWR | O_CREAT | O_EXLOCK, mode_t(0o600))
        guard descriptor >= 0 else { throw PackageStoreFailure.io }
        defer { _ = Darwin.close(descriptor) }
        return try body()
    }

    private func acquireLock(at url: URL) async throws -> Int32 {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while true {
            let descriptor = Darwin.open(
                url.path,
                O_RDWR | O_CREAT | O_EXLOCK | O_NONBLOCK,
                mode_t(0o600)
            )
            if descriptor >= 0 {
                return descriptor
            }
            guard errno == EWOULDBLOCK || errno == EINTR else {
                throw PackageStoreFailure.io
            }
            guard !Task.isCancelled, clock.now < deadline else {
                throw PackageStoreFailure.operationInProgress
            }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                throw PackageStoreFailure.operationInProgress
            }
        }
    }

    private func reloadRecordsPreservingImportDirectories() throws {
        var ticketDirectories: [PackageID: String] = [:]
        for ticket in tickets.values {
            let packageID = ticket.preview.packageID
            if let directory = directories[packageID] {
                ticketDirectories[packageID] = directory
            }
        }
        try loadRecords()
        for (packageID, directory) in ticketDirectories where records[packageID] == nil {
            let hasIncomingTicket = tickets.values.contains { ticket in
                ticket.preview.packageID == packageID
                    && fileManager.fileExists(
                        atPath: incomingDirectory(
                            packageID: packageID,
                            directory: directory,
                            ticket: ticket.preview.ticket
                        ).path
                    )
            }
            if hasIncomingTicket {
                directories[packageID] = directory
            }
        }
    }

    private func appendStep(
        _ transaction: String,
        kind: String,
        step: String,
        versionCode: VersionCode? = nil
    ) throws {
        let begin = transactions[transaction]?.begin
        try append(
            JournalEntry(
                v: 1,
                seq: 0,
                txn: transaction,
                at: clock(),
                op: "step",
                kind: kind,
                package: begin?.package,
                dir: begin?.dir,
                from: begin?.from,
                to: versionCode ?? begin?.to,
                setDigest: begin?.setDigest,
                ticket: begin?.ticket,
                keepData: begin?.keepData,
                step: step,
                reason: nil
            )
        )
    }

    private func appendAbort(_ transaction: String, reason: String) throws {
        let begin = transactions[transaction]?.begin
        try append(
            JournalEntry(
                v: 1,
                seq: 0,
                txn: transaction,
                at: clock(),
                op: "abort",
                kind: begin?.kind,
                package: begin?.package,
                dir: begin?.dir,
                from: begin?.from,
                to: begin?.to,
                setDigest: begin?.setDigest,
                ticket: begin?.ticket,
                keepData: begin?.keepData,
                step: nil,
                reason: reason
            )
        )
    }

    private func appendTerminal(_ transaction: String, op: String) throws {
        let begin = transactions[transaction]?.begin
        try append(
            JournalEntry(
                v: 1,
                seq: 0,
                txn: transaction,
                at: clock(),
                op: op,
                kind: begin?.kind,
                package: begin?.package,
                dir: begin?.dir,
                from: begin?.from,
                to: begin?.to,
                setDigest: begin?.setDigest,
                ticket: begin?.ticket,
                keepData: begin?.keepData,
                step: nil,
                reason: nil
            )
        )
    }

    private func promoteIncoming(incoming: URL, current: URL, transaction: String, kind: String) throws {
        try createDirectory(current.deletingLastPathComponent())
        let oldCurrent = trashDirectory.appendingPathComponent("\(transaction)-current", isDirectory: true)
        if fileManager.fileExists(atPath: current.path), !fileManager.fileExists(atPath: oldCurrent.path) {
            try moveItem(current, to: oldCurrent)
        }
        guard fileManager.fileExists(atPath: incoming.path) else {
            if fileManager.fileExists(atPath: current.path) { return }
            throw PackageStoreFailure.importTicketNotFound
        }
        if fileManager.fileExists(atPath: current.path) {
            throw PackageStoreFailure.io
        }
        try moveItem(incoming, to: current)
        _ = kind
    }

    private func writeRecord(_ record: PackageRecord, directory: String) throws {
        let packageDirectory = packagesDirectory.appendingPathComponent(directory, isDirectory: true)
        try createDirectory(packageDirectory)
        do {
            try writeJSON(record, to: packageDirectory.appendingPathComponent("metadata.json"))
        } catch {
            throw PackageStoreFailure.io
        }
    }

    private func writeJSON<T: Encodable>(_ value: T, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try createDirectory(parent)
        let data: Data
        do {
            data = try Self.encoder().encode(value)
        } catch {
            throw PackageStoreFailure.io
        }
        let temporary = parent.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            try syncFile(temporary)
            try moveReplacing(temporary, destination: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw PackageStoreFailure.io
        }
    }

    private func moveReplacing(_ source: URL, destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            let backup = destination.deletingLastPathComponent()
                .appendingPathComponent(".\(destination.lastPathComponent).old-\(UUID().uuidString)")
            try moveItem(destination, to: backup)
            do {
                try moveItem(source, to: destination)
                try syncDirectory(destination.deletingLastPathComponent())
                try? fileManager.removeItem(at: backup)
            } catch {
                try? moveItem(backup, to: destination)
                throw error
            }
        } else {
            try moveItem(source, to: destination)
            try syncDirectory(destination.deletingLastPathComponent())
        }
    }

    private func createDirectory(_ directory: URL) throws {
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw PackageStoreFailure.io
        }
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func moveItem(_ source: URL, to destination: URL) throws {
        try createDirectory(destination.deletingLastPathComponent())
        do {
            try fileManager.moveItem(at: source, to: destination)
            try syncDirectory(source.deletingLastPathComponent())
            if source.deletingLastPathComponent() != destination.deletingLastPathComponent() {
                try syncDirectory(destination.deletingLastPathComponent())
            }
        } catch {
            throw PackageStoreFailure.io
        }
    }

    private func syncFile(_ file: URL) throws {
        let descriptor = Darwin.open(file.path, O_RDONLY)
        guard descriptor >= 0 else { throw PackageStoreFailure.io }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw PackageStoreFailure.io }
    }

    private func syncDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw PackageStoreFailure.io }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw PackageStoreFailure.io }
    }

    private func purgeTrash() throws {
        guard fileManager.fileExists(atPath: trashDirectory.path) else { return }
        do {
            let items = try fileManager.contentsOfDirectory(at: trashDirectory, includingPropertiesForKeys: nil)
            for item in items {
                try fileManager.removeItem(at: item)
            }
        } catch {
            throw PackageStoreFailure.io
        }
    }

    private func incomingDirectory(packageID: PackageID, directory: String, ticket: UUID) -> URL {
        packagesDirectory
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent("incoming", isDirectory: true)
            .appendingPathComponent(ticket.uuidString, isDirectory: true)
    }

    private func removeIncoming(ticket: UUID, packageID: PackageID, directory: String? = nil) {
        let dir = directory ?? directories[packageID] ?? directoryName(for: packageID)
        try? fileManager.removeItem(at: incomingDirectory(packageID: packageID, directory: dir, ticket: ticket))
        tickets[ticket] = nil
        activeTickets.remove(ticket)
    }

    private func directoryName(for packageID: PackageID) -> String {
        if let existing = directories[packageID] { return existing }
        let rawName = packageID.rawValue
        let entries =
            (try? fileManager.contentsOfDirectory(
                at: packagesDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
        if !entries.contains(where: { $0.lastPathComponent.caseInsensitiveCompare(rawName) == .orderedSame }) {
            return rawName
        }
        let digest = SHA256Digest(data: Data(rawName.utf8)).hexValue.prefix(8)
        return "\(rawName)~\(digest)"
    }

    private func requireOpen() throws {
        guard opened else { throw PackageStoreFailure.notOpen }
    }

    private func requireWritable() throws {
        try requireOpen()
        guard !isReadOnly else { throw PackageStoreFailure.journalUnreadable }
    }

    private func injectFault(kind: String, step: String) throws {
        try faultInjector(kind, step)
    }

    private func queryPackage(
        _ packageID: PackageID,
        through runtime: any StoreRuntimeAccess
    ) async throws -> StorePackageInfo? {
        try await runtime.withStoreAgent(UUID()) { channel in
            try await channel.packageInfo(packageID)
        }
    }

    private static func artifactURLs(in incoming: URL, set: ArtifactSet) -> [URL] {
        set.files.map { incoming.appendingPathComponent($0.name) }
    }

    private static func validateSplitFacts(_ facts: [APKFacts]) throws -> APKFacts {
        guard !facts.isEmpty,
            facts.allSatisfy({ $0.versionCode >= 0 && $0.minSDK >= 0 && $0.targetSDK >= 0 })
        else {
            throw PackageStoreFailure.invalidImport
        }
        guard let base = facts.first(where: { $0.splitName == nil }) else {
            throw PackageStoreFailure.invalidSplitSet
        }
        guard facts.filter({ $0.splitName == nil }).count == 1 else {
            throw PackageStoreFailure.invalidSplitSet
        }
        guard facts.allSatisfy({ $0.packageID == base.packageID }) else {
            throw PackageStoreFailure.importPackageMismatch
        }
        guard facts.allSatisfy({ $0.versionCode == base.versionCode }) else {
            throw PackageStoreFailure.importVersionMismatch
        }
        let splitNames = facts.compactMap(\.splitName)
        guard Set(splitNames).count == splitNames.count else {
            throw PackageStoreFailure.duplicateSplitName
        }
        return base
    }

    private static func isSafeSplitName(_ name: String) -> Bool {
        !name.isEmpty
            && name.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || $0 == 45 || $0 == 46 || $0 == 95
            } && name != "." && name != ".."
    }

    private static func safeSourceFileName(_ name: String) -> String {
        let leaf = URL(fileURLWithPath: name).lastPathComponent
        return leaf.isEmpty || leaf == "." || leaf == ".." ? "package.apk" : leaf
    }

    private static func packageID(fromDirectoryName name: String) -> PackageID? {
        if let packageID = PackageID(rawValue: name) {
            return packageID
        }
        guard let separator = name.range(of: "~", options: .backwards) else { return nil }
        let rawPackageID = String(name[..<separator.lowerBound])
        let suffix = String(name[separator.upperBound...])
        guard suffix.utf8.count == 8,
            suffix.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
            let packageID = PackageID(rawValue: rawPackageID),
            SHA256Digest(data: Data(rawPackageID.utf8)).hexValue.hasPrefix(suffix)
        else {
            return nil
        }
        return packageID
    }

    private static func hasPersistedPackageData(in directory: URL, fileManager: FileManager) -> Bool {
        ["settings.json", "current", "previous", "staged", "failed"].contains { name in
            fileManager.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
    }

    private static func metadataIssueDetail(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let schemaVersion = object["schemaVersion"] as? Int,
            schemaVersion != 1
        else {
            return "invalidMetadata"
        }
        return "unsupportedSchemaVersion"
    }

    private static func hashFile(at url: URL) throws -> (Int64, SHA256Digest) {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw PackageStoreFailure.io
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        do {
            while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                size += Int64(chunk.count)
                hasher.update(data: chunk)
            }
        } catch {
            throw PackageStoreFailure.io
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard let digest = SHA256Digest(hex: hex) else { throw PackageStoreFailure.io }
        return (size, digest)
    }

    private func requireHostSpace(for needed: Int64) throws {
        let available = hostFreeSpace(packagesDirectory)
        guard available >= needed else {
            throw PackageStoreFailure.insufficientHostSpace(needed: needed, available: available)
        }
    }

    private func copyBoundedFile(
        from source: URL,
        to destination: URL,
        maximumBytes: Int64,
        totalBytesAlreadyCopied: Int64,
        totalBytesLimit: Int64,
        requiredFreeSpaceAfterWrite: (Int64) -> Int64,
        didCopy: ((Int64) -> Void)? = nil
    ) throws {
        guard
            fileManager.createFile(
                atPath: destination.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ),
            let input = try? FileHandle(forReadingFrom: source),
            let output = try? FileHandle(forWritingTo: destination)
        else {
            throw PackageStoreFailure.io
        }
        defer {
            try? input.close()
            try? output.close()
        }
        var fileBytes: Int64 = 0
        var totalBytes = totalBytesAlreadyCopied
        do {
            while let chunk = try input.read(upToCount: Self.copyChunkSize), !chunk.isEmpty {
                let nextFileBytes = fileBytes + Int64(chunk.count)
                guard nextFileBytes <= maximumBytes else {
                    throw PackageStoreFailure.apkFileTooLarge
                }
                let nextTotalBytes = totalBytes + Int64(chunk.count)
                guard nextTotalBytes <= totalBytesLimit else {
                    throw PackageStoreFailure.importSetTooLarge
                }
                let requiredSpace = requiredFreeSpaceAfterWrite(nextTotalBytes)
                let (neededForChunk, overflow) = requiredSpace.addingReportingOverflow(Int64(chunk.count))
                guard !overflow else { throw PackageStoreFailure.importSetTooLarge }
                try requireHostSpace(for: neededForChunk)
                try output.write(contentsOf: chunk)
                fileBytes = nextFileBytes
                totalBytes = nextTotalBytes
                didCopy?(Int64(chunk.count))
            }
            try output.synchronize()
        } catch let failure as PackageStoreFailure {
            try? fileManager.removeItem(at: destination)
            throw failure
        } catch {
            try? fileManager.removeItem(at: destination)
            throw PackageStoreFailure.io
        }
    }

    private func transactionTicketForRecovery(ticket: UUID, packageID: PackageID) -> Bool {
        transactions.values.contains {
            Self.needsGuestRecovery($0)
                && $0.begin.kind.map { $0 == "firstInstall" || $0 == "reinstall" } == true
                && $0.begin.package == packageID.rawValue
                && $0.begin.ticket.flatMap(UUID.init(uuidString:)) == ticket
        }
    }

    /// Closes older ambiguous attempts after a later install confirms the exact same APK set.
    ///
    /// PackageManager has no operation receipt. When a first-install attempt returned an
    /// ambiguous error, a later successful install of the same package, version, and set digest
    /// is the first conclusive proof that the stored artifact set is installed.
    private func abortSupersededInstallTransactions(
        packageID: PackageID,
        versionCode: VersionCode,
        setDigest: SHA256Digest,
        excluding confirmedTransaction: String
    ) throws {
        let superseded = transactions.filter { transactionID, transaction in
            transactionID != confirmedTransaction
                && Self.needsGuestRecovery(transaction)
                && transaction.begin.package == packageID.rawValue
                && transaction.begin.to == versionCode
                && transaction.begin.setDigest == setDigest.rawValue
        }

        for (transactionID, transaction) in superseded {
            try appendAbort(transactionID, reason: "confirmedBySameSetRetry")
            guard let ticket = transaction.begin.ticket.flatMap(UUID.init(uuidString:)) else {
                continue
            }
            guard !transactionTicketForRecovery(ticket: ticket, packageID: packageID) else {
                continue
            }
            tickets[ticket] = nil
            activeTickets.remove(ticket)
            removeIncoming(ticket: ticket, packageID: packageID)
        }
    }

    private static func installCommitIsVisible(
        begin: JournalEntry,
        current: StorePackageInfo
    ) -> Bool {
        guard let wasInstalled = begin.androidWasInstalled else {
            // Older journal entries lack a pre-install snapshot. Fail closed rather than
            // treating a pre-existing package as the result of this install.
            return false
        }
        guard wasInstalled else {
            // A package that appears during recovery may have been installed by another
            // client after this process lost its result. Preserve the ambiguous transaction.
            return false
        }
        if let previousVersion = begin.androidInstalledVersion, current.versionCode != previousVersion {
            return true
        }
        guard let previousUpdate = begin.androidLastUpdateTime,
            let currentUpdate = current.lastUpdateTime
        else {
            return false
        }
        return currentUpdate > previousUpdate
    }

    private static func installCommitIsVisible(
        previouslyInstalled: StorePackageInfo?,
        current: StorePackageInfo
    ) -> Bool {
        guard let previouslyInstalled else {
            // A package appearing after an uncertain first install could have been installed
            // by another client. Only a successful channel reply can confirm that operation.
            return false
        }
        if current.versionCode != previouslyInstalled.versionCode {
            return true
        }
        guard let previousUpdate = previouslyInstalled.lastUpdateTime,
            let currentUpdate = current.lastUpdateTime
        else {
            return false
        }
        return currentUpdate > previousUpdate
    }

    private static func packageMatchesPreInstallSnapshot(
        begin: JournalEntry,
        current: StorePackageInfo
    ) -> Bool {
        guard begin.androidWasInstalled == true,
            let previousVersion = begin.androidInstalledVersion,
            let previousUpdate = begin.androidLastUpdateTime,
            current.versionCode == previousVersion,
            current.lastUpdateTime == previousUpdate
        else {
            return false
        }
        return true
    }

    private static func packageMatchesPreInstallSnapshot(
        previouslyInstalled: StorePackageInfo?,
        current: StorePackageInfo?
    ) -> Bool {
        guard let previouslyInstalled else {
            return current == nil
        }
        guard let current, current.versionCode == previouslyInstalled.versionCode,
            let previousUpdate = previouslyInstalled.lastUpdateTime,
            current.lastUpdateTime == previousUpdate
        else {
            return false
        }
        return true
    }

    private static func transactions(from entries: [JournalEntry]) -> [String: JournalTransaction] {
        var result: [String: JournalTransaction] = [:]
        for entry in entries {
            switch entry.op {
            case "begin":
                result[entry.txn] = JournalTransaction(begin: entry, lastStep: nil)
            case "step":
                if var transaction = result[entry.txn] {
                    transaction.lastStep = entry.step
                    result[entry.txn] = transaction
                }
            case "commit", "abort":
                result[entry.txn] = nil
            default:
                break
            }
        }
        return result
    }

    private static func needsGuestRecovery(_ transaction: JournalTransaction) -> Bool {
        switch (transaction.begin.kind, transaction.lastStep) {
        case ("firstInstall", "guestCommitRequested"), ("firstInstall", "guestInstalled"),
            ("firstInstall", "filesPromoted"), ("reinstall", "guestCommitRequested"),
            ("reinstall", "guestInstalled"), ("reinstall", "filesPromoted"),
            ("uninstall", "guestUninstallRequested"), ("uninstall", "guestUninstalled"):
            return true
        default:
            return false
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func makeTransactionID(at date: Date) -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        let milliseconds = max(0, UInt64(date.timeIntervalSince1970 * 1_000))
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<6 {
            bytes[index] = UInt8((milliseconds >> (8 * (5 - index))) & 0xff)
        }
        for index in 6..<16 {
            bytes[index] = UInt8.random(in: .min ... .max)
        }
        var bits: [UInt8] = [0, 0]
        for byte in bytes {
            for shift in stride(from: 7, through: 0, by: -1) {
                bits.append((byte >> shift) & 1)
            }
        }
        return stride(from: 0, to: bits.count, by: 5).map { offset in
            let value = bits[offset..<(offset + 5)].reduce(0) { ($0 << 1) | Int($1) }
            return alphabet[value]
        }.map(String.init).joined()
    }

    private static func environmentFaultInjector(_ kind: String, _ step: String) throws {
        #if DEBUG
            guard ProcessInfo.processInfo.environment["APKRUN_STORE_FAULT"] == "\(kind):\(step)" else {
                return
            }
            Darwin._exit(86)
        #endif
    }

    private static let maximumAPKCount = 256
    private static let maximumAPKFileSize: Int64 = 2 * 1_024 * 1_024 * 1_024
    private static let maximumImportSetSize: Int64 = 8 * 1_024 * 1_024 * 1_024
    private static let importSpaceReserve: Int64 = 2 * 1_024 * 1_024 * 1_024
    private static let importTicketLifetime: TimeInterval = 60 * 60
    private static let copyChunkSize = 1_024 * 1_024
    private static let forgetResolutionIntent = "resolvesUnverifiedUninstall"

    private static func availableHostSpace(_ directory: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory.path),
            let available = attributes[.systemFreeSize] as? NSNumber
        else {
            return 0
        }
        return available.int64Value
    }
}
