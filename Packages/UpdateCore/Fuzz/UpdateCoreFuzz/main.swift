import Foundation
import UpdateCoreTestSupport

/// libFuzzer's per-input entry point (#92); `APKRUN_FUZZ_TARGET` selects the
/// parser under test. Typed errors are fine — a trap is a finding.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ bytes: UnsafePointer<UInt8>, _ size: Int) -> CInt {
    let input = UnsafeBufferPointer(start: bytes, count: size)
    switch ProcessInfo.processInfo.environment["APKRUN_FUZZ_TARGET"] ?? "" {
    case "direct-manifest":
        UpdateCoreFuzzEntries.directManifest(input)
    case "fdroid-index":
        UpdateCoreFuzzEntries.fdroidIndex(input)
    case "github-releases":
        UpdateCoreFuzzEntries.githubReleases(input)
    default:
        break
    }
    return 0
}
