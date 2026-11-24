import Foundation
import RuntimeAPI

/// The kind of a generated wrapper (wrapper.md §6.1).
public enum WrapperKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// A local wrapper registered on this Mac.
    case local
    /// A portable wrapper carrying its APK set (#90).
    case portable
    /// A wrapper signed for distribution (#89).
    case distribution
}

/// Where a generated wrapper is placed (wrapper.md §6.3).
public enum WrapperDestination: Sendable, Equatable {
    /// `~/Applications`, created when missing. The default.
    case userApplications
    /// `/Applications`, for every user of this Mac.
    case applications
    /// Any other directory picked by the user or passed as `--output`.
    case directory(URL)
}

/// What generation may do when the destination already holds this package's
/// registered wrapper (wrapper.md §6.4).
public enum ReplacePolicy: String, Codable, Sendable {
    /// Never replace anything; a conflict throws.
    case never
    /// Replace only the registered wrapper of the same package (a refresh).
    case sameWrapper
}

/// The kind of item already occupying the destination path (wrapper.md §6.4).
public enum ExistingItemKind: Sendable, Equatable {
    /// A wrapper registered to a different package.
    case otherWrapper(RuntimePackageID)
    /// A native application or any other bundle.
    case otherApp
    /// A plain file or folder that is not an app bundle.
    case file
}

/// The Android `ApplicationInfo.category` values that map to a Mac
/// `LSApplicationCategoryType` (wrapper.md §2.1).
public enum AndroidAppCategory: String, Codable, Sendable, CaseIterable {
    case game
    case audio
    case video
    case image
    case social
    case news
    case maps
    case productivity

    /// The `LSApplicationCategoryType` value written to Info.plist.
    public var lsApplicationCategoryType: String {
        switch self {
        case .game: "public.app-category.games"
        case .audio: "public.app-category.music"
        case .video: "public.app-category.video"
        case .image: "public.app-category.photography"
        case .social: "public.app-category.social-networking"
        case .news: "public.app-category.news"
        case .maps: "public.app-category.navigation"
        case .productivity: "public.app-category.productivity"
        }
    }
}

/// The initial window mode of a wrapper (wrapper-json.md §2.2).
public enum WrapperWindowMode: String, Codable, Sendable {
    /// `window.mode = secondaryDisplay`.
    case standard
    /// `window.mode = primaryDisplayCompatibility`.
    case compatibility
}

/// The initial window defaults written to `wrapper.json`.
public struct WindowDefaults: Codable, Sendable, Equatable {
    /// The window mode.
    public var mode: WrapperWindowMode
    /// The default window width in points (320–8192).
    public var defaultWidth: Int
    /// The default window height in points (400–8192).
    public var defaultHeight: Int
    /// Whether the window can be resized.
    public var resizable: Bool

    /// Creates window defaults.
    public init(
        mode: WrapperWindowMode = .standard,
        defaultWidth: Int = 480,
        defaultHeight: Int = 850,
        resizable: Bool = true
    ) {
        self.mode = mode
        self.defaultWidth = defaultWidth
        self.defaultHeight = defaultHeight
        self.resizable = resizable
    }
}

/// The initial update authority of a wrapper (wrapper-json.md §2.2).
public enum WrapperUpdateAuthority: String, Codable, Sendable {
    /// APKRun manages updates.
    case apkrun
    /// The user updates the app by hand.
    case manual
}

/// The initial update mode of a wrapper.
public enum WrapperUpdateMode: String, Codable, Sendable {
    /// Updates install automatically.
    case automatic
    /// The user is asked before updates install.
    case notifyOnly
}

/// A provider reference stored in `wrapper.json` (package-metadata-json.md §2.4).
/// `local` is never written: it is rewritten to `manual` authority (wrapper-json.md §2.5).
public enum WrapperProviderConfiguration: Sendable, Hashable {
    /// A direct HTTPS manifest.
    case direct(url: String)
    /// An F-Droid repository.
    case fdroid(repository: String, fingerprint: String)
    /// A GitHub releases provider.
    case github(repository: String, assetPattern: String, channel: String)
}

/// A provider type paired with its configuration (package-metadata-json.md §2.4).
public struct WrapperUpdateProvider: Codable, Sendable, Hashable {
    /// The provider type.
    public var type: String
    /// The provider-specific configuration fields.
    public var configuration: WrapperProviderConfiguration

    /// Creates a provider reference.
    public init(type: String, configuration: WrapperProviderConfiguration) {
        self.type = type
        self.configuration = configuration
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case configuration
    }

