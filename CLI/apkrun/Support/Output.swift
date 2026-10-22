import DiagnosticsCore
import Foundation

struct VersionRuntimeDetails: Equatable, Sendable {
    let daemonVersion: String
    let daemonBuild: Int
    let imageVersion: String?
}

enum Output {
    static func write(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    static func writeLogLine(_ text: String, toStandardError: Bool = false) {
        let handle = toStandardError ? FileHandle.standardError : FileHandle.standardOutput
        handle.write(Data((text + "\n").utf8))
    }

    static func versionHuman(
        _ version: BuildInfo,
        runtimeDetails: VersionRuntimeDetails? = nil
    ) -> String {
        let cliVersion = "apkrun \(version.marketingVersion) (\(version.buildNumber))"
        guard let runtimeDetails else { return cliVersion }
        return [
            cliVersion,
            "Daemon: \(runtimeDetails.daemonVersion) (\(runtimeDetails.daemonBuild))",
            "Android image: \(runtimeDetails.imageVersion ?? "unknown")",
        ].joined(separator: "\n")
    }

    static func versionFlag(_ version: BuildInfo) -> String {
        version.marketingVersion
    }

    static func versionJSON(
        _ version: BuildInfo,
        runtimeDetails: VersionRuntimeDetails? = nil
    ) -> String {
        let encodedVersion = encodeJSONString(version.marketingVersion)
        let encodedBuild = encodeJSONString(version.buildNumber)
        let encodedIdentity = encodeJSONString(version.buildIdentity)
        let encodedCommit = encodeJSONString(version.gitCommit)
        let encodedConfiguration = encodeJSONString(version.configuration.rawValue)
        let cliResult =
            #""cli":{"version":\#(encodedVersion),"build":\#(encodedBuild),"buildIdentity":\#(encodedIdentity),"commit":\#(encodedCommit),"configuration":\#(encodedConfiguration),"embeddedRuntime":\#(version.usesEmbeddedRuntime)}"#
        guard let runtimeDetails else {
            return #"{"schemaVersion":1,"result":{\#(cliResult)}}"#
        }
        let daemonVersion = encodeJSONString(runtimeDetails.daemonVersion)
        let imageVersion = runtimeDetails.imageVersion.map(encodeJSONString) ?? "null"
        return """
            {"schemaVersion":1,"result":{\(cliResult),"daemon":{"version":\(daemonVersion),"build":\(runtimeDetails.daemonBuild)},"android":{"imageVersion":\(imageVersion)}}}
            """
    }

    private static func encodeJSONString(_ value: String) -> String {
        guard let encoded = try? JSONEncoder().encode(value) else {
            return "\"\""
        }
        return String(decoding: encoded, as: UTF8.self)
    }
}
