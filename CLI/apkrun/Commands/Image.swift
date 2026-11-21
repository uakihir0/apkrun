import ArgumentParser
import Foundation
import RuntimeAPI
import RuntimeClient

/// `apkrun image`, the Android-image management commands
/// (runtime-maintenance.md §4.7–§4.8).
struct ImageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "image",
        abstract: "Manage Android images and image updates.",
        subcommands: [
            ImageListCommand.self,
            ImageCheckCommand.self,
            ImageInstallCommand.self,
            ImageApplyCommand.self,
            ImageRollbackCommand.self,
            ImageRecoveryPointsCommand.self,
        ]
    )
}

/// `apkrun image list [--json]`: current, previous, and candidate images plus
/// the update phase and the recovery points.
struct ImageListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Show the Android images and the update state."
    )

    @Flag(name: .long, help: "Print the result as JSON.")
    var json = false

    mutating func run() async throws {
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let status = try await client.imageStatus()
            if json {
                try PackageQueryOutput.writeJSON(status)
                return
            }
            Output.write("Current:  \(status.current ?? "none")")
            Output.write("Previous: \(status.previous ?? "none")")
            Output.write("State:    \(status.phase)")
            if let last = status.lastResult {
                Output.write("Last:     \(last)")
            }
            for rejected in status.rejected {
                Output.write(
                    "Rejected: \(rejected.version) (\(rejected.reason), \(rejected.at))"
                )
            }
            for point in status.recoveryPoints {
                Output.write(
                    "Recovery: \(point.name)\(point.isFailedDump ? " (failed)" : "")"
                )
            }
        } catch let failure as RuntimeWireError {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

/// `apkrun image check`: a user-initiated feed check (§4.2): fetch the feed,
/// pick a candidate through C1–C7, and download and install it.
struct ImageCheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Check the image feed for an update now."
    )

    mutating func run() async throws {
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let result = try await client.imageFeedAction("check")
            Output.write(result)
        } catch let failure as RuntimeWireError {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

/// `apkrun image install <file.aar> [--yes]`: installs an `.aar` beside the
/// current image as a `ready` candidate (§4.7). The user's file is only read;
/// it is never moved or deleted.
struct ImageInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install an Android image from an .aar file."
    )

    @Argument(help: "The .aar file to install.")
    var file: String?

    @Flag(name: .long, help: "Download and install the newest image the feed offers.")
    var latest = false

    @Flag(name: .long, help: "Skip the confirmation prompt.")
    var yes = false

    mutating func run() async throws {
        if latest {
            guard file == nil else {
                throw ValidationError("Pass either a file or --latest, not both.")
            }
            do {
                let client = try RuntimeControlClient(clientKind: .cli)
                let result = try await client.imageFeedAction("install-latest")
                Output.write(result)
            } catch let failure as RuntimeWireError {
                throw failure
            } catch {
                throw await RuntimeStatusOutput.commandFailure(error)
            }
            return
        }
        guard let file else {
            throw ValidationError("Pass an .aar file or --latest.")
        }
        let url = URL(fileURLWithPath: file)
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let client = try RuntimeControlClient(clientKind: .cli)
            let version = try await client.installImage(file: handle, assumeYes: yes)
            Output.write("Installed image \(version). It is ready to apply.")
        } catch let failure as RuntimeWireError {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

/// `apkrun image apply <version>`: migrates to a `ready` image (§4.3).
struct ImageApplyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Apply a ready Android image."
    )

    @Argument(help: "The image version to apply, from `apkrun image list`.")
    var version: String

    mutating func run() async throws {
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            try await client.applyImage(version: version)
            Output.write("Image \(version) applied.")
        } catch let failure as RuntimeWireError {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

/// `apkrun image rollback`: returns to the previous image (§4.8).
struct ImageRollbackCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rollback",
        abstract: "Roll back to the previous Android image."
    )

    mutating func run() async throws {
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let result = try await client.rollbackImage()
            Output.write(result)
        } catch let failure as RuntimeWireError {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

/// `apkrun image recovery-points`, the recovery-point commands (§12.3).
struct ImageRecoveryPointsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recovery-points",
        abstract: "List and delete image recovery points.",
        subcommands: [
            ImageRecoveryPointsListCommand.self,
            ImageRecoveryPointsDeleteCommand.self,
        ]
    )
}

struct ImageRecoveryPointsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the image recovery points."
    )

    @Flag(name: .long, help: "Print the result as JSON.")
    var json = false

    mutating func run() async throws {
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let status = try await client.imageStatus()
            if json {
                try PackageQueryOutput.writeJSON(status.recoveryPoints)
                return
            }
            if status.recoveryPoints.isEmpty {
                Output.write("No recovery points.")
            }
            for point in status.recoveryPoints {
                let image = point.imageVersion ?? "unknown image"
                let kind = point.isFailedDump ? "failed" : "rollback"
                Output.write("\(point.name)  \(kind)  \(image)  \(point.createdAt)")
            }
        } catch let failure as RuntimeWireError {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

struct ImageRecoveryPointsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a recovery point."
    )

    @Argument(help: "The recovery-point name.")
    var name: String

    mutating func run() async throws {
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            try await client.deleteImageRecoveryPoint(name: name)
            Output.write("Deleted \(name).")
        } catch let failure as RuntimeWireError {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}
