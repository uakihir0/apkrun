import DiagnosticsCore
import Foundation
import RuntimeAPI

/// The state of a registry entry (wrapper-json.md §4.3).
public enum WrapperEntryState: String, Codable, Sendable {
    /// Generation finished; the bundle is at `path`.
    case active
    /// The bundle is staged and waiting for placement.
    case pending
    /// A refresh swapped in a new bundle (#77).
    case refreshing
}

/// How an entry was authorized (wrapper.md §7.2).
public enum WrapperApprovalSource: String, Codable, Sendable {
    /// apkrund built it on this Mac.
    case generated
    /// The user approved it (wrapper.md §7.3).
    case user
}

/// User-chosen name and icon overrides (wrapper-json.md §4.2).
public struct WrapperCustomization: Codable, Sendable, Equatable {
    /// The user's custom name; `null` means the Android label.
    public var displayName: String?
    /// The custom icon file `<bundleId>.png` in `Wrappers/icons/`; `null` means
    /// the Android icon.
    public var iconFile: String?

    /// Creates a customization record.
    public init(displayName: String? = nil, iconFile: String? = nil) {
        self.displayName = displayName
        self.iconFile = iconFile
    }
}

/// One `wrappers` entry of `registry.json` (wrapper-json.md §4.2).
public struct WrapperRegistryEntry: Codable, Sendable, Equatable {
    /// `map(packageId)`; the bundle ID and code-signing identifier.
    public var bundleId: String
    /// The only package this wrapper may open (NFR-SEC-07).
    public var packageId: String
    /// `local`, `portable`, or `distribution`.
    public var kind: WrapperKind
    /// The journal state (wrapper.md §6.2 crash safety).
    public var state: WrapperEntryState
    /// The last known bundle location.
    public var path: String
    /// Security bookmark of `path`; present while `active` or `refreshing`.
    public var bookmark: String?
    /// The staged bundle while `pending` or `refreshing`.
    public var stagingPath: String?
    /// The code directory hash accepted by the `.wrapper` endpoint.
    public var cdhash: String
    /// The new bundle's cdhash while `refreshing`.
    public var pendingCdhash: String?
    /// `APKRunLauncherVersion` of the bundle.
    public var launcherVersion: String
    /// `APKRunLauncherAPI` of the bundle.
    public var launcherAPI: String
    /// `APKRunWrapperFormat` of the bundle.
    public var formatVersion: Int
    /// The bundle file name without `.app`.
    public var fileName: String
    /// `CFBundleDisplayName`.
    public var displayName: String
    /// User-chosen name and icon.
    public var customization: WrapperCustomization
    /// SHA-256 of the 1024 px icon master; `null` with a custom icon.
    public var iconDigest: String?
    /// `generated` or `user`.
    public var approval: WrapperApprovalSource
    /// When the entry was created.
    public var createdAt: Date
    /// The last finished refresh; `null` before the first.
    public var refreshedAt: Date?
    /// The last full validation; `null` before the first.
    public var lastValidatedAt: Date?

    /// Creates a registry entry with the fields every state shares.
    public init(
        bundleId: String,
        packageId: String,
        kind: WrapperKind,
        state: WrapperEntryState,
        path: String,
        cdhash: String,
        launcherVersion: String,
        launcherAPI: String,
        fileName: String,
        displayName: String,
        createdAt: Date
    ) {
        self.bundleId = bundleId
        self.packageId = packageId
        self.kind = kind
        self.state = state
        self.path = path
        bookmark = nil
        stagingPath = nil
        self.cdhash = cdhash
        pendingCdhash = nil
        self.launcherVersion = launcherVersion
        self.launcherAPI = launcherAPI
        formatVersion = 1
        self.fileName = fileName
        self.displayName = displayName
        customization = WrapperCustomization()
        iconDigest = nil
        approval = .generated
        self.createdAt = createdAt
        refreshedAt = nil
        lastValidatedAt = nil
    }
}

