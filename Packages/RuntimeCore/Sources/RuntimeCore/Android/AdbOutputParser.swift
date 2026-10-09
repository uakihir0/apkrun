import Foundation

/// One package of `pm list packages --show-versioncode`.
public struct AdbPackageListing: Equatable, Sendable {
    /// The package name.
    public var name: String
    /// The installed `versionCode`, when `pm` printed one.
    public var versionCode: Int?

    /// Creates a listing.
    public init(name: String, versionCode: Int?) {
        self.name = name
        self.versionCode = versionCode
    }
}

/// The metadata that `dumpsys package` reports for one installed package (#016 step 4).
public struct AdbPackageMetadata: Equatable, Sendable {
    /// The installed `versionCode`.
    public var versionCode: Int
    /// The installed `versionName`.
    public var versionName: String?
    /// The `minSdkVersion` that the package declares.
    public var minSdk: Int?
    /// The `targetSdkVersion` that the package declares.
    public var targetSdk: Int?

    /// Creates the metadata.
    public init(versionCode: Int, versionName: String?, minSdk: Int?, targetSdk: Int?) {
        self.versionCode = versionCode
        self.versionName = versionName
        self.minSdk = minSdk
        self.targetSdk = targetSdk
    }
}

/// Reads the replies of `adb install`, `adb uninstall`, `pm list packages`, and `dumpsys package`.
///
/// The functions are pure: they read the text of a reply and nothing else. The T0 tests run them on
/// replies that were recorded from a real Android 17 guest.
enum AdbOutputParser {
    /// What an install or uninstall reply said.
    enum PackageReply: Equatable {
        case success
        /// `Failure [CODE]`, with the code.
        case failure(reason: String)
        /// Neither `Success` nor `Failure`.
        case unknown
    }

    /// Reads the reply of `adb install` or `adb uninstall`. A success is a `Success` line. adb reports
    /// a rejection as `Failure [CODE]`, sometimes after a prefix such as `adb: failed to install <apk>: `,
    /// so the code is read from anywhere on its line.
    static func packageReply(_ output: String) -> PackageReply {
        for line in lines(output) {
            if line == "Success" {
                return .success
            }
            guard let marker = line.range(of: "Failure ["),
                let close = line[marker.upperBound...].firstIndex(of: "]")
            else {
                continue
            }
            let reason = String(line[marker.upperBound..<close])
            return .failure(reason: reason.isEmpty ? "unknown" : reason)
        }
        return .unknown
    }

    /// Reads `pm list packages --show-versioncode`, where each line is `package:<name> versionCode:<n>`.
    static func packageListings(_ output: String) -> [AdbPackageListing] {
        lines(output).compactMap { line -> AdbPackageListing? in
            guard line.hasPrefix("package:") else {
                return nil
            }
            let fields = line.dropFirst("package:".count).split(separator: " ")
            guard let name = fields.first else {
                return nil
            }
            let versionCode = fields.dropFirst().first { $0.hasPrefix("versionCode:") }
                .flatMap { Int($0.dropFirst("versionCode:".count)) }
            return AdbPackageListing(name: String(name), versionCode: versionCode)
        }
    }

    /// Reads the metadata of `packageName` from `dumpsys package <packageName>`.
    ///
    /// The block starts at `Package [<name>]` and ends at the next `Package [` header. Its first
    /// `versionCode=… minSdk=… targetSdk=…` line and its first `versionName=` line are used.
    /// Returns nil when the block or its `versionCode` is missing.
    static func packageMetadata(_ dump: String, packageName: String) -> AdbPackageMetadata? {
        let all = lines(dump)
        guard
            let start = all.firstIndex(where: {
                $0 == "Package [\(packageName)]" || $0.hasPrefix("Package [\(packageName)] ")
            })
        else {
            return nil
        }
        let block = all[(start + 1)...].prefix { !$0.hasPrefix("Package [") }
        guard let versionLine = block.first(where: { $0.hasPrefix("versionCode=") }) else {
            return nil
        }
        let values = keyValues(versionLine)
        guard let versionCode = values["versionCode"].flatMap(Int.init) else {
            return nil
        }
        let versionName = block.first(where: { $0.hasPrefix("versionName=") })
            .map { String($0.dropFirst("versionName=".count)) }
        return AdbPackageMetadata(
            versionCode: versionCode,
            versionName: versionName,
            minSdk: values["minSdk"].flatMap(Int.init),
            targetSdk: values["targetSdk"].flatMap(Int.init)
        )
    }

    /// The lines of a reply, without carriage returns and without blank lines at either end.
    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The `key=value` tokens of one line, such as `versionCode=1 minSdk=29 targetSdk=37`.
    private static func keyValues(_ line: String) -> [String: String] {
        var values: [String: String] = [:]
        for token in line.split(separator: " ") {
            guard let equals = token.firstIndex(of: "=") else {
                continue
            }
            values[String(token[..<equals])] = String(token[token.index(after: equals)...])
        }
        return values
    }
}
