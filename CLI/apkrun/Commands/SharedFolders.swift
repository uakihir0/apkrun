import ArgumentParser
import Foundation
import RuntimeAPI
import RuntimeClient

/// `apkrun shared-folders`, the shared-folder management commands
/// (runtime-api.md §11.1, desktop-integration.md §6.4).
struct SharedFoldersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shared-folders",
        abstract: "List, add, and remove folders shared with Android apps.",
        subcommands: [
            SharedFoldersListCommand.self,
            SharedFoldersAddCommand.self,
            SharedFoldersRemoveCommand.self,
        ]
    )
}

/// `apkrun shared-folders list [--json]`: every shared root with its access
/// and availability.
struct SharedFoldersListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the folders shared with Android apps."
    )

    @Flag(name: .long, help: "Print the result as JSON.")
    var json = false

    mutating func run() async throws {
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let folders = try await client.sharedFolders()
            if json {
                try PackageQueryOutput.writeJSON(folders)
            } else {
                if folders.isEmpty {
                    Output.write("No shared folders.")
                }
                for folder in folders {
                    Output.write(SharedFoldersOutput.line(folder))
                }
            }
        } catch let failure as RuntimeWireError {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

/// `apkrun shared-folders add <path> [--read-write]`: adds a folder the picked
/// Android apps may browse through the Files integration. The built-in Shared
/// folder always exists and cannot be added.
struct SharedFoldersAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Share a Mac folder with Android apps."
    )

    @Argument(help: "The path of the folder to share.")
    var path: String

    @Flag(name: .long, help: "Allow apps to write to the folder, not only read it.")
    var readWrite = false

    @Flag(name: .long, help: "Print the result as JSON.")
    var json = false

    mutating func run() async throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw CLIFailure.invalidArgument(
                argument: "path", reason: "\(path) is not an existing folder")
        }
        let bookmark: Data
        do {
            bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil)
        } catch {
            throw CLIFailure.invalidArgument(
                argument: "path", reason: "could not bookmark \(path): \(error.localizedDescription)")
        }
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let folder = try await client.addSharedFolder(
                bookmark: bookmark, access: readWrite ? "readWrite" : "readOnly")
            if json {
                try PackageQueryOutput.writeJSON(folder)
            } else {
                Output.write("Added \(SharedFoldersOutput.line(folder))")
            }
        } catch let failure as RuntimeWireError {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

/// `apkrun shared-folders remove <path|id>`: stops sharing a folder. The
/// built-in `shared` root is refused by the daemon.
struct SharedFoldersRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Stop sharing a folder with Android apps."
    )

    @Argument(help: "The shared folder's path or id.")
    var folder: String

    mutating func run() async throws {
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            var id = folder
            if folder.contains("/") || folder.hasPrefix("~") {
                // A path: resolve it to the folder id the daemon assigned.
                let wanted =
                    URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
                    .standardizedFileURL.path
                let folders = try await client.sharedFolders()
                guard
                    let match = folders.first(where: {
                        URL(fileURLWithPath: $0.path).standardizedFileURL.path == wanted
                    })
                else {
                    throw CLIFailure.invalidArgument(
                        argument: "folder", reason: "\(folder) is not a shared folder")
                }
                id = match.id
            }
            try await client.removeSharedFolder(id: id)
            Output.write("Removed \(folder).")
        } catch let failure as RuntimeWireError {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

/// The terminal form of one shared folder line.
enum SharedFoldersOutput {
    /// "shared — Shared — ~/Library/…/Shared — readOnly — built-in — available"
    static func line(_ folder: SharedFolder) -> String {
        var parts = [folder.id, folder.name, folder.path, folder.access]
        if folder.builtIn {
            parts.append("built-in")
        }
        parts.append(folder.availability)
        return parts.joined(separator: " — ")
    }
}
