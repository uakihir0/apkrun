/// The set of packages allowed to use the microphone
/// (desktop-integration.md §8.2): `integrations.enabled.microphone` gates the
/// kind globally, and only packages whose `integrations.microphone` value is
/// "true" may record. The empty set means the VM boots without an input
/// stream, so the gate cannot be fooled by a recording the gate never saw.
public enum AudioPolicy {
    /// The packages whose microphone access is on. `packageValues` maps a
    /// package ID to its stored `integrations.microphone` value (nil for the
    /// §2.1 default "false"); the global switch comes from `settings.json`.
    public static func enabledPackages(
        packageValues: [String: String?],
        globalEnabled: Bool
    ) -> Set<String> {
        guard globalEnabled else {
            return []
        }
        return Set(
            packageValues.compactMap { packageID, value in
                value == "true" ? packageID : nil
            })
    }
}
