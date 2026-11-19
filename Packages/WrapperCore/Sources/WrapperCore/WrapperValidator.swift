import DiagnosticsCore
import Foundation
import RuntimeAPI

/// `WrapperRefreshReason`, `WrapperState`, and `BundleProblem` are defined in
/// RuntimeAPI so the wire and domain layers share one type (runtime-api.md §10).

/// The on-demand status of a wrapper (wrapper.md §9.1).
public struct WrapperStatus: Codable, Sendable, Equatable {
    /// The state decided by the first failing check.
    public var state: WrapperState
    /// Why the wrapper wants a refresh.
    public var refreshReasons: Set<WrapperRefreshReason>

    /// Creates a status.
    public init(state: WrapperState, refreshReasons: Set<WrapperRefreshReason> = []) {
        self.state = state
        self.refreshReasons = refreshReasons
    }
}

/// Runs the structural checks of wrapper.md §9.1 (checks 1–3 and 5) and the
/// wrapper.json cross-checks of wrapper-json.md §5.1 on any bundle, registered
/// or not. `deep` adds the strict all-architecture signature check (check 4).
public struct WrapperValidator: Sendable {
    /// The detailed result of `verify` (runtime-api.md §10.4
    /// `WrapperVerification`).
    public struct Verification: Sendable, Equatable {
        /// The bundle that was checked.
        public var bundleURL: URL
        /// `CFBundleIdentifier` when the bundle is an APKRun wrapper.
        public var bundleID: String?
        /// `APKRunPackageID` when readable.
        public var packageID: String?
        /// The wrapper kind when readable.
        public var kind: WrapperKind?
        /// Whether the bundle ID has a registry entry.
        public var registered: Bool
        /// The registry-observed state; `nil` for bundles that are not wrappers.
        public var state: WrapperState?
        /// The static-check failures found (wrapper.md §13).
        public var problems: [BundleProblem]
        /// `adHoc`, `developerID`, or `unknown`.
        public var signer: String?
        /// The 40-hex code directory hash.
        public var cdhash: String?
        /// `APKRunLauncherVersion`.
        public var launcherVersion: String?
        /// `APKRunLauncherAPI`.
        public var launcherAPI: String?
        /// Why the wrapper wants a refresh (check 6).
        public var refreshReasons: Set<WrapperRefreshReason>

        /// Creates a verification result.
        public init(bundleURL: URL) {
            self.bundleURL = bundleURL
            bundleID = nil
            packageID = nil
            kind = nil
            registered = false
            state = nil
            problems = []
            signer = nil
            cdhash = nil
            launcherVersion = nil
            launcherAPI = nil
            refreshReasons = []
        }
    }

    private let registry: WrapperRegistry
    private let currentLauncher: LauncherBuild?
    private let packageExists: @Sendable (String) -> Bool
    private let logger: APKLogger

    /// Creates a validator.
    ///
    /// - Parameters:
    ///   - registry: the wrapper registry for checks 1 and 3.
    ///   - currentLauncher: the installed template's build constants; check 6
    ///     refresh reasons are skipped when nil.
    ///   - packageExists: check 5 — whether the store has a record for the
    ///     package. WrapperCore never reads the store itself.
    public init(
        registry: WrapperRegistry,
        currentLauncher: LauncherBuild? = nil,
        packageExists: @escaping @Sendable (String) -> Bool,
        sink: (any LogSink)? = nil
    ) {
        self.registry = registry
        self.currentLauncher = currentLauncher
        self.packageExists = packageExists
        logger = APKLogger(category: WrapperLogCategory.lifecycle, sink: sink)
    }

    /// Verifies a bundle (checks 1–3 and 5 of wrapper.md §9.1, plus X1–X6 of
    /// wrapper-json.md §2.3 for any bundle). Throws `bundleInvalid` only when
    /// the bundle is not an APKRun wrapper.
    public func verify(url: URL, deep: Bool) async throws(WrapperFailure) -> Verification {
        var result = Verification(bundleURL: url)

        // Check 1: the bundle exists and is not in the Trash.
        guard FileManager.default.fileExists(atPath: url.path),
            !url.path.contains("/.Trash/")
        else {
            result.state = .missing
            result.problems = []
            return result
        }

        // Check 2: read access.
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            result.state = .inaccessible
            return result
        }

