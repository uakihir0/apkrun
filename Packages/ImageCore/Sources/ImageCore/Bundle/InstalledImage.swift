import Foundation

/// A runtime image bundle on disk and its manifest (android-image.md §9.1).
public struct InstalledImage: Equatable, Sendable {
    /// The bundle's version, from its manifest.
    public var version: ImageVersion
    /// The bundle directory, `Images/<version>/` once installed.
    public var root: URL
    /// The decoded `manifest.json`.
    public var manifest: RuntimeImageManifest

    /// Creates an installed image value.
    public init(version: ImageVersion, root: URL, manifest: RuntimeImageManifest) {
        self.version = version
        self.root = root
        self.manifest = manifest
    }

    /// The URL of a bundle-relative path from the manifest.
    public func url(of path: String) -> URL {
        root.appendingPathComponent(path)
    }
}
