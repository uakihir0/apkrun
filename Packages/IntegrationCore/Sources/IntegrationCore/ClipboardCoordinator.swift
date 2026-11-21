import CryptoKit
import Foundation
import GuestProtocol
import RuntimeAPI

/// The transport the coordinator uses to reach the Guest Agent (desktop-integration.md §3.3).
public protocol IntegrationChannel: Sendable {
    /// Sends one host clip to the guest; throws ``IntegrationFailure/guestUnavailable`` without an agent.
    func setClipboard(_ clip: GPClipData) async throws(IntegrationFailure)
    /// Whether the session advertises `clipboard.image.v1` (guest-protocol.md §5.3).
    func supportsImages() async -> Bool
    /// Uploads PNG bytes on the bulk stream and answers its transfer ID
    /// (guest-protocol.md §10).
    func uploadClipboardImage(_ png: Data) async throws(IntegrationFailure) -> UInt64
    /// The payload of an announced inbound transfer, or nil on abort/timeout.
    func inboundTransfer(_ transferID: UInt64) async -> Data?
}

extension IntegrationChannel {
    /// Channels without bulk support report no image capability.
    public func supportsImages() async -> Bool { false }
    /// Channels without bulk support cannot upload.
    public func uploadClipboardImage(_ png: Data) async throws(IntegrationFailure) -> UInt64 {
        throw .guestUnavailable
    }
    /// Channels without bulk support never resolve transfers.
    public func inboundTransfer(_ transferID: UInt64) async -> Data? { nil }
}

