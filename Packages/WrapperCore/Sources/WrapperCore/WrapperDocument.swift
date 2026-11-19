import Foundation
import RuntimeAPI

/// The `Resources/wrapper.json` document of a wrapper (wrapper-json.md §2).
/// It carries identity and initial preferences only: never a version code,
/// version name, APK path, or digest (FR-WRP-03).
public struct WrapperDocument: Codable, Sendable, Equatable {
    /// The wrapper format version; always `1` in v1.
    public var formatVersion: Int
    /// The wrapper kind (`local`, `portable`, `distribution`).
    public var kind: WrapperKind
    /// The application identity.
    public var application: Application
    /// The runtime compatibility block.
    public var runtime: Runtime
    /// The initial window values (wrapper-json.md §2.2).
    public var window: Window?
    /// The initial update values for `apkrun` and `manual` packages.
    public var updates: Updates?
    /// The explicitly configured integration values.
    public var integration: Integration?

    /// The `application` object.
    public struct Application: Codable, Sendable, Equatable {
        /// The Android package ID; equals Info.plist `APKRunPackageID`.
        public var packageId: String
        /// The display name; equals `CFBundleDisplayName`.
        public var displayName: String

        /// Creates the application block.
        public init(packageId: String, displayName: String) {
            self.packageId = packageId
            self.displayName = displayName
        }
    }

    /// The `runtime` object.
    public struct Runtime: Codable, Sendable, Equatable {
        /// `LauncherBuild.minimumRuntimeVersion` of the template.
        public var minimumVersion: String
        /// The RuntimeAPI version the launcher was built against.
        public var launcherAPI: String

        /// Creates the runtime block.
        public init(minimumVersion: String, launcherAPI: String) {
            self.minimumVersion = minimumVersion
            self.launcherAPI = launcherAPI
        }
    }

    /// The `window` object. Every key is optional at read time: the spec
    /// validates each key alone and ignores a bad one, so a partial or partly
    /// invalid block decodes with the keys that are present
    /// (wrapper-json.md §2.2).
    public struct Window: Codable, Sendable, Equatable {
        /// `standard` or `compatibility`; `nil` when absent or invalid.
        public var mode: WrapperWindowMode?
        /// The default window width in points (320–8192).
        public var defaultWidth: Int?
        /// The default window height in points (400–8192).
        public var defaultHeight: Int?
        /// Whether the window can be resized.
        public var resizable: Bool?

        /// Creates the window block.
        public init(mode: WrapperWindowMode, defaultWidth: Int, defaultHeight: Int, resizable: Bool) {
            self.mode = mode
            self.defaultWidth = defaultWidth
            self.defaultHeight = defaultHeight
            self.resizable = resizable
        }

        /// Decodes the block, ignoring keys that are absent or invalid.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            mode = try? container.decode(WrapperWindowMode.self, forKey: .mode)
            defaultWidth = try? container.decode(Int.self, forKey: .defaultWidth)
            defaultHeight = try? container.decode(Int.self, forKey: .defaultHeight)
            resizable = try? container.decode(Bool.self, forKey: .resizable)
        }
    }

    /// The `updates` object. Every key is optional at read time, like
    /// `window` (wrapper-json.md §2.2).
    public struct Updates: Codable, Sendable, Equatable {
        /// `apkrun` or `manual`; `nil` when absent or invalid.
        public var authority: WrapperUpdateAuthority?
        /// `automatic` or `notifyOnly`; `nil` when absent or invalid.
        public var mode: WrapperUpdateMode?
        /// The provider; `null` for `local` providers.
        public var provider: WrapperUpdateProvider?

        /// Creates the updates block.
        public init(authority: WrapperUpdateAuthority, mode: WrapperUpdateMode, provider: WrapperUpdateProvider?) {
            self.authority = authority
            self.mode = mode
            self.provider = provider
        }

        /// Decodes the block, ignoring keys that are absent or invalid.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            authority = try? container.decode(WrapperUpdateAuthority.self, forKey: .authority)
            mode = try? container.decode(WrapperUpdateMode.self, forKey: .mode)
            provider = try? container.decode(WrapperUpdateProvider?.self, forKey: .provider)
        }
    }

    /// The `integration` object; absent keys take this Mac's defaults.
    public struct Integration: Codable, Sendable, Equatable {
        /// `integrations.clipboard`.
        public var clipboard: Bool?
        /// `integrations.notifications`.
        public var notifications: Bool?
        /// `integrations.links` (`ask`, `mac`, `android`).
        public var links: IntegrationLinkTarget?
        /// `integrations.files`.
        public var files: Bool?
        /// `integrations.sharedFolders` (`off`, `readOnly`, `readWrite`).
        public var sharedFolders: SharedFolderMode?
        /// `integrations.microphone`.
        public var microphone: Bool?

        /// Creates the integration block.
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

    /// Creates a document.
    public init(
        formatVersion: Int = 1,
        kind: WrapperKind,
        application: Application,
        runtime: Runtime,
        window: Window?,
        updates: Updates?,
        integration: Integration?
    ) {
        self.formatVersion = formatVersion
        self.kind = kind
        self.application = application
        self.runtime = runtime
        self.window = window
        self.updates = updates
        self.integration = integration
    }

    /// Builds the document a generator writes for a `local` wrapper
    /// (wrapper-json.md §2.5).
    public static func generated(
        configuration: WrapperConfiguration,
        displayName: String,
        build: LauncherBuild
    ) -> WrapperDocument {
        WrapperDocument(
            kind: configuration.kind,
            application: Application(
                packageId: configuration.packageID.rawValue,
                displayName: displayName
            ),
            runtime: Runtime(
                minimumVersion: build.minimumRuntimeVersion,
                launcherAPI: build.launcherAPI
            ),
            window: Window(
                mode: configuration.window.mode,
                defaultWidth: configuration.window.defaultWidth,
                defaultHeight: configuration.window.defaultHeight,
                resizable: configuration.window.resizable
            ),
            updates: WrapperDocument.Updates(
                authority: configuration.updates.authority,
                mode: configuration.updates.mode,
                provider: configuration.updates.provider
            ),
            integration: Integration(
                clipboard: configuration.integrations.clipboard,
                notifications: configuration.integrations.notifications,
                links: configuration.integrations.links,
                files: configuration.integrations.files,
                sharedFolders: configuration.integrations.sharedFolders,
                microphone: configuration.integrations.microphone
            )
        )
    }
}

/// Encodes and decodes `wrapper.json` byte-for-byte deterministically
/// (wrapper.md §3): UTF-8, sorted keys, pretty printed, unescaped slashes,
/// trailing newline.
public enum WrapperDocumentCodec {
    /// The largest accepted file size (wrapper-json.md §5.1).
    public static let maximumBytes = 65_536

    /// Encodes a document to its canonical bytes.
    public static func encode(_ document: WrapperDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var data = try encoder.encode(document)
        data.append(0x0A)
        return data
    }

    /// Decodes canonical document bytes.
    public static func decode(_ data: Data) throws -> WrapperDocument {
        guard data.count <= maximumBytes else {
            throw WrapperFailure.verificationFailed("wrapper.json is larger than 64 KiB")
        }
        return try JSONDecoder().decode(WrapperDocument.self, from: data)
    }

    /// Reads and decodes the `wrapper.json` of a bundle.
    public static func load(from bundleURL: URL) throws -> WrapperDocument {
        let url =
            bundleURL
            .appendingPathComponent("Contents/Resources/wrapper.json")
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try decode(data)
    }
}
