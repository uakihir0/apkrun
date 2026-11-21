import CryptoKit
import Darwin
import DiagnosticsCore
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
    /// Split names excluded by ABI and density selection (§4.4), empty for plain APK imports.
    public let excludedSplits: [String]
    /// Non-blocking observations of the intrinsic checks (§4.6).
    public let warnings: [ImportWarning]
    /// How this import relates to the managed record (package-store.md §4.7).
    public let relation: ImportRelation

    /// Creates an import preview.
    public init(
        ticket: UUID,
        packageID: PackageID,
        displayName: String,
        versionCode: VersionCode,
        versionName: String?,
        artifactSet: ArtifactSet,
        sourceFileNames: [String],
        excludedSplits: [String] = [],
        warnings: [ImportWarning] = [],
        relation: ImportRelation = .newPackage
    ) {
        self.ticket = ticket
        self.packageID = packageID
        self.displayName = displayName
        self.versionCode = versionCode
        self.versionName = versionName
        self.artifactSet = artifactSet
        self.sourceFileNames = sourceFileNames
        self.excludedSplits = excludedSplits
        self.warnings = warnings
        self.relation = relation
    }

    private enum CodingKeys: String, CodingKey {
        case ticket, packageID, displayName, versionCode, versionName
        case artifactSet, sourceFileNames, excludedSplits, warnings, relation
    }

    /// Decodes an import preview, defaulting fields absent in older manifests.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ticket = try container.decode(UUID.self, forKey: .ticket)
        packageID = try container.decode(PackageID.self, forKey: .packageID)
        displayName = try container.decode(String.self, forKey: .displayName)
        versionCode = try container.decode(VersionCode.self, forKey: .versionCode)
        versionName = try container.decodeIfPresent(String.self, forKey: .versionName)
        artifactSet = try container.decode(ArtifactSet.self, forKey: .artifactSet)
        sourceFileNames = try container.decode([String].self, forKey: .sourceFileNames)
        excludedSplits = try container.decodeIfPresent([String].self, forKey: .excludedSplits) ?? []
        warnings = try container.decodeIfPresent([ImportWarning].self, forKey: .warnings) ?? []
        relation = try container.decodeIfPresent(ImportRelation.self, forKey: .relation) ?? .newPackage
    }
}

/// How an import relates to the managed record of its package
/// (package-store.md §4.7).
public enum ImportRelation: Codable, Sendable, Equatable {
    /// No managed record exists for the package.
    case newPackage
    /// The same artifact set as the managed record.
    case sameAsInstalled
    /// The same versionCode, different files.
    case reinstallSameVersion
    /// A newer versionCode; UpdateCore takes it as a manual update.
    case update(from: VersionCode)
    /// A lower versionCode; refused with store.downgradeRefused.
    case downgrade(from: VersionCode)
    /// A different signer; refused with store.signerMismatch.
    case otherSigner
    /// The package was uninstalled keeping its data; installing restores it.
    case uninstalledWithData(VersionCode)
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
    case packageAlreadyManaged
    case packageNotFound
    case uninstallDataUnverified(PackageID)
    case operationInProgress
    case importTicketNotFound
    case importTicketExpired
    case importTicketChanged
    case runtimeUnavailable
    case guestPackageMismatch
    case guestVersionMismatch
    case downgradeRefused(installed: VersionCode, candidate: VersionCode)
    /// The import is signed by a different key than the managed record
    /// (package-store.md §4.7 `otherSigner`).
    case signerMismatch(PackageID)
    case downgradeReinstallUnavailable
    case unsupportedJournalVersion(Int)
    case journalUnreadable
    case metadataUnreadable(PackageID, detail: String)
    case androidInventoryUnreadable
    case unreadablePackageRecord
    /// `authority == .apkrun` requires a configured update provider.
    case providerNotConfigured
    /// The record's update authority installs nothing through APKRun
    /// (`googlePlay`, `external`; update-system.md §2.1).
    case authorityDoesNotAllowUpdates
    /// The package has an open runtime session; an update cannot start.
    case packageInUse(PackageID)
    /// The package has no staged update to install.
    case stagedUpdateMissing
    case io
}

private struct GuestUninstallBoundaryFailure: Error, @unchecked Sendable {
    let underlying: any Error
}

private struct GuestInstallBoundaryFailure: Error, @unchecked Sendable {
    let underlying: any Error
}

private final class GuestInstallBoundaryState: @unchecked Sendable {
    private let lock = NSLock()
    private var hasPassed = false

    func markPassed() {
        lock.lock()
        hasPassed = true
        lock.unlock()
    }

    func didPass() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasPassed
    }
}

private final class GuestUninstallBoundaryState: @unchecked Sendable {
    private let lock = NSLock()
    private var hasPassed = false

    func markPassed() {
        lock.lock()
        hasPassed = true
        lock.unlock()
    }

    func didPass() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasPassed
    }
}