/// Copies clips between the Mac and the guest of the focused session (desktop-integration.md §4).
///
/// The coordinator owns the direction-independent state of §4.4: the host seq
/// space, the last digest it sent to Android (signal 2 of the three echo
/// guards), and which session's window is the key window. The guest origin
/// filter (signal 1) runs in `ClipboardBridge`; the pasteboard marker
/// (signal 3) runs in `PasteboardAdapter`.
public actor ClipboardCoordinator {
    /// The 1 MiB UTF-8 text limit (runtime-api.md §11.4); the adapter
    /// truncates instead of erroring.
    public static let textByteLimit: Int64 = 1 * 1024 * 1024
    /// The 1 MiB HTML limit (runtime-api.md §11.4).
    public static let htmlByteLimit: Int64 = 1 * 1024 * 1024
    /// The 16 MiB PNG limit (runtime-api.md §11.4).
    public static let imageByteLimit: Int64 = 16 * 1024 * 1024
    /// The 8192-px image limit (runtime-api.md §11.4).
    public static let imagePixelLimit = 8192
    /// The capability #54 requires (guest-protocol.md §5.3).
    public static let requiredCapability = "clipboard.text.v1"

    /// The session whose package window is the key window, if any.
    public struct KeySession: Sendable, Equatable {
        /// The XPC session identifier.
        public var sessionID: UUID
        /// The package the session displays.
        public var packageID: RuntimePackageID
        /// Creates a key-session record.
        public init(sessionID: UUID, packageID: RuntimePackageID) {
            self.sessionID = sessionID
            self.packageID = packageID
        }
    }

    private let policy: IntegrationPolicy
    private let channel: any IntegrationChannel
    private let onGuestClip: @Sendable (UUID, RuntimePackageID, ClipItem) async -> Void
    private var keySession: KeySession?
    private var nextSeq: UInt64 = 1
    private var lastHostDigest: RuntimeSHA256Digest?
    private var lastWritten: (sessionID: UUID, changeCount: Int, digest: RuntimeSHA256Digest)?

    /// Creates a coordinator over the policy, channel, and clip sink.
    public init(
        policy: IntegrationPolicy,
        channel: any IntegrationChannel,
        onGuestClip: @escaping @Sendable (UUID, RuntimePackageID, ClipItem) async -> Void
    ) {
        self.policy = policy
        self.channel = channel
        self.onGuestClip = onGuestClip
    }

    /// Records a window becoming or ceasing to be key (desktop-integration.md §4.1).
    public func noteFocusChanged(sessionID: UUID, packageID: RuntimePackageID, isKey: Bool) {
        if isKey {
            keySession = KeySession(sessionID: sessionID, packageID: packageID)
        } else if keySession?.sessionID == sessionID {
            keySession = nil
        }
    }

    /// Drops the key session when its session ends.
    public func noteSessionEnded(sessionID: UUID) {
        if keySession?.sessionID == sessionID {
            keySession = nil
        }
    }

    /// Pushes one Mac clip toward Android and returns the acknowledged seq (§4.2).
    ///
    /// The call runs the §2.3 policy for the pushing package: the session must
    /// exist and be key, the package and global switches must be on, and the
    /// image must report `clipboard.text.v1`.
    public func push(
        sessionID: UUID,
        packageID: RuntimePackageID,
        item: ClipItem
    ) async throws(IntegrationFailure) -> ClipAck {
        let context = IntegrationContext(
            hasSession: true,
            windowIsKey: keySession?.sessionID == sessionID,
            requiredCapability: Self.requiredCapability
        )
        switch await policy.evaluate(.clipboard, package: packageID, context: context) {
        case .deny(let reason):
            throw .disabled(.clipboard, reason)
        case .ask:
            // `clipboard` has no `ask` value (desktop-integration.md §2.1).
            throw .disabled(.clipboard, .packageOff)
        case .allow:
            break
        }
        // The §11.4 per-field limits; long text never arrives here because the
        // adapter truncates it at the 1 MiB boundary.
        if let html = item.html, Int64(html.utf8.count) > Self.htmlByteLimit {
            throw .clipboardTooLarge(bytes: Int64(html.utf8.count), limit: Self.htmlByteLimit)
        }
        // An image over the limits is dropped, not refused: text and HTML
        // still go, and the ack carries the drop (desktop-integration.md §4.4).
        var image = item.image
        var droppedImageTooLarge = false
        if let candidate = image,
            Int64(candidate.png.count) > Self.imageByteLimit
                || max(candidate.pixelWidth, candidate.pixelHeight) > Self.imagePixelLimit
        {
            image = nil
            droppedImageTooLarge = true
            if item.text == nil && item.html == nil {
                throw .clipboardTooLarge(
                    bytes: Int64(candidate.png.count), limit: Self.imageByteLimit)
            }
        }
        if let text = item.text, Int64(text.utf8.count) > Self.textByteLimit {
            throw .clipboardTooLarge(bytes: Int64(text.utf8.count), limit: Self.textByteLimit)
        }
        let seq = nextSeq
        nextSeq += 1
        var clip = GPClipData()
        clip.seq = seq
        clip.origin = .host
        clip.text = item.text ?? ""
        clip.truncated = item.truncated
        clip.html = item.html ?? ""
        clip.sensitive = item.sensitive
        if let image = image {
            // An image needs `clipboard.image.v1`; without it an image-only
            // clip answers UNSUPPORTED and a mixed clip still sends its text
            // (desktop-integration.md §4.4).
            guard await channel.supportsImages() else {
                guard item.text != nil || item.html != nil else {
                    throw .notSupportedOnImage(capability: "clipboard.image.v1")
                }
                try await channel.setClipboard(clip)
                lastHostDigest = item.digest
                return ClipAck(seq: seq, droppedImageTooLarge: droppedImageTooLarge)
            }
            let transferID = try await channel.uploadClipboardImage(image.png)
            var wire = GPClipImage()
            wire.mimeType = "image/png"
            wire.width = UInt32(image.pixelWidth)
            wire.height = UInt32(image.pixelHeight)
            wire.transferID = transferID
            clip.image = wire
        }
        try await channel.setClipboard(clip)
        lastHostDigest = item.digest
        return ClipAck(seq: seq, droppedImageTooLarge: droppedImageTooLarge)
    }

    /// Handles one `ClipboardChanged` event from the guest (§4.3).
    ///
    /// A clip is dropped, never queued, when no package window is key, when the
    /// key package's `integrations.clipboard` is off, when a known
    /// `source_package` is neither that package nor one that also allows
    /// clipboard, or when the digest matches the clip the host just sent
    /// (echo, §4.4 signal 2).
    public func guestChanged(_ clip: GPClipData) async {
        guard clip.origin == .guest || clip.origin == .unspecified else {
            return
        }
        guard let key = keySession else {
            return
        }
        let decision = await policy.evaluate(
            .clipboard,
            package: key.packageID,
            context: IntegrationContext(hasSession: true, windowIsKey: true)
        )
        guard case .allow = decision else {
            return
        }
        if !clip.sourcePackage.isEmpty, clip.sourcePackage != key.packageID.rawValue {
            guard await packageAllowsClipboard(clip.sourcePackage) else {
                return
            }
        }
        let imageBytes =
            clip.hasImage ? await channel.inboundTransfer(clip.image.transferID) : nil
        guard let item = Self.item(for: clip, imageBytes: imageBytes),
            item.digest != lastHostDigest
        else {
            return
        }
        // The accepted guest clip becomes the pasteboard's content; forgetting
        // the older pushed digest keeps a later re-copy of it from being
        // swallowed as an echo (§4.4).
        lastHostDigest = item.digest
        await onGuestClip(key.sessionID, key.packageID, item)
    }

    /// Records a `clipboardWritten` report from a window (§4.2).
    public func noteWritten(sessionID: UUID, written: ClipboardWritten) {
        lastWritten = (sessionID, written.changeCount, written.digest)
    }

    /// The last write a window reported, for tests and `apkrun integrations status`.
    public var lastWrite: (sessionID: UUID, changeCount: Int, digest: RuntimeSHA256Digest)? {
        lastWritten
    }

    /// The current key session, for `apkrun integrations status`.
    public var currentKeySession: KeySession? {
        keySession
    }

    /// One §2.3 evaluation, for `integrationStatus` (runtime-api.md §11).
    public func policyDecision(
        _ kind: IntegrationKind,
        package: RuntimePackageID,
        context: IntegrationContext
    ) async -> IntegrationDecision {
        await policy.evaluate(kind, package: package, context: context)
    }

    /// Builds the wire `ClipItem` of a guest clip (§11.2). `imageBytes` is
    /// the resolved payload of `clip.image`, fetched by the caller.
    public static func item(for clip: GPClipData, imageBytes: Data? = nil) -> ClipItem? {
        var image: ClipImage?
        var imageDigest: RuntimeSHA256Digest?
        if clip.hasImage, let imageBytes {
            image = ClipImage(
                png: imageBytes,
                pixelWidth: Int(clip.image.width),
                pixelHeight: Int(clip.image.height))
            imageDigest = digest(imageBytes: imageBytes)
        }
        guard let digest = digest(text: clip.text) ?? imageDigest else {
            return nil
        }
        return ClipItem(
            text: clip.text.isEmpty ? nil : clip.text,
            html: clip.html.isEmpty ? nil : clip.html,
            image: image,
            sensitive: clip.sensitive,
            digest: digest,
            truncated: clip.truncated
        )
    }

    /// The §4.4 digest: SHA-256 over the NFC-normalized text's UTF-8 bytes.
    public static func digest(text: String) -> RuntimeSHA256Digest? {
        guard !text.isEmpty else { return nil }
        let hash = SHA256.hash(data: Data(text.precomposedStringWithCanonicalMapping.utf8))
        return RuntimeSHA256Digest(
            rawValue: "sha256:" + hash.map { String(format: "%02x", $0) }.joined())
    }

    /// The §4.4 digest of an image clip: SHA-256 over the PNG bytes.
    public static func digest(imageBytes: Data) -> RuntimeSHA256Digest? {
        guard !imageBytes.isEmpty else { return nil }
        let hash = SHA256.hash(data: imageBytes)
        return RuntimeSHA256Digest(
            rawValue: "sha256:" + hash.map { String(format: "%02x", $0) }.joined())
    }

    private func packageAllowsClipboard(_ rawPackageID: String) async -> Bool {
        guard let packageID = RuntimePackageID(rawValue: rawPackageID) else {
            return false
        }
        let decision = await policy.evaluate(
            .clipboard,
            package: packageID,
            context: IntegrationContext(hasSession: false, windowIsKey: false)
        )
        // A non-key, sessionless package still "allows clipboard" when its
        // switches are on; the focused/session checks don't apply to it.
        switch decision {
        case .allow:
            return true
        case .deny(let reason):
            return reason == .noSession || reason == .notFocused
        case .ask:
            return false
        }
    }
}