/// One `denied` entry of `registry.json` (wrapper-json.md §4.4).
public struct WrapperDeniedEntry: Codable, Sendable, Equatable {
    /// The refused wrapper.
    public var bundleId: String
    /// The refused bundle's cdhash.
    public var cdhash: String
    /// Until when a new approval request is refused at once.
    public var until: Date

    /// Creates a denied entry.
    public init(bundleId: String, cdhash: String, until: Date) {
        self.bundleId = bundleId
        self.cdhash = cdhash
        self.until = until
    }
}

/// The `registry.json` document (wrapper-json.md §4).
public struct WrapperRegistryFile: Codable, Sendable, Equatable {
    /// The file schema version; `1` in v1.
    public var schemaVersion: Int
    /// The registered wrappers, sorted by `bundleId`.
    public var wrappers: [WrapperRegistryEntry]
    /// The refused wrappers, sorted by `bundleId` then `cdhash`.
    public var denied: [WrapperDeniedEntry]

    /// Creates a registry file.
    public init(
        schemaVersion: Int = 1,
        wrappers: [WrapperRegistryEntry],
        denied: [WrapperDeniedEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.wrappers = wrappers
        self.denied = denied
    }

    /// An empty registry.
    public static let empty = WrapperRegistryFile(wrappers: [], denied: [])
}

/// Encodes `registry.json` deterministically: sorted keys, pretty printed,
/// unescaped slashes, trailing newline (wrapper-json.md §1.2, §4).
public enum WrapperRegistryCodec {
    /// The largest accepted registry size (wrapper-json.md §5.3).
    public static let maximumBytes = 4 * 1024 * 1024

    /// Canonical encoder shared by every host JSON document.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Canonical decoder.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Encodes a registry file to its canonical bytes.
    public static func encode(_ file: WrapperRegistryFile) throws -> Data {
        var data = try makeEncoder().encode(file)
        data.append(0x0A)
        return data
    }
}

/// The wrapper registry: the only writer of `Wrappers/registry.json` and the
/// crash-safety journal of wrapper generation (wrapper.md §7.2). Recovery runs
/// at apkrund start: a `pending` entry whose final bundle exists with the
/// recorded cdhash is activated; otherwise staging and `.apkrun-<uuid>`
/// leftovers are deleted and the entry is dropped.
public actor WrapperRegistry {
    /// How `load` found the file on disk.
    public enum LoadOutcome: Sendable, Equatable {
        /// A valid file (or none) was read.
        case ready
        /// The file was corrupt and kept aside as `registry.json.corrupt-<time>`.
        case corrupt
        /// The file was written by a newer schema version; reads are degraded
        /// and writes are refused (wrapper-json.md §5.3).
        case newerVersion
    }

    /// The registry file location.
    public let fileURL: URL
    /// The directory that holds `staging/`; cleaned by `recover()`.
    public let stagingRoot: URL

    private var document: WrapperRegistryFile
    private var outcome: LoadOutcome
    private let fileManager: FileManager
    private let logger: APKLogger
    private var hasPendingAfterRecovery = false

    /// Creates a registry bound to a file. `stagingRoot` is the directory that
    /// holds `staging/` (`Wrappers/`), used only by `recover()`.
    public init(
        fileURL: URL,
        stagingRoot: URL? = nil,
        fileManager: FileManager = .default,
        sink: (any LogSink)? = nil
    ) {
        self.fileURL = fileURL
        self.stagingRoot = stagingRoot ?? fileURL.deletingLastPathComponent()
        self.fileManager = fileManager
        logger = APKLogger(category: WrapperLogCategory.registry, sink: sink)
        document = .empty
        outcome = .ready
    }

    /// Creates a registry on `APKRunPaths` locations.
    public init(paths: APKRunPaths, fileManager: FileManager = .default, sink: (any LogSink)? = nil) {
        self.init(
            fileURL: paths.wrapperRegistryFile,
            stagingRoot: paths.wrappersDirectory,
            fileManager: fileManager,
            sink: sink
        )
    }

    /// Loads the file per wrapper-json.md §5.3. Returns how it was found.
    @discardableResult
    public func load() -> LoadOutcome {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            document = .empty
            outcome = .ready
            return outcome
        }
        let decoded: WrapperRegistryFile? = {
            guard data.count <= WrapperRegistryCodec.maximumBytes else { return nil }
            guard
                let file = try? WrapperRegistryCodec.makeDecoder()
                    .decode(WrapperRegistryFile.self, from: data)
            else { return nil }
            return Self.sanitized(file)
        }()
        guard var file = decoded, file.schemaVersion >= 1 else {
            keepAsideAsCorrupt()
            document = .empty
            outcome = .corrupt
            return outcome
        }
        if file.schemaVersion > 1 {
            document = file
            outcome = .newerVersion
            return outcome
        }
        file.schemaVersion = 1
        document = file
        outcome = .ready
        return outcome
    }

