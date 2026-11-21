import Foundation
import RuntimeAPI

/// One export the Guest Agent's SaveToMacActivity offered
/// (`exportOffered`, desktop-integration.md §6.3).
public struct FileExportOffer: Sendable, Equatable {
    /// The offer identifier `ResolveExport` answers.
    public var offerID: String
    /// The session whose window owns the offer.
    public var sessionID: UUID
    /// The Android package that shared.
    public var sourcePackage: RuntimePackageID
    /// The file name Android reported (sanitized before the save panel).
    public var name: String
    /// The reported size, if Android knew it.
    public var size: Int64?
    /// The MIME type.
    public var type: String

    /// Creates an offer row.
    public init(
        offerID: String, sessionID: UUID, sourcePackage: RuntimePackageID,
        name: String, size: Int64?, type: String
    ) {
        self.offerID = offerID
        self.sessionID = sessionID
        self.sourcePackage = sourcePackage
        self.name = name
        self.size = size
        self.type = type
    }
}

/// The transport ``FileTransferService`` uses to reach the Guest Agent
/// (desktop-integration.md §6). RuntimeHost implements it over the session's
/// control and bulk connections.
public protocol FileTransferChannel: Sendable {
    /// Sends `ImportFiles` after the file bytes have gone on the bulk stream.
    /// `transferIDs[i]` is the bulk transfer carrying `handles[i]`
    /// (guest-protocol.md §7.4). Throws `.guestUnavailable` with no agent.
    func sendImport(
        package: RuntimePackageID, displayID: Int,
        handles: [FileHandle], infos: [ImportFileInfo]
    ) async throws(IntegrationFailure) -> ImportResult

    /// Answers `ResolveExport` and, on accept, streams the file to `handle`,
    /// verifying its SHA-256 from `BulkEnd` (§6.3). On a hash or transport
    /// failure the partial file is already deleted before this throws.
    /// `package` is nil only for a decline of an offer whose
    /// `source_package` never parsed — the answer carries only the offer id.
    func resolveExport(
        offerID: String, package: RuntimePackageID?, accept: Bool, writeTo: FileHandle?
    ) async throws(IntegrationFailure)
}

