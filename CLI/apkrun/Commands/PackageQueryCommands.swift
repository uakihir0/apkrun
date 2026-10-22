import ArgumentParser
import DiagnosticsCore
import Foundation
import RuntimeAPI
import RuntimeClient

struct ListPackagesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List installed Android apps."
    )

    @Flag(name: .long, help: "Include packages installed outside APKRun that are known to Android.")
    var all = false

    @Flag(name: .long, help: "Print the result as JSON.")
    var json = false

    mutating func run() async throws {
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let result = try await client.listPackages(filter: all ? .all : .managed)

            if json {
                try PackageQueryOutput.writeJSON(result)
            } else {
                if all {
                    switch result.source {
                    case .managedRecords:
                        break
                    case .liveAndroid:
                        Output.write(
                            "Android inventory: live (observed \(PackageQueryOutput.timestamp(result.observedAt)))."
                        )
                    case .cachedAndroid:
                        Output.write(
                            "Android inventory: cached from \(PackageQueryOutput.timestamp(result.observedAt))."
                        )
                    case .noAndroidInventory:
                        Output.write(
                            "No Android inventory is saved yet. Start Android once to discover installed apps."
                        )
                    }
                }
                if result.packages.isEmpty {
                    if !all || result.source != .noAndroidInventory {
                        Output.write("No apps installed.")
                    } else {
                        Output.write("No managed apps are recorded.")
                    }
                } else {
                    for package in result.packages {
                        Output.write(PackageQueryOutput.packageListLine(package))
                    }
                }
            }
        } catch let failure as RuntimeWireError {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

struct PackageInfoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show runtime status or details for one Android app."
    )

    @Argument(help: "The Android package name. Omit it to inspect runtime status.")
    var package: String?

    @Flag(name: .long, help: "Include additional runtime status fields when no package is given.")
    var runtime = false

    @Flag(name: .long, help: "Include the Android display pool snapshot.")
    var displays = false

    @Flag(name: .long, help: "Print the result as JSON.")
    var json = false

    mutating func run() async throws {
        if let package {
            guard !runtime, !displays else {
                throw CLIFailure.invalidArgument(argument: "--runtime/--displays", reason: "runtimeInfoOnly")
            }
            try await showPackageInfo(package)
        } else {
            try await showRuntimeInfo()
        }
    }

    private func showPackageInfo(_ package: String) async throws {
        guard let packageID = RuntimePackageID(rawValue: package) else {
            throw CLIFailure.invalidPackageName(package: package)
        }

        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let details = try await client.packageInfo(packageID: packageID)
            if json {
                try PackageQueryOutput.writeJSON(details)
            } else {
                let summary = details.summary
                Output.write(
                    "\(PackageQueryOutput.safeTerminalText(summary.displayName)) "
                        + "(\(summary.packageID.rawValue))"
                )
                Output.write(
                    "Version: \(summary.versionName.map(PackageQueryOutput.safeTerminalText) ?? "unknown") "
                        + "(\(summary.versionCode.map(String.init) ?? "unknown"))"
                )
                Output.write("State: \(PackageQueryOutput.stateName(summary.state))")
                Output.write("Managed: \(summary.managed ? "yes" : "no")")
                Output.write("Update authority: \(summary.updateAuthority.rawValue)")
                Output.write("Stored APKs: \(details.files.count), \(details.artifactBytes) bytes")
                if let androidDataBytes = details.androidDataBytes {
                    Output.write("Android data: \(androidDataBytes) bytes")
                }
            }
        } catch let failure as RuntimeWireError {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }

    private func showRuntimeInfo() async throws {
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let info = try await client.runtimeInfo(
                RuntimeInfoRequest(resources: runtime, displays: displays)
            )
            let includeRuntimeDetails = runtime || displays
            if json {
                Output.write(
                    try RuntimeInfoOutput.json(
                        info,
                        buildInfo: .current,
                        includeRuntimeDetails: includeRuntimeDetails
                    )
                )
            } else {
                Output.write(
                    RuntimeInfoOutput.human(
                        info,
                        buildInfo: .current,
                        includeRuntimeDetails: includeRuntimeDetails
                    )
                )
            }
        } catch let failure as RuntimeWireError {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

enum PackageQueryOutput {
    static func writeJSON<Value: Encodable>(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(PackageQueryJSONEnvelope(result: value))
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    static func timestamp(_ date: Date?) -> String {
        date.map(ISO8601DateFormatter().string(from:)) ?? "unknown"
    }

    static func stateName(_ state: RuntimePackageState) -> String {
        switch state {
        case .installing: "installing"
        case .installed: "installed"
        case .uninstalling: "uninstalling"
        case .uninstalledKeepingData: "uninstalled, data kept"
        case .broken(let reason): "broken: \(safeTerminalText(reason))"
        case .unknown: "unknown"
        }
    }

    static func safeTerminalText(_ text: String) -> String {
        let replacementCharacter = "\u{FFFD}".unicodeScalars.first
        let sanitized = text.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0x0000...0x001F, 0x007F...0x009F,
                0x061C, 0x200E, 0x200F,
                0x2028, 0x2029,
                0x202A...0x202E, 0x2066...0x2069:
                replacementCharacter ?? scalar
            default:
                scalar
            }
        }
        return String(String.UnicodeScalarView(sanitized))
    }

    static func packageListLine(_ package: RuntimePackageSummary) -> String {
        let ownership = package.managed ? "managed" : "unmanaged"
        return "\(safeTerminalText(package.displayName))\t\(package.packageID.rawValue)"
            + "\t\(package.versionCode.map(String.init) ?? "unknown")\t\(ownership)\t\(stateName(package.state))"
    }
}

