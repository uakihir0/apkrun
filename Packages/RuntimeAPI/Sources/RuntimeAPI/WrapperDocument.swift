import Foundation

/// The format of a generated Mac app wrapper's `wrapper.json`.
///
/// This is a value-only model. It does not authorize a wrapper; apkrund uses its registry for
/// authorization.
public struct WrapperDocument: Codable, Equatable, Hashable, Sendable {
    /// The only wrapper document format understood by this launcher.
    public static let currentFormatVersion = 1

    /// The wrapper document format version. Decoding rejects unsupported versions.
    public let formatVersion: Int
    /// Whether the wrapper is local, portable, or intended for distribution.
    public let kind: WrapperKind
    /// The Android application's identity and display name.
    public let application: WrapperApplication
    /// The runtime compatibility requirements for the launcher.
    public let runtime: WrapperRuntime
    /// Initial window preferences, when present.
    public let window: WrapperWindow?
    /// Initial update preferences, when present.
    public let updates: WrapperUpdates?
    /// Initial host integration preferences, when present.
    public let integration: WrapperIntegration?

    /// Creates a wrapper document in the current supported format.
    public init(
        kind: WrapperKind,
        application: WrapperApplication,
        runtime: WrapperRuntime,
        window: WrapperWindow,
        updates: WrapperUpdates? = nil,
        integration: WrapperIntegration = WrapperIntegration()
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.kind = kind
        self.application = application
        self.runtime = runtime
        self.window = window
        self.updates = updates
        self.integration = integration
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case kind
        case application
        case runtime
        case window
        case updates
        case integration
    }

    /// Decodes the strict identity fields and tolerates absent or malformed preference sections.
    /// Decodes and validates the package ID and display name.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        guard formatVersion == Self.currentFormatVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .formatVersion,
                in: container,
                debugDescription: "Unsupported wrapper document format version."
            )
        }

        self.formatVersion = formatVersion
        self.kind = try container.decode(WrapperKind.self, forKey: .kind)
        self.application = try container.decode(WrapperApplication.self, forKey: .application)
        self.runtime = try container.decode(WrapperRuntime.self, forKey: .runtime)
        self.window = try Self.decodeOptionalSection(WrapperWindow.self, forKey: .window, in: container)
        self.updates = try Self.decodeOptionalSection(WrapperUpdates.self, forKey: .updates, in: container)
        self.integration = try Self.decodeOptionalSection(
            WrapperIntegration.self,
            forKey: .integration,
            in: container
        )
    }

    /// Encodes the current wrapper format, omitting absent preference sections.
    /// Parsed reader documents can omit these writer-required sections, so refuse to write one.
    public func encode(to encoder: any Encoder) throws {
        guard let window, let integration else {
            throw WrapperDocumentValidationError.incompleteGeneratedDocument
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(kind, forKey: .kind)
        try container.encode(application, forKey: .application)
        try container.encode(runtime, forKey: .runtime)
        try container.encode(window, forKey: .window)
        try container.encodeIfPresent(updates, forKey: .updates)
        try container.encode(integration, forKey: .integration)
    }

    private static func decodeOptionalSection<Value: Decodable>(
        _ type: Value.Type,
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Value? {
        guard container.contains(key) else {
            return nil
        }
        guard try !container.decodeNil(forKey: key) else {
            throw DecodingError.typeMismatch(
                type,
                DecodingError.Context(
                    codingPath: container.codingPath + [key],
                    debugDescription: "Expected a wrapper preference object."
                )
            )
        }
        return try container.decode(type, forKey: key)
    }
}

/// The kind recorded by a wrapper document.
public enum WrapperKind: String, Codable, Equatable, Hashable, Sendable {
    /// A wrapper for a package already managed on this Mac.
    case local
    /// A wrapper that carries a bootstrap APK set.
    case portable
    /// A wrapper prepared for signed distribution.
    case distribution
}

/// The Android package identity and the name shown by the wrapper.
public struct WrapperApplication: Codable, Equatable, Hashable, Sendable {
    /// The case-sensitive Android package ID.
    public let packageID: RuntimePackageID
    /// The display name captured when the wrapper was generated.
    public let displayName: String

    /// Creates an application identity with a schema-valid display name.
    public init(packageID: RuntimePackageID, displayName: String) throws {
        guard Self.isValidDisplayName(displayName) else {
            throw WrapperDocumentValidationError.invalidDisplayName
        }
        self.packageID = packageID
        self.displayName = displayName
    }

    private enum CodingKeys: String, CodingKey {
        case packageID = "packageId"
        case displayName
    }

    /// Decodes and validates the application display name.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let displayName = try container.decode(String.self, forKey: .displayName)
        guard Self.isValidDisplayName(displayName) else {
            throw DecodingError.dataCorruptedError(
                forKey: .displayName,
                in: container,
                debugDescription: "Wrapper display name must contain 1 to 1024 Unicode scalars."
            )
        }
        self.packageID = try container.decode(RuntimePackageID.self, forKey: .packageID)
        self.displayName = displayName
    }

    /// Encodes the application identity and display name.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(packageID, forKey: .packageID)
        try container.encode(displayName, forKey: .displayName)
    }

    private static func isValidDisplayName(_ value: String) -> Bool {
        (1...1024).contains(value.unicodeScalars.count)
    }
}

