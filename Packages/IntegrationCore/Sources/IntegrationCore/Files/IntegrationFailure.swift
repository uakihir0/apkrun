import DiagnosticsCore
import Foundation

/// The reason a user-selected shared folder cannot be used.
public enum FolderProblem: String, Equatable, Sendable {
    /// The folder no longer exists.
    case missing

    /// macOS denied access to the folder.
    case privacyDenied

    /// The folder's volume is not mounted or available.
    case offline
}

/// The reason an Android shared-folder path is refused.
public enum PathProblem: String, Equatable, Sendable {
    /// The path is absolute, traverses above the root, or contains an invalid component.
    case outsideRoot

    /// The path contains a hidden item or a package bundle.
    case hidden

    /// The target is not a regular file or directory.
    case notRegularFile
}

/// The reason an explicitly selected Mac folder is refused as a shared root.
public enum FolderRefusal: String, Equatable, Sendable {
    /// The selected directory is the root of a mounted volume.
    case volumeRoot
    /// The selected directory is the user's home folder.
    case homeFolder
    /// The selected directory is inside the user's Library folder.
    case insideLibrary
    /// The selected directory or one of its ancestors is hidden.
    case hidden
    /// The maximum number of user-selected roots is already configured.
    case limitReached
}

/// A file integration operation could not proceed.
public enum IntegrationFailure: APKRunError, Equatable {
    /// A file import operation must contain at least one item.
    case emptyFileSet

    /// The package has disabled Mac-to-Android file integration.
    case filesDisabled

    /// File-sharing preferences could not be read safely.
    case settingsUnreadable

    /// The XPC file handle is invalid or does not name a regular file.
    case invalidFileHandle

    /// The file metadata does not match the file handle.
    case invalidMetadata

    /// A file drop exceeded its item-count limit.
    case tooManyFiles(count: Int, limit: Int)

    /// One dropped file or the total drop exceeded its byte limit.
    case fileTooLarge(name: String, bytes: UInt64)

    /// A file transfer did not complete or failed integrity validation.
    case transferFailed

    /// A shared folder cannot currently be opened.
    case folderUnavailable(FolderProblem, name: String)
    /// A user-selected folder is not eligible to share.
    case folderRefused(FolderRefusal, name: String)

    /// An Android shared-folder request named a disallowed path or item.
    case pathRejected(PathProblem)

    /// The package does not have access to the requested shared folder.
    case packageAccessDenied

    /// The package or root is read-only.
    case readOnly

    /// A shared-folder handle or request limit was reached.
    case resourceExhausted

    /// The requested shared-folder item does not exist.
    case itemNotFound

    /// A shared-folder range or pagination token is malformed or exceeds its limit.
    case invalidRequest

    /// A configured shared-folder root has an invalid or duplicate identifier.
    case invalidRootConfiguration

    /// The stable error-code namespace owned by IntegrationCore.
    public static let domain: ErrorDomain = .integration

    /// The stable catalog code for this failure.
    public var code: String {
        switch self {
        case .emptyFileSet:
            "emptyFileSet"
        case .filesDisabled:
            "filesDisabled"
        case .settingsUnreadable:
            "settingsUnreadable"
        case .invalidFileHandle:
            "invalidFileHandle"
        case .invalidMetadata:
            "invalidMetadata"
        case .tooManyFiles:
            "tooManyFiles"
        case .fileTooLarge:
            "fileTooLarge"
        case .transferFailed:
            "transferFailed"
        case .folderUnavailable:
            "folderUnavailable"
        case .folderRefused:
            "folderRefused"
        case .pathRejected:
            "pathRejected"
        case .packageAccessDenied:
            "packageAccessDenied"
        case .readOnly:
            "readOnly"
        case .resourceExhausted:
            "resourceExhausted"
        case .itemNotFound:
            "itemNotFound"
        case .invalidRequest:
            "invalidRequest"
        case .invalidRootConfiguration:
            "invalidRootConfiguration"
        }
    }

    /// Safe catalog parameters. File names are reduced to their final path component.
    public var parameters: [String: ErrorParameter] {
        switch self {
        case .emptyFileSet, .filesDisabled, .settingsUnreadable, .invalidFileHandle, .invalidMetadata, .transferFailed,
            .packageAccessDenied, .readOnly,
            .resourceExhausted, .itemNotFound, .invalidRequest, .invalidRootConfiguration:
            [:]
        case .tooManyFiles(let count, let limit):
            ["count": .count(count), "limit": .count(limit)]
        case .fileTooLarge(let name, let bytes):
            ["file": .fileName(URL(fileURLWithPath: name).lastPathComponent), "bytes": .bytes(Int64(clamping: bytes))]
        case .folderUnavailable(let problem, let name):
            [
                "file": .fileName(URL(fileURLWithPath: name).lastPathComponent),
                "reason": .text(problem.rawValue),
            ]
        case .folderRefused(let reason, let name):
            [
                "file": .fileName(URL(fileURLWithPath: name).lastPathComponent),
                "reason": .text(reason.rawValue),
            ]
        case .pathRejected(let problem):
            ["reason": .text(problem.rawValue)]
        }
    }
}
