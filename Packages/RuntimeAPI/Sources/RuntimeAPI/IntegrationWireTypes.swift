import Foundation

/// The clipboard wire types of runtime-api.md §11.2 and desktop-integration.md
/// §3.3 and §4.
///
/// A clip fits the 32 MiB XPC message limit: text and HTML cap at 1 MiB and a
/// clip image is PNG bytes of at most 16 MiB.

/// What brought a `ClipItem` to apkrund (desktop-integration.md §4.2).
public enum ClipTrigger: String, Codable, Sendable, Equatable {
    /// ⌘V or Edit → Paste in the window.
    case paste
    /// The window became key and the pasteboard changed.
    case focus
}

/// A clipboard image as PNG bytes (desktop-integration.md §4.4, target #81).
public struct ClipImage: Codable, Sendable, Equatable {
    /// PNG bytes, at most 16 MiB.
    public var png: Data
    /// The image's pixel width, at most 8192.
    public var pixelWidth: Int
    /// The image's pixel height, at most 8192.
    public var pixelHeight: Int

    /// Creates a clip image.
    public init(png: Data, pixelWidth: Int, pixelHeight: Int) {
        self.png = png
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// One clipboard payload, either direction (runtime-api.md §11.2).
public struct ClipItem: Codable, Sendable, Equatable {
    /// UTF-8 text, at most 1 MiB.
    public var text: String?
    /// HTML, at most 1 MiB, only together with `text`.
    public var html: String?
    /// A PNG image (target #81).
    public var image: ClipImage?
    /// `ClipDescription.EXTRA_IS_SENSITIVE` / `org.nspasteboard.ConcealedType`.
    public var sensitive: Bool
    /// SHA-256 over the normalized text (or image bytes); a loop-prevention signal.
    public var digest: RuntimeSHA256Digest
    /// `true` when content was cut at its limit.
    public var truncated: Bool
    /// What triggered the item; set by the client, not by apkrund.
    public var trigger: ClipTrigger?

    /// Creates a clip item.
    public init(
        text: String? = nil,
        html: String? = nil,
        image: ClipImage? = nil,
        sensitive: Bool = false,
        digest: RuntimeSHA256Digest,
        truncated: Bool = false,
        trigger: ClipTrigger? = nil
    ) {
        self.text = text
        self.html = html
        self.image = image
        self.sensitive = sensitive
        self.digest = digest
        self.truncated = truncated
        self.trigger = trigger
    }
}

/// The acknowledged sequence number of a `pushClipboard` (runtime-api.md §11.2).
public struct ClipAck: Codable, Sendable, Equatable {
    /// The sequence number the host assigned to the clip.
    public var seq: UInt64
    /// An image that exceeded the §11.4 limits was dropped; the text and HTML
    /// still went (desktop-integration.md §4.4).
    public var droppedImageTooLarge: Bool

    /// Creates an acknowledgment.
    public init(seq: UInt64, droppedImageTooLarge: Bool = false) {
        self.seq = seq
        self.droppedImageTooLarge = droppedImageTooLarge
    }
}

/// `clipboardWritten`: the window wrote a guest clip to the Mac pasteboard
/// (runtime-api.md §11.2, desktop-integration.md §4.3).
public struct ClipboardWritten: Codable, Sendable, Equatable {
    /// `NSPasteboard.changeCount` after the write.
    public var changeCount: Int
    /// The digest of the clip that was written.
    public var digest: RuntimeSHA256Digest

    /// Creates the report.
    public init(changeCount: Int, digest: RuntimeSHA256Digest) {
        self.changeCount = changeCount
        self.digest = digest
    }
}

/// `pushClipboard` through the authenticated control endpoint. The session
/// channel carries it once the wrapper endpoint exists; until then the window
/// names its session here (runtime-api.md §6.3, §11.2).
public struct RuntimePushClipboardControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader
    /// The session of the window that pushes.
    public var sessionID: UUID
    /// The clip payload.
    public var item: ClipItem

    /// Creates a push request.
    public init(header: APIRequestHeader, sessionID: UUID, item: ClipItem) {
        self.header = header
        self.sessionID = sessionID
        self.item = item
    }
}

/// The reply of `pushClipboard`.
public struct RuntimePushClipboardControlReply: Codable, Equatable, Sendable {
    /// The acknowledged sequence number on success.
    public let ack: ClipAck?
    /// The control error on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(ack: ClipAck) {
        self.ack = ack
        error = nil
    }

    /// Creates an error reply.
    public init(error: RuntimeWireError) {
        ack = nil
        self.error = error
    }
}

