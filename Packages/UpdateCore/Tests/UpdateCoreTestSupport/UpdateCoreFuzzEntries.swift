import APKStoreCore
import Foundation

@testable import UpdateCore

/// libFuzzer entry points of UpdateCore (test-strategy.md §7.2, #92).
/// Every parser enforces its §12 size limit before decoding.
package enum UpdateCoreFuzzEntries {
    /// `direct-manifest`: the `direct:` manifest (1 MiB budget).
    package static func directManifest(_ bytes: UnsafeBufferPointer<UInt8>) {
        let data = Data(bytes)
        guard data.count <= 1_048_576 else { return }
        _ = try? JSONDecoder().decode(DirectManifest.self, from: data)
    }

    /// `fdroid-index`: the streaming index decoder (64 MiB budget).
    package static func fdroidIndex(_ bytes: UnsafeBufferPointer<UInt8>) {
        _ = try? FDroidIndexReader().packages(
            in: Data(bytes), keep: Set([PackageID(rawValue: "com.example")].compactMap { $0 }))
    }

    /// `github-releases`: the release listing decoder (4 MiB budget).
    package static func githubReleases(_ bytes: UnsafeBufferPointer<UInt8>) {
        let data = Data(bytes)
        guard data.count <= 4_194_304 else { return }
        _ = try? GitHubProvider.decodeReleasesForFuzzing(data)
    }
}
