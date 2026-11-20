import APKStoreCore
import Foundation

// Core types of the update system (update-system.md §4.1, state-machines.md §6).

/// An opaque, provider-defined checkpoint of what a provider saw last.
public struct ProviderCursor: Codable, Sendable, Hashable {
    /// The provider type that produced the cursor.
    public var type: ProviderType
    /// The provider-defined cursor value (an ETag, a release id, a timestamp).
    public var value: String

    /// Creates a provider cursor.
    public init(type: ProviderType, value: String) {
        self.type = type
        self.value = value
    }
}

/// The guest facts a provider needs to filter candidates (SDK and ABIs).
public struct GuestFacts: Codable, Sendable, Hashable {
    /// The guest Android SDK level (37 on the baseline image).
    public var sdk: Int
    /// The guest ABIs, most preferred first.
    public var abis: [String]

    /// Creates guest facts; defaults to the baseline image.
    public init(sdk: Int = 37, abis: [String] = ["arm64-v8a"]) {
        self.sdk = sdk
        self.abis = abis
    }
}

/// What a provider sees of the installed package.
public struct InstalledPackage: Sendable {
    /// The package identifier.
    public var id: PackageID
    /// The installed versionCode.
    public var versionCode: VersionCode
    /// The current signer set, one digest per signer.
    public var signerDigests: [SHA256Digest]
    /// The signing history, oldest signer first.
    public var lineage: [SHA256Digest]
    /// The guest the package runs on.
    public var guest: GuestFacts
    /// The cursor the provider produced for the last processed candidate.
    public var lastCursor: ProviderCursor?

    /// Creates an installed-package view.
    public init(
        id: PackageID,
        versionCode: VersionCode,
        signerDigests: [SHA256Digest],
        lineage: [SHA256Digest],
        guest: GuestFacts,
        lastCursor: ProviderCursor? = nil
    ) {
        self.id = id
        self.versionCode = versionCode
        self.signerDigests = signerDigests
        self.lineage = lineage
        self.guest = guest
        self.lastCursor = lastCursor
    }
}

/// The kind of a remote update artifact.
public enum RemoteArtifactKind: Codable, Sendable, Hashable {
    /// A single APK (the base or a whole-app update).
    case apk
    /// One split APK carrying its split name.
    case split(String)
    /// A container archive (`.apks`, `.xapk`, `.apkm`).
    case container
}

/// One artifact of an update candidate.
public struct RemoteArtifact: Codable, Sendable, Hashable {
    /// The artifact location: HTTPS, or a file URL for LocalProvider.
    public var url: URL
    /// What the artifact is.
    public var kind: RemoteArtifactKind
    /// The provider-declared SHA-256; required for Direct and F-Droid.
    public var sha256: SHA256Digest?
    /// The declared byte size, when known.
    public var size: Int64?

    /// Creates a remote artifact.
    public init(url: URL, kind: RemoteArtifactKind, sha256: SHA256Digest? = nil, size: Int64? = nil) {
        self.url = url
        self.kind = kind
        self.sha256 = sha256
        self.size = size
    }
}

/// A release a provider found that may be newer than the installed package.
public struct UpdateCandidate: Codable, Sendable, Hashable {
    /// The package it updates.
    public var packageID: PackageID
    /// The provider that produced it.
    public var provider: UpdateProviderRef
    /// The declared versionCode; nil when unknown before download.
    public var declaredVersionCode: VersionCode?
    /// The declared versionName, when known.
    public var declaredVersionName: String?
    /// Provider-declared signer digests (F-Droid index, Direct manifest).
    public var declaredSignerDigests: [SHA256Digest]?
    /// The artifacts to download.
    public var artifacts: [RemoteArtifact]
    /// Plain-text release notes, at most 16 KiB; never HTML.
    public var releaseNotes: String?
    /// When the provider published the release.
    public var publishedAt: Date?
    /// Identifies this release to the provider.
    public var cursor: ProviderCursor

