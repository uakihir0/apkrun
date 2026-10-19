import ArgumentParser
import DiagnosticsCore
import Foundation
import RuntimeAPI
import RuntimeClient

struct LaunchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch",
        abstract: "Launch an installed Android app."
    )

    @Argument(help: "The Android package name.")
    var package: String

    @Flag(name: .long, help: "Print the result as JSON.")
    var json = false

    mutating func run() async throws {
        guard let packageID = RuntimePackageID(rawValue: package) else {
            throw CLIFailure.invalidPackageName(package: package)
        }

        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let result = try await client.launch(RuntimeLaunchRequest(packageID: packageID))
            guard result.state == .running else {
                throw RuntimeWireError(
                    domain: "runtime",
                    code: "runtime.launchFailed",
                    message: "Android didn't reach the running state for \(packageID.rawValue).",
                    remediation: "Try again. If it happens again, restart Android."
                )
            }
            if json {
                Output.write(try SessionCommandOutput.json(result))
            } else {
                Output.write("Launched \(packageID.rawValue) (\(result.state.rawValue)).")
            }
        } catch let failure as RuntimeWireError {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

struct StopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop an Android app session."
    )

    @Argument(help: "The Android package name.")
    var package: String

    mutating func run() async throws {
        guard let packageID = RuntimePackageID(rawValue: package) else {
            throw CLIFailure.invalidPackageName(package: package)
        }

        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let result = try await client.terminate(RuntimeTerminateRequest(packageID: packageID))
            Output.write(
                result.hadSession
                    ? "Stopped \(packageID.rawValue)."
                    : "No active session for \(packageID.rawValue)."
            )
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

enum SessionCommandOutput {
    static func json<Value: Encodable>(_ result: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(SessionCommandEnvelope(result: result))
        return String(decoding: data, as: UTF8.self)
    }
}

private struct SessionCommandEnvelope<Value: Encodable>: Encodable {
    let schemaVersion = 1
    let result: Value
}