/// The launcher compatibility requirements stored in a wrapper document.
public struct WrapperRuntime: Codable, Equatable, Hashable, Sendable {
    /// The minimum APKRun version that can open this wrapper.
    public let minimumVersion: WrapperMinimumRuntimeVersion
    /// The RuntimeAPI version against which the launcher was built.
    public let launcherAPI: WrapperLauncherAPIVersion

    /// Creates runtime compatibility requirements.
    public init(
        minimumVersion: WrapperMinimumRuntimeVersion,
        launcherAPI: WrapperLauncherAPIVersion
    ) {
        self.minimumVersion = minimumVersion
        self.launcherAPI = launcherAPI
    }
}

/// A validated `MAJOR.MINOR.PATCH` APKRun version string.
public struct WrapperMinimumRuntimeVersion: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    /// The canonical version string.
    public let rawValue: String

    /// Creates a version when it matches the wrapper JSON schema.
    public init?(rawValue: String) {
        guard Self.hasNumericComponents(rawValue, count: 3, maximumLength: 32) else {
            return nil
        }
        self.rawValue = rawValue
    }

    /// Decodes and validates the version string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let version = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid wrapper minimum runtime version."
            )
        }
        self = version
    }

    /// Encodes the version as a string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    fileprivate static func hasNumericComponents(
        _ value: String,
        count expectedCount: Int,
        maximumLength: Int
    ) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumLength else {
            return false
        }
        let components = value.utf8.split(separator: 46, omittingEmptySubsequences: false)
        guard components.count == expectedCount else {
            return false
        }
        return components.allSatisfy { component in
            !component.isEmpty
                && (component.count == 1 || component.first != 48)
                && component.allSatisfy { (48...57).contains($0) }
        }
    }
}

/// A validated `MAJOR.MINOR` RuntimeAPI version string.
public struct WrapperLauncherAPIVersion: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    /// The canonical API version string.
    public let rawValue: String

    /// Creates a version when it matches the wrapper JSON schema.
    public init?(rawValue: String) {
        guard
            WrapperMinimumRuntimeVersion.hasNumericComponents(
                rawValue,
                count: 2,
                maximumLength: 16
            )
        else {
            return nil
        }
        self.rawValue = rawValue
    }

    /// Decodes and validates the API version string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let version = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid wrapper launcher API version."
            )
        }
        self = version
    }

    /// Encodes the API version string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Window preferences copied into package settings when the package is first recorded.
public struct WrapperWindow: Codable, Equatable, Hashable, Sendable {
    /// The display mode selected by the wrapper generator.
    public let mode: WrapperWindowMode?
    /// The initial window width in points.
    public let defaultWidth: Int?
    /// The initial window height in points.
    public let defaultHeight: Int?
    /// Whether the user may resize the window.
    public let resizable: Bool?

    /// Creates the complete window preference object required in generated wrappers.
    public init(
        mode: WrapperWindowMode,
        defaultWidth: Int,
        defaultHeight: Int,
        resizable: Bool
    ) throws {
        guard (320...8192).contains(defaultWidth) else {
            throw WrapperDocumentValidationError.invalidWindowWidth
        }
        guard (400...8192).contains(defaultHeight) else {
            throw WrapperDocumentValidationError.invalidWindowHeight
        }
        self.mode = mode
        self.defaultWidth = defaultWidth
        self.defaultHeight = defaultHeight
        self.resizable = resizable
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case defaultWidth
        case defaultHeight
        case resizable
    }