        // Structure: Info.plist with APKRunPackageID, an executable, wrapper.json.
        guard let plist = InfoPlistWriter.infoDictionary(of: url),
            let packageID = plist["APKRunPackageID"] as? String,
            let bundleID = plist["CFBundleIdentifier"] as? String
        else {
            throw .bundleInvalid(url, reason: .wrapperJSONInvalid)
        }
        result.packageID = packageID
        result.bundleID = bundleID
        result.launcherVersion = plist["APKRunLauncherVersion"] as? String
        result.launcherAPI = plist["APKRunLauncherAPI"] as? String
        result.kind = (plist["APKRunWrapperKind"] as? String).flatMap(WrapperKind.init(rawValue:))

        var problems: [BundleProblem] = []

        // X5: CFBundleIdentifier equals map(APKRunPackageID).
        if bundleID != BundleIDMapper.map(packageID) {
            problems.append(.bundleIDMismatch)
        }
        // X2: formatVersion equals APKRunWrapperFormat and is supported.
        let formatVersion = plist["APKRunWrapperFormat"] as? Int ?? -1
        guard formatVersion == InfoPlistWriter.wrapperFormat else {
            problems.append(.wrapperJSONInvalid)
            throw .bundleInvalid(url, reason: .wrapperJSONInvalid)
        }

        // wrapper.json: readable, ≤ 64 KiB, schema, X1 (packageId), X3 (kind),
        // X4 (launcherAPI).
        let document: WrapperDocument
        do {
            document = try WrapperDocumentCodec.load(from: url)
        } catch {
            throw .bundleInvalid(url, reason: .wrapperJSONInvalid)
        }
        if document.application.packageId != packageID {
            throw .bundleInvalid(url, reason: .packageMismatch)
        }
        if document.kind != result.kind || document.formatVersion != formatVersion {
            problems.append(.wrapperJSONInvalid)
        }
        if document.runtime.launcherAPI != result.launcherAPI {
            problems.append(.wrapperJSONInvalid)
        }

        let entry = await registry.entry(bundleID: bundleID)
        result.registered = entry != nil

        // Check 3 + X6: the signature's identifier equals `map(packageId)` on
        // every check (wrapper-json.md §2.3 X6); `deep` additionally runs the
        // strict all-architecture validity check (wrapper.md §9.1 check 4).
        let signatureOK: Bool
        if deep {
            signatureOK = WrapperCodeSign.signatureIsValid(bundleURL: url, identifier: bundleID)
        } else {
            signatureOK = WrapperCodeSign.signatureIdentifier(of: url) == bundleID
        }
        if !signatureOK {
            problems.append(.signatureInvalid)
        }
        result.cdhash = WrapperCodeSign.cdhash(of: url)
        if let entry, let cdhash = result.cdhash, cdhash != entry.cdhash {
            problems.append(.signatureInvalid)
        }
        result.signer = result.cdhash != nil ? "adHoc" : "unknown"

        result.problems = problems

        if !problems.isEmpty {
            // A modified local wrapper is reported, never approvable (§7.3).
            result.state = .signatureInvalid
            return result
        }

        // Check 5: the store has a record for the package.
        if !packageExists(packageID) {
            result.state = .unknownPackage
            return result
        }

        // Check 6: refresh reasons (state stays `valid`).
        var reasons: Set<WrapperRefreshReason> = []
        if let current = currentLauncher,
            let found = result.launcherVersion,
            found != current.launcherVersion
        {
            reasons.insert(.launcher(version: found))
        }
        if let entry, entry.displayName != (plist["CFBundleDisplayName"] as? String) {
            reasons.insert(.displayName)
        }
        result.refreshReasons = reasons

        result.state = .valid
        return result
    }
}
