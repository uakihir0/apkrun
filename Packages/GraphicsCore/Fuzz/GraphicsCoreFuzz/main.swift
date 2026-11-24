import Foundation
import GraphicsCoreTestSupport

// libFuzzer entry: `APKRUN_FUZZ_TARGET` selects the parser under test
// (test-strategy.md §7.2, #92). Everything reachable here is typed-error
// only; a trap is a finding.
let target = ProcessInfo.processInfo.environment["APKRUN_FUZZ_TARGET"] ?? ""

/// libFuzzer's per-input entry point (#92); `APKRUN_FUZZ_TARGET` selects the
/// parser under test. Typed errors are fine — a trap is a finding.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ bytes: UnsafePointer<UInt8>, _ size: Int) -> CInt {
    let input = UnsafeBufferPointer(start: bytes, count: size)
    switch target {
    case "virtio-gpu-request":
        GraphicsCoreFuzzEntries.virtioGPURequest(input)
    case "resource-table":
        GraphicsCoreFuzzEntries.resourceTable(input)
    default:
        break
    }
    return 0
}