    /// Decodes window preferences, treating invalid values as absent individually.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try? container.decode(WrapperWindowMode.self, forKey: .mode)
        self.defaultWidth = Self.decodeInteger(in: container, forKey: .defaultWidth, range: 320...8192)
        self.defaultHeight = Self.decodeInteger(in: container, forKey: .defaultHeight, range: 400...8192)
        self.resizable = try? container.decode(Bool.self, forKey: .resizable)
    }

    /// Encodes all four writer-required fields, refusing a partial decoded preference object.
    public func encode(to encoder: any Encoder) throws {
        guard let mode, let defaultWidth, let defaultHeight, let resizable else {
            throw WrapperDocumentValidationError.incompleteWindowPreferences
        }
        guard (320...8192).contains(defaultWidth) else {
            throw WrapperDocumentValidationError.invalidWindowWidth
        }
        guard (400...8192).contains(defaultHeight) else {
            throw WrapperDocumentValidationError.invalidWindowHeight
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(defaultWidth, forKey: .defaultWidth)
        try container.encode(defaultHeight, forKey: .defaultHeight)
        try container.encode(resizable, forKey: .resizable)
    }

    private static func decodeInteger(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys,
        range: ClosedRange<Int>
    ) -> Int? {
        guard let value = try? container.decode(Int.self, forKey: key), range.contains(value) else {
            return nil
        }
        return value
    }
}

/// Window modes accepted by `wrapper.json`.
public enum WrapperWindowMode: String, Codable, Equatable, Hashable, Sendable {
    /// Opens the package on a secondary display.
    case standard
    /// Opens the package using primary-display compatibility behavior.
    case compatibility
}

/// Initial package update settings stored in a wrapper document.
public struct WrapperUpdates: Codable, Equatable, Hashable, Sendable {
    /// The package's initial update authority.
    public let authority: WrapperUpdateAuthority?
    /// The initial automatic-update behavior.
    public let mode: WrapperUpdateMode?
    /// The provider configuration, or `nil` when the file says `null`, omits it, or has an invalid value.
    public let provider: WrapperUpdateProviderRef?

    /// Creates update preferences.
    public init(
        authority: WrapperUpdateAuthority? = nil,
        mode: WrapperUpdateMode? = nil,
        provider: WrapperUpdateProviderRef? = nil
    ) {
        self.authority = authority
        self.mode = mode
        self.provider = provider
    }

    private enum CodingKeys: String, CodingKey {
        case authority
        case mode
        case provider
    }

    /// Decodes update preferences, treating invalid values as absent individually.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.authority = try? container.decode(WrapperUpdateAuthority.self, forKey: .authority)
        self.mode = try? container.decode(WrapperUpdateMode.self, forKey: .mode)
        self.provider = try? container.decode(WrapperUpdateProviderRef.self, forKey: .provider)
    }

    /// Encodes the complete writer representation, including `null` for an absent provider.
    public func encode(to encoder: any Encoder) throws {
        guard let authority, let mode else {
            throw WrapperDocumentValidationError.incompleteUpdatePreferences
        }
        if authority == .apkrun, provider == nil {
            throw WrapperDocumentValidationError.missingRequiredUpdateProvider
        }
        try provider?.validate()

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(authority, forKey: .authority)
        try container.encode(mode, forKey: .mode)
        // The writer contract requires the provider key; nil has the documented JSON `null` value.
        try container.encode(provider, forKey: .provider)
    }
}

/// Update authority values allowed in a wrapper.
public enum WrapperUpdateAuthority: String, Codable, Equatable, Hashable, Sendable {
    /// APKRun manages updates for the package.
    case apkrun
    /// The user or another source manages updates.
    case manual
}

/// Update modes allowed in a wrapper.
public enum WrapperUpdateMode: String, Codable, Equatable, Hashable, Sendable {
    /// Download and install eligible updates automatically.
    case automatic
    /// Notify the user when an update is available.
    case notifyOnly
}

/// A non-local update provider that may be embedded in a wrapper.
///
/// Local provider paths and bookmarks are Mac-specific and are never written into a wrapper.
public enum WrapperUpdateProviderRef: Codable, Equatable, Hashable, Sendable {
    /// An HTTPS manifest URL.
    case direct(url: String)
    /// An F-Droid repository and its signing-certificate fingerprint.
    case fdroid(repository: String, fingerprint: String)
    /// A GitHub release repository and selection policy.
    case github(repository: String, assetPattern: String, channel: WrapperGitHubReleaseChannel)