    /// Creates an update candidate.
    public init(
        packageID: PackageID,
        provider: UpdateProviderRef,
        declaredVersionCode: VersionCode? = nil,
        declaredVersionName: String? = nil,
        declaredSignerDigests: [SHA256Digest]? = nil,
        artifacts: [RemoteArtifact],
        releaseNotes: String? = nil,
        publishedAt: Date? = nil,
        cursor: ProviderCursor
    ) {
        self.packageID = packageID
        self.provider = provider
        self.declaredVersionCode = declaredVersionCode
        self.declaredVersionName = declaredVersionName
        self.declaredSignerDigests = declaredSignerDigests
        self.artifacts = artifacts
        self.releaseNotes = releaseNotes
        self.publishedAt = publishedAt
        self.cursor = cursor
    }
}

/// The shared HTTP session of update-system.md §3.4.
public protocol UpdateHTTPClient: Sendable {
    /// Performs a GET request and returns the body and response metadata.
    /// Reading stops once `byteLimit` + 1 bytes have arrived, so a body
    /// longer than the limit can never be buffered in full.
    func get(_ url: URL, headers: [String: String], byteLimit: Int64?) async throws(UpdateFailure)
        -> HTTPResponse

    /// Streams a GET request into `file`, hashing the bytes while they
    /// arrive. Writing stops after `byteLimit` bytes (`limitHit` in the
    /// result); a nil `byteLimit` streams without a cap. The caller maps the
    /// status code to its failure semantics.
    func download(
        _ url: URL,
        headers: [String: String],
        into file: URL,
        byteLimit: Int64?
    ) async throws(UpdateFailure) -> DownloadResponse
}

/// Response metadata an HTTP provider needs for cursors.
public struct HTTPResponse: Sendable {
    /// The response status code.
    public var status: Int
    /// The response body.
    public var body: Data
    /// The `ETag` header value, when present.
    public var etag: String?
    /// The `Last-Modified` header value, when present.
    public var lastModified: String?
    /// The URL the response finally came from, after redirects.
    public var finalURL: URL?
    /// The `Retry-After` header in seconds, when present.
    public var retryAfter: TimeInterval?

    /// Creates an HTTP response.
    public init(
        status: Int,
        body: Data,
        etag: String? = nil,
        lastModified: String? = nil,
        finalURL: URL? = nil,
        retryAfter: TimeInterval? = nil
    ) {
        self.status = status
        self.body = body
        self.etag = etag
        self.lastModified = lastModified
        self.finalURL = finalURL
        self.retryAfter = retryAfter
    }
}

/// The result of a streamed download.
public struct DownloadResponse: Sendable {
    /// The response status code.
    public var status: Int
    /// Bytes written to the file.
    public var bytesWritten: Int64
    /// SHA-256 of the written bytes.
    public var sha256: SHA256Digest?
    /// True when writing stopped because `byteLimit` was reached.
    public var limitHit: Bool
    /// The URL the response finally came from, after redirects.
    public var finalURL: URL?
    /// The `Retry-After` header in seconds, when present.
    public var retryAfter: TimeInterval?

    /// Creates a download result.
    public init(
        status: Int,
        bytesWritten: Int64,
        sha256: SHA256Digest? = nil,
        limitHit: Bool = false,
        finalURL: URL? = nil,
        retryAfter: TimeInterval? = nil
    ) {
        self.status = status
        self.bytesWritten = bytesWritten
        self.sha256 = sha256
        self.limitHit = limitHit
        self.finalURL = finalURL
        self.retryAfter = retryAfter
    }
}

extension UpdateHTTPClient {
    /// Clients that cannot stream answer `providerUnreachable` — providers
    /// only call `download` on transports that support it.
    public func download(
        _ url: URL,
        headers: [String: String],
        into file: URL,
        byteLimit: Int64?
    ) async throws(UpdateFailure) -> DownloadResponse {
        throw .providerUnreachable(reason: "the HTTP client cannot download")
    }
}

/// Per-provider on-disk cache under `Providers/cache/<type>/<key>/`.
public protocol ProviderCache: Sendable {
    /// Returns the cache directory for `key`, creating it when needed.
    func directory(forKey key: String) throws -> URL
}

/// Keychain access for provider credentials (update-system.md §4.6).
public protocol ProviderCredentials: Sendable {
    /// Returns the stored token for a service name, when one exists.
    func token(for service: String) -> String?
    /// Stores, replaces (`""` deletes), or keeps (`nil`) a token.
    func setToken(_ token: String?, for service: String) throws
}

