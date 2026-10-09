import Foundation

/// The Android settings a fresh instance needs once (android-image.md §7.6).
///
/// Bluetooth has no controller on VZ and Wi-Fi is off on a fresh `/data`, and
/// bootconfig cannot express either. These are the standard Android commands
/// that Cuttlefish's automotive `wifi_on.sh` also runs; Android persists both.
enum FirstBootSettings {
    /// The commands, in order.
    static let commands = [
        "cmd bluetooth_manager disable",
        "cmd wifi set-wifi-enabled enabled",
        "cmd wifi connect-network VirtWifi open",
    ]
}
