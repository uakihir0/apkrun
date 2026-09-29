import Foundation

enum Output {
    static func write(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    static func versionHuman(_ version: VersionInformation) -> String {
        "apkrun \(version.marketingVersion) (\(version.buildNumber))"
    }

    static func versionFlag(_ version: VersionInformation) -> String {
        version.marketingVersion
    }

    static func versionJSON(_ version: VersionInformation) -> String {
        let encodedVersion = encodeJSONString(version.marketingVersion)
        let encodedBuild = encodeJSONString(version.buildNumber)
        return """
        {"schemaVersion":1,"result":{"cli":{"version":\(encodedVersion),"build":\(encodedBuild)}}}
        """
    }

    private static func encodeJSONString(_ value: String) -> String {
        let encoded = try! JSONEncoder().encode(value)
        return String(decoding: encoded, as: UTF8.self)
    }
}