/// The context every provider receives.
public struct ProviderContext: Sendable {
    /// The shared HTTP session.
    public var http: any UpdateHTTPClient
    /// The provider cache root.
    public var cache: any ProviderCache
    /// Keychain access for provider credentials.
    public var credentials: any ProviderCredentials
    /// True when the user asked for this check.
    public var userInitiated: Bool

    /// Creates a provider context.
    public init(
        http: any UpdateHTTPClient,
        cache: any ProviderCache,
        credentials: any ProviderCredentials,
        userInitiated: Bool = false
    ) {
        self.http = http
        self.cache = cache
        self.credentials = credentials
        self.userInitiated = userInitiated
    }
}

/// Download progress reported while streaming artifacts.
public struct DownloadProgress: Sendable {
    /// Bytes written so far across all artifacts.
    public var bytesWritten: Int64
    /// The declared total, when every artifact declares a size.
    public var bytesTotal: Int64?

    /// Creates a progress sample.
    public init(bytesWritten: Int64, bytesTotal: Int64?) {
        self.bytesWritten = bytesWritten
        self.bytesTotal = bytesTotal
    }
}

/// Where a provider writes downloaded artifacts (`Packages/<id>/incoming/<ticket>/`).
public struct DownloadDestination: Sendable {
    /// The operation ticket directory name.
    public var ticket: UUID
    /// The directory the provider writes into.
    public var directory: URL

    /// Creates a download destination.
    public init(ticket: UUID, directory: URL) {
        self.ticket = ticket
        self.directory = directory
    }
}

/// A provider of application updates (update-system.md §4.1).
public protocol UpdateProvider: Sendable {
    /// The provider identity stored on the package record.
    var ref: UpdateProviderRef { get }

    /// Returns a candidate that may be newer than `package`, or nil. Must not download APKs.
    /// The final decision is UpdateValidator's, made on the downloaded APKs (FR-UPD-14).
    func check(_ package: InstalledPackage, context: ProviderContext) async throws(UpdateFailure)
        -> UpdateCandidate?

    /// Downloads every artifact of the candidate into `destination`, hashing while streaming.
    func download(
        _ candidate: UpdateCandidate,
        to destination: DownloadDestination,
        context: ProviderContext,
        progress: @Sendable (DownloadProgress) -> Void
    ) async throws(UpdateFailure) -> PackageArtifact
}

/// A typed update-system failure (runtime-api.md §9.3).
public enum UpdateFailure: Error, Equatable, Sendable {
    /// The provider could not be reached at all.
    case providerUnreachable(reason: String)
    /// The provider answered with a non-success HTTP status.
    case providerHTTPStatus(Int)
    /// The provider rate-limited the request; `retryAfter` carries the
    /// server's `Retry-After` hint, when it gave one.
    case providerRateLimited(retryAfter: TimeInterval?)
    /// The provider's metadata (manifest, index, directory) failed validation.
    case providerMetadataInvalid(detail: String)
    /// The provider's signed metadata did not verify.
    case providerSignatureInvalid(detail: String)
    /// Versions exist but none fits the installed package or the guest.
    case noCompatibleArtifact(NoCompatibleArtifactReason)
    /// The provider offered several artifacts the caller cannot choose between.
    case ambiguousAsset(detail: String)
    /// `automatic` or `notifyOnly` was chosen without a provider.
    case providerNotConfigured
    /// An artifact download failed.
    case downloadFailed(reason: String)
    /// A downloaded artifact's hash differs from the provider's declaration.
    case hashMismatch(artifact: String)
    /// A downloaded set exceeds its size limit.
    case tooLarge(bytes: Int64, limit: Int64)
    /// A downloaded set failed a validation check (update-system.md §6).
    case validation(detail: String)
    /// The package's update authority does not allow APKRun-managed updates.
    case authorityDoesNotAllowUpdates
    /// The Android install transaction failed.
    case installFailed(detail: String)
    /// The post-install health check failed.
    case healthCheckFailed(detail: String)
    /// A rollback could not be performed.
    case rollbackFailed(detail: String)
    /// The user cancelled the operation.
    case cancelled

