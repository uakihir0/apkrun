import Foundation
import GuestProtocolTestSupport

/// libFuzzer's per-input entry point (#92); `APKRUN_FUZZ_TARGET` selects the
/// parser under test. Typed errors are fine — a trap is a finding.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ bytes: UnsafePointer<UInt8>, _ size: Int) -> CInt {
    let input = UnsafeBufferPointer(start: bytes, count: size)
    if ProcessInfo.processInfo.environment["APKRUN_FUZZ_TARGET"]
        == "guest-frame-swift"
    {
        GuestProtocolFuzzEntries.guestFrame(input)
    }
    return 0
}
