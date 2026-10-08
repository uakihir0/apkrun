import Foundation
import Virtualization

/// Creates stable-format machine identifiers and locally administered MAC addresses.
public enum MachineIdentity {
    /// Generates the serialized identity used by `VZGenericPlatformConfiguration`.
    public static func newMachineIdentifier() -> Data {
        VMQueue().performSynchronously {
            VZGenericMachineIdentifier().dataRepresentation
        }
    }

    /// Generates a valid locally administered unicast MAC address.
    public static func newMACAddress() -> String {
        VMQueue().performSynchronously {
            VZMACAddress.randomLocallyAdministered().string
        }
    }
}