    /// The `update.*` error-catalog code for the wire and for logging.
    public var errorCode: String {
        switch self {
        case .providerUnreachable: "update.providerUnreachable"
        case .providerHTTPStatus: "update.providerHTTPStatus"
        case .providerRateLimited: "update.providerRateLimited"
        case .providerMetadataInvalid: "update.providerMetadataInvalid"
        case .providerSignatureInvalid: "update.providerSignatureInvalid"
        case .noCompatibleArtifact: "update.noCompatibleArtifact"
        case .ambiguousAsset: "update.ambiguousAsset"
        case .providerNotConfigured: "update.providerNotConfigured"
        case .downloadFailed: "update.downloadFailed"
        case .hashMismatch: "update.hashMismatch"
        case .tooLarge: "update.tooLarge"
        case .validation: "update.validation"
        case .authorityDoesNotAllowUpdates: "update.authorityDoesNotAllowUpdates"
        case .installFailed: "update.installFailed"
        case .healthCheckFailed: "update.healthCheckFailed"
        case .rollbackFailed: "update.rollbackFailed"
        case .cancelled: "update.cancelled"
        }
    }
}

/// Why no provider artifact fits (update-system.md §4.5, §6).
public enum NoCompatibleArtifactReason: String, Codable, Sendable, Hashable {
    /// The provider's builds are signed by a different key.
    case signerDiffers
    /// No artifact matches a guest ABI.
    case abiMismatch
    /// The artifact needs a newer Android SDK than the guest.
    case sdkTooLow
    /// The provider offers nothing newer than the installed version.
    case noNewerVersion
}

/// Why a rollback ran (state-machines.md §6).
public enum RollbackReason: Sendable, Equatable {
    /// The post-install health check failed.
    case healthCheckFailed(UpdateFailure)
    /// The user asked for the rollback.
    case userRequested
}

/// Why an update run ended without installing (state-machines.md §6).
public enum SkipReason: Sendable, Equatable {
    /// The provider has nothing newer.
    case upToDate
    /// The provider check failed.
    case checkFailed(UpdateFailure)
    /// The download failed.
    case downloadFailed(UpdateFailure)
    /// The downloaded set failed validation.
    case validationFailed(UpdateFailure)
    /// The install failed.
    case installFailed(UpdateFailure)
    /// The user chose "Skip This Version".
    case userSkipped
    /// The update authority changed before install.
    case authorityChanged

    /// The history-file name of the reason (update-system.md §10.2).
    public var name: String {
        switch self {
        case .upToDate: "upToDate"
        case .checkFailed: "checkFailed"
        case .downloadFailed: "downloadFailed"
        case .validationFailed: "validationFailed"
        case .installFailed: "installFailed"
        case .userSkipped: "userSkipped"
        case .authorityChanged: "authorityChanged"
        }
    }
}

/// The terminal outcome of an update run (state-machines.md §6).
public enum UpdateOutcome: Sendable, Equatable {
    /// The new version installed.
    case updated(from: VersionCode, to: VersionCode)
    /// The install rolled back to the previous set.
    case rolledBack(reason: RollbackReason)
    /// The health check failed but no rollback was possible or confirmed.
    case keptAfterFailedHealthCheck(reason: RollbackReason)
    /// The run ended early without installing.
    case skipped(SkipReason)
}

/// The update phase of one package (state-machines.md §6).
public enum UpdatePhase: Sendable, Equatable {
    /// A provider check is running.
    case checking
    /// A newer candidate is known; `notifyOnly` stops here.
    case available(UpdateCandidate)
    /// Artifacts are downloading.
    case downloading(progress: Double)
    /// The downloaded set is being verified.
    case validating
    /// The validated set waits for a gentle-install window.
    case staged
    /// The Android install transaction is running.
    case installing
    /// The post-install health check is running.
    case healthChecking
    /// A rollback is running.
    case rollingBack(RollbackReason)
    /// The run ended; the next check starts a new cycle.
    case completed(UpdateOutcome)

    /// The persisted phase names in `Updates/state.json`; only `available` and
    /// `staged` survive a restart (update-system.md §10.1).
    var persistedName: String? {
        switch self {
        case .available: "available"
        case .staged: "staged"
        default: nil
        }
    }
}
