import Foundation

/// The `icon.json` manifest beside a package's rendered icon layers
/// (package-store.md §10.2).
public struct PackageIconManifest: Codable, Equatable, Sendable {
    /// Whether the guest rendered adaptive layers or one legacy bitmap.
    public var kind: StoreIconKind
    /// The pixel size the layers were rendered at.
    public var sizePx: Int
    /// The package version the icon was rendered for.
    public var renderedForVersionCode: VersionCode
    /// SHA-256 of the layer set: role names and payloads in role order.
    public var setDigest: SHA256Digest

    /// Creates a manifest describing a written icon set.
    public init(
        kind: StoreIconKind,
        sizePx: Int,
        renderedForVersionCode: VersionCode,
        setDigest: SHA256Digest
    ) {
        self.kind = kind
        self.sizePx = sizePx
        self.renderedForVersionCode = renderedForVersionCode
        self.setDigest = setDigest
    }
}
