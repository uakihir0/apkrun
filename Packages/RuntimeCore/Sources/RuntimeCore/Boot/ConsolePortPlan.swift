import Foundation
import VirtualMachineCore

/// The attachment order of the console ports, corrected to the guest's numbering (vm.md §6.2).
///
/// The port test sends `APKRUN-PORT-<i>` to attachment port `i` and reads each `/dev/hvc<j>`. When the
/// marker of port `i` arrives on `/dev/hvc<j>` with `j != i`, the guest numbers the ports differently
/// from the Cuttlefish map (android-image.md §7.1), and the attachment order must change to match.
/// On VZ the test shows the identity mapping, so the boot path does not apply a reordering.
public enum ConsolePortPlan {
    /// Returns `ports` reordered so that `/dev/hvc<j>` is the port attached at `observedDevice[i] == j`.
    ///
    /// `observedDevice` maps each attachment index to the device number that received its marker. The
    /// mapping must be a permutation of `0..<ports.count`; otherwise the result is nil.
    public static func reordered(
        _ ports: [ConsolePortDefinition],
        observedDevice: [Int: Int]
    ) -> [ConsolePortDefinition]? {
        guard observedDevice.count == ports.count else {
            return nil
        }
        guard Set(observedDevice.values) == Set(0..<ports.count) else {
            return nil
        }
        var ordered = ports
        for (attachmentIndex, device) in observedDevice {
            ordered[device] = ports[attachmentIndex]
        }
        return ordered
    }
}