/// `clipboardWritten` through the authenticated control endpoint
/// (runtime-api.md §6.3, §11.2).
public struct RuntimeClipboardWrittenControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader
    /// The session of the window that wrote the pasteboard.
    public var sessionID: UUID
    /// The write report.
    public var written: ClipboardWritten

    /// Creates the request.
    public init(header: APIRequestHeader, sessionID: UUID, written: ClipboardWritten) {
        self.header = header
        self.sessionID = sessionID
        self.written = written
    }
}

/// The reply of `clipboardWritten`.
public struct RuntimeClipboardWrittenControlReply: Codable, Equatable, Sendable {
    /// The control error on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init() {
        error = nil
    }

    /// Creates an error reply.
    public init(error: RuntimeWireError) {
        self.error = error
    }
}

/// `focusChanged`: the window reports whether it is the key window. The session
/// channel carries it once the wrapper endpoint exists; until then it names its
/// session here (runtime-api.md §6.3, input.md §7.2).
public struct RuntimeFocusChangedControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader
    /// The session of the window.
    public var sessionID: UUID
    /// `true` when the window became key, `false` when it resigned key.
    public var isKey: Bool

    /// Creates the request.
    public init(header: APIRequestHeader, sessionID: UUID, isKey: Bool) {
        self.header = header
        self.sessionID = sessionID
        self.isKey = isKey
    }
}

/// The reply of `focusChanged`.
public struct RuntimeFocusChangedControlReply: Codable, Equatable, Sendable {
    /// The control error on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init() {
        error = nil
    }

    /// Creates an error reply.
    public init(error: RuntimeWireError) {
        self.error = error
    }
}

/// An integration event of the `integrations` topic (runtime-api.md §8,
/// desktop-integration.md §3.3). `clipboardFromGuest` is published only for the
/// key window's session.
public enum IntegrationChange: Codable, Sendable, Equatable {
    /// A guest clip that the key window should write to its pasteboard.
    case clipboardFromGuest(sessionID: UUID, packageID: RuntimePackageID, item: ClipItem)
    /// An event kind this client does not know.
    case unknown

    private enum Kind: String, Codable {
        case clipboardFromGuest
        case unknown
    }

    private enum CodingKeys: String, CodingKey {
        case kind, sessionID, packageID, item
    }

    /// Creates the event from its coded form.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .unknown
        switch kind {
        case .clipboardFromGuest:
            self = .clipboardFromGuest(
                sessionID: try container.decode(UUID.self, forKey: .sessionID),
                packageID: try container.decode(RuntimePackageID.self, forKey: .packageID),
                item: try container.decode(ClipItem.self, forKey: .item)
            )
        case .unknown:
            self = .unknown
        }
    }

    /// Writes the event's coded form.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .clipboardFromGuest(let sessionID, let packageID, let item):
            try container.encode(Kind.clipboardFromGuest, forKey: .kind)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(packageID, forKey: .packageID)
            try container.encode(item, forKey: .item)
        case .unknown:
            try container.encode(Kind.unknown, forKey: .kind)
        }
    }
}

// MARK: - Integration status (runtime-api.md §11, desktop-integration.md §2.3)

/// Why an integration request was denied (runtime-api.md §11,
/// `WireIntegrationDecision.deny`).
public enum IntegrationDenial: String, Codable, Sendable, Equatable {
    /// The global switch `integrations.enabled.<name>` is off.
    case globallyOff
    /// `integrations.<name>` is off for the package.
    case packageOff
    /// The window is not key, or a link came without recent input.
    case notFocused
    /// The package has no session.
    case noSession
    /// The running image lacks the capability.
    case notSupported
    /// A rate limit, for example more than 3 links in 10 s.
    case rateLimited
    /// Any later, unknown reason.
    case unknown
}

/// The policy decision reported by `integrationStatus` (runtime-api.md §11).
/// Coded as `{"kind": "deny", "reason": "notFocused"}`; unit cases omit
/// `reason`.
public enum IntegrationStatusDecision: Codable, Sendable, Equatable {
    /// The integration may proceed.
    case allow
    /// Ask the user; links only (desktop-integration.md §7).
    case ask
    /// The integration is refused.
    case deny(IntegrationDenial)
    /// Any later, unknown decision.
    case unknown

    private enum Kind: String, Codable {
        case allow, ask, deny, unknown
    }

    private enum CodingKeys: String, CodingKey {
        case kind, reason
    }

    /// Decodes the kind/reason form.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .unknown
        switch kind {
        case .allow: self = .allow
        case .ask: self = .ask
        case .deny:
            self = .deny(try container.decodeIfPresent(IntegrationDenial.self, forKey: .reason) ?? .unknown)
        case .unknown: self = .unknown
        }
    }

    /// Encodes the kind/reason form.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .allow: try container.encode(Kind.allow, forKey: .kind)
        case .ask: try container.encode(Kind.ask, forKey: .kind)
        case .deny(let reason):
            try container.encode(Kind.deny, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .unknown: try container.encode(Kind.unknown, forKey: .kind)
        }
    }
}