/// Owns package artifacts, records, and the transaction journal.
///
/// `packagesDirectory` is the APKRun `Packages/` directory. Supplying it directly keeps tests
/// isolated and lets RuntimeHost use `APKRunPaths` without making APKStoreCore depend on
/// DiagnosticsCore.
public actor PackageStore {
    /// The Android package that owns update installation for APKRun-managed apps.
    ///
    /// The Store Agent on custom images signs as this package (package-store.md §6.3,
    /// guest-components.md §8.1).
    public static let updateOwnerPackage: PackageID = {
        guard let package = PackageID(rawValue: "io.apkrun.store") else {
            preconditionFailure("The Store Agent package name is a valid package ID.")
        }
        return package
    }()

    /// Async host-side APK metadata reader, injected to keep package import testable.
    public typealias Inspector = @Sendable (URL) async throws -> APKFacts

    /// Debug-only transaction hook used by crash-recovery tests and fault injection.
    public typealias FaultInjector = @Sendable (_ kind: String, _ step: String) throws -> Void
    /// Runs under the package mutation lock after validating the managed package.
    public typealias BeforeUninstall = @Sendable () async throws -> Void
    /// Runs after the package transaction and Store Agent channel are ready, before the guest call.
    public typealias BeforeGuestUninstall = @Sendable () async throws -> Void
    /// Runs after the Store Agent channel is ready, immediately before the guest install call.
    public typealias BeforeGuestInstall = @Sendable () async throws -> Void
    /// Runs under the package mutation lock after validating the managed package.
    public typealias BeforeForget = @Sendable () async throws -> Void

    /// The file set the import stage verified, with the metadata the §4 checks produced.
    public struct VerifiedImport: Sendable {
        /// The APK files to keep, in store order (base first), inside the scratch directory.
        public var files: [URL]
        /// One facts record per file in `files`.
        public var facts: [APKFacts]
        /// Certificate digests of the verified signers (§4.5).
        public var signerDigests: [SHA256Digest]
        /// Signing lineage digests when a rotation proof was present.
        public var lineage: [SHA256Digest]
        /// The lineage nodes with capability flags, matching `lineage`.
        public var lineageNodes: [SignerLineageNode]
        /// Non-blocking observations of the intrinsic checks (§4.6).
        public var warnings: [ImportWarning]
        /// Split names excluded by ABI and density selection (§4.4).
        public var excludedSplits: [String]

        /// Creates a verified import result.
        public init(
            files: [URL],
            facts: [APKFacts],
            signerDigests: [SHA256Digest],
            lineage: [SHA256Digest],
            lineageNodes: [SignerLineageNode] = [],
            warnings: [ImportWarning],
            excludedSplits: [String]
        ) {
            self.files = files
            self.facts = facts
            self.signerDigests = signerDigests
            self.lineage = lineage
            self.lineageNodes = lineageNodes
            self.warnings = warnings
            self.excludedSplits = excludedSplits
        }
    }

    /// Host inspection stage of `importPackage` (package-store.md §4): takes the privately staged
    /// copies and a scratch directory, returns the verified APK set or refuses it. Injected like
    /// `inspector` so store-mechanics tests can keep stubbed inputs.
    public typealias ImportVerifier =
        @Sendable (_ staged: [URL], _ scratch: URL, _ inspect: Inspector) async throws -> VerifiedImport

    /// The §4 pipeline: container detection and expansion, signature verification, the intrinsic
    /// checks I1–I12, and ABI/density split selection.
    public static let strictImportVerifier: ImportVerifier = { staged, scratch, inspect in
        let reader = ContainerReader()
        var stagedURLs: [URL] = []
        var expandedFromContainer = false
        for (index, stagedFile) in staged.enumerated() {
            let container = try reader.detect(at: stagedFile)
            switch container {
            case .apk:
                stagedURLs.append(stagedFile)
            default:
                expandedFromContainer = true
                let target = scratch.appendingPathComponent("extracted-\(index)", isDirectory: true)
                stagedURLs.append(contentsOf: try reader.extract(container, from: stagedFile, into: target))
            }
        }
        guard stagedURLs.count <= ContainerReader.maxAPKs else {
            throw StoreFailure.archiveLimitExceeded(.apkCount)
        }

        var facts: [APKFacts] = []
        for stagedURL in stagedURLs {
            facts.append(try await inspect(stagedURL))
        }

        // Host signature verification and the intrinsic checks I1–I12 (§4.5, §4.6).
        let signatureVerifier = APKSignatureVerifier()
        var inspected: [InspectedAPK] = []
        for (stagedURL, itemFacts) in zip(stagedURLs, facts) {
            let signature = try signatureVerifier.verify(apk: stagedURL, targetSDK: itemFacts.targetSDK)
            let zipFacts = ArtifactVerifier.zipFacts(of: stagedURL)
            inspected.append(
                InspectedAPK(
                    file: ArtifactFile(
                        name: stagedURL.lastPathComponent,
                        splitName: itemFacts.splitName,
                        size: 0,
                        sha256: SHA256Digest(data: Data())
                    ),
                    facts: itemFacts,
                    signature: signature,
                    libraryABIs: zipFacts.libraryABIs,
                    resourcesArscOK: zipFacts.resourcesArscOK,
                    permissions: itemFacts.permissions,
                    requiredFeatures: itemFacts.requiredFeatures,
                    debuggable: itemFacts.debuggable,
                    attributes: SplitAttributes(
                        isFeatureSplit: itemFacts.isFeatureSplit,
                        configForSplit: itemFacts.configForSplit,
                        isSplitRequired: itemFacts.isSplitRequired,
                        requiredSplitTypes: itemFacts.requiredSplitTypes,
                        splitTypes: itemFacts.splitTypes
                    )
                )
            )
        }
        var verified = try ArtifactVerifier().verify(set: inspected)
        var excludedSplits: [String] = []
        if expandedFromContainer, stagedURLs.count > 1 {
            let selection = try SplitSelector().select(
                inspected.map {
                    SplitCandidate(name: $0.file.name, splitName: $0.facts.splitName, attributes: $0.attributes)
                }
            )
            excludedSplits = selection.excludedSplits
            let keep = Set(selection.included)
            var pairs = Array(zip(stagedURLs, facts))
            pairs = pairs.filter { keep.contains($0.0.lastPathComponent) }
            stagedURLs = pairs.map(\.0)
            facts = pairs.map(\.1)
            inspected = inspected.filter { keep.contains($0.file.name) }
            verified = try ArtifactVerifier().verify(set: inspected)
        }

        return VerifiedImport(
            files: stagedURLs,
            facts: facts,
            signerDigests: verified.signerDigests,
            lineage: verified.lineage,
            lineageNodes: verified.lineageNodes,
            warnings: verified.warnings,
            excludedSplits: excludedSplits
        )
    }

    /// The pre-§4 behavior: inspect every staged file without container expansion, signature
    /// verification, or the intrinsic checks. For tests that stub the inspector.
    public static let legacyImportVerifier: ImportVerifier = { staged, _, inspect in
        var facts: [APKFacts] = []
        for stagedURL in staged {
            facts.append(try await inspect(stagedURL))
        }
        return VerifiedImport(
            files: staged,
            facts: facts,
            signerDigests: [],
            lineage: [],
            warnings: [],
            excludedSplits: []
        )
    }

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
        /// The staged candidate's provenance, journaled on `stage` begins so
        /// recovery can rewrite `artifacts.staged` after a crash.
        var origin: ArtifactOrigin? = nil
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
    private let importVerifier: ImportVerifier
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
    /// Download tickets handed to providers, before `inspect(ticket:)` verifies
    /// them into regular tickets. Maps the ticket to its package's directory.
    private var downloadTickets: [UUID: (packageID: PackageID, directory: String)] = [:]
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
        faultInjector: FaultInjector? = nil,
        importVerifier: @escaping ImportVerifier = PackageStore.strictImportVerifier
    ) {
        self.packagesDirectory = packagesDirectory
        self.runtimeAccess = runtimeAccess
        self.inspector = inspector
        self.importVerifier = importVerifier
        self.fileManager = fileManager
        self.clock = clock
        self.hostFreeSpace = hostFreeSpace ?? { Self.availableHostSpace($0) }
        self.faultInjector = faultInjector ?? Self.environmentFaultInjector
    }

    /// The readable journal issue found during the last `open()`, such as a torn final line.
    public private(set) var journalIssue: String?

    /// Loads records, recovers host-only operations, and restores unexpired import tickets.
    public func open() async throws {
        // Idempotent: the shared store is opened by whichever service runs first.
        guard !opened else { return }
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

        // §4 host inspection: containers expand, signatures and the intrinsic checks I1–I12 run,
        // splits are selected. Injectable so store-mechanics tests can keep stubbed inputs.
        let verifiedImport = try await importVerifier(stagedURLs, scratch, inspector)
        stagedURLs = verifiedImport.files
        let facts = verifiedImport.facts
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
            signerDigests: verifiedImport.signerDigests,
            lineage: verifiedImport.lineage,
            lineageNodes: verifiedImport.lineageNodes,
            permissions: baseFacts.permissions,
            targetSdk: baseFacts.targetSDK,
            inspection: InspectionProvenance(
                aapt2Version: "unknown",
                verifierVersion: "host-inspection-v1",
                inspectedAt: clock(),
                hostChecksPerformed: [
                    "packageMetadata",
                    "versionCode",
                    "splitSet",
                    "sha256",
                    "signature:verified",
                    "intrinsicChecks",
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
            sourceFileNames: sourceNames,
            excludedSplits: verifiedImport.excludedSplits,
            warnings: verifiedImport.warnings,
            relation: classifyRelation(
                packageID: baseFacts.packageID,
                versionCode: baseFacts.versionCode,
                setDigest: artifactSet.setDigest,
                signerDigests: artifactSet.signerDigests
            )
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

    /// Removes an unconsumed import ticket and its private APK copies.
    public func discardImport(ticket: UUID) async throws {
        try requireWritable()
        let importsLock = try await acquireLock(at: importsLockURL)
        defer { _ = Darwin.close(importsLock) }
        let mutationLock = try await acquireLock(at: mutationLockURL)
        defer { _ = Darwin.close(mutationLock) }
        try reloadRecordsPreservingImportDirectories()
        guard let manifest = tickets[ticket] else { return }
        let packageID = manifest.preview.packageID
        guard !operationsInProgress.contains(packageID),
            !transactionTicketForRecovery(ticket: ticket, packageID: packageID)
        else {
            throw PackageStoreFailure.operationInProgress
        }

        let directory = directories[packageID] ?? directoryName(for: packageID)
        let incoming = incomingDirectory(packageID: packageID, directory: directory, ticket: ticket)
        do {
            if fileManager.fileExists(atPath: incoming.path) {
                try fileManager.removeItem(at: incoming)
            }
        } catch {
            throw PackageStoreFailure.io
        }
        tickets[ticket] = nil
        activeTickets.remove(ticket)
    }

    /// Opens a download ticket for an update (package-store.md §4,
    /// update-system.md §5). The provider streams artifacts into
    /// `incoming/<ticket>/`; `inspect(ticket:)` verifies them in place. The
    /// directory is scratch space: no journal entries reference it, `open()`
    /// deletes it if the run dies before `inspect`, and `discardDownload`
    /// removes it after a failed or refused download.
    ///
    /// - Returns: the ticket and the directory the provider writes into.
    public func beginDownloadTicket(for packageID: PackageID) async throws -> (
        ticket: UUID, directory: URL
    ) {
        try requireWritable()
        let importsLock = try await acquireLock(at: importsLockURL)
        defer { _ = Darwin.close(importsLock) }
        let mutationLock = try await acquireLock(at: mutationLockURL)
        defer { _ = Darwin.close(mutationLock) }
        try reloadRecordsPreservingImportDirectories()
        guard records[packageID] != nil else {
            throw PackageStoreFailure.packageNotFound
        }
        let directory = directories[packageID] ?? directoryName(for: packageID)
        let ticket = UUID()
        let incoming = incomingDirectory(
            packageID: packageID, directory: directory, ticket: ticket)
        try createDirectory(incoming)
        downloadTickets[ticket] = (packageID, directory)
        return (ticket, incoming)
    }

    /// Writes a JSON sidecar into a verified ticket's `incoming/` set — the
    /// coordinator's `validation.json` (update-system.md §6), which `stage`
    /// then carries into `staged/` alongside the artifact set.
    public func writeTicketFile(ticket: UUID, name: String, contents: Data) async throws {
        try requireWritable()
        guard Self.isSafeTicketSidecarName(name) else {
            throw PackageStoreFailure.invalidImport
        }
        let importsLock = try await acquireLock(at: importsLockURL)
        defer { _ = Darwin.close(importsLock) }
        let mutationLock = try await acquireLock(at: mutationLockURL)
        defer { _ = Darwin.close(mutationLock) }
        try reloadRecordsPreservingImportDirectories()
        guard let preview = tickets[ticket]?.preview else {
            throw PackageStoreFailure.importTicketNotFound
        }
        let directory = directories[preview.packageID] ?? directoryName(for: preview.packageID)
        let target = try incomingDirectory(
            packageID: preview.packageID, directory: directory, ticket: ticket
        )
        .appendingPathComponent(name)
        try contents.write(to: target, options: .atomic)
    }

    /// The sidecar names `writeTicketFile` accepts: `*.json` files that are
    /// neither the manifest (`ticket.json`) nor the artifact set
    /// (`artifact.json`), made of filename-safe characters only.
    private static func isSafeTicketSidecarName(_ name: String) -> Bool {
        name.hasSuffix(".json")
            && name != "ticket.json" && name != "artifact.json"
            && name.count <= 64
            && name.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-")
            }
    }

    /// Discards an unverified download ticket's `incoming/` set (§5): a failed
    /// download, a hash mismatch, or a refused validation. The ticket may also
    /// be a verified one whose `inspect` manifest exists; either way the set
    /// goes to `.trash`'s purge path by plain removal.
    public func discardDownload(ticket: UUID) async throws {
        try requireWritable()
        let importsLock = try await acquireLock(at: importsLockURL)
        defer { _ = Darwin.close(importsLock) }
        let mutationLock = try await acquireLock(at: mutationLockURL)
        defer { _ = Darwin.close(mutationLock) }
        try reloadRecordsPreservingImportDirectories()
        let packageID = downloadTickets[ticket]?.packageID ?? tickets[ticket]?.preview.packageID
        guard let packageID else { return }
        removeIncoming(ticket: ticket, packageID: packageID)
        downloadTickets[ticket] = nil
    }

    /// Verifies a download ticket's `incoming/` set in place (package-store.md
    /// §4.6, update-system.md §5). The files the provider wrote are run through
    /// the same verifier as imports — containers expand, signatures and the
    /// intrinsic checks I1–I12 run, splits are selected — then canonicalized as
    /// `base.apk`/`split_<name>.apk` beside a `ticket.json` and `artifact.json`.
    /// Afterwards the ticket is an ordinary verified ticket: `stage` or
    /// `installStaged`'s callers consume it like an import ticket.
    public func inspect(ticket: UUID) async throws -> PackageImportPreview {
        try requireWritable()
        let importsLock = try await acquireLock(at: importsLockURL)
        defer { _ = Darwin.close(importsLock) }
        let mutationLock = try await acquireLock(at: mutationLockURL)
        defer { _ = Darwin.close(mutationLock) }
        try reloadRecordsPreservingImportDirectories()
        guard let ticketInfo = downloadTickets[ticket] else {
            // A verified import ticket needs no second inspect: its preview is
            // the manifest written by `importPackage` (update-system.md §7.1
            // runs the `--file` path through `validate` with such a ticket).
            if let preview = tickets[ticket]?.preview {
                return preview
            }
            throw PackageStoreFailure.importTicketNotFound
        }
        let packageID = ticketInfo.packageID
        guard !operationsInProgress.contains(packageID) else {
            throw PackageStoreFailure.operationInProgress
        }
        let incoming = incomingDirectory(
            packageID: packageID, directory: ticketInfo.directory, ticket: ticket)
        guard fileManager.fileExists(atPath: incoming.path) else {
            throw PackageStoreFailure.importTicketNotFound
        }

        let rawFiles =
            ((try? fileManager.contentsOfDirectory(
                at: incoming,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []).filter { !$0.hasDirectoryPath }
        guard !rawFiles.isEmpty else {
            try? fileManager.removeItem(at: incoming)
            downloadTickets[ticket] = nil
            throw PackageStoreFailure.invalidImport
        }
        let sourceNames = rawFiles.map(\.lastPathComponent)
        let scratch = incoming.appendingPathComponent(".inspect", isDirectory: true)
        try createDirectory(scratch)
        let verifiedImport = try await importVerifier(rawFiles, scratch, inspector)
        let facts = verifiedImport.facts
        let baseFacts = try Self.validateSplitFacts(facts)
        guard baseFacts.packageID == packageID else {
            try? fileManager.removeItem(at: incoming)
            downloadTickets[ticket] = nil
            throw PackageStoreFailure.importPackageMismatch
        }

        var artifactFiles: [ArtifactFile] = []
        let ordered = zip(verifiedImport.files, facts).sorted { lhs, rhs in
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
                // A downloaded file may already sit at its canonical name.
                if sourceURL.standardizedFileURL != destination.standardizedFileURL {
                    try copyBoundedFile(
                        from: sourceURL,
                        to: destination,
                        maximumBytes: Self.maximumAPKFileSize,
                        totalBytesAlreadyCopied: artifactFiles.reduce(Int64(0)) { $0 + $1.size },
                        totalBytesLimit: Self.maximumImportSetSize,
                        requiredFreeSpaceAfterWrite: { _ in 0 }
                    )
                }
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                let (size, digest) = try Self.hashFile(at: destination)
                artifactFiles.append(
                    ArtifactFile(name: name, splitName: itemFacts.splitName, size: size, sha256: digest)
                )
            }
        } catch let failure as PackageStoreFailure {
            try? fileManager.removeItem(at: incoming)
            downloadTickets[ticket] = nil
            throw failure
        } catch {
            try? fileManager.removeItem(at: incoming)
            downloadTickets[ticket] = nil
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
            downloadTickets[ticket] = nil
            throw PackageStoreFailure.invalidSplitSet
        }
        let artifactSet = ArtifactSet(
            packageID: baseFacts.packageID,
            versionCode: baseFacts.versionCode,
            versionName: baseFacts.versionName,
            files: artifactFiles,
            setDigest: digest,
            signerDigests: verifiedImport.signerDigests,
            lineage: verifiedImport.lineage,
            lineageNodes: verifiedImport.lineageNodes,
            permissions: baseFacts.permissions,
            targetSdk: baseFacts.targetSDK,
            inspection: InspectionProvenance(
                aapt2Version: "unknown",
                verifierVersion: "host-inspection-v1",
                inspectedAt: clock(),
                hostChecksPerformed: [
                    "packageMetadata",
                    "versionCode",
                    "splitSet",
                    "sha256",
                    "signature:verified",
                    "intrinsicChecks",
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
            sourceFileNames: sourceNames,
            excludedSplits: verifiedImport.excludedSplits,
            warnings: verifiedImport.warnings,
            relation: classifyRelation(
                packageID: baseFacts.packageID,
                versionCode: baseFacts.versionCode,
                setDigest: artifactSet.setDigest,
                signerDigests: artifactSet.signerDigests
            )
        )
        let manifest = TicketManifest(
            preview: preview,
            createdAt: clock(),
            facts: facts.map(PersistedAPKFacts.init),
            origin: nil
        )
        do {
            try writeJSON(manifest, to: incoming.appendingPathComponent("ticket.json"))
            try writeJSON(artifactSet, to: incoming.appendingPathComponent("artifact.json"))
        } catch {
            try? fileManager.removeItem(at: incoming)
            downloadTickets[ticket] = nil
            throw PackageStoreFailure.io
        }
        // Drop the provider's raw file names and the inspection scratch; only
        // the canonical set and its metadata remain.
        for item
            in (try? fileManager.contentsOfDirectory(
                at: incoming,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
        {
            let name = item.lastPathComponent
            if name != "ticket.json", name != "artifact.json",
                !artifactFiles.contains(where: { $0.name == name })
            {
                try? fileManager.removeItem(at: item)
            }
        }
        try? fileManager.removeItem(at: scratch)
        tickets[ticket] = manifest
        activeTickets.insert(ticket)
        downloadTickets[ticket] = nil
        return preview
    }

    /// Returns the package identity of an open import ticket without starting Android.
    public func packageIDForImportTicket(_ ticket: UUID) throws -> PackageID {
        try requireOpen()
        guard let manifest = tickets[ticket] else {
            throw PackageStoreFailure.importTicketNotFound
        }
        return manifest.preview.packageID
    }

    /// Installs a new package or reinstalls a retained-data package from an import ticket.
    public func installImported(ticket: UUID) async throws -> PackageRecord {
        try await installImportedWithOutcome(ticket: ticket).record
    }

    /// Installs a new package or retained-data package and reports its committed prior state.
    public func installImportedWithOutcome(
        ticket: UUID,
        beforeGuestInstall: BeforeGuestInstall? = nil,
        requiresReinstallMark: Bool = false
    ) async throws -> PackageInstallOutcome {
        try requireWritable()
        guard let manifest = try verifiedTicket(ticket) else {
            throw PackageStoreFailure.importTicketNotFound
        }
        if let existing = records[manifest.preview.packageID] {
            if existing.state != .uninstalledKeepingData {
                // Route refusals through the §4.7 relation so a signer
                // mismatch or a versionCode regression names its real cause.
                switch classifyRelation(
                    packageID: manifest.preview.packageID,
                    versionCode: manifest.preview.versionCode,
                    setDigest: manifest.preview.artifactSet.setDigest,
                    signerDigests: manifest.preview.artifactSet.signerDigests
                ) {
                case .otherSigner:
                    throw PackageStoreFailure.signerMismatch(manifest.preview.packageID)
                case .downgrade(let from):
                    throw PackageStoreFailure.downgradeRefused(
                        installed: from, candidate: manifest.preview.versionCode)
                default:
                    throw PackageStoreFailure.packageAlreadyInstalled
                }
            }
            return try await performInstall(
                manifest,
                kind: "reinstall",
                from: existing.versionCode,
                beforeGuestInstall: beforeGuestInstall,
                requiresReinstallMark: requiresReinstallMark
            )
        }
        return try await performInstall(
            manifest,
            kind: "firstInstall",
            from: nil,
            beforeGuestInstall: beforeGuestInstall,
            requiresReinstallMark: requiresReinstallMark
        )
    }

    /// Reinstalls the package in a ticket over its current version.
    public func reinstall(ticket: UUID) async throws -> PackageRecord {
        try await reinstallWithOutcome(ticket: ticket).record
    }

    /// Reinstalls a package and reports the prior state validated by its install transaction.
    public func reinstallWithOutcome(
        ticket: UUID,
        beforeGuestInstall: BeforeGuestInstall? = nil,
        requiresReinstallMark: Bool = false
    ) async throws -> PackageInstallOutcome {
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
            beforeGuestInstall: beforeGuestInstall,
            requiresReinstallMark: requiresReinstallMark
        )
    }

    /// Uninstalls a package, optionally retaining its Android app data and package record.
    public func uninstall(packageID: PackageID, keepData: Bool = false) async throws {
        _ = try await uninstallWithOutcome(packageID: packageID, keepData: keepData)
    }

    /// Whether a store mutation for the package is in flight (GU6 of
    /// update-system.md §7.1). Gentle installs read this before starting;
    /// it does not take the file-level mutation lock.
    public func packageMutationInProgress(_ packageID: PackageID) -> Bool {
        operationsInProgress.contains(packageID)
    }

    /// Uninstalls a package and returns whether post-commit trash cleanup needs to be retried.
    public func uninstallWithOutcome(
        packageID: PackageID,
        keepData: Bool = false,
        beforeUninstall: BeforeUninstall? = nil,
        beforeGuestUninstall: BeforeGuestUninstall? = nil
    ) async throws -> PackageUninstallOutcome {
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
        try Task.checkCancellation()
        try await beforeUninstall?()

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
        let boundaryState = GuestUninstallBoundaryState()
        do {
            try await runtimeAccess.withStoreAgent(operation) { channel in
                if let beforeGuestUninstall {
                    do {
                        try await beforeGuestUninstall()
                    } catch {
                        throw GuestUninstallBoundaryFailure(underlying: error)
                    }
                }
                boundaryState.markPassed()
                try await channel.uninstall(packageID, keepData: keepData)
            }
        } catch let boundaryFailure as GuestUninstallBoundaryFailure {
            try appendAbort(transaction, reason: "uninstallNotStarted")
            throw boundaryFailure.underlying
        } catch let uninstallFailure {
            guard boundaryState.didPass() else {
                try appendAbort(transaction, reason: "uninstallNotStarted")
                throw uninstallFailure
            }
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
        guard
            let cleanupDeferred = try finishUninstall(
                transaction: transaction,
                packageID: packageID,
                directory: directory,
                keepData: keepData
            )
        else {
            throw PackageStoreFailure.packageNotFound
        }
        return PackageUninstallOutcome(keptData: keepData, cleanupDeferred: cleanupDeferred)
    }

    /// Removes APKRun's record and artifacts without issuing an Android uninstall.
    public func forget(
        packageID: PackageID,
        beforeForget: BeforeForget? = nil
    ) async throws {
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
        try Task.checkCancellation()
        try await beforeForget?()

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

    /// Stages a verified update's incoming ticket as the package's `staged/` set
    /// (package-store.md §5.2, §7.1). Host-only: it skips the Android commit queue.
    ///
    /// The candidate must describe the ticket's artifact set: a mismatch means the
    /// caller validated a different set than the one on disk.
    public func stage(ticket: UUID, candidate: StagedUpdateInfo) async throws {
        try requireWritable()
        guard let manifest = try verifiedTicket(ticket) else {
            throw PackageStoreFailure.importTicketNotFound
        }
        let packageID = manifest.preview.packageID
        guard manifest.preview.versionCode == candidate.versionCode,
            manifest.preview.artifactSet.setDigest == candidate.setDigest
        else {
            throw PackageStoreFailure.guestVersionMismatch
        }
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
        guard let record = records[packageID] else { throw PackageStoreFailure.packageNotFound }
        // A download racing an authority change stops here: `googlePlay` and `external`
        // never install through APKRun (update-system.md §2.1).
        if record.updateAuthority == .googlePlay || record.updateAuthority == .external {
            throw PackageStoreFailure.authorityDoesNotAllowUpdates
        }

        let directory = directories[packageID] ?? directoryName(for: packageID)
        let incoming = incomingDirectory(packageID: packageID, directory: directory, ticket: ticket)
        guard fileManager.fileExists(atPath: incoming.appendingPathComponent("artifact.json").path) else {
            throw PackageStoreFailure.importTicketNotFound
        }

        let transaction = Self.makeTransactionID(at: clock())
        try append(
            JournalEntry(
                v: 1,
                seq: 0,
                txn: transaction,
                at: clock(),
                op: "begin",
                kind: "stage",
                package: packageID.rawValue,
                dir: directory,
                from: records[packageID]?.versionCode,
                to: candidate.versionCode,
                setDigest: candidate.setDigest.rawValue,
                ticket: ticket.uuidString,
                keepData: nil,
                step: nil,
                reason: nil,
                origin: candidate.origin
            )
        )
        try injectFault(kind: "stage", step: "begin")
        try finishStage(
            transaction: transaction,
            packageID: packageID,
            directory: directory,
            candidate: candidate,
            injectFaults: true
        )
        tickets[ticket] = nil
        activeTickets.remove(ticket)
        try purgeTrash()
    }

    /// Discards the package's staged update: the `staged/` set moves to `.trash`
    /// and `artifacts.staged` clears (package-store.md §5.2). UpdateCore calls it
    /// when a candidate is withdrawn, the authority changes, or the user skips it.
    public func discardStaged(packageID: PackageID) async throws {
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

        let directory = directories[packageID] ?? directoryName(for: packageID)
        let transaction = Self.makeTransactionID(at: clock())
        try append(
            JournalEntry(
                v: 1,
                seq: 0,
                txn: transaction,
                at: clock(),
                op: "begin",
                kind: "discardStaged",
                package: packageID.rawValue,
                dir: directory,
                from: nil,
                to: nil,
                setDigest: nil,
                ticket: nil,
                keepData: nil,
                step: nil,
                reason: nil
            )
        )
        try injectFault(kind: "discardStaged", step: "begin")
        try finishDiscardStaged(
            transaction: transaction,
            packageID: packageID,
            directory: directory,
            injectFaults: true
        )
        try purgeTrash()
    }

    /// Installs the package's staged update through PackageInstaller and promotes
    /// the `staged/` set to `current/`, retaining the previous set for rollback
    /// (package-store.md §5.2 `update`, §5.5 recovery).
    ///
    /// `hasOpenSession` must report whether the package currently has an open
    /// runtime session. It is consulted before the journal begins, so a busy
    /// package fails with `packageInUse` without touching the store.
    ///
    /// `enableRollback` is forwarded to the channel only when the channel
    /// advertises the `rollback` capability; otherwise it is dropped.
    public func installStaged(
        for packageID: PackageID,
        enableRollback: Bool,
        hasOpenSession: @Sendable () async -> Bool,
        commitGate: (@Sendable () async -> Bool)? = nil
    ) async throws -> PackageRecord {
        try requireWritable()
        guard let runtimeAccess else { throw PackageStoreFailure.runtimeUnavailable }
        if await hasOpenSession() {
            throw PackageStoreFailure.packageInUse(packageID)
        }
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
        guard let existing = records[packageID] else { throw PackageStoreFailure.packageNotFound }
        guard existing.state == .installed else { throw PackageStoreFailure.packageNotFound }
        // Re-checked here, under the lock, so a staged set staged before an authority
        // change to `googlePlay` or `external` can never reach Android (§2.1).
        if existing.updateAuthority == .googlePlay || existing.updateAuthority == .external {
            throw PackageStoreFailure.authorityDoesNotAllowUpdates
        }

        let directory = directories[packageID] ?? directoryName(for: packageID)
        let packageDirectory = packagesDirectory.appendingPathComponent(directory, isDirectory: true)
        let staged = packageDirectory.appendingPathComponent("staged", isDirectory: true)
        let current = packageDirectory.appendingPathComponent("current", isDirectory: true)
        let previous = packageDirectory.appendingPathComponent("previous", isDirectory: true)
        guard fileManager.fileExists(atPath: staged.appendingPathComponent("artifact.json").path) else {
            throw PackageStoreFailure.stagedUpdateMissing
        }
        guard let stagedDigest = stagedSetDigest(in: staged) else {
            throw PackageStoreFailure.stagedUpdateMissing
        }
        guard let stagedSet = try artifactSet(in: staged) else {
            throw PackageStoreFailure.stagedUpdateMissing
        }
        guard stagedSet.packageID == packageID else {
            throw PackageStoreFailure.guestPackageMismatch
        }
        guard stagedSet.versionCode > existing.versionCode else {
            throw PackageStoreFailure.downgradeRefused(
                installed: existing.versionCode,
                candidate: stagedSet.versionCode
            )
        }

        let transaction = Self.makeTransactionID(at: clock())
        let startedAt = clock()
        let operationID = UUID()
        try append(
            JournalEntry(
                v: 1,
                seq: 0,
                txn: transaction,
                at: startedAt,
                op: "begin",
                kind: "update",
                package: packageID.rawValue,
                dir: directory,
                from: existing.versionCode,
                to: stagedSet.versionCode,
                setDigest: stagedDigest.rawValue,
                ticket: nil,
                keepData: nil,
                step: nil,
                reason: nil
            )
        )
        try injectFault(kind: "update", step: "begin")

        // §7.2 race boundary: the last moment a pre-commit install can be
        // cancelled back to `staged` before the guest commit is requested.
        if let commitGate, await !commitGate() {
            try appendAbort(transaction, reason: "installCancelled")
            throw PackageStoreFailure.packageInUse(packageID)
        }
        try appendStep(transaction, kind: "update", step: "guestCommitRequested")
        try injectFault(kind: "update", step: "guestCommitRequested")

        let info: StorePackageInfo
        let boundaryState = GuestInstallBoundaryState()
        do {
            info = try await runtimeAccess.withStoreAgent(operationID) { channel in
                boundaryState.markPassed()
                return try await channel.install(
                    StoreInstallRequest(
                        packageID: packageID,
                        versionCode: stagedSet.versionCode,
                        allowDowngrade: false,
                        mode: .update,
                        signerDigests: stagedSet.signerDigests,
                        enableRollback: enableRollback && channel.capabilities.contains(.rollback),
                        requestUpdateOwnership: existing.updateAuthority.claimsUpdateOwnership
                            && channel.capabilities.contains(.updateOwnership)
                    ),
                    files: Self.artifactURLs(in: staged, set: stagedSet)
                )
            }
        } catch {
            guard boundaryState.didPass() else {
                try appendAbort(transaction, reason: "guestInstallNotStarted")
                throw error
            }
            var committedInfo: StorePackageInfo?
            do {
                committedInfo = try await queryPackage(packageID, through: runtimeAccess)
            } catch {
                throw error
            }
            if let committedInfo,
                committedInfo.packageID == packageID,
                committedInfo.versionCode == stagedSet.versionCode
            {
                info = committedInfo
            } else {
                // The update did not commit; `staged/` stays staged so the
                // caller can retry once the package is inspected again.
                try appendAbort(transaction, reason: "guestInstallFailed")
                throw error
            }
        }
        guard info.packageID == packageID else {
            try appendAbort(transaction, reason: "guestPackageMismatch")
            throw PackageStoreFailure.guestPackageMismatch
        }
        guard info.versionCode == stagedSet.versionCode else {
            try appendAbort(transaction, reason: "guestVersionMismatch")
            throw PackageStoreFailure.guestVersionMismatch
        }
        try appendStep(transaction, kind: "update", step: "guestInstalled", versionCode: info.versionCode)
        try injectFault(kind: "update", step: "guestInstalled")

        try finishUpdatePromotion(
            transaction: transaction,
            toDigest: stagedDigest,
            fromDigest: existing.artifacts.current?.setDigest,
            staged: staged,
            current: current,
            previous: previous
        )
        try appendStep(transaction, kind: "update", step: "filesPromoted")
        try injectFault(kind: "update", step: "filesPromoted")

        let record = recordAfterUpdate(
            existing,
            info: info,
            generation: await runtimeAccess.userdataGeneration() ?? UUID(),
            operationID: operationID,
            startedAt: startedAt
        )
        try writeRecord(record, directory: directory)
        try appendStep(transaction, kind: "update", step: "metadataWritten")
        try injectFault(kind: "update", step: "metadataWritten")
        try appendTerminal(transaction, op: "commit")
        records[packageID] = record
        warnOnMissingUpdateOwner(record)
        try purgeTrash()
        return record
    }

    /// The managed packages whose Android update owner is not `io.apkrun.store`
    /// even though their authority claims ownership (package-store.md §6.3).
    ///
    /// Health reports these as `store.ownership` warnings (`store.updateOwnerMissing`):
    /// expected on stock images and when the image's enforcement flag is off.
    public func updateOwnerMissingPackages() async throws -> [PackageID] {
        try requireOpen()
        let mutationLock = try await acquireLock(at: mutationLockURL)
        defer { _ = Darwin.close(mutationLock) }
        try reloadRecordsPreservingImportDirectories()
        return records.values
            .filter { record in
                record.state == .installed && record.updateAuthority.claimsUpdateOwnership
                    && record.android.updateOwner != Self.updateOwnerPackage
            }
            .map(\.packageId)
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// Logs the `store.ownership` health warning for a record whose update owner
    /// Android did not report as the Store Agent (package-store.md §6.3, §13).
    private func warnOnMissingUpdateOwner(_ record: PackageRecord) {
        guard record.updateAuthority.claimsUpdateOwnership,
            record.android.updateOwner != Self.updateOwnerPackage
        else { return }
        APKLogger(category: StoreLogCategory.reconcile).warning(
            "\(record.packageId.rawValue, .public) is not update-owned by io.apkrun.store",
            errorCode: "store.updateOwnerMissing"
        )
    }

    /// Sets the package's update policy — authority and/or provider — as
    /// separate record fields (update-system.md §3.1). Not a journal
    /// transaction: the record update is a single atomic metadata write
    /// (package-store.md §5.2).
    ///
    /// A nil argument leaves the field unchanged; `removeProvider` clears the
    /// provider. Authority and provider stay independent on the record.
    public func setUpdatePolicy(
        for packageID: PackageID,
        authority: UpdateAuthority? = nil,
        provider: UpdateProviderRef? = nil,
        removeProvider: Bool = false,
        requireProvider: Bool = false
    ) async throws {
        try requireWritable()
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
        guard var record = records[packageID] else { throw PackageStoreFailure.packageNotFound }
        let directory = directories[packageID] ?? directoryName(for: packageID)
        if let authority { record.updateAuthority = authority }
        if removeProvider {
            record.updateProvider = nil
        } else if let provider {
            record.updateProvider = provider
        }
        // Checked inside the mutation lock so a concurrent provider removal
        // cannot leave `apkrun` authority without a provider.
        if requireProvider, record.updateAuthority == .apkrun,
            record.updateProvider == nil
        {
            throw PackageStoreFailure.providerNotConfigured
        }
        record.updatedAt = clock()
        try writeRecord(record, directory: directory)
        records[packageID] = record
    }

    /// Writes `update.mode` to the package's `settings.json` (update-system.md
    /// §2.3). The caller writes this before `setUpdatePolicy` so a crash never
    /// turns on automatic updates without the record change.
    public func setUpdateMode(for packageID: PackageID, mode: String) async throws {
        try requireWritable()
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
        guard records[packageID] != nil else { throw PackageStoreFailure.packageNotFound }
        let directory = directories[packageID] ?? directoryName(for: packageID)
        let url = packagesDirectory.appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent("settings.json")
        var settings: PackageSettings
        if fileManager.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url),
            let decoded = try? Self.decoder().decode(PackageSettings.self, from: data)
        {
            settings = decoded
        } else {
            settings = PackageSettings()
        }
        settings.update["mode"] = mode
        try writeJSON(settings, to: url)
    }

    /// Moves a package to a different update authority (package-store.md §6.3).
    ///
    /// Leaving an authority that claims ownership (`apkrun`, `manual`) for one that
    /// does not (`googlePlay`, `external`) asks Android to relinquish update
    /// ownership before the record write. When the runtime is not `ready` — or the
    /// guest call cannot be made — the journaled `relinquishOwnership` transaction
    /// stays pending as a post-boot task; an authority change never starts Android.
    /// `FAILED_PRECONDITION` (APKRun is not the owner) is not an error.
    public func setUpdateAuthority(
        id packageID: PackageID,
        authority: UpdateAuthority,
        provider: UpdateProviderRef? = nil
    ) async throws {
        try requireWritable()
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
        guard var record = records[packageID] else { throw PackageStoreFailure.packageNotFound }
        let directory = directories[packageID] ?? directoryName(for: packageID)

        if record.updateAuthority.claimsUpdateOwnership, !authority.claimsUpdateOwnership {
            // The transaction is journaled before the guest call so a crash between
            // the relinquish and the record write leaves a pending post-boot task —
            // the old authority has no owner until recovery replays the call (§5.5).
            let transaction = Self.makeTransactionID(at: clock())
            try append(
                JournalEntry(
                    v: 1,
                    seq: 0,
                    txn: transaction,
                    at: clock(),
                    op: "begin",
                    kind: "relinquishOwnership",
                    package: packageID.rawValue,
                    dir: directory,
                    from: nil,
                    to: nil,
                    setDigest: nil,
                    ticket: nil,
                    keepData: nil,
                    step: nil,
                    reason: nil
                )
            )
            try appendStep(transaction, kind: "relinquishOwnership", step: "guestRelinquishRequested")
            try injectFault(kind: "relinquishOwnership", step: "guestRelinquishRequested")
            if let runtimeAccess {
                do {
                    try await runtimeAccess.withStoreAgent(UUID()) { channel in
                        if channel.capabilities.contains(.updateOwnership) {
                            try await channel.relinquishUpdateOwnership(packageID)
                        }
                    }
                    try appendTerminal(transaction, op: "commit")
                } catch StoreChannelFailure.updateOwnershipNotHeld(_) {
                    try appendTerminal(transaction, op: "commit")
                } catch {
                    // Android could not answer: leave the transaction pending as the
                    // post-boot task of §5.5; the record change still lands now.
                }
            }
            // The new authority does not hold the owner either way — a pending post-boot
            // task finishes the relinquish, so the record must not keep the stale owner.
            record.android.updateOwner = nil
        }

        record.updateAuthority = authority
        if let provider {
            record.updateProvider = provider
        }
        record.updatedAt = clock()
        try writeRecord(record, directory: directory)
        records[packageID] = record
    }

    /// Adopts a package Android has but APKRun does not manage (package-store.md §9.3).
    ///
    /// The record gets `installer: external`, `updateAuthority: external`, no artifact, and
    /// `source: adopted`; APKRun never updates the package. Adoption queries Android for the
    /// live package facts, so the runtime must be attached.
    public func adoptPackage(packageID: PackageID) async throws -> PackageRecord {
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
        guard records[packageID] == nil else { throw PackageStoreFailure.packageAlreadyManaged }
        guard let info = try await queryPackage(packageID, through: runtimeAccess) else {
            throw PackageStoreFailure.packageNotFound
        }

        let now = clock()
        let record = PackageRecord(
            packageId: packageID,
            displayName: info.displayName,
            versionCode: info.versionCode,
            versionName: info.versionName,
            signingCertificates: info.signingDigests,
            installer: .external,
            updateAuthority: .external,
            state: .installed,
            artifacts: ArtifactSlots(currentMatchesAndroid: false),
            android: AndroidPackageFacts(
                updateOwner: info.updateOwner,
                installerOfRecord: info.installerPackage,
                firstInstallTime: info.firstInstallTime,
                lastUpdateTime: info.lastUpdateTime,
                minSdk: info.minSDK,
                targetSdk: info.targetSDK,
                nativeAbis: [],
                userdataGeneration: await runtimeAccess.userdataGeneration() ?? UUID(),
                lastSyncedAt: now
            ),
            source: PackageSource(kind: .adopted, at: now),
            lastOperation: OperationSummary(
                kind: .adopt,
                operationID: UUID(),
                startedAt: now,
                finishedAt: now,
                toVersionCode: info.versionCode,
                result: .succeeded
            ),
            createdAt: now,
            updatedAt: now
        )
        let directory = directoryName(for: packageID)
        try writeRecord(record, directory: directory)
        records[packageID] = record
        directories[packageID] = directory
        return record
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

            case ("update", "guestCommitRequested"), ("update", "guestInstalled"),
                ("update", "filesPromoted"):
                let info = try await queryPackage(packageID, through: runtimeAccess)
                guard let info, info.packageID == packageID, info.versionCode == transaction.begin.to else {
                    // The update did not commit in Android. Keep `staged/` so
                    // the candidate can be retried; files stay unpromoted.
                    if transaction.lastStep == "guestInstalled" || transaction.lastStep == "filesPromoted" {
                        continue
                    }
                    try appendAbort(transactionID, reason: "guestVersionDidNotCommit")
                    continue
                }
                if transaction.lastStep == "guestCommitRequested" {
                    try appendStep(transactionID, kind: kind, step: "guestInstalled", versionCode: info.versionCode)
                }
                try finishUpdateRecovery(
                    transaction: transactionID,
                    packageID: packageID,
                    directory: directory,
                    info: info,
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

            case ("relinquishOwnership", _):
                // Post-boot task (§5.5, §6.3): replay the relinquish only while the record
                // still names a non-owning authority — a switch back to `apkrun` or `manual`
                // while the runtime was down cancels the pending relinquish, and a missing
                // record makes it moot. A failure re-queues the task for the next boot and
                // FAILED_PRECONDITION commits it.
                if let record = records[packageID], !record.updateAuthority.claimsUpdateOwnership {
                    do {
                        try await runtimeAccess.withStoreAgent(UUID()) { channel in
                            if channel.capabilities.contains(.updateOwnership) {
                                try await channel.relinquishUpdateOwnership(packageID)
                            }
                        }
                        try appendTerminal(transactionID, op: "commit")
                    } catch StoreChannelFailure.updateOwnershipNotHeld(_) {
                        try appendTerminal(transactionID, op: "commit")
                    } catch {
                        continue
                    }
                } else {
                    try appendTerminal(transactionID, op: "commit")
                }

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

    /// Marks every managed package as missing from a new userdata generation (package-store.md §9.2,
    /// runtime-daemon.md §9.5): `installed` becomes `needsReinstall(.userdataReset)`, and adopted
    /// packages without a host artifact become `broken(.removedInAndroid)`.
    ///
    /// Called by `resetAndroid` after the new instance's userdata generation exists, before the
    /// daemon reinstalls managed packages from `Packages/<id>/current/`.
    public func markForUserdataReset() async throws -> [PackageID] {
        try requireOpen()
        let mutationLock = try await acquireLock(at: mutationLockURL)
        defer { _ = Darwin.close(mutationLock) }
        try reloadRecordsPreservingImportDirectories()
        var marked: [PackageID] = []
        for (packageID, var record) in records {
            guard record.installer == .apkrun else { continue }
            switch record.state {
            case .installed:
                record.state = .needsReinstall(.userdataReset)
                record.updatedAt = Date()
                try writeRecord(
                    record, directory: directories[packageID] ?? directoryName(for: packageID))
                records[packageID] = record
                marked.append(packageID)
            case .needsReinstall(.userdataReset), .needsReinstall(.userdataRestored),
                .broken(.reinstallFailed):
                marked.append(packageID)
            case .uninstalledKeepingData, .broken:
                break
            }
        }
        // Adopted packages have no host artifact to reinstall from.
        for (packageID, var record) in records {
            guard record.source.kind == .adopted else { continue }
            let directory = directories[packageID] ?? directoryName(for: packageID)
            let current =
                packagesDirectory
                .appendingPathComponent(directory, isDirectory: true)
                .appendingPathComponent("current", isDirectory: true)
            let hasArtifact =
                (try? fileManager.contentsOfDirectory(atPath: current.path))?
                .contains { $0.hasSuffix(".apk") } ?? false
            if !hasArtifact, record.state == .installed {
                record.state = .broken(.removedInAndroid)
                record.updatedAt = Date()
                try writeRecord(record, directory: directory)
                records[packageID] = record
            }
        }
        return marked
    }

    /// The `current/` artifact directory of a managed package, honoring the collision-resolved
    /// directory name (`<id>~<digest>`) on case-insensitive volumes.
    public func artifactCurrentDirectory(packageID: PackageID) async throws -> URL {
        try requireOpen()
        let directory = directories[packageID] ?? directoryName(for: packageID)
        return
            packagesDirectory
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent("current", isDirectory: true)
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

    /// Returns the stored `settings.json` of a package, or nil when it has none
    /// (package-metadata-json.md §3). Unmanaged and unconfigured packages take
    /// their documented defaults.
    public func packageSettings(for packageID: PackageID) async throws -> PackageSettings? {
        try requireOpen()
        let mutationLock = try await acquireLock(at: mutationLockURL)
        defer { _ = Darwin.close(mutationLock) }
        let directory = directories[packageID] ?? directoryName(for: packageID)
        let url = packagesDirectory.appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent("settings.json")
        guard fileManager.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        return try? Self.decoder().decode(PackageSettings.self, from: data)
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
        beforeGuestInstall: BeforeGuestInstall?,
        requiresReinstallMark: Bool = false
    ) async throws -> PackageInstallOutcome {
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
        // Checked inside the mutation lock so an uninstall or forget committed between
        // the caller's pending-reinstall snapshot and this install cannot resurrect a
        // removed package (package-store.md §9.2).
        if requiresReinstallMark {
            guard let record = records[packageID], Self.isReinstallPending(record.state) else {
                throw PackageStoreFailure.packageNotFound
            }
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
        let previousRecord = records[packageID]
        if kind == "reinstall" {
            guard let existing = previousRecord,
                existing.state == .uninstalledKeepingData || Self.canReinstall(existing.state)
            else {
                throw PackageStoreFailure.packageNotFound
            }
            guard from == existing.versionCode else {
                throw PackageStoreFailure.guestVersionMismatch
            }
        }
        // Refuse signer mismatches before any Android call (package-store.md §4.7).
        // The relation is re-derived here: the record may have changed since the
        // preview was built. A versionCode regression is refused again below against
        // the guest-reported version.
        switch classifyRelation(
            packageID: packageID,
            versionCode: preview.versionCode,
            setDigest: preview.artifactSet.setDigest,
            signerDigests: preview.artifactSet.signerDigests
        ) {
        case .otherSigner:
            throw PackageStoreFailure.signerMismatch(packageID)
        case .downgrade(let from):
            throw PackageStoreFailure.downgradeRefused(
                installed: from, candidate: preview.versionCode)
        default:
            break
        }
        let operationID = UUID()
        let previouslyInstalled = try await runtimeAccess.withStoreAgent(operationID) { channel in
            try await channel.packageInfo(packageID)
        }
        if let installedVersion = previouslyInstalled?.versionCode ?? from,
            preview.versionCode < installedVersion
        {
            throw PackageStoreFailure.downgradeRefused(
                installed: installedVersion,
                candidate: preview.versionCode
            )
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
        let boundaryState = GuestInstallBoundaryState()
        do {
            info = try await runtimeAccess.withStoreAgent(operationID) { channel in
                if let beforeGuestInstall {
                    do {
                        try Task.checkCancellation()
                        try await beforeGuestInstall()
                    } catch {
                        throw GuestInstallBoundaryFailure(underlying: error)
                    }
                } else {
                    do {
                        try Task.checkCancellation()
                    } catch {
                        throw GuestInstallBoundaryFailure(underlying: error)
                    }
                }
                boundaryState.markPassed()
                return try await channel.install(
                    StoreInstallRequest(
                        packageID: packageID,
                        versionCode: preview.versionCode,
                        allowDowngrade: false,
                        mode: kind == "reinstall" ? .reinstall : .new,
                        signerDigests: preview.artifactSet.signerDigests,
                        // package-store.md §6.3: the authority the record will carry decides
                        // whether the install asks Android for update ownership.
                        requestUpdateOwnership: (previousRecord?.updateAuthority ?? .manual)
                            .claimsUpdateOwnership
                            && channel.capabilities.contains(.updateOwnership)
                    ),
                    files: Self.artifactURLs(in: incoming, set: preview.artifactSet)
                )
            }
        } catch let boundaryFailure as GuestInstallBoundaryFailure {
            try appendAbort(transaction, reason: "installNotStarted")
            throw boundaryFailure.underlying
        } catch {
            guard boundaryState.didPass() else {
                try appendAbort(transaction, reason: "guestInstallNotStarted")
                throw error
            }
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
            existing: previousRecord,
            operationID: operationID,
            startedAt: startedAt,
            kind: kind
        )
        try writeRecord(record, directory: directory)
        try appendStep(transaction, kind: kind, step: "metadataWritten")
        try injectFault(kind: kind, step: "metadataWritten")
        try appendTerminal(transaction, op: "commit")
        records[packageID] = record
        directories[packageID] = directory
        tickets[preview.ticket] = nil
        activeTickets.remove(preview.ticket)
        warnOnMissingUpdateOwner(record)
        try injectFault(kind: kind, step: "commit")
        // Cleanup follows the durable commit and cannot change whether the install succeeded.
        var cleanupDeferred = false
        let ticketMarker = current.appendingPathComponent("ticket.json")
        do {
            try fileManager.removeItem(at: ticketMarker)
        } catch {
            if fileManager.fileExists(atPath: ticketMarker.path) {
                cleanupDeferred = true
            }
        }
        do {
            try abortSupersededInstallTransactions(
                packageID: packageID,
                versionCode: preview.versionCode,
                setDigest: preview.artifactSet.setDigest,
                excluding: transaction
            )
        } catch {
            cleanupDeferred = true
        }
        do {
            try purgeTrash()
        } catch {
            cleanupDeferred = true
        }
        let previousVersionCode = previouslyInstalled?.versionCode ?? previousRecord?.versionCode
        return PackageInstallOutcome(
            record: record,
            previousVersionCode: previousVersionCode,
            restoredRetainedData: previousRecord?.state == .uninstalledKeepingData
                && previouslyInstalled == nil,
            cleanupDeferred: cleanupDeferred
        )
    }

    /// Whether the record still waits on the pending-reinstall reconcile: the same set
    /// `pendingReinstalls()` reports (`needsReinstall` and a failed earlier reinstall).
    private static func isReinstallPending(_ state: PackageState) -> Bool {
        switch state {
        case .needsReinstall, .broken(.reinstallFailed):
            return true
        case .installed, .uninstalledKeepingData, .broken(.removedInAndroid),
            .broken(.artifactMissing), .broken(.signerChanged):
            return false
        }
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
                warnOnMissingUpdateOwner(recovered)
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
        warnOnMissingUpdateOwner(recovered)
        tickets[ticketID] = nil
        try? fileManager.removeItem(at: current.appendingPathComponent("ticket.json"))
        try purgeTrash()
    }

    @discardableResult
    private func finishUninstall(
        transaction: String,
        packageID: PackageID,
        directory: String,
        keepData: Bool
    ) throws -> Bool? {
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
                return nil
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
        do {
            try injectFault(kind: "uninstall", step: "trashCleanup")
            try purgeTrash()
            return false
        } catch {
            return true
        }
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
            updateOwner: info.updateOwner,
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
            // A reinstall keeps the update policy the package already has: an adopted
            // package stays externally managed, and an apkrun-managed package keeps
            // its provider (package-store.md §2.1, §9.3).
            updateAuthority: existing?.updateAuthority ?? .manual,
            updateProvider: existing?.updateProvider,
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
            updateOwner: info.updateOwner,
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
            if !fileManager.fileExists(atPath: metadataURL.path) {
                // A crash inside `moveReplacing` can leave only the `.old-*`
                // backup of metadata.json; restore the newest one so the
                // record survives without rolling back a later write.
                let backups =
                    (try? fileManager.contentsOfDirectory(atPath: child.path))?
                    .filter { $0.hasPrefix(".metadata.json.old-") } ?? []
                let newest = backups.max { lhs, rhs in
                    let lhsDate =
                        (try? fileManager.attributesOfItem(
                            atPath: child.appendingPathComponent(lhs).path))?[.modificationDate] as? Date
                    let rhsDate =
                        (try? fileManager.attributesOfItem(
                            atPath: child.appendingPathComponent(rhs).path))?[.modificationDate] as? Date
                    return (lhsDate ?? .distantPast, lhs) < (rhsDate ?? .distantPast, rhs)
                }
                if let newest {
                    try? fileManager.moveItem(
                        atPath: child.appendingPathComponent(newest).path,
                        toPath: metadataURL.path)
                }
            }
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
            case "firstInstall", "reinstall", "uninstall", "update":
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
            case "stage":
                // package-store.md §5.5: roll forward when `staged/` already
                // holds the new digest or a step was journaled; otherwise abort
                // and delete the `incoming/` set.
                let staged =
                    packagesDirectory
                    .appendingPathComponent(directory, isDirectory: true)
                    .appendingPathComponent("staged", isDirectory: true)
                let rolledToStaged =
                    state.begin.setDigest != nil
                    && stagedSetDigest(in: staged)?.rawValue == state.begin.setDigest
                if state.lastStep != nil || rolledToStaged {
                    guard
                        let candidate = recoveredStageCandidate(in: staged, begin: state.begin)
                    else {
                        throw PackageStoreFailure.io
                    }
                    try finishStage(
                        transaction: transaction,
                        packageID: packageID,
                        directory: directory,
                        candidate: candidate,
                        injectFaults: false
                    )
                } else {
                    if let ticketString = state.begin.ticket,
                        let ticket = UUID(uuidString: ticketString)
                    {
                        try? fileManager.removeItem(
                            at: incomingDirectory(
                                packageID: packageID, directory: directory, ticket: ticket))
                    }
                    try appendAbort(transaction, reason: "interruptedBeforeFileMove")
                }
            case "discardStaged":
                let staged =
                    packagesDirectory
                    .appendingPathComponent(directory, isDirectory: true)
                    .appendingPathComponent("staged", isDirectory: true)
                if state.lastStep != nil
                    || !fileManager.fileExists(atPath: staged.path)
                    || fileManager.fileExists(
                        atPath:
                            trashDirectory
                            .appendingPathComponent("\(transaction)-staged", isDirectory: true).path)
                {
                    // A file step rolls forward; an already-moved set is a
                    // partial move worth finishing so the record clears.
                    try finishDiscardStaged(
                        transaction: transaction,
                        packageID: packageID,
                        directory: directory,
                        injectFaults: false
                    )
                } else {
                    try appendAbort(transaction, reason: "interruptedBeforeFileMove")
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

    /// Rolls the `stage` transaction forward (§5.2, §5.5). Idempotent across a
    /// crash: an already-trashed old staged set or an already-moved incoming set
    /// is recognized and skipped.
    private func finishStage(
        transaction: String,
        packageID: PackageID,
        directory: String,
        candidate: StagedUpdateInfo,
        injectFaults: Bool
    ) throws {
        let packageDirectory = packagesDirectory.appendingPathComponent(directory, isDirectory: true)
        let staged = packageDirectory.appendingPathComponent("staged", isDirectory: true)
        let trashedStaged = trashDirectory.appendingPathComponent("\(transaction)-staged", isDirectory: true)
        let stagedDigest = stagedSetDigest(in: staged)

        if fileManager.fileExists(atPath: staged.path), stagedDigest != candidate.setDigest {
            // The old staged set goes to .trash once per transaction.
            if fileManager.fileExists(atPath: trashedStaged.path) {
                throw PackageStoreFailure.io
            }
            try moveItem(staged, to: trashedStaged)
        }
        if stagedSetDigest(in: staged) != candidate.setDigest {
            guard let ticketString = transactions[transaction]?.begin.ticket,
                let ticket = UUID(uuidString: ticketString)
            else {
                throw PackageStoreFailure.importTicketNotFound
            }
            let incoming = incomingDirectory(
                packageID: packageID, directory: directory, ticket: ticket)
            guard fileManager.fileExists(atPath: incoming.path) else {
                throw PackageStoreFailure.importTicketNotFound
            }
            try moveItem(incoming, to: staged)
        }
        if transactions[transaction]?.lastStep != "filesStaged" {
            try appendStep(transaction, kind: "stage", step: "filesStaged")
            if injectFaults {
                try injectFault(kind: "stage", step: "filesStaged")
            }
        }
        if transactions[transaction]?.lastStep != "metadataWritten" {
            guard var record = records[packageID] else {
                throw PackageStoreFailure.packageNotFound
            }
            record.artifacts.staged = candidate.slotSummary
            record.updatedAt = clock()
            try writeRecord(record, directory: directory)
            records[packageID] = record
            try appendStep(transaction, kind: "stage", step: "metadataWritten")
            if injectFaults {
                try injectFault(kind: "stage", step: "metadataWritten")
            }
        }
        try appendTerminal(transaction, op: "commit")
    }

    /// The `setDigest` recorded in a slot's `artifact.json`, or nil when the slot
    /// is absent or unreadable.
    private func stagedSetDigest(in slot: URL) -> SHA256Digest? {
        let artifactURL = slot.appendingPathComponent("artifact.json")
        guard let data = try? Data(contentsOf: artifactURL),
            let set = try? Self.decoder().decode(ArtifactSet.self, from: data)
        else {
            return nil
        }
        return set.setDigest
    }

    /// Rebuilds the stage candidate from `staged/artifact.json` after a crash;
    /// the provenance comes from the journaled begin entry.
    private func recoveredStageCandidate(in staged: URL, begin: JournalEntry) -> StagedUpdateInfo? {
        let artifactURL = staged.appendingPathComponent("artifact.json")
        guard let data = try? Data(contentsOf: artifactURL),
            let set = try? Self.decoder().decode(ArtifactSet.self, from: data)
        else {
            return nil
        }
        return StagedUpdateInfo(
            versionCode: set.versionCode,
            versionName: set.versionName,
            setDigest: set.setDigest,
            size: set.files.reduce(0) { $0 + $1.size },
            fileCount: set.files.count,
            origin: begin.origin ?? ArtifactOrigin(type: .manualFile)
        )
    }

    /// Rolls the `discardStaged` transaction forward (§5.2, §5.5). Idempotent:
    /// an already-trashed staged set and an already-cleared record are skipped.
    private func finishDiscardStaged(
        transaction: String,
        packageID: PackageID,
        directory: String,
        injectFaults: Bool
    ) throws {
        let packageDirectory = packagesDirectory.appendingPathComponent(directory, isDirectory: true)
        let staged = packageDirectory.appendingPathComponent("staged", isDirectory: true)
        let target = trashDirectory.appendingPathComponent("\(transaction)-staged", isDirectory: true)
        if fileManager.fileExists(atPath: staged.path) {
            guard !fileManager.fileExists(atPath: target.path) else {
                throw PackageStoreFailure.io
            }
            try moveItem(staged, to: target)
        }
        if transactions[transaction]?.lastStep != "filesRemoved" {
            try appendStep(transaction, kind: "discardStaged", step: "filesRemoved")
            if injectFaults {
                try injectFault(kind: "discardStaged", step: "filesRemoved")
            }
        }
        if transactions[transaction]?.lastStep != "metadataWritten" {
            guard var record = records[packageID] else {
                throw PackageStoreFailure.packageNotFound
            }
            record.artifacts.staged = nil
            record.updatedAt = clock()
            try writeRecord(record, directory: directory)
            records[packageID] = record
            try appendStep(transaction, kind: "discardStaged", step: "metadataWritten")
            if injectFaults {
                try injectFault(kind: "discardStaged", step: "metadataWritten")
            }
        }
        try appendTerminal(transaction, op: "commit")
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
                reason: nil,
                origin: begin?.origin
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

    /// Rolls an `update` transaction forward after a crash (package-store.md
    /// §5.5). Slots are identified by `setDigest`, never by directory name:
    /// the `to` digest belongs in `current/`, the `from` digest in `previous/`,
    /// and any other set goes to `.trash`.
    private func finishUpdateRecovery(
        transaction: String,
        packageID: PackageID,
        directory: String,
        info: StorePackageInfo,
        userdataGeneration: UUID
    ) throws {
        let packageDirectory = packagesDirectory.appendingPathComponent(directory, isDirectory: true)
        let staged = packageDirectory.appendingPathComponent("staged", isDirectory: true)
        let current = packageDirectory.appendingPathComponent("current", isDirectory: true)
        let previous = packageDirectory.appendingPathComponent("previous", isDirectory: true)
        guard
            let toDigest = transactions[transaction]?.begin.setDigest
                .flatMap(SHA256Digest.init(rawValue:))
        else {
            try appendAbort(transaction, reason: "updateSetDigestMissing")
            return
        }
        let fromDigest = records[packageID]?.artifacts.current?.setDigest
        if transactions[transaction]?.lastStep != "filesPromoted" {
            try finishUpdatePromotion(
                transaction: transaction,
                toDigest: toDigest,
                fromDigest: fromDigest,
                staged: staged,
                current: current,
                previous: previous
            )
            try appendStep(transaction, kind: "update", step: "filesPromoted")
        }
        guard let old = records[packageID] else {
            try appendAbort(transaction, reason: "packageRecordMissing")
            return
        }
        // Idempotent record conversion: a crash between `writeRecord` and the
        // `metadataWritten` step replays this function with an already-updated
        // record, whose `staged` slot is nil — reconverting it would erase
        // `current` and alias `previous` to the new set.
        let record =
            old.artifacts.current?.setDigest == toDigest
            ? old
            : recordAfterUpdate(
                old,
                info: info,
                generation: userdataGeneration,
                operationID: UUID(),
                startedAt: transactions[transaction]?.begin.at ?? clock()
            )
        if record != old {
            try writeRecord(record, directory: directory)
        }
        try appendStep(transaction, kind: "update", step: "metadataWritten")
        try appendTerminal(transaction, op: "commit")
        records[packageID] = record
        warnOnMissingUpdateOwner(record)
        try purgeTrash()
    }

    /// Decodes a slot's `artifact.json`, or nil when the file is absent.
    private func artifactSet(in slot: URL) throws -> ArtifactSet? {
        let artifactURL = slot.appendingPathComponent("artifact.json")
        guard fileManager.fileExists(atPath: artifactURL.path),
            let data = try? Data(contentsOf: artifactURL)
        else {
            return nil
        }
        return try? Self.decoder().decode(ArtifactSet.self, from: data)
    }

    /// The installed `current/artifact.json` for a managed package, or nil
    /// when the slot is absent or unreadable. UpdateCore reads it for the
    /// §6 signer-lineage and notes inputs.
    public func installedArtifactSet(for packageID: PackageID) async throws -> ArtifactSet? {
        try requireOpen()
        guard let directory = directories[packageID] else {
            return nil
        }
        let current =
            packagesDirectory
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent("current", isDirectory: true)
        return try artifactSet(in: current)
    }

    /// Promotes `staged/` to `current/` for the `update` transaction
    /// (package-store.md §5.2, §5.5):
    ///
    /// 1. the old `previous/` set moves to `.trash`;
    /// 2. `staged/` and `current/` swap via `renamex_np(RENAME_SWAP)`;
    /// 3. `staged/` — now holding the old current set — moves to `previous/`.
    ///
    /// Idempotent by `setDigest` (never by directory name): the set with
    /// `toDigest` ends in `current/`, the set with `fromDigest` in `previous/`,
    /// and any other set in these slots goes to `.trash`.
    private func finishUpdatePromotion(
        transaction: String,
        toDigest: SHA256Digest,
        fromDigest: SHA256Digest?,
        staged: URL,
        current: URL,
        previous: URL
    ) throws {
        // Only a *stale* previous set goes to `.trash`: after a crash between
        // the staged→previous move and the `filesPromoted` step, `previous/`
        // already holds the `from` set and must stay (package-store.md §5.5).
        if fileManager.fileExists(atPath: previous.path),
            stagedSetDigest(in: previous) != fromDigest
        {
            var trashedPrevious =
                trashDirectory
                .appendingPathComponent("\(transaction)-previous", isDirectory: true)
            var suffix = 1
            while fileManager.fileExists(atPath: trashedPrevious.path) {
                suffix += 1
                trashedPrevious =
                    trashDirectory
                    .appendingPathComponent(
                        "\(transaction)-previous-\(suffix)", isDirectory: true)
            }
            try moveItem(previous, to: trashedPrevious)
        }
        let stagedDigest = stagedSetDigest(in: staged)
        let currentDigest = stagedSetDigest(in: current)
        if stagedDigest == toDigest {
            // Swap not done yet (or crash before it): exchange staged/current,
            // unless current already holds the new set.
            if currentDigest != toDigest {
                guard !fileManager.fileExists(atPath: previous.path) else {
                    throw PackageStoreFailure.io
                }
                if fileManager.fileExists(atPath: current.path) {
                    try swapDirectories(staged, current)
                } else {
                    try moveItem(staged, to: current)
                }
            }
        }
        // `staged/` now holds the old current set (or a foreign set): anything
        // that is not the new set and remains in `staged/` goes to `previous/`
        // when it matches `fromDigest`, otherwise to `.trash`.
        if fileManager.fileExists(atPath: staged.path) {
            let remaining = stagedSetDigest(in: staged)
            if remaining == fromDigest, !fileManager.fileExists(atPath: previous.path) {
                try moveItem(staged, to: previous)
            } else {
                let trashed =
                    trashDirectory
                    .appendingPathComponent("\(transaction)-staged", isDirectory: true)
                guard !fileManager.fileExists(atPath: trashed.path) else {
                    throw PackageStoreFailure.io
                }
                try moveItem(staged, to: trashed)
            }
        }
        guard stagedSetDigest(in: current) == toDigest else {
            throw PackageStoreFailure.io
        }
    }

    /// Atomically exchanges two directories via `renamex_np(RENAME_SWAP)`
    /// (package-store.md §5.2). Both paths must exist.
    private func swapDirectories(_ lhs: URL, _ rhs: URL) throws {
        var status: Int32 = -1
        lhs.path.withCString { lhsPath in
            rhs.path.withCString { rhsPath in
                status = renamex_np(lhsPath, rhsPath, UInt32(RENAME_SWAP))
            }
        }
        guard status == 0 else {
            throw PackageStoreFailure.io
        }
        try syncDirectory(lhs.deletingLastPathComponent())
    }

    /// The record after an `update` transaction commits: `current/` is the
    /// staged set, `previous/` retains the old current set, `staged/` clears.
    private func recordAfterUpdate(
        _ old: PackageRecord,
        info: StorePackageInfo,
        generation: UUID,
        operationID: UUID,
        startedAt: Date
    ) -> PackageRecord {
        var record = old
        record.displayName = info.displayName
        record.versionCode = info.versionCode
        record.versionName = info.versionName
        record.signingCertificates = info.signingDigests
        record.state = .installed
        let newCurrent = record.artifacts.staged.map {
            ArtifactSlotSummary(
                versionCode: $0.versionCode,
                versionName: $0.versionName,
                setDigest: $0.setDigest,
                size: $0.size,
                fileCount: $0.fileCount
            )
        }
        record.artifacts = ArtifactSlots(
            current: newCurrent,
            previous: old.artifacts.current,
            staged: nil,
            currentMatchesAndroid: true
        )
        record.android = AndroidPackageFacts(
            updateOwner: info.updateOwner,
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
            kind: .update,
            operationID: operationID,
            startedAt: startedAt,
            finishedAt: clock(),
            fromVersionCode: old.versionCode,
            result: .succeeded
        )
        record.updatedAt = clock()
        return record
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

    /// Classifies an import against the managed record (package-store.md §4.7).
    /// `uninstalledKeepingData` takes precedence over the signer and version
    /// checks: a reinstall that restores kept data is legal with any signer.
    private func classifyRelation(
        packageID: PackageID,
        versionCode: VersionCode,
        setDigest: SHA256Digest,
        signerDigests: [SHA256Digest]
    ) -> ImportRelation {
        guard let record = records[packageID] else { return .newPackage }
        if record.state == .uninstalledKeepingData {
            return .uninstalledWithData(record.versionCode)
        }
        let candidateSigners = Set(signerDigests)
        let installedSigners = Set(record.signingCertificates)
        if !candidateSigners.isEmpty, !installedSigners.isEmpty,
            candidateSigners != installedSigners
        {
            return .otherSigner
        }
        if versionCode < record.versionCode {
            return .downgrade(from: record.versionCode)
        }
        if versionCode > record.versionCode {
            return .update(from: record.versionCode)
        }
        if setDigest == record.artifacts.current?.setDigest,
            record.state == .installed
        {
            return .sameAsInstalled
        }
        return .reinstallSameVersion
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

    /// Queries Android for the package's installed metadata through the store
    /// agent (update-system.md §8.1 H1). Nil when Android reports no such
    /// package.
    public func installedPackageInfo(_ packageID: PackageID) async throws -> StorePackageInfo? {
        try requireOpen()
        guard let runtimeAccess else { throw PackageStoreFailure.runtimeUnavailable }
        return try await queryPackage(packageID, through: runtimeAccess)
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
        set.installSpecs.map { incoming.appendingPathComponent($0.name) }
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
            ("update", "guestCommitRequested"), ("update", "guestInstalled"),
            ("update", "filesPromoted"),
            ("uninstall", "guestUninstallRequested"), ("uninstall", "guestUninstalled"),
            ("relinquishOwnership", _):
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
