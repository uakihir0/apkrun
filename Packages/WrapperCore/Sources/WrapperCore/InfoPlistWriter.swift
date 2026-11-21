import Foundation

/// Writes the `Contents/Info.plist` of a wrapper (wrapper.md §2.1). The XML has
/// sorted keys and is byte-for-byte deterministic (wrapper.md §6.5).
public enum InfoPlistWriter {
    /// The wrapper format version written to `APKRunWrapperFormat`.
    public static let wrapperFormat = 1

    /// Returns the deterministic XML bytes of a wrapper's Info.plist.
    public static func plistData(
        bundleID: String,
        fileName: String,
        displayName: String,
        packageID: String,
        category: AndroidAppCategory?,
        kind: WrapperKind,
        build: LauncherBuild
    ) throws -> Data {
        var plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": fileName,
            "CFBundleDisplayName": displayName,
            "CFBundleExecutable": "APKRunLauncher",
            "CFBundlePackageType": "APPL",
            "CFBundleIconFile": "AppIcon",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleDevelopmentRegion": "en",
            "CFBundleLocalizations": ["en"],
            "LSMinimumSystemVersion": "27.0",
            "LSMultipleInstancesProhibited": true,
            "NSHighResolutionCapable": true,
            "NSPrincipalClass": "NSApplication",
            "NSSupportsAutomaticTermination": false,
            "NSSupportsSuddenTermination": false,
            "NSQuitAlwaysKeepsWindows": false,
            "APKRunPackageID": packageID,
            "APKRunWrapperFormat": wrapperFormat,
            "APKRunWrapperKind": kind.rawValue,
            "APKRunLauncherVersion": build.launcherVersion,
            "APKRunLauncherAPI": build.launcherAPI,
        ]
        if let category {
            plist["LSApplicationCategoryType"] = category.lsApplicationCategoryType
        }
        return try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
    }

    /// Reads `CFBundleIdentifier` and `APKRunPackageID` from a bundle's Info.plist.
    public static func identity(of bundleURL: URL) -> (bundleID: String?, packageID: String?)? {
        let url = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(
                from: data, format: nil) as? [String: Any]
        else { return nil }
        return (
            plist["CFBundleIdentifier"] as? String,
            plist["APKRunPackageID"] as? String
        )
    }

    /// Reads the full Info.plist dictionary of a bundle.
    public static func infoDictionary(of bundleURL: URL) -> [String: Any]? {
        let url = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }
}