/// Where the reported `integrations.*` value comes from (`SettingSource`,
/// runtime-api.md §11).
public enum IntegrationSettingSource: String, Codable, Sendable, Equatable {
    /// The global `integrations.enabled.*`/`defaults.*` switch decided it.
    case globalSwitch
    /// The package's own `settings.json` stores it.
    case user
    /// A compatibility-database recommendation set it.
    case recommended
    /// The documented default applies; nothing is stored.
    case `default`
    /// Any later, unknown source.
    case unknown
}

/// The `JSONValue` subset used for `integrations.*` values: a flag or an
/// enum word (`ask`, `off`, `ro`).
public enum IntegrationValue: Codable, Sendable, Equatable {
    /// A boolean setting.
    case bool(Bool)
    /// An enum-word setting.
    case string(String)
    /// No value.
    case null

    /// Decodes a bool, then a string, else null.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let word = try? container.decode(String.self) {
            self = .string(word)
        } else {
            self = .null
        }
    }

    /// Encodes the scalar form.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let flag): try container.encode(flag)
        case .string(let word): try container.encode(word)
        case .null: try container.encodeNil()
        }
    }

    /// The string form used by `IntegrationPolicy`.
    public var policyString: String? {
        switch self {
        case .bool(let flag): return flag ? "true" : "false"
        case .string(let word): return word
        case .null: return nil
        }
    }

    /// Builds a value from a stored policy string.
    public init?(policyString: String?) {
        guard let policyString else { return nil }
        switch policyString {
        case "true": self = .bool(true)
        case "false": self = .bool(false)
        default: self = .string(policyString)
        }
    }
}

/// Whether the running image reports the capability a kind needs
/// (runtime-api.md §11).
public enum IntegrationSupport: String, Codable, Sendable, Equatable {
    /// The capability is present.
    case supported
    /// The running image lacks the capability.
    case unsupported
    /// Unknown; no image is running or the kind needs none.
    case unknown
}

/// One `integrations.*` line of `integrationStatus` (runtime-api.md §11).
public struct IntegrationItemStatus: Codable, Sendable, Equatable {
    /// The integration kind.
    public var kind: IntegrationKind
    /// The stored or default value.
    public var value: IntegrationValue
    /// Where `value` comes from.
    public var source: IntegrationSettingSource
    /// The §2.3 decision for the current context.
    public var decision: IntegrationStatusDecision
    /// The image support of the kind's capability.
    public var support: IntegrationSupport
    /// The missing capability when `support` is `unsupported`.
    public var capability: String?
    /// The macOS permission of the adapter, when the kind has one.
    public var macPermission: String?

    /// Creates one status line.
    public init(
        kind: IntegrationKind,
        value: IntegrationValue,
        source: IntegrationSettingSource,
        decision: IntegrationStatusDecision,
        support: IntegrationSupport,
        capability: String? = nil,
        macPermission: String? = nil
    ) {
        self.kind = kind
        self.value = value
        self.source = source
        self.decision = decision
        self.support = support
        self.capability = capability
        self.macPermission = macPermission
    }
}

/// The `integrationStatus` reply body (runtime-api.md §11).
public struct IntegrationStatus: Codable, Sendable, Equatable {
    /// The queried package.
    public var packageID: RuntimePackageID
    /// One item per `IntegrationKind`.
    public var items: [IntegrationItemStatus]
    /// True while a microphone change needs a session restart.
    public var microphoneNeedsRestart: Bool

    /// Creates a status reply.
    public init(packageID: RuntimePackageID, items: [IntegrationItemStatus], microphoneNeedsRestart: Bool = false) {
        self.packageID = packageID
        self.items = items
        self.microphoneNeedsRestart = microphoneNeedsRestart
    }
}

/// The `integrationStatus` request (runtime-api.md §11).
public struct RuntimeIntegrationStatusControlRequest: Codable, Sendable {
    /// The common request header.
    public var header: APIRequestHeader
    /// The package to report on.
    public var packageID: RuntimePackageID

    /// Creates a status request.
    public init(header: APIRequestHeader, packageID: RuntimePackageID) {
        self.header = header
        self.packageID = packageID
    }
}

/// The `integrationStatus` reply (runtime-api.md §11).
public struct RuntimeIntegrationStatusControlReply: Codable, Sendable {
    /// The per-kind status on success.
    public var status: IntegrationStatus?
    /// The failure on error, for example `store.packageNotFound`.
    public var error: RuntimeWireError?

    /// Creates a status reply.
    public init(status: IntegrationStatus? = nil, error: RuntimeWireError? = nil) {
        self.status = status
        self.error = error
    }
}
