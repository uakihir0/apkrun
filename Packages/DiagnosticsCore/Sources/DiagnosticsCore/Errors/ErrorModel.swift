import Foundation

/// The stable error-code namespace owned by each APKRun module.
public enum ErrorDomain: String, CaseIterable, Codable, Sendable {
    case vm
    case graphics
    case runtime
    case guestProtocol
    case image
    case store
    case update
    case wrapper
    case integration
    case maintenance
    case diagnostics
    case cli
}

/// A parameter safe to use in catalog text and user-facing errors.
public enum ErrorParameter: Codable, Equatable, Sendable {
    case text(String)
    case bytes(Int64)
    case count(Int)
    case duration(Duration)
    case fileName(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
        case seconds
        case attoseconds
    }

    private enum Kind: String, Codable {
        case text
        case bytes
        case count
        case duration
        case fileName
    }

    /// Decodes the tagged representation while sanitizing file names.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .text:
            self = .text(try container.decode(String.self, forKey: .value))
        case .bytes:
            self = .bytes(try container.decode(Int64.self, forKey: .value))
        case .count:
            self = .count(try container.decode(Int.self, forKey: .value))
        case .fileName:
            let value = try container.decode(String.self, forKey: .value)
            self = .fileName(URL(fileURLWithPath: value).lastPathComponent)
        case .duration:
            self = .duration(
                Duration(
                    secondsComponent: try container.decode(Int64.self, forKey: .seconds),
                    attosecondsComponent: try container.decode(Int64.self, forKey: .attoseconds)
                )
            )
        }
    }

    /// Encodes the tagged representation without exposing arbitrary error metadata.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .bytes(let value):
            try container.encode(Kind.bytes, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .count(let value):
            try container.encode(Kind.count, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .fileName(let value):
            try container.encode(Kind.fileName, forKey: .kind)
            try container.encode(URL(fileURLWithPath: value).lastPathComponent, forKey: .value)
        case .duration(let value):
            try container.encode(Kind.duration, forKey: .kind)
            try container.encode(value.components.seconds, forKey: .seconds)
            try container.encode(value.components.attoseconds, forKey: .attoseconds)
        }
    }
}

/// Selects the catalog text used to render one item in a list error.
public enum ErrorListItemSelector: Codable, Equatable, Sendable {
    /// A fully qualified error code, such as `vm.diskMissing`.
    case errorCode(String)

    /// A catalog variant, such as `cli.fileNotAccessible` / `notFound`.
    case variant(code: String, key: String)
}

/// One ordered, parameterized item carried by a list error.
public struct ErrorListItem: Codable, Equatable, Sendable {
    /// The catalog entry or variant used to select this item's text.
    public let selector: ErrorListItemSelector

    /// Public-safe values used only by this item's templates.
    public let parameters: [String: ErrorParameter]

    /// Creates one item while preserving its own catalog parameters.
    public init(
        selector: ErrorListItemSelector,
        parameters: [String: ErrorParameter] = [:]
    ) {
        self.selector = selector
        self.parameters = parameters
    }
}

/// The safe domain and integer code of a system error.
public struct UnderlyingError: Codable, Equatable, Sendable {
    /// The system error namespace, without `userInfo` or path-bearing metadata.
    public let domain: String

    /// The numeric system error code.
    public let code: Int

    /// Creates a safe, path-free representation of a system error.
    public init(domain: String, code: Int) {
        self.domain = domain
        self.code = code
    }
}

/// The action a user can take after seeing a catalog error.
public enum RemediationAction: String, CaseIterable, Codable, Sendable {
    case none
    case retry
    case openTroubleshooting
    case restartAndroid
    case startGraphicsSafeMode
    case openRuntimeSettings
    case openStorageSettings
    case openPrivacySettings
    case openLoginItemsSettings
    case openNotificationSettings
    case openDownloadsPage
    case updateAPKRun
    case updateAndroid
    case updateMacApp
    case createMacApp
    case reinstallApp
    case reportProblem
}

/// A typed error whose public identity and message parameters come from the error catalog.
public protocol APKRunError: Error, Sendable {
    static var domain: ErrorDomain { get }
    var code: String { get }
    var parameters: [String: ErrorParameter] { get }
    var listItems: [ErrorListItem] { get }
    var cause: (any APKRunError)? { get }
    var underlying: UnderlyingError? { get }
}

extension APKRunError {
    /// The stable `<domain>.<case>` error code.
    public var qualifiedCode: String {
        "\(Self.domain.rawValue).\(code)"
    }

    /// Safe catalog parameters, empty unless the error supplies its own values.
    public var parameters: [String: ErrorParameter] { [:] }

    /// Ordered item details, empty unless the error is a list case.
    public var listItems: [ErrorListItem] { [] }

    /// The typed error that caused this error, if any.
    public var cause: (any APKRunError)? { nil }

    /// The system error underlying this error, if any.
    public var underlying: UnderlyingError? { nil }
}
