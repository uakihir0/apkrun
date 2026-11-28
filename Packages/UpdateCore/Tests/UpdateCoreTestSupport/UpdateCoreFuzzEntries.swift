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

    /// `fdroid-index`: the streaming index decoder (64 MiB budget) and the
    /// signed `entry.jar` parser — the spec covers both under the one target
    /// (M12-v1-release.md #92 step 3). `entryJSON` reads a file, so the input
    /// lands in a fixed temporary path; libFuzzer is single-threaded.
    package static func fdroidIndex(_ bytes: UnsafeBufferPointer<UInt8>) {

        _ = try? FDroidIndexReader().packages(
            in: Data(bytes), keep: Set([PackageID(rawValue: "com.example")].compactMap { $0 }))
        let jar = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apkrun-fuzz-entry.jar")
        try? Data(bytes).write(to: jar)
        _ = try? FDroidIndexVerifier.entryJSON(
            in: jar,
            // The fingerprint never matches fuzzed input; the ZIP, manifest,
            // and signature-block parsing ahead of the signature comparison is
            // the untrusted-input surface under test.
            fingerprint: SHA256Digest(
                hex: "867322208466d85ddf20f8bd8a946a7f39fc84754cf801ff92ecdd18457f695a")!)
    }

    /// `github-releases`: the release listing decoder (4 MiB budget).
    package static func githubReleases(_ bytes: UnsafeBufferPointer<UInt8>) {
        let data = Data(bytes)
        guard data.count <= 4_194_304 else { return }
        _ = try? GitHubProvider.decodeReleasesForFuzzing(data)
    }
}