enum RuntimeInfoOutput {
    static func json(
        _ info: RuntimeInfo,
        buildInfo: BuildInfo,
        includeRuntimeDetails: Bool
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let status = info.status
        let result = RuntimeInfoResult(
            buildInfo: buildInfo,
            hostState: status.hostState,
            runtimeState: status.runtimeState,
            imageVersion: status.imageVersion,
            runtimeDetails: includeRuntimeDetails ? info : nil
        )
        let data = try encoder.encode(RuntimeInfoEnvelope(result: result))
        return String(decoding: data, as: UTF8.self)
    }

    static func human(
        _ info: RuntimeInfo,
        buildInfo: BuildInfo,
        includeRuntimeDetails: Bool
    ) -> String {
        let status = info.status
        var lines = [
            "APKRun: \(buildInfo.marketingVersion) (\(buildInfo.buildNumber))",
            "Background service: \(PackageQueryOutput.safeTerminalText(status.hostState))",
            "Android: \(PackageQueryOutput.safeTerminalText(status.runtimeState))",
            "Image: \(status.imageVersion.map(PackageQueryOutput.safeTerminalText) ?? "unknown")",
        ]
        guard includeRuntimeDetails else {
            return lines.joined(separator: "\n")
        }

        lines.append("Owner: \(RuntimeStatusOutput.ownerName(for: buildInfo))")
        lines.append("Daemon PID: \(status.daemonPID)")
        lines.append("Guest Agent: \(status.guestAgentState?.rawValue ?? "unknown")")
        if let protocolVersion = status.guestAgentProtocolVersion {
            lines.append("Guest Agent protocol: \(PackageQueryOutput.safeTerminalText(protocolVersion))")
        }
        lines.append(
            "Runtime sizing: \(info.sizing.cpuCount) CPUs, \(info.sizing.memoryGiB) GiB memory, "
                + "\(info.sizing.userdataGiB.map { String($0) } ?? "unavailable") GiB Android storage"
        )
        if let footprint = info.resources?.daemonPhysicalFootprintBytes {
            lines.append("Daemon memory: \(footprint) bytes")
        }
        if let progress = status.bootProgress {
            lines.append("Boot progress: \(Int((progress * 100).rounded()))%")
        }
        if status.crashLoopActive {
            lines.append("Automatic starts are paused after repeated failed starts.")
        }
        if let step = status.startupFailureStep, let code = status.startupFailureCode {
            lines.append("Startup issue: step \(step) (\(PackageQueryOutput.safeTerminalText(code)))")
        }
        if let displays = info.displays {
            lines.append("Displays:")
            for display in displays {
                let mode = display.pixelSize.map { "\($0.width)×\($0.height)" } ?? "no mode"
                lines.append(
                    "  Slot \(display.slot): \(displayStateName(display.state)), \(mode)"
                )
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func displayStateName(_ state: WireDisplayState) -> String {
        switch state {
        case .free: "free"
        case .reserved: "reserved"
        case .attaching: "attaching"
        case .allocated: "allocated"
        case .releasing: "releasing"
        case .faulted(let error): "faulted (\(error.code))"
        case .unknown: "unknown"
        }
    }
}

private struct PackageQueryJSONEnvelope<Value: Encodable>: Encodable {
    let schemaVersion = 1
    let result: Value
}

private struct RuntimeInfoEnvelope: Encodable {
    let schemaVersion = 1
    let result: RuntimeInfoResult
}

private struct RuntimeInfoResult: Encodable {
    let buildInfo: BuildInfo
    let hostState: String
    let runtimeState: String
    let imageVersion: String?
    let runtimeDetails: RuntimeInfo?
}
