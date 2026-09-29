import DiagnosticsCore
import Foundation

enum Output {
    static func write(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    static func writeLogLine(_ text: String, toStandardError: Bool = false) {
        let handle = toStandardError ? FileHandle.standardError : FileHandle.standardOutput
        handle.write(Data((text + "\n").utf8))
    }

    static func versionHuman(_ version: BuildInfo) -> String {
        "apkrun \(version.marketingVersion) (\(version.buildNumber))"
    }

    static func versionFlag(_ version: BuildInfo) -> String {
        version.marketingVersion
    }

    static func versionJSON(_ version: BuildInfo) -> String {
        let encodedVersion = encodeJSONString(version.marketingVersion)
        let encodedBuild = encodeJSONString(version.buildNumber)
        let encodedIdentity = encodeJSONString(version.buildIdentity)
        let encodedCommit = encodeJSONString(version.gitCommit)
        let encodedConfiguration = encodeJSONString(version.configuration.rawValue)
        return """
            {"schemaVersion":1,"result":{"cli":{"version":\(encodedVersion),"build":\(encodedBuild),"buildIdentity":\(encodedIdentity),"commit":\(encodedCommit),"configuration":\(encodedConfiguration),"embeddedRuntime":\(version.usesEmbeddedRuntime)}}}
            """
    }

    private static func encodeJSONString(_ value: String) -> String {
        guard let encoded = try? JSONEncoder().encode(value) else {
            return "\"\""
        }
        return String(decoding: encoded, as: UTF8.self)
    }
}
