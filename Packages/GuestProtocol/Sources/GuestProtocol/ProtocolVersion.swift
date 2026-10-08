/// A protocol version: a major and a minor number (guest-protocol.md §5.2).
///
/// Different majors are never compatible. A higher minor is compatible, and the features that
/// differ are negotiated through capabilities (§5.3).
public struct ProtocolVersion: Equatable, Hashable, Comparable, Sendable, CustomStringConvertible {
    /// The major version. A different major is a different protocol.
    public let major: UInt32
    /// The minor version. A higher minor adds fields, messages, or capabilities.
    public let minor: UInt32

    /// Creates a version.
    public init(major: UInt32, minor: UInt32) {
        self.major = major
        self.minor = minor
    }

    /// Creates a version from its wire form.
    public init(_ wire: GPProtocolVersion) {
        self.init(major: wire.major, minor: wire.minor)
    }

    /// The version that this build of APKRun speaks.
    public static let host = ProtocolVersion(major: 1, minor: 0)

    /// The majors that this build of APKRun speaks. Major 1 is the only one in v1 (§5.2).
    public static let supportedMajors: ClosedRange<UInt32> = 1...1

    /// Compares an agent's version with ``supportedMajors``.
    public static func compatibility(of agent: ProtocolVersion) -> ProtocolCompatibility {
        if supportedMajors.contains(agent.major) {
            return .compatible
        }
        return agent.major < supportedMajors.lowerBound ? .agentOlder : .agentNewer
    }

    /// Orders versions by major, and then by minor.
    public static func < (lhs: ProtocolVersion, rhs: ProtocolVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    /// The version as `major.minor`.
    public var description: String {
        "\(major).\(minor)"
    }
}

/// How an agent's major version relates to ``ProtocolVersion/supportedMajors``.
public enum ProtocolCompatibility: Equatable, Sendable {
    /// The major version is supported. Any minor is accepted.
    case compatible
    /// The agent is older than APKRun supports. The user is asked to update Android
    /// (error-catalog.md §8.1, `hostNewer`).
    case agentOlder
    /// The agent is newer than APKRun supports. The user is asked to update APKRun
    /// (error-catalog.md §8.1, `guestNewer`).
    case agentNewer
}
