import APKStoreCoreTestSupport
import Foundation

/// libFuzzer's per-input entry point (#92); `APKRUN_FUZZ_TARGET` selects the
/// parser under test. Typed errors are fine — a trap is a finding.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ bytes: UnsafePointer<UInt8>, _ size: Int) -> CInt {
    let input = UnsafeBufferPointer(start: bytes, count: size)
    switch ProcessInfo.processInfo.environment["APKRUN_FUZZ_TARGET"] ?? "" {
    case "container-reader":
        APKStoreCoreFuzzEntries.containerReader(input)
    case "apk-signing-block":
        APKStoreCoreFuzzEntries.apkSigningBlock(input)
    case "aapt2-badging":
        APKStoreCoreFuzzEntries.aapt2Badging(input)
    default:
        break
    }
    return 0
}
