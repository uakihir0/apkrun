import ArgumentParser
import Darwin
import Foundation
import RuntimeAPI
import RuntimeClient

struct SharedFoldersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shared-folders",
        abstract: "List and manage Mac folders shared with Android.",
        subcommands: [
            SharedFoldersListCommand.self,
            SharedFoldersAddCommand.self,
            SharedFoldersRemoveCommand.self,
        ]
    )
}

struct SharedFoldersListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List shared folders and their access status."
    )

    @Flag(name: .long, help: "Print the result as JSON.")
    var json = false

    mutating func run() async throws {
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let folders = try await client.sharedFolders()
            if json {
                Output.write(try SharedFolderCommandOutput.json(folders))
            } else {
                Output.write(SharedFolderCommandOutput.human(folders))
            }
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

struct SharedFoldersAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a Mac folder for Android file access."
    )

    @Argument(help: "The folder to share.")
    var path: String

    @Flag(name: .long, help: "Allow Android apps to create and change files in this folder.")
    var readWrite = false

    mutating func run() async throws {
        let bookmark = try SharedFolderCommandSupport.securityScopedBookmark(for: path)
        let access: SharedFolderAccess = readWrite ? .readWrite : .readOnly

        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let folder = try await client.addSharedFolder(
                AddSharedFolderRequest(bookmark: bookmark, access: access)
            )
            Output.write(SharedFolderCommandOutput.added(folder))
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

struct SharedFoldersRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a shared folder by its path or ID."
    )

    @Argument(
        help: ArgumentHelp(
            "The displayed folder path or its ID.",
            valueName: "path|id"
        )
    )
    var target: String

    mutating func run() async throws {
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let folders = try await client.sharedFolders()
            // RuntimeAPI accepts only opaque IDs; paths are a client-side lookup key.
            let folder = try SharedFolderCommandSupport.folder(
                matching: target,
                in: folders
            )
            _ = try await client.removeSharedFolder(id: folder.id)
            Output.write(SharedFolderCommandOutput.removed(folder))
        } catch let failure as CLIFailure {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

enum SharedFolderCommandSupport {
    static func securityScopedBookmark(for path: String) throws -> Data {
        let url = fileURL(for: path)
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOTDIR {
                throw CLIFailure.invalidArgument(argument: "path", reason: "directoryRequired")
            }
            let problem: FileProblem =
                errno == ENOENT
                ? .notFound
                : .permissionDenied
            throw CLIFailure.fileNotAccessible(file: url.path, problem)
        }
        defer { _ = close(descriptor) }

        do {
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw CLIFailure.fileNotAccessible(file: url.path, .permissionDenied)
        }
    }

    static func folder(matching target: String, in folders: [SharedFolder]) throws -> SharedFolder {
        let idMatches = folders.filter { $0.id == target }
        if idMatches.count == 1 {
            return idMatches[0]
        }
        if idMatches.count > 1 {
            throw CLIFailure.invalidArgument(argument: "path|id", reason: "ambiguous")
        }

        let requestedPath = fileURL(for: target).path
        let pathMatches = folders.filter { fileURL(for: $0.path).path == requestedPath }
        switch pathMatches.count {
        case 1:
            return pathMatches[0]
        case 0:
            throw CLIFailure.invalidArgument(argument: "path|id", reason: "notFound")
        default:
            throw CLIFailure.invalidArgument(argument: "path|id", reason: "ambiguous")
        }
    }

    private static func fileURL(for path: String) -> URL {
        let expandedPath = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expandedPath, isDirectory: true).standardizedFileURL
    }
}

enum SharedFolderCommandOutput {
    static func human(_ folders: [SharedFolder]) -> String {
        guard !folders.isEmpty else {
            return "No shared folders."
        }
        return folders.map { folder in
            let builtInLabel = folder.builtIn ? " (built-in)" : ""
            return "\(safe(folder.name)) [\(safe(folder.id))]\t"
                + "\(accessName(folder.access))\t\(availabilityName(folder.availability))"
                + builtInLabel
        }
        .joined(separator: "\n")
    }

    static func json(_ folders: [SharedFolder]) throws -> String {
        let result = folders.map { folder in
            SharedFolderListEntry(
                id: safe(folder.id),
                name: safe(folder.name),
                access: accessName(folder.access),
                builtIn: folder.builtIn,
                availability: availabilityName(folder.availability)
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(SharedFolderListEnvelope(result: result))
        return String(decoding: data, as: UTF8.self)
    }

    static func added(_ folder: SharedFolder) -> String {
        "Added \(safe(folder.name)) [\(safe(folder.id))] "
            + "(\(accessName(folder.access)), \(availabilityName(folder.availability)))."
    }

    static func removed(_ folder: SharedFolder) -> String {
        "Removed \(safe(folder.name)) [\(safe(folder.id))]."
    }

    private static func safe(_ text: String) -> String {
        PackageQueryOutput.safeTerminalText(text)
    }

    private static func accessName(_ access: SharedFolderAccess) -> String {
        switch access {
        case .readOnly:
            "read-only"
        case .readWrite:
            "read-write"
        }
    }

    private static func availabilityName(_ availability: SharedFolderAvailability) -> String {
        switch availability {
        case .available:
            "available"
        case .missing:
            "missing"
        case .privacyDenied:
            "privacy denied"
        case .offline:
            "offline"
        case .unknown:
            "unknown"
        }
    }
}

private struct SharedFolderListEnvelope: Encodable {
    let schemaVersion = 1
    let result: [SharedFolderListEntry]
}

private struct SharedFolderListEntry: Encodable {
    let id: String
    let name: String
    let access: String
    let builtIn: Bool
    let availability: String
}
