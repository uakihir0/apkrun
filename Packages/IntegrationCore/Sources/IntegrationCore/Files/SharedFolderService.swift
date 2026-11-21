import Foundation
import RuntimeAPI
import UniformTypeIdentifiers

#if canImport(Darwin)
    import Darwin
#endif

/// The access a shared-folder root grants, or `integrations.sharedFolders`
/// allows (desktop-integration.md §6.4). `off` is the absence of access.
public enum SharedFolderAccess: String, Sendable, Equatable, Comparable {
    case readOnly
    case readWrite

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs == .readOnly && rhs == .readWrite
    }
}

/// One shared-folder root (§6.4). The built-in Shared folder and every
/// user-added root are stored in `sharedFolders.roots` of the configuration.
public struct SharedFolderRoot: Sendable, Equatable {
    /// The stable document-ID prefix of the root (`<root_id>:<path>`).
    public var rootID: String
    /// The title shown in the Android picker.
    public var title: String
    /// The resolved folder on disk.
    public var url: URL
    /// The most the root ever grants.
    public var maxAccess: SharedFolderAccess

    public init(rootID: String, title: String, url: URL, maxAccess: SharedFolderAccess) {
        self.rootID = rootID
        self.title = title
        self.url = url
        self.maxAccess = maxAccess
    }
}

/// A `RootInfo` row of guest-protocol.md §7.5.
public struct SharedRootInfo: Sendable, Equatable {
    public var rootID: String
    public var title: String
    public var access: SharedFolderAccess
    public var available: Bool
    public var bytesFree: Int64

    public init(
        rootID: String, title: String, access: SharedFolderAccess, available: Bool,
        bytesFree: Int64
    ) {
        self.rootID = rootID
        self.title = title
        self.access = access
        self.available = available
        self.bytesFree = bytesFree
    }
}

/// A `DocInfo` row of guest-protocol.md §7.5.
public struct SharedDocInfo: Sendable, Equatable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var mtimeMilliseconds: Int64
    public var mimeType: String

    public init(
        path: String, name: String, isDirectory: Bool, size: Int64,
        mtimeMilliseconds: Int64, mimeType: String
    ) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.mtimeMilliseconds = mtimeMilliseconds
        self.mimeType = mimeType
    }
}

/// A `HostQueryChildren` page (§7.5).
public struct SharedDocPage: Sendable, Equatable {
    public var entries: [SharedDocInfo]
    public var nextPageToken: String

    public init(entries: [SharedDocInfo], nextPageToken: String) {
        self.entries = entries
        self.nextPageToken = nextPageToken
    }
}

/// The open mode of `HostOpenFile` (§7.5).
public enum SharedOpenMode: Sendable, Equatable {
    case read
    case write
    case readWrite
    case truncate
}

/// The error a guest-facing shared-folder request fails with. `code` becomes
/// the reply's `GuestErrorCode`; `failure` is the catalog error for the log
/// (§6.4, error-catalog.md §13.3). `SharedFolderFailure` is thrown only by
/// ``SharedFolderService``.
public struct SharedFolderFailure: Error, Sendable, Equatable {
    public enum Code: String, Sendable, Equatable {
        case invalidArgument = "INVALID_ARGUMENT"
        case notFound = "NOT_FOUND"
        case permissionDenied = "PERMISSION_DENIED"
        case unavailable = "UNAVAILABLE"
        case resourceExhausted = "RESOURCE_EXHAUSTED"
        case `internal` = "INTERNAL"
    }

    public var code: Code
    public var failure: IntegrationFailure?

    public init(_ code: Code, _ failure: IntegrationFailure? = nil) {
        self.code = code
        self.failure = failure
    }
}