    private enum CodingKeys: String, CodingKey {
        case type
        case configuration
    }

    private enum ConfigurationKeys: String, CodingKey {
        case url
        case repository
        case fingerprint
        case assetPattern
        case channel
    }

    /// Decodes a supported non-local update provider and its configuration.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let configuration = try container.nestedContainer(
            keyedBy: ConfigurationKeys.self,
            forKey: .configuration
        )
        let provider: Self
        switch type {
        case "direct":
            provider = .direct(url: try configuration.decode(String.self, forKey: .url))
        case "fdroid":
            provider = .fdroid(
                repository: try configuration.decode(String.self, forKey: .repository),
                fingerprint: try configuration.decode(String.self, forKey: .fingerprint)
            )
        case "github":
            provider = .github(
                repository: try configuration.decode(String.self, forKey: .repository),
                assetPattern: try configuration.decode(String.self, forKey: .assetPattern),
                channel: try configuration.decode(WrapperGitHubReleaseChannel.self, forKey: .channel)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported wrapper update provider."
            )
        }
        do {
            try provider.validate()
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .configuration,
                in: container,
                debugDescription: "Invalid wrapper update provider configuration."
            )
        }
        self = provider
    }

    /// Encodes the provider as a type and its flat provider-specific configuration object.
    public func encode(to encoder: any Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        var configuration = container.nestedContainer(
            keyedBy: ConfigurationKeys.self,
            forKey: .configuration
        )
        switch self {
        case .direct(let url):
            try container.encode("direct", forKey: .type)
            try configuration.encode(url, forKey: .url)
        case .fdroid(let repository, let fingerprint):
            try container.encode("fdroid", forKey: .type)
            try configuration.encode(repository, forKey: .repository)
            try configuration.encode(fingerprint, forKey: .fingerprint)
        case .github(let repository, let assetPattern, let channel):
            try container.encode("github", forKey: .type)
            try configuration.encode(repository, forKey: .repository)
            try configuration.encode(assetPattern, forKey: .assetPattern)
            try configuration.encode(channel, forKey: .channel)
        }
    }

    fileprivate func validate() throws(WrapperDocumentValidationError) {
        let isValid: Bool
        switch self {
        case .direct(let url):
            isValid = WrapperProviderValidation.isValidManifestURL(url)
        case .fdroid(let repository, let fingerprint):
            isValid =
                WrapperProviderValidation.isValidRepositoryURL(repository)
                && WrapperProviderValidation.isLowercaseSHA256(fingerprint)
        case .github(let repository, let assetPattern, _):
            isValid =
                WrapperProviderValidation.isGitHubRepository(repository)
                && WrapperProviderValidation.isGitHubAssetPattern(assetPattern)
        }
        guard isValid else {
            throw .invalidUpdateProvider
        }
    }
}

private enum WrapperProviderValidation {
    static func isValidManifestURL(_ value: String) -> Bool {
        isValidHTTPSURL(value)
    }

    static func isValidRepositoryURL(_ value: String) -> Bool {
        guard isValidHTTPSURL(value),
            !value.hasSuffix("/")
        else {
            return false
        }
        guard let components = URLComponents(string: value) else {
            return false
        }
        return components.query == nil && components.fragment == nil
    }

    private static func isValidHTTPSURL(_ value: String) -> Bool {
        guard value.unicodeScalars.count <= 2048,
            let components = URLComponents(string: value),
            let scheme = components.scheme?.lowercased(),
            let host = components.host,
            !host.isEmpty,
            components.user == nil,
            components.password == nil,
            let url = components.url,
            url.baseURL == nil
        else {
            return false
        }
        if scheme == "https" {
            return true
        }
        #if DEBUG
            if scheme == "http" {
                let normalizedHost = host.lowercased()
                return normalizedHost == "localhost"
                    || normalizedHost == "127.0.0.1"
                    || normalizedHost == "::1"
            }
        #endif
        return false
    }

