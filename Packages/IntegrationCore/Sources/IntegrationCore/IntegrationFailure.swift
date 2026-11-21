import Foundation
import RuntimeAPI

/// The `integration` error domain of error-catalog.md §13.
public enum IntegrationFailure: Error, Sendable, Equatable {
    /// `IntegrationPolicy` denied the request (§13.1).
    case disabled(IntegrationKind, IntegrationDenial)
    /// The running image lacks the capability the operation needs (§13.1).
    case notSupportedOnImage(capability: String)
    /// The Guest Agent is not connected (§13.1).
    case guestUnavailable
    /// A clip above its size limit; long text is truncated instead (§13.2).
    case clipboardTooLarge(bytes: Int64, limit: Int64)
    /// The link prompt got no answer in 60 s, or names an unknown prompt (§13.1).
    case promptTimedOut
    /// A link was dropped (§13.2); logged and counted, never shown.
    case linkRejected(reason: LinkRejection)
    /// A drop of more than 20 files (§6.2, §13.2).
    case tooManyFiles(count: Int, limit: Int)
    /// A dropped file above 2 GiB, or a drop above 4 GiB in total (§6.2).
    case fileTooLarge(name: String, bytes: Int64)
    /// A bulk transfer aborted, its SHA-256 mismatched, or the file system
    /// failed; any partial file is deleted (§6.2, §6.3).
    case transferFailed(detail: String)
    /// A shared-folder root can't be used (§6.4, §13.3).
    case folderUnavailable(problem: FolderProblem)
    /// An Android request named a path that isn't shared (§6.4 rules 2–3);
    /// answered with PERMISSION_DENIED and logged, never shown.
    case pathRejected(problem: PathProblem)
    /// `addSharedFolder` named a folder that can't be shared (§6.4).
    case folderRefused(reason: FolderRefusal)
    /// A write, create, delete, or rename in a read-only root, or with
    /// read-only package access (§6.4).
    case readOnly
}

/// Why a shared-folder root can't be used (desktop-integration.md §6.4).
public enum FolderProblem: String, Sendable, Equatable {
    /// The folder no longer exists.
    case missing
    /// macOS privacy controls deny access.
    case privacyDenied
    /// The volume is not mounted.
    case offline
}

/// Why an Android file request was refused (desktop-integration.md §6.4).
public enum PathProblem: String, Sendable, Equatable {
    /// The path escapes the root (`..` or absolute).
    case outsideRoot
    /// The path names a hidden item or a package that looks like one file.
    case hidden
    /// The path names a symlink, device, socket, or other non-regular entry.
    case notRegularFile
}

/// Why `addSharedFolder` refused a folder (desktop-integration.md §6.4).
public enum FolderRefusal: String, Sendable, Equatable {
    /// The folder is the root of a volume.
    case volumeRoot
    /// The folder is the home folder.
    case homeFolder
    /// The folder is `~/Library` or inside it.
    case insideLibrary
    /// The folder, or a folder that contains it, is hidden.
    case hidden
    /// 32 folders are already added.
    case limitReached
}

/// Why LinkForwarder dropped a link (desktop-integration.md §7.2).
public enum LinkRejection: String, Sendable, Equatable {
    /// The scheme is not http, https, or mailto, or an http(s) link has no host.
    case scheme
    /// Longer than 8 KiB.
    case tooLong
    /// The window is not key and had no input in the last 5 s.
    case notFocused
    /// More than 3 links in 10 s.
    case rateLimited
}
