import Foundation

/// Where first-run setup takes the Android image from (runtime-api.md §5.4).
public enum SetupImageSource: Codable, Equatable, Sendable {
    /// A signed `.aar` image archive attached to the request's file side-channel.
    case archive(fileIndex: Int)
    /// An image directory the client opened through a security-scoped bookmark.
    case directory(bookmark: Data)
    /// The published APKRun image feed.
    case feed
    /// A source added by a newer peer.
    case unknown

    private enum AssociatedKey: String, CodingKey {
        case fileIndex
        case bookmark
    }

    /// Decodes a known image source, preserving a future source as ``unknown``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RuntimeEventCodingKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected one image source case.")
            )
        }
        switch key.stringValue {
        case "archive":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .archive(fileIndex: try payload.decode(Int.self, forKey: .fileIndex))
        case "directory":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .directory(bookmark: try payload.decode(Data.self, forKey: .bookmark))
        case "feed":
            self = .feed
        default:
            self = .unknown
        }
    }

    /// Encodes a known image source.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: RuntimeEventCodingKey.self)
        switch self {
        case .archive(let fileIndex):
            var payload = container.nestedContainer(
                keyedBy: AssociatedKey.self,
                forKey: RuntimeEventCodingKey("archive")
            )
            try payload.encode(fileIndex, forKey: .fileIndex)
        case .directory(let bookmark):
            var payload = container.nestedContainer(
                keyedBy: AssociatedKey.self,
                forKey: RuntimeEventCodingKey("directory")
            )
            try payload.encode(bookmark, forKey: .bookmark)
        case .feed:
            _ = container.nestedContainer(
                keyedBy: RuntimeEventCodingKey.self,
                forKey: RuntimeEventCodingKey("feed")
            )
        case .unknown:
            _ = container.nestedContainer(
                keyedBy: RuntimeEventCodingKey.self,
                forKey: RuntimeEventCodingKey("unknown")
            )
        }
    }
}

/// The body of a `setup` request: first-run provisioning or repair
/// (runtime-daemon.md §9). Every field is optional work selection.
public struct SetupRequest: Codable, Equatable, Sendable {
    /// Where the Android image comes from. Defaults to the feed.
    public var image: SetupImageSource
    /// When true, discards the existing instance and provisions from scratch.
    /// The onboarding sheet sets this for "Start Over" after two failed first
    /// boots (host-ui.md §4).
    public var recreateInstance: Bool?

    /// Creates a setup request.
    public init(image: SetupImageSource = .feed, recreateInstance: Bool? = nil) {
        self.image = image
        self.recreateInstance = recreateInstance
    }
}

/// A `setup` control request: start or resume provisioning and return the
/// provisioning operation handle (runtime-api.md §5.4).
public struct RuntimeSetupControlRequest: Codable, Equatable, Sendable {
    /// The authenticated request metadata. Its operation ID is reused by the
    /// returned handle.
    public let header: APIRequestHeader
    /// The setup options.
    public let request: SetupRequest

    /// Creates a setup control request.
    public init(header: APIRequestHeader, request: SetupRequest) {
        self.header = header
        self.request = request
    }
}

/// The result or structured failure for a setup request.
public struct RuntimeSetupControlReply: Codable, Equatable, Sendable {
    /// The provisioning operation handle, present on success.
    public let result: OperationHandle?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: OperationHandle) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// The body of a `resetAndroid` request (runtime-api.md §5.4, runtime-daemon.md §9.5).
public struct ResetAndroidRequest: Codable, Equatable, Sendable {
    /// Keep a recovery point of the current userdata (7 days). Default true.
    public var keepBackup: Bool
    /// The user confirmed the destructive reset. When false the request fails
    /// with `runtime.malformedRequest`.
    public var confirmed: Bool

    /// Creates a reset request.
    public init(keepBackup: Bool = true, confirmed: Bool) {
        self.keepBackup = keepBackup
        self.confirmed = confirmed
    }
}

/// A `resetAndroid` control request (runtime-api.md §5.4).
public struct RuntimeResetAndroidControlRequest: Codable, Equatable, Sendable {
    /// The authenticated request metadata. Its operation ID is reused by the
    /// returned handle.
    public let header: APIRequestHeader
    /// The reset options.
    public let request: ResetAndroidRequest

    /// Creates a reset control request.
    public init(header: APIRequestHeader, request: ResetAndroidRequest) {
        self.header = header
        self.request = request
    }
}

/// The result or structured failure for a reset-Android request.
public struct RuntimeResetAndroidControlReply: Codable, Equatable, Sendable {
    /// The reset operation handle, present on success.
    public let result: OperationHandle?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: OperationHandle) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}