    static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func isGitHubRepository(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return false
        }
        let owner = parts[0].utf8
        let name = parts[1].utf8
        guard
            (1...39).contains(owner.count),
            (1...100).contains(name.count),
            let firstOwnerByte = owner.first
        else {
            return false
        }
        let isASCIIAlphaNumeric: (UInt8) -> Bool = {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
        }
        guard isASCIIAlphaNumeric(firstOwnerByte) else {
            return false
        }
        guard owner.allSatisfy({ isASCIIAlphaNumeric($0) || $0 == 45 }) else {
            return false
        }
        guard name.allSatisfy({ isASCIIAlphaNumeric($0) || $0 == 46 || $0 == 95 || $0 == 45 }) else {
            return false
        }
        return parts[1] != "." && parts[1] != ".."
    }

    static func isGitHubAssetPattern(_ value: String) -> Bool {
        (1...255).contains(value.unicodeScalars.count) && !value.contains("/")
    }
}

/// GitHub release channel values accepted by a wrapper update provider.
public enum WrapperGitHubReleaseChannel: String, Codable, Equatable, Hashable, Sendable {
    /// Stable releases only.
    case stable
    /// Stable and prerelease releases.
    case prerelease
}

/// Host integration preferences copied into package settings on first record.
public struct WrapperIntegration: Codable, Equatable, Hashable, Sendable {
    /// Initial clipboard sharing preference.
    public let clipboard: Bool?
    /// Initial host notification preference.
    public let notifications: Bool?
    /// Initial handling policy for Android links.
    public let links: WrapperLinkPolicy?
    /// Initial shared file access preference.
    public let files: Bool?
    /// Initial shared-folder access mode.
    public let sharedFolders: WrapperSharedFolderMode?
    /// Initial microphone access preference.
    public let microphone: Bool?

    /// Creates integration preferences.
    public init(
        clipboard: Bool? = nil,
        notifications: Bool? = nil,
        links: WrapperLinkPolicy? = nil,
        files: Bool? = nil,
        sharedFolders: WrapperSharedFolderMode? = nil,
        microphone: Bool? = nil
    ) {
        self.clipboard = clipboard
        self.notifications = notifications
        self.links = links
        self.files = files
        self.sharedFolders = sharedFolders
        self.microphone = microphone
    }

    private enum CodingKeys: String, CodingKey {
        case clipboard
        case notifications
        case links
        case files
        case sharedFolders
        case microphone
    }

    /// Decodes integration preferences, treating invalid values as absent individually.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.clipboard = try? container.decode(Bool.self, forKey: .clipboard)
        self.notifications = try? container.decode(Bool.self, forKey: .notifications)
        self.links = try? container.decode(WrapperLinkPolicy.self, forKey: .links)
        self.files = try? container.decode(Bool.self, forKey: .files)
        self.sharedFolders = try? container.decode(WrapperSharedFolderMode.self, forKey: .sharedFolders)
        self.microphone = try? container.decode(Bool.self, forKey: .microphone)
    }

    /// Encodes the available integration preferences.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(clipboard, forKey: .clipboard)
        try container.encodeIfPresent(notifications, forKey: .notifications)
        try container.encodeIfPresent(links, forKey: .links)
        try container.encodeIfPresent(files, forKey: .files)
        try container.encodeIfPresent(sharedFolders, forKey: .sharedFolders)
        try container.encodeIfPresent(microphone, forKey: .microphone)
    }
}

/// Link handling modes accepted by the wrapper schema.
public enum WrapperLinkPolicy: String, Codable, Equatable, Hashable, Sendable {
    /// Ask the user where to open the link.
    case ask
    /// Open the link on macOS.
    case mac
    /// Open the link in Android.
    case android
}

/// Shared-folder access modes accepted by the wrapper schema.
public enum WrapperSharedFolderMode: String, Codable, Equatable, Hashable, Sendable {
    /// Do not share host folders.
    case off
    /// Share selected folders read-only.
    case readOnly
    /// Share selected folders read-write.
    case readWrite
}

/// Errors when constructing a wrapper document value that has local schema constraints.
public enum WrapperDocumentValidationError: Error, Equatable, Sendable {
    /// The display name is empty or exceeds the schema's 1024 Unicode scalar limit.
    case invalidDisplayName
    /// A generated wrapper omitted its required window or integration section.
    case incompleteGeneratedDocument
    /// The generated window preferences do not contain all four required fields.
    case incompleteWindowPreferences
    /// The generated updates section omitted its authority or mode.
    case incompleteUpdatePreferences
    /// The `apkrun` update authority requires a valid provider.
    case missingRequiredUpdateProvider
    /// An update provider does not satisfy package metadata provider constraints.
    case invalidUpdateProvider
    /// The generated window width is outside the supported range.
    case invalidWindowWidth
    /// The generated window height is outside the supported range.
    case invalidWindowHeight
}