    /// Whether the file was corrupt at the last `load()`.
    public var lastLoadWasCorrupt: Bool {
        outcome == .corrupt
    }

    /// Whether `pending` entries survived the last `recover()` (health
    /// `wrappers.registry` warns).
    public var hasUnresolvedPendingEntries: Bool {
        hasPendingAfterRecovery
    }

    /// Every registered entry.
    public func entries() -> [WrapperRegistryEntry] {
        document.wrappers
    }

    /// The entry for a bundle ID, if any. Bundle IDs compare case-insensitively.
    public func entry(bundleID: String) -> WrapperRegistryEntry? {
        document.wrappers.first { $0.bundleId.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// The entry for a package ID, if any.
    public func entry(packageID: RuntimePackageID) -> WrapperRegistryEntry? {
        document.wrappers.first { $0.packageId == packageID.rawValue }
    }

    /// Inserts or replaces the entry for `entry.bundleId` with state `pending`
    /// (generation step 10).
    public func markPending(_ entry: WrapperRegistryEntry) throws {
        var pending = entry
        pending.state = .pending
        upsert(pending)
        try save()
    }

    /// Marks the entry `active` with the placed location and bookmark
    /// (generation step 12).
    public func activate(bundleID: String, path: URL, bookmark: Data) throws {
        guard var entry = entry(bundleID: bundleID) else {
            throw WrapperFailure.verificationFailed("no registry entry for \(bundleID)")
        }
        entry.state = .active
        entry.path = path.path
        entry.bookmark = bookmark.base64EncodedString()
        entry.stagingPath = nil
        entry.pendingCdhash = nil
        upsert(entry)
        try save()
    }

    /// Records the moved or renamed location of an entry (wrapper-json.md §4.3).
    public func updateLocation(bundleID: String, path: URL, bookmark: Data) throws {
        guard var entry = entry(bundleID: bundleID) else { return }
        entry.path = path.path
        entry.fileName = path.deletingPathExtension().lastPathComponent
        entry.bookmark = bookmark.base64EncodedString()
        upsert(entry)
        try save()
    }

    /// Records the last full validation time (wrapper-json.md §4.2).
    public func markValidated(bundleID: String, at date: Date = Date()) throws {
        guard var entry = entry(bundleID: bundleID) else { return }
        entry.lastValidatedAt = date
        upsert(entry)
        try save()
    }

    /// Removes the entry for a bundle ID (removal is #77; used by recovery).
    public func remove(bundleID: String) throws {
        document.wrappers.removeAll {
            $0.bundleId.caseInsensitiveCompare(bundleID) == .orderedSame
        }
        try save()
    }

    /// Adds or refreshes a denied entry (wrapper-json.md §4.4).
    public func deny(bundleID: String, cdhash: String, until: Date) throws {
        document.denied.removeAll {
            $0.bundleId == bundleID && $0.cdhash == cdhash
        }
        document.denied.append(WrapperDeniedEntry(bundleId: bundleID, cdhash: cdhash, until: until))
        pruneExpiredDenials()
        sortDocument()
        try save()
    }

    /// Whether an approval request for this pair is refused at once.
    public func isDenied(bundleID: String, cdhash: String, at date: Date = Date()) -> Bool {
        document.denied.contains { $0.bundleId == bundleID && $0.cdhash == cdhash && $0.until > date }
    }

    /// Removes every denied entry for a bundle ID (Settings → Privacy).
    public func clearDenial(bundleID: String) throws {
        document.denied.removeAll { $0.bundleId == bundleID }
        try save()
    }

    /// The denied entries, for Settings → Privacy.
    public func deniedEntries() -> [WrapperDeniedEntry] {
        document.denied
    }

    /// Runs recovery at apkrund start (wrapper.md §6.2 crash safety).
    ///
    /// - `pending`: activates the entry when the bundle at `path` exists with
    ///   the recorded cdhash; otherwise deletes the staging directory and
    ///   `.apkrun-<uuid>` leftovers and drops the entry.
    /// - `refreshing`: completes the refresh when the bundle's cdhash equals
    ///   `pendingCdhash`; otherwise returns the entry to `active` unchanged.
    ///
    /// - Parameter cdhashOf: reads the cdhash of a bundle. Defaults to
    ///   `WrapperCodeSign.cdhash`.
    @discardableResult
    public func recover(
        cdhashOf: (URL) -> String? = WrapperCodeSign.cdhash(of:)
    ) -> Bool {
        var changed = false
        let unresolved = false
        for entry in document.wrappers {
            switch entry.state {
            case .active:
                continue
            case .pending:
                let finalURL = URL(fileURLWithPath: entry.path)
                if fileManager.fileExists(atPath: finalURL.path),
                    cdhashOf(finalURL) == entry.cdhash
                {
                    var updated = entry
                    updated.state = .active
                    updated.stagingPath = nil
                    updated.bookmark = (try? finalURL.bookmarkData())?
                        .base64EncodedString()
                    upsert(updated)
                } else {
                    if let stagingPath = entry.stagingPath {
                        try? fileManager.removeItem(
                            at: URL(fileURLWithPath: stagingPath)
                                .deletingLastPathComponent()
                        )
                    }
                    removeLeftovers(near: finalURL)
                    document.wrappers.removeAll { $0.bundleId == entry.bundleId }
                    logger.notice(
                        "Dropped pending wrapper entry \(entry.bundleId, .public) after a failed generation.")
                }
                changed = true
            case .refreshing:
                let finalURL = URL(fileURLWithPath: entry.path)
                if let pendingCdhash = entry.pendingCdhash,
                    cdhashOf(finalURL) == pendingCdhash
                {
                    var updated = entry
                    updated.state = .active
                    updated.cdhash = pendingCdhash
                    updated.pendingCdhash = nil
                    updated.stagingPath = nil
                    updated.refreshedAt = Date()
                    upsert(updated)
                } else {
                    if let stagingPath = entry.stagingPath {
                        try? fileManager.removeItem(
                            at: URL(fileURLWithPath: stagingPath)
                        )
                    }
                    var updated = entry
                    updated.state = .active
                    updated.pendingCdhash = nil
                    updated.stagingPath = nil
                    upsert(updated)
                }
                changed = true
            }
        }
        cleanOrphanedStaging()
        hasPendingAfterRecovery =
            unresolved
            || document.wrappers.contains {
                $0.state != .active
            }
        if changed {
            try? save()
        }
        return hasPendingAfterRecovery
    }

    /// Persists the document atomically (write, fsync, rename).
    public func save() throws {
        guard outcome != .newerVersion else { return }
        pruneExpiredDenials()
        sortDocument()
        let data = try WrapperRegistryCodec.encode(document)
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")
        fileManager.createFile(atPath: temporary.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        // rename(2) atomically replaces the destination on the same volume.
        guard rename(temporary.path, fileURL.path) == 0 else {
            try? fileManager.removeItem(at: temporary)
            throw WrapperFailure.registryUnavailable
        }
    }

    private func keepAsideAsCorrupt() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let corrupt = fileURL.deletingLastPathComponent()
            .appendingPathComponent(
                "registry.json.corrupt-\(formatter.string(from: Date()))")
        try? fileManager.moveItem(at: fileURL, to: corrupt)
        logger.error(
            "registry.json was corrupt and was kept aside.", errorCode: "wrapper.registryUnavailable")
    }

    /// Applies the per-entry acceptance rules of wrapper-json.md §5.3: an entry
    /// that breaks §4.2 or the code checks is ignored and dropped at the next
    /// write.
    private static func sanitized(_ file: WrapperRegistryFile) -> WrapperRegistryFile? {
        guard file.schemaVersion >= 1 else { return nil }
        var file = file
        file.wrappers = file.wrappers.filter { entry in
            guard entry.bundleId.hasPrefix(BundleIDMapper.prefix),
                entry.bundleId == BundleIDMapper.map(entry.packageId),
                entry.cdhash.range(
                    of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
                entry.path.hasSuffix(".app"), entry.path.hasPrefix("/"),
                entry.path.utf8.count <= 1024,
                !entry.fileName.isEmpty, entry.fileName.utf8.count <= 251,
                !entry.fileName.contains("/"),
                !entry.displayName.isEmpty, entry.displayName.count <= 1024,
                entry.formatVersion >= 1
            else { return false }
            switch entry.state {
            case .active:
                return entry.bookmark != nil && entry.stagingPath == nil
                    && entry.pendingCdhash == nil
            case .pending:
                return entry.stagingPath != nil && entry.bookmark == nil
                    && entry.pendingCdhash == nil
            case .refreshing:
                return entry.bookmark != nil && entry.stagingPath != nil
                    && entry.pendingCdhash != nil && entry.pendingCdhash != entry.cdhash
            }
        }
        file.denied = file.denied.filter {
            $0.bundleId.hasPrefix(BundleIDMapper.prefix)
                && $0.cdhash.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
        }
        return file
    }

    private func upsert(_ entry: WrapperRegistryEntry) {
        document.wrappers.removeAll {
            $0.bundleId.caseInsensitiveCompare(entry.bundleId) == .orderedSame
        }
        document.wrappers.append(entry)
    }

    private func sortDocument() {
        document.wrappers.sort { $0.bundleId.localizedCaseInsensitiveCompare($1.bundleId) == .orderedAscending }
        document.denied.sort {
            $0.bundleId == $1.bundleId
                ? $0.cdhash < $1.cdhash
                : $0.bundleId.localizedCaseInsensitiveCompare($1.bundleId) == .orderedAscending
        }
        document.wrappers = Array(document.wrappers.prefix(1000))
        document.denied = Array(document.denied.prefix(1000))
    }

    private func pruneExpiredDenials(at date: Date = Date()) {
        document.denied.removeAll { $0.until <= date }
    }

    private func removeLeftovers(near destination: URL) {
        let directory = destination.deletingLastPathComponent()
        guard
            let items = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        else { return }
        for item in items where item.lastPathComponent.contains(".apkrun-") {
            try? fileManager.removeItem(at: item)
        }
    }

    private func cleanOrphanedStaging() {
        let staging = stagingRoot.appendingPathComponent("staging", isDirectory: true)
        guard
            let items = try? fileManager.contentsOfDirectory(
                at: staging,
                includingPropertiesForKeys: nil
            )
        else { return }
        let activeStaging = Set(document.wrappers.compactMap(\.stagingPath))
        for item in items {
            if !activeStaging.contains(where: { $0.hasPrefix(item.path) }) {
                try? fileManager.removeItem(at: item)
            }
        }
    }
}