    /// Decodes the flat provider configuration selected by its type.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        let nested = try container.nestedContainer(
            keyedBy: DynamicCodingKey.self, forKey: .configuration)
        switch type {
        case "direct":
            configuration = .direct(url: try nested.decode(String.self, forKey: .init("url")))
        case "fdroid":
            configuration = .fdroid(
                repository: try nested.decode(String.self, forKey: .init("repository")),
                fingerprint: try nested.decode(String.self, forKey: .init("fingerprint"))
            )
        case "github":
            configuration = .github(
                repository: try nested.decode(String.self, forKey: .init("repository")),
                assetPattern: try nested.decode(String.self, forKey: .init("assetPattern")),
                channel: try nested.decode(String.self, forKey: .init("channel"))
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown provider type \(type)"
            )
        }
    }

    /// Encodes the flat provider reference.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        var nested = container.nestedContainer(
            keyedBy: DynamicCodingKey.self, forKey: .configuration)
        switch configuration {
        case .direct(let url):
            try nested.encode(url, forKey: .init("url"))
        case .fdroid(let repository, let fingerprint):
            try nested.encode(repository, forKey: .init("repository"))
            try nested.encode(fingerprint, forKey: .init("fingerprint"))
        case .github(let repository, let assetPattern, let channel):
            try nested.encode(repository, forKey: .init("repository"))
            try nested.encode(assetPattern, forKey: .init("assetPattern"))
            try nested.encode(channel, forKey: .init("channel"))
        }
    }
}

/// A coding key built from a field name.
struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}

/// The initial update defaults written to `wrapper.json`.
public struct WrapperUpdateDefaults: Codable, Sendable, Equatable {
    /// The update authority.
    public var authority: WrapperUpdateAuthority
    /// The update mode.
    public var mode: WrapperUpdateMode
    /// The update provider. Written as `null` for `local` providers.
    public var provider: WrapperUpdateProvider?

    /// Creates update defaults.
    public init(
        authority: WrapperUpdateAuthority = .manual,
        mode: WrapperUpdateMode = .automatic,
        provider: WrapperUpdateProvider? = nil
    ) {
        self.authority = authority
        self.mode = mode
        self.provider = provider
    }
}

/// Where Android links open (wrapper-json.md §2.2, desktop-integration.md §2.1).
public enum IntegrationLinkTarget: String, Codable, Sendable {
    /// The user is asked per link.
    case ask
    /// Links open on the Mac.
    case mac
    /// Links stay in Android.
    case android
}

/// How Android sees shared folders (desktop-integration.md §2.1).
public enum SharedFolderMode: String, Codable, Sendable {
    /// Folders are not shared.
    case off
    /// Folders are shared read-only.
    case readOnly
    /// Folders are shared for reading and writing.
    case readWrite
}

/// The explicitly configured integration values of a wrapper. Only set keys are
/// written to `wrapper.json` (wrapper-json.md §2.5).
public struct IntegrationDefaults: Codable, Sendable, Equatable {
    /// The clipboard integration value.
    public var clipboard: Bool?
    /// The notifications integration value.
    public var notifications: Bool?
    /// Where links open.
    public var links: IntegrationLinkTarget?
    /// The file-transfer integration value.
    public var files: Bool?
    /// The shared-folder integration value.
    public var sharedFolders: SharedFolderMode?
    /// The microphone integration value.
    public var microphone: Bool?

    /// Creates integration defaults; every key starts absent.
    public init(
        clipboard: Bool? = nil,
        notifications: Bool? = nil,
        links: IntegrationLinkTarget? = nil,
        files: Bool? = nil,
        sharedFolders: SharedFolderMode? = nil,
        microphone: Bool? = nil
    ) {
        self.clipboard = clipboard
        self.notifications = notifications
        self.links = links
        self.files = files
        self.sharedFolders = sharedFolders
        self.microphone = microphone
    }
}

/// The icon input of a generation request (wrapper.md §6.1). The full icon
/// pipeline is #56; `rendered` and `preview` carry already-prepared bytes.
public enum WrapperIconSource: Sendable, Equatable {
    /// Finished `.icns` bytes.
    case rendered(Data)
    /// A PNG that is wrapped into an `.icns` container.
    case preview(Data)
    /// A file the user picked; converted when read.
    case custom(URL)
    /// The built-in placeholder icon.
    case placeholder
}