/// The `files` integration: Mac → Android drops and Android → Mac "Save to
/// Mac" offers (desktop-integration.md §6.2–§6.3).
///
/// Limits are enforced before any transport: at most 20 files, each at most
/// 2 GiB, 4 GiB in total. The policy `.files` gates both directions — a drop
/// can only come from a window the user dropped onto, and an export offer can
/// only come from the session on the offer's display.
public actor FileTransferService {
    /// The most files one drop or one export carries (§6.2, §6.3).
    public static let fileLimit = 20
    /// The largest single file (§6.2).
    public static let fileByteLimit: Int64 = 2 * 1024 * 1024 * 1024
    /// The largest drop in total (§6.2).
    public static let totalByteLimit: Int64 = 4 * 1024 * 1024 * 1024

    /// An offer the window has not answered yet, per session.
    private struct PendingOffer {
        var package: RuntimePackageID
        var sessionID: UUID
    }

    private let policy: IntegrationPolicy
    private let channel: any FileTransferChannel
    private let onExportOffered: @Sendable (UUID, FileExportOffer) async -> Void
    private var pending: [String: PendingOffer] = [:]

    /// Creates the service over the policy, its transport, and the sink for
    /// `exportOffered` session events (runtime-api.md §11.2).
    public init(
        policy: IntegrationPolicy,
        channel: any FileTransferChannel,
        onExportOffered: @escaping @Sendable (UUID, FileExportOffer) async -> Void
    ) {
        self.policy = policy
        self.channel = channel
        self.onExportOffered = onExportOffered
    }

    // MARK: Mac → Android (§6.2)

    /// Validates a drop and imports its files into the package's session.
    ///
    /// Called only after the window reported a real user drop: the policy
    /// sees `windowIsKey` so a background package cannot inject files
    /// (NFR-SEC-02). The handles are already open for reading.
    public func importFiles(
        sessionID: UUID,
        package: RuntimePackageID,
        displayID: Int,
        handles: [FileHandle],
        infos: [ImportFileInfo],
        windowIsKey: Bool
    ) async throws(IntegrationFailure) -> ImportResult {
        guard infos.count <= Self.fileLimit else {
            throw .tooManyFiles(count: infos.count, limit: Self.fileLimit)
        }
        var total: Int64 = 0
        for info in infos {
            guard info.size <= Self.fileByteLimit else {
                throw .fileTooLarge(name: info.name, bytes: info.size)
            }
            total += info.size
        }
        guard total <= Self.totalByteLimit else {
            throw .fileTooLarge(name: "the drop", bytes: total)
        }
        switch await policy.evaluate(
            .files,
            package: package,
            context: IntegrationContext(hasSession: true, windowIsKey: windowIsKey)
        ) {
        case .deny(let reason):
            throw .disabled(.files, reason)
        case .allow, .ask:
            break
        }
        return try await channel.sendImport(
            package: package, displayID: displayID,
            handles: handles, infos: infos)
    }

    // MARK: Android → Mac (§6.3)

    /// An `ExportFileOffered` event from the Guest Agent. The `files` policy
    /// runs for `source_package` — a package without the integration cannot
    /// reach the Mac at all — then the offer goes to the session's window.
    /// With no live session the offer is declined at once (§6.3).
    public func exportOffered(
        _ offer: FileExportOffer,
        hasSession: Bool
    ) async throws(IntegrationFailure) {
        // The offer exists because the user picked "Save to Mac" inside the
        // app's window, so a live session counts as the acting window for
        // the `.files` policy (§2.3): no key-window check on this path.
        switch await policy.evaluate(
            .files,
            package: offer.sourcePackage,
            context: IntegrationContext(hasSession: hasSession, windowIsKey: hasSession)
        ) {
        case .deny:
            try await channel.resolveExport(
                offerID: offer.offerID, package: offer.sourcePackage, accept: false, writeTo: nil)
            return
        case .allow, .ask:
            break
        }
        guard hasSession else {
            try await channel.resolveExport(
                offerID: offer.offerID, package: offer.sourcePackage, accept: false, writeTo: nil)
            return
        }
        pending[offer.offerID] = PendingOffer(
            package: offer.sourcePackage, sessionID: offer.sessionID)
        await onExportOffered(offer.sessionID, offer)
    }

    /// The wrapper's save-panel answer (`acceptExport`, runtime-api.md
    /// §11.2). `handle` is the file the user picked, already open for
    /// writing; nil is the panel's cancel. Only the session the offer was
    /// sent to may answer it, and only for its own package (NFR-SEC-07).
    public func acceptExport(
        offerID: String,
        sessionID: UUID,
        callerPackageID: RuntimePackageID,
        writeTo handle: FileHandle?
    ) async throws(IntegrationFailure) {
        guard let entry = pending[offerID],
            entry.package == callerPackageID,
            entry.sessionID == sessionID
        else {
            throw .promptTimedOut
        }
        pending.removeValue(forKey: offerID)
        try await channel.resolveExport(
            offerID: offerID, package: entry.package, accept: handle != nil, writeTo: handle)
    }

    /// Declines an offer whose `source_package` failed to parse — a
    /// malformed or hostile frame with no package for the policy
    /// (NFR-SEC-01). The decline itself only echoes the offer id.
    public func declineExport(offerID: String) async {
        try? await channel.resolveExport(
            offerID: offerID, package: nil, accept: false, writeTo: nil)
    }

    /// Drops every pending offer of a session (window closed or session
    /// ended); the agent's offer times out on its own.
    public func discardOffers(of sessionID: UUID) {
        pending = pending.filter { $0.value.sessionID != sessionID }
    }
}
