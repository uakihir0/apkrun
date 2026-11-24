import Foundation

/// The layer-2 allowlists of diagnostics.md §6.2: structured sources are
/// copied field by field, never filtered by a blocklist.
public enum DiagnosticsAllowlists {
    /// `true` when the Android property name is on the §6.2 getprop
    /// allowlist. `ro.serialno` and `ro.boot.serialno` are never allowed.
    public static func allowsGetprop(_ name: String) -> Bool {
        if getpropNever.contains(name) {
            return false
        }
        return getpropPrefixes.contains(where: { name.hasPrefix($0) })
            || getpropExact.contains(name)
    }

    /// Filters `getprop` output to one `[name]: [value]` line per
    /// allowlisted name, sorted for a stable diff. Runs on the host as well
    /// as in the agent: guest payloads are untrusted (§6.2, §8.3).
    public static func filterGetprop(_ output: String) -> String {
        let lines =
            output
            .split(separator: "\n")
            .compactMap { raw -> String? in
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("["), line.hasSuffix("]"),
                    let close = line.firstIndex(of: "]"),
                    line[line.index(after: close)...].hasPrefix(": [")
                else { return nil }
                let name = String(line[line.index(after: line.startIndex)..<close])
                return allowsGetprop(name) ? line : nil
            }
            .sorted()
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// Property names that never reach a report, even when a prefix would
    /// match (§6.2; mirrors the guest-side allowlist).
    private static let getpropNever: Set<String> = [
        "ro.serialno",
        "ro.boot.serialno",
        "ro.ril.oem.sno",
        "persist.sys.safemode_reason",
    ]

    private static let getpropPrefixes = [
        "ro.build.version.",
        "ro.product.cpu.abilist",
        "ro.hardware",
        "ro.boot.hardware.",
        "ro.apkrun.",
        "init.svc.",
        "dalvik.vm.heap",
    ]

    private static let getpropExact: Set<String> = [
        "ro.build.fingerprint",
        "ro.build.id",
        "ro.build.type",
        "ro.product.model",
        "ro.product.device",
        "ro.opengles.version",
        "ro.kernel.version",
        "sys.boot_completed",
        "persist.sys.locale",
        "debug.hwui.renderer",
    ]

    /// The package-record keys of §6.2; `packages.json` and `settings.json`
    /// entries keep only these.
    public static let packageRecordKeys: Set<String> = [
        "packageID",
        "label",
        "versionName",
        "versionCode",
        "state",
        "installer",
        "updateOwner",
        "provider",
        "providerType",
        "providerHost",
        "signerDigest",
        "size",
        "splitCount",
        "installedAt",
        "updatedAt",
    ]

    /// Keeps only the allowlisted keys of a decoded package record. A
    /// `signerDigest` value is truncated to 12 hex.
    public static func filterPackageRecord(_ record: [String: Any]) -> [String: Any] {
        var filtered: [String: Any] = [:]
        for (key, value) in record where packageRecordKeys.contains(key) {
            if key == "signerDigest", let digest = value as? String {
                filtered[key] = String(digest.prefix(12))
            } else {
                filtered[key] = value
            }
        }
        return filtered
    }

    /// The global-settings keys copied to `host/config.json` (§6.2;
    /// configuration.md). `sharedFolders.roots` is never copied — only its
    /// count and last components.
    public static let configKeys: Set<String> = [
        "audio.output",
        "developer.enabled",
        "display.maxSessions",
        "graphics.limits.maxBackingEntries",
        "graphics.limits.maxContexts",
        "graphics.limits.maxDimension",
        "graphics.limits.maxResourceMiB",
        "graphics.limits.maxResources",
        "graphics.limits.maxSubmit3DMiB",
        "graphics.limits.totalResourceMemoryMiB",
        "graphics.safeMode",
        "input.escapeKey",
        "input.hover",
        "input.scrollMode",
        "input.secondaryClick",
        "input.sendCommandKey",
        "integrations.defaults.clipboard",
        "integrations.defaults.links",
        "integrations.defaults.microphone",
        "integrations.defaults.sharedFolders",
        "maintenance.channel",
        "maintenance.checkAutomatically",
        "maintenance.downloadImagesAutomatically",
        "maintenance.installAPKRunAutomatically",
        "maintenance.imageChannel",
        "system.syncClockFormat",
        "system.syncLocale",
        "system.syncTimeZone",
        "update.autoRollback",
        "update.healthCheckLaunch",
        "update.mode",
        "updates.checkIntervalHours",
        "updates.downloadOnExpensiveNetwork",
        "updates.notifyInstalled",
        "updates.startRuntimeToInstall",
        "window.alwaysOnTop",
        "window.closeBehavior",
        "window.defaultHeight",
        "window.defaultWidth",
        "window.mode",
        "window.resizable",
        "window.zoom",
        "wrappers.defaultLocation",
    ]

    /// The per-package settings keys copied to `packages/settings.json`.
    public static let packageSettingKeys: Set<String> = [
        "audio.output",
        "display.profile",
        "graphics.safeMode",
        "input.hover",
        "input.scrollMode",
        "input.secondaryClick",
        "input.sendCommandKey",
        "integrations.clipboard",
        "integrations.files",
        "integrations.links",
        "integrations.microphone",
        "integrations.notifications",
        "integrations.sharedFolders",
        "language",
        "update.autoRollback",
        "update.mode",
        "updates.authority",
        "updates.mode",
        "updates.provider",
        "window.alwaysOnTop",
        "window.closeBehavior",
        "window.mode",
        "window.resizable",
        "window.zoom",
    ]

    /// Keeps only the allowlisted keys of a decoded settings object.
    public static func filterSettings(_ settings: [String: Any]) -> [String: Any] {
        settings.filter { configKeys.contains($0.key) || packageSettingKeys.contains($0.key) }
    }

    /// Cuts a unified-log message at the unit separator (§3.2): everything
    /// past U+001F is structure that a report never sees.
    public static func cutAtUnitSeparator(_ text: String) -> String {
        guard let index = text.firstIndex(of: "\u{001F}") else { return text }
        return String(text[..<index])
    }

    /// The bootconfig/instance keys whose values become stable placeholders
    /// (§6.2): `androidboot.serialno` → `<serial-N>`, UUIDs → `<uuid-N>`,
    /// MAC addresses → `<mac-N>` handled by the layer-3 MAC rule.
    public static func redactBootconfig(_ text: String, redactor: Redactor) -> String {
        var result = text
        guard
            let regex = try? NSRegularExpression(
                pattern:
                    #"(androidboot\.serialno|androidboot\.apkrun\.instance_uuid|androidboot\.apkrun\.machine_id)=([^\s]+)"#
            )
        else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: range).reversed() {
            guard
                let whole = Range(match.range, in: text),
                let keyRange = Range(match.range(at: 1), in: text),
                let valueRange = Range(match.range(at: 2), in: text)
            else { continue }
            let key = text[keyRange]
            let value = String(text[valueRange])
            let kind = key.hasSuffix("serialno") ? "serial" : "uuid"
            result.replaceSubrange(whole, with: "\(key)=\(redactor.placeholder(for: value, kind: kind))")
        }
        return result
    }
}