/// Everything the generator needs to build a wrapper. WrapperCore never reads
/// APKs or package state; RuntimeHost fills this from the package record,
/// settings, and icon files (wrapper.md §6.1).
public struct WrapperConfiguration: Sendable, Equatable {
    /// The Android package ID.
    public var packageID: RuntimePackageID
    /// The display name written to `CFBundleDisplayName`.
    public var displayName: String
    /// The icon source.
    public var icon: WrapperIconSource
    /// The Android app category, mapped to `LSApplicationCategoryType`.
    public var category: AndroidAppCategory?
    /// The initial window defaults.
    public var window: WindowDefaults
    /// The initial update defaults.
    public var updates: WrapperUpdateDefaults
    /// The explicitly set integration defaults.
    public var integrations: IntegrationDefaults
    /// The wrapper kind.
    public var kind: WrapperKind
    /// The APK set a portable wrapper bundles (wrapper.md §10). Required for
    /// `.portable`, ignored otherwise.
    public var bootstrap: BootstrapSet?

    /// Creates a generation configuration.
    public init(
        packageID: RuntimePackageID,
        displayName: String,
        icon: WrapperIconSource = .placeholder,
        category: AndroidAppCategory? = nil,
        window: WindowDefaults = WindowDefaults(),
        updates: WrapperUpdateDefaults = WrapperUpdateDefaults(),
        integrations: IntegrationDefaults = IntegrationDefaults(),
        kind: WrapperKind = .local,
        bootstrap: BootstrapSet? = nil
    ) {
        self.packageID = packageID
        self.displayName = displayName
        self.icon = icon
        self.category = category
        self.window = window
        self.updates = updates
        self.integrations = integrations
        self.kind = kind
        self.bootstrap = bootstrap
    }
}

/// A generation request (wrapper.md §6.1).
public struct WrapperGenerationRequest: Sendable {
    /// The wrapper contents.
    public var configuration: WrapperConfiguration
    /// Where the finished bundle goes.
    public var destination: WrapperDestination
    /// A file name that overrides §4.3 (without `.app`).
    public var fileName: String?
    /// The conflict policy.
    public var replace: ReplacePolicy

    /// Creates a generation request.
    public init(
        configuration: WrapperConfiguration,
        destination: WrapperDestination = .userApplications,
        fileName: String? = nil,
        replace: ReplacePolicy = .never
    ) {
        self.configuration = configuration
        self.destination = destination
        self.fileName = fileName
        self.replace = replace
    }
}

/// The result of a generation (wrapper.md §6.1).
public struct GeneratedWrapper: Codable, Sendable, Equatable {
    /// The final bundle location.
    public var bundleURL: URL
    /// The deterministic bundle ID.
    public var bundleID: String
    /// The code directory hash of the signed bundle, 40 hex characters.
    public var cdhash: String
    /// The APKRun version that built the launcher.
    public var launcherVersion: String

    /// Creates a generation result.
    public init(bundleURL: URL, bundleID: String, cdhash: String, launcherVersion: String) {
        self.bundleURL = bundleURL
        self.bundleID = bundleID
        self.cdhash = cdhash
        self.launcherVersion = launcherVersion
    }
}

/// Build constants of the launcher template (wrapper.md §3, §5.3). The values
/// come from the template, never from the APKRun.app version.
public struct LauncherBuild: Sendable, Equatable {
    /// The lowest APKRun version the launcher works with (`runtime.minimumVersion`).
    public var minimumRuntimeVersion: String
    /// The RuntimeAPI version the launcher was built against (`APKRunLauncherAPI`).
    public var launcherAPI: String
    /// The APKRun version that built the launcher (`APKRunLauncherVersion`).
    public var launcherVersion: String
    /// The `APKRunBuildIdentity` of the template app (`dev`, `release`, or
    /// `updatetest`); the generated wrapper copies it so its
    /// `RuntimeControlClient` reaches the matching apkrund.
    public var buildIdentity: String
    /// The URL of the launcher executable inside the template app.
    public var executableURL: URL

    /// Creates launcher build constants.
    public init(
        minimumRuntimeVersion: String = "1.0.0",
        launcherAPI: String,
        launcherVersion: String,
        buildIdentity: String = "dev",
        executableURL: URL
    ) {
        self.minimumRuntimeVersion = minimumRuntimeVersion
        self.launcherAPI = launcherAPI
        self.launcherVersion = launcherVersion
        self.buildIdentity = buildIdentity
        self.executableURL = executableURL
    }
}