/// The host side of the `files.shared.v1` document provider
/// (desktop-integration.md §6.4, guest-protocol.md §7.5).
///
/// Every request is checked in order: the package's effective access for the
/// root (`min(root.maxAccess, integrations.sharedFolders)`), the path rules
/// (relative, no `..`, no absolute, no hidden components, no `.app`-like
/// packages), then POSIX `openat` from the root's descriptor with `O_NOFOLLOW`
/// per component so a symlink can never leave the root. Only regular files
/// and directories are served; nothing is copied into the guest.
///
/// `com.android.documentsui` may only browse (roots, children, stat): the
/// picker has no package of its own, and contents are served only to the real
/// calling package of `HostOpenFile`.
public actor SharedFolderService {
    /// The package name the Android picker reports while browsing (§6.4).
    public static let documentsUIPackage = "com.android.documentsui"

    /// The browsing-only pseudo-package may list and stat but never open.
    static let browserOnlyPackage = documentsUIPackage

    /// The inputs that change with the configuration; evaluated per request.
    public struct Source: Sendable {
        /// The configured roots (built-in + user-added).
        public var roots: @Sendable () async -> [SharedFolderRoot]
        /// The package's `integrations.sharedFolders` value
        /// (`off` / `readOnly` / `readWrite`).
        public var valueForPackage: @Sendable (RuntimePackageID) async -> String
        /// The shared-folder roots' home (for health), not a root itself.
        public init(
            roots: @escaping @Sendable () async -> [SharedFolderRoot],
            valueForPackage: @escaping @Sendable (RuntimePackageID) async -> String
        ) {
            self.roots = roots
            self.valueForPackage = valueForPackage
        }
    }

    /// One open handle of `HostOpenFile` (§7.5: 64 per package).
    private struct OpenHandle {
        var package: RuntimePackageID
        var rootID: String
        var path: String
        var descriptor: Int32
        var mode: SharedOpenMode
        /// Set when Android wrote bytes; `close` applies quarantine (§6.1).
        var written: Bool = false
    }

    private let source: Source
    private var handles: [UInt64: OpenHandle] = [:]
    private var nextHandle: UInt64 = 1

    /// Operations currently running per package; the transport admits at most
    /// 16 in flight (§7.5), which the dispatcher enforces.
    public init(source: Source) {
        self.source = source
    }

    // MARK: Limits (§6.4, §12.1)

    /// Entries per `HostQueryChildren` page.
    public static let entriesPerPage = 4096
    /// Bytes per `HostReadRange` / `HostWriteRange`.
    public static let rangeLimit = 1_048_576
    /// Open handles per package.
    public static let handlesPerPackage = 64

    // MARK: Roots

    /// `HostListRoots` (§7.5). A package sees only roots it has access to;
    /// the picker pseudo-package sees every root's name and title.
    public func listRoots(package: RuntimePackageID) async throws(SharedFolderFailure)
        -> [SharedRootInfo]
    {
        let browsing = package.rawValue == Self.browserOnlyPackage
        var result: [SharedRootInfo] = []
        for root in await source.roots() {
            let effective: SharedFolderAccess?
            if browsing {
                effective = .readOnly
            } else {
                effective = try await effectiveAccess(package: package, root: root)
            }
            guard let effective else { continue }
            let availability = Self.rootAvailability(root.url)
            result.append(
                SharedRootInfo(
                    rootID: root.rootID,
                    title: root.title,
                    access: effective,
                    available: availability == nil,
                    bytesFree: availability == nil ? Self.bytesFree(root.url) : 0))
        }
        return result
    }

    // MARK: Reading

    /// `HostQueryChildren` (§7.5): one page of a directory, sorted by name.
    /// Hidden entries and `.app`-style packages are never listed (§6.4 rule 3).
    public func queryChildren(
        package: RuntimePackageID,
        rootID: String,
        path: String,
        pageToken: String
    ) async throws(SharedFolderFailure) -> SharedDocPage {
        let (root, _) = try await checkedAccess(package: package, rootID: rootID, write: false)
        let offset = Int(pageToken) ?? 0
        guard pageToken.isEmpty || Int(pageToken) != nil else {
            throw SharedFolderFailure(.invalidArgument)
        }
        var dirFD: Int32 = -1
        defer { if dirFD >= 0 { close(dirFD) } }
        let resolved = try resolve(root: root, path: path, requireDirectory: true)
        dirFD = resolved

        var entries: [SharedDocInfo] = []
        let stream = fdopendir(dirFD)
        guard stream != nil else { throw SharedFolderFailure(.internal, .transferFailed(detail: "fdopendir")) }
        // fdopendir takes ownership on success; re-point dirFD so defer does
        // not close it twice.
        dirFD = -1
        defer { closedir(stream) }
        var index = 0
        let rootPath = root.url.path
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 256) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." || Self.isHiddenOrPackage(name) { continue }
            let childPath = path.isEmpty ? name : path + "/" + name
            let full = rootPath + "/" + childPath
            guard let info = Self.docInfo(path: childPath, name: name, fullPath: full) else {
                continue
            }
            if index >= offset {
                entries.append(info)
                if entries.count == Self.entriesPerPage { break }
            }
            index += 1
        }
        let next = entries.count == Self.entriesPerPage ? String(offset + entries.count) : ""
        return SharedDocPage(entries: entries, nextPageToken: next)
    }

    /// `HostStat` (§7.5): one `DocInfo`, or NOT_FOUND.
    public func stat(
        package: RuntimePackageID,
        rootID: String,
        path: String
    ) async throws(SharedFolderFailure) -> SharedDocInfo {
        let (root, _) = try await checkedAccess(package: package, rootID: rootID, write: false)
        if path.isEmpty {
            return SharedDocInfo(
                path: "", name: root.title, isDirectory: true, size: 0,
                mtimeMilliseconds: 0, mimeType: "")
        }
        let resolved = try resolve(root: root, path: path, requireDirectory: false)
        close(resolved)
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let full = root.url.path + "/" + path
        guard let info = Self.docInfo(path: path, name: name, fullPath: full) else {
            throw SharedFolderFailure(.notFound)
        }
        return info
    }

    // MARK: Open / read / write / close

    /// `HostOpenFile` (§7.5). WRITE-family modes need readWrite access.
    /// Opens only regular files; directories are statted, not opened.
    public func openFile(
        package: RuntimePackageID,
        rootID: String,
        path: String,
        mode: SharedOpenMode
    ) async throws(SharedFolderFailure) -> (handle: UInt64, size: Int64) {
        // The picker pseudo-package never gets contents, even for read
        // (§6.4: contents are served only to the real calling package).
        guard package.rawValue != Self.browserOnlyPackage else {
            throw SharedFolderFailure(
                .permissionDenied, .disabled(.sharedFolders, .packageOff))
        }
        let write = mode != .read
        let (root, _) = try await checkedAccess(
            package: package, rootID: rootID, write: write)
        let openHandles = handles.values.filter { $0.package == package }.count
        guard openHandles < Self.handlesPerPackage else {
            throw SharedFolderFailure(.resourceExhausted)
        }
        let fd = try resolve(
            root: root, path: path, requireDirectory: false,
            flags: Self.flags(for: mode))
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw SharedFolderFailure(.permissionDenied, .pathRejected(problem: .notRegularFile))
        }
        let handle = nextHandle
        nextHandle += 1
        handles[handle] = OpenHandle(
            package: package, rootID: rootID, path: path, descriptor: fd, mode: mode)
        return (handle, Int64(info.st_size))
    }

    /// `HostReadRange` (§7.5): at most 1 MiB per call, shorter at end of file.
    public func readRange(handle: UInt64, offset: Int64, length: Int) async throws(SharedFolderFailure)
        -> Data
    {
        guard let entry = handles[handle] else { throw SharedFolderFailure(.notFound) }
        guard length >= 0, length <= Self.rangeLimit, offset >= 0 else {
            throw SharedFolderFailure(.invalidArgument)
        }
        guard entry.mode != .write else {
            throw SharedFolderFailure(.permissionDenied, .readOnly)
        }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { ptr in
            pread(entry.descriptor, ptr.baseAddress, length, off_t(offset))
        }
        guard read >= 0 else {
            throw SharedFolderFailure(.internal, .transferFailed(detail: "pread failed"))
        }
        return data.prefix(read)
    }

    /// `HostWriteRange` (§7.5). Marks the handle so `closeFile` applies
    /// `com.apple.quarantine` (§6.1).
    public func writeRange(handle: UInt64, offset: Int64, data: Data) async throws(SharedFolderFailure) {
        guard var entry = handles[handle] else { throw SharedFolderFailure(.notFound) }
        guard data.count <= Self.rangeLimit, offset >= 0 else {
            throw SharedFolderFailure(.invalidArgument)
        }
        guard entry.mode != .read else {
            throw SharedFolderFailure(.permissionDenied, .readOnly)
        }
        let written = data.withUnsafeBytes { ptr in
            pwrite(entry.descriptor, ptr.baseAddress, data.count, off_t(offset))
        }
        guard written == data.count else {
            throw SharedFolderFailure(.internal, .transferFailed(detail: "pwrite failed"))
        }
        entry.written = true
        handles[handle] = entry
    }

    /// `HostCloseFile` (§7.5). Android-written files get the quarantine
    /// attribute of §6.1.
    public func closeFile(handle: UInt64, fsync: Bool) async throws(SharedFolderFailure) {
        guard let entry = handles.removeValue(forKey: handle) else {
            throw SharedFolderFailure(.notFound)
        }
        if fsync { Darwin.fsync(entry.descriptor) }
        let fd = entry.descriptor
        if entry.written {
            fsetxattr(
                fd, "com.apple.quarantine", Self.quarantineValue(package: entry.package),
                Self.quarantineValue(package: entry.package).utf8.count, 0, 0)
        }
        close(fd)
    }

    /// Closes every open handle (runtime stop, §6.4).
    public func closeAll() {
        for (_, entry) in handles { close(entry.descriptor) }
        handles.removeAll()
    }

    // MARK: Create / delete / rename

    /// `HostCreateDocument` (§7.5): makes the name unique as Android
    /// providers do (`name`, `name (1)`, … before the extension).
    public func createDocument(
        package: RuntimePackageID,
        rootID: String,
        parentPath: String,
        name: String,
        isDirectory: Bool
    ) async throws(SharedFolderFailure) -> SharedDocInfo {
        let (root, _) = try await checkedAccess(
            package: package, rootID: rootID, write: true)
        guard let clean = Self.sanitizedName(name), !Self.isHiddenOrPackage(clean) else {
            throw SharedFolderFailure(.permissionDenied, .pathRejected(problem: .hidden))
        }
        let parentFD = try resolve(root: root, path: parentPath, requireDirectory: true)
        defer { close(parentFD) }
        var candidate = clean
        var attempt = 0
        while true {
            let childPath =
                parentPath.isEmpty ? candidate : parentPath + "/" + candidate
            let created: Bool
            if isDirectory {
                created = mkdirat(parentFD, candidate, 0o755) == 0
            } else {
                let fd = openat(parentFD, candidate, O_WRONLY | O_CREAT | O_EXCL, 0o644)
                if fd >= 0 { close(fd) }
                created = fd >= 0
            }
            if created {
                let full = root.url.path + "/" + childPath
                if let info = Self.docInfo(path: childPath, name: candidate, fullPath: full) {
                    return info
                }
                throw SharedFolderFailure(.internal, .transferFailed(detail: "stat after create"))
            }
            if errno == EEXIST {
                attempt += 1
                candidate = Self.numberedName(clean, attempt)
                continue
            }
            throw SharedFolderFailure(.internal, .transferFailed(detail: "create failed"))
        }
    }

    /// `HostDeleteDocument` (§7.5): a regular file, or an empty directory.
    public func deleteDocument(
        package: RuntimePackageID,
        rootID: String,
        path: String
    ) async throws(SharedFolderFailure) {
        let (root, _) = try await checkedAccess(
            package: package, rootID: rootID, write: true)
        let resolved = try resolve(root: root, path: path, requireDirectory: false)
        var info = Darwin.stat()
        guard fstat(resolved, &info) == 0 else {
            close(resolved)
            throw SharedFolderFailure(.internal, .transferFailed(detail: "fstat"))
        }
        let isDir = (info.st_mode & S_IFMT) == S_IFDIR
        close(resolved)
        let result = unlinkat(
            AT_FDCWD, root.url.path + "/" + path, isDir ? AT_REMOVEDIR : 0)
        guard result == 0 else {
            if errno == ENOTEMPTY {
                throw SharedFolderFailure(.invalidArgument)
            }
            throw SharedFolderFailure(.internal, .transferFailed(detail: "unlink"))
        }
    }

    /// `HostRenameDocument` (§7.5): same directory, sanitized new name.
    public func renameDocument(
        package: RuntimePackageID,
        rootID: String,
        path: String,
        newName: String
    ) async throws(SharedFolderFailure) -> SharedDocInfo {
        let (root, _) = try await checkedAccess(
            package: package, rootID: rootID, write: true)
        guard let clean = Self.sanitizedName(newName), !Self.isHiddenOrPackage(clean) else {
            throw SharedFolderFailure(.permissionDenied, .pathRejected(problem: .hidden))
        }
        let parentPath = path.split(separator: "/", omittingEmptySubsequences: false)
            .dropLast().joined(separator: "/")
        let parentFD = try resolve(root: root, path: parentPath, requireDirectory: true)
        defer { close(parentFD) }
        let oldName = path.split(separator: "/").last.map(String.init) ?? path
        let oldFD = openat(parentFD, oldName, O_RDONLY | O_NOFOLLOW)
        guard oldFD >= 0 else {
            throw SharedFolderFailure(.notFound)
        }
        close(oldFD)
        let newPath = parentPath.isEmpty ? clean : parentPath + "/" + clean
        guard renameat(parentFD, oldName, parentFD, clean) == 0 else {
            throw SharedFolderFailure(.internal, .transferFailed(detail: "rename"))
        }
        let full = root.url.path + "/" + newPath
        guard let info = Self.docInfo(path: newPath, name: clean, fullPath: full) else {
            throw SharedFolderFailure(.internal, .transferFailed(detail: "stat after rename"))
        }
        return info
    }

    // MARK: Access checking

    /// `min(root.maxAccess, integrations.sharedFolders)` for the package; nil
    /// when the package has no access (§6.4).
    private func effectiveAccess(
        package: RuntimePackageID, root: SharedFolderRoot
    ) async throws(SharedFolderFailure) -> SharedFolderAccess? {
        let value = await source.valueForPackage(package)
        let setting: SharedFolderAccess?
        switch value {
        case "readOnly": setting = .readOnly
        case "readWrite": setting = .readWrite
        default: setting = nil
        }
        guard let setting else { return nil }
        return min(setting, root.maxAccess)
    }

    /// The access check of every request: the pseudo-package may only browse,
    /// others need the effective access for the op's write level (§6.4).
    private func checkedAccess(
        package: RuntimePackageID, rootID: String, write: Bool
    ) async throws(SharedFolderFailure) -> (SharedFolderRoot, SharedFolderAccess) {
        let roots = await source.roots()
        guard let root = roots.first(where: { $0.rootID == rootID }) else {
            throw SharedFolderFailure(.notFound)
        }
        if package.rawValue == Self.browserOnlyPackage {
            guard !write else {
                throw SharedFolderFailure(.permissionDenied, .readOnly)
            }
            return (root, .readOnly)
        }
        guard let effective = try await effectiveAccess(package: package, root: root) else {
            throw SharedFolderFailure(
                .permissionDenied, .disabled(.sharedFolders, .packageOff))
        }
        if write, effective != .readWrite {
            throw SharedFolderFailure(.permissionDenied, .readOnly)
        }
        return (root, effective)
    }

    // MARK: Path confinement (§6.4 rules 2–3)

    /// Resolves `path` inside `root` with `openat` + `O_NOFOLLOW` on every
    /// component, so a symlink cannot leave the root. Returns an open
    /// descriptor to the final component (a directory when
    /// `requireDirectory`).
    private func resolve(
        root: SharedFolderRoot, path: String, requireDirectory: Bool,
        flags: Int32 = O_RDONLY
    ) throws(SharedFolderFailure) -> Int32 {
        if path.hasPrefix("/") || path.contains("//") {
            throw SharedFolderFailure(.permissionDenied, .pathRejected(problem: .outsideRoot))
        }
        let rootFD = open(root.url.path, O_RDONLY | O_DIRECTORY)
        guard rootFD >= 0 else {
            throw SharedFolderFailure(.unavailable, availabilityFailure(for: root.url))
        }
        var fd = rootFD
        var succeeded = false
        defer { if !succeeded, fd >= 0 { close(fd) } }

        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else {
            if requireDirectory {
                succeeded = true
                return fd
            }
            close(fd)
            fd = -1
            throw SharedFolderFailure(.permissionDenied, .pathRejected(problem: .notRegularFile))
        }
        for (index, component) in components.enumerated() {
            let name = String(component)
            if name == ".." || name == "." {
                throw SharedFolderFailure(.permissionDenied, .pathRejected(problem: .outsideRoot))
            }
            if Self.isHiddenOrPackage(name) {
                throw SharedFolderFailure(.permissionDenied, .pathRejected(problem: .hidden))
            }
            let isLast = index == components.count - 1
            var componentFlags: Int32 = O_RDONLY | O_NOFOLLOW
            if !isLast || requireDirectory {
                componentFlags |= O_DIRECTORY
            } else {
                componentFlags = flags | O_NOFOLLOW
            }
            let child = openat(fd, name, componentFlags)
            close(fd)
            fd = -1
            if child < 0 {
                switch errno {
                case ENOENT:
                    throw SharedFolderFailure(.notFound)
                case ELOOP:
                    throw SharedFolderFailure(
                        .permissionDenied, .pathRejected(problem: .notRegularFile))
                case ENOTDIR:
                    throw SharedFolderFailure(
                        .permissionDenied, .pathRejected(problem: .notRegularFile))
                case EACCES, EPERM:
                    throw SharedFolderFailure(
                        .permissionDenied, .folderUnavailable(problem: .privacyDenied))
                default:
                    throw SharedFolderFailure(.internal, .transferFailed(detail: "openat"))
                }
            }
            fd = child
        }
        if requireDirectory {
            var info = Darwin.stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
                throw SharedFolderFailure(.permissionDenied, .pathRejected(problem: .notRegularFile))
            }
        } else {
            var info = Darwin.stat()
            guard fstat(fd, &info) == 0,
                (info.st_mode & S_IFMT) == S_IFREG || (info.st_mode & S_IFMT) == S_IFDIR
            else {
                throw SharedFolderFailure(.permissionDenied, .pathRejected(problem: .notRegularFile))
            }
        }
        succeeded = true
        return fd
    }

    /// `stat` metadata for one child entry; nil for non-regular, non-directory
    /// entries (devices, sockets, fifos, dangling symlinks), which §6.4
    /// filters out. `lstat` is used so symlinks are never followed.
    private static func docInfo(path: String, name: String, fullPath: String) -> SharedDocInfo? {
        var info = Darwin.stat()
        guard lstat(fullPath, &info) == 0 else { return nil }
        let kind = info.st_mode & S_IFMT
        let isDir = kind == S_IFDIR
        guard isDir || kind == S_IFREG else { return nil }
        let mime: String
        if isDir {
            mime = ""
        } else {
            let ext = (name as NSString).pathExtension
            mime =
                UTType(filenameExtension: ext)?.preferredMIMEType
                ?? "application/octet-stream"
        }
        return SharedDocInfo(
            path: path,
            name: name,
            isDirectory: isDir,
            size: Int64(info.st_size),
            mtimeMilliseconds: Int64(info.st_mtimespec.tv_sec) * 1000
                + Int64(info.st_mtimespec.tv_nsec) / 1_000_000,
            mimeType: mime)
    }

    /// Whether a path component is hidden or a file-like package name (§6.4).
    static func isHiddenOrPackage(_ name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        let lower = name.lowercased()
        return lower.hasSuffix(".app") || lower.hasSuffix(".photoslibrary")
    }

    /// The sanitized file name of wrapper.md §4.3 plus the export rule of
    /// §6.3: NFC, no control/format characters, `/` and `:` become `-`,
    /// whitespace collapses, leading `.` removed, cut to 200 UTF-8 bytes.
    /// Returns nil when nothing usable remains.
    public static func sanitizedName(_ raw: String) -> String? {
        var name = raw.precomposedStringWithCanonicalMapping
        name = String(
            name.unicodeScalars.filter { scalar in
                guard
                    CharacterSet.controlCharacters.contains(scalar)
                        || scalar.properties.generalCategory == .format
                else { return true }
                return scalar.value == 0x200D
                    || (0xFE00...0xFE0F).contains(scalar.value)
                    || (0xE0100...0xE01EF).contains(scalar.value)
            }.map(Character.init))
        name = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        name = name.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        while name.hasPrefix(".") { name.removeFirst() }
        name = truncateToUTF8ByteLimit(name, limit: 200)
        return name.isEmpty ? nil : name
    }

    /// `name (n)` before the extension, for unique creates (§7.5).
    private static func numberedName(_ name: String, _ n: Int) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ext.isEmpty ? name : ns.deletingPathExtension
        let numbered = "\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
        return truncateToUTF8ByteLimit(numbered, limit: 200)
    }

    /// Adds the MIME type's extension when the name has none (§6.3).
    public static func nameWithExtension(_ name: String, mimeType: String) -> String {
        let ns = name as NSString
        guard ns.pathExtension.isEmpty,
            let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension
        else { return name }
        return name + "." + ext
    }

    /// The `com.apple.quarantine` value for Android-written files (§6.1):
    /// agent name "‹App› (APKRun)".
    static func quarantineValue(package: RuntimePackageID) -> String {
        "0003;\(String(format: "%llx", Int64(Date().timeIntervalSince1970)));\(package.rawValue) (APKRun);"
    }

    /// `EACCES`-style availability of a root before any request (§6.4, R-22).
    private static func rootAvailability(_ url: URL) -> FolderProblem? {
        if !FileManager.default.fileExists(atPath: url.path) {
            return volumeMounted(url) ? .missing : .offline
        }
        let probe = open(url.path, O_RDONLY | O_DIRECTORY)
        if probe < 0 {
            return (errno == EACCES || errno == EPERM) ? .privacyDenied : .missing
        }
        close(probe)
        return nil
    }

    /// Whether the path's volume is still mounted (for missing vs offline).
    private static func volumeMounted(_ url: URL) -> Bool {
        var info = statfs()
        return statfs(url.path, &info) == 0
    }

    /// The failure a failed root open maps to (§6.4).
    private func availabilityFailure(for url: URL) -> IntegrationFailure {
        switch Self.rootAvailability(url) {
        case .privacyDenied: return .folderUnavailable(problem: .privacyDenied)
        case .offline: return .folderUnavailable(problem: .offline)
        case .missing, nil: return .folderUnavailable(problem: .missing)
        }
    }

    /// Free bytes of the root's volume (for `RootInfo.bytes_free`).
    private static func bytesFree(_ url: URL) -> Int64 {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return 0 }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }

    /// Open flags for a `HostOpenFile` mode (§7.5).
    private static func flags(for mode: SharedOpenMode) -> Int32 {
        switch mode {
        case .read: return O_RDONLY
        case .write: return O_WRONLY
        case .readWrite: return O_RDWR
        case .truncate: return O_RDWR | O_TRUNC
        }
    }
}

/// Cuts `name` to `limit` UTF-8 bytes at a grapheme-cluster boundary
/// (wrapper.md §4.3 step 3), shared with the export sanitizer.
func truncateToUTF8ByteLimit(_ name: String, limit: Int) -> String {
    guard name.utf8.count > limit else { return name }
    var result = ""
    var used = 0
    for cluster in name {
        let bytes = String(cluster).utf8.count
        if used + bytes > limit { break }
        result.append(cluster)
        used += bytes
    }
    return result
}
