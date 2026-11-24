import Darwin
import Foundation
import UniformTypeIdentifiers

/// The package's maximum access to one shared folder.
public enum SharedFolderAccess: Int, Codable, Equatable, Sendable {
    /// The package cannot see the root.
    case off

    /// The package can list and read files.
    case readOnly

    /// The package can list, read, create, modify, delete, and rename files.
    case readWrite
}

/// The context for listing shared-folder metadata.
public enum SharedFolderListingContext: Equatable, Sendable {
    /// Listing for an Android package; only roots granted to this package are returned.
    case package(String)

    /// Listing in Android's document picker; metadata is visible, but file contents remain
    /// package-authorized through the content operations.
    case documentPicker
}

/// A root selected by the user or created by APKRun.
public struct SharedFolderRoot: Equatable, Sendable {
    /// The stable, opaque identifier sent to Android.
    public let id: String

    /// A user-visible name that does not contain the root's full path.
    public let title: String

    /// The directory selected for sharing.
    public let directoryURL: URL

    /// The maximum access allowed by this root's Settings entry.
    public let maximumAccess: SharedFolderAccess

    /// Creates a root definition. The service opens it and retains a directory descriptor.
    public init(id: String, title: String, directoryURL: URL, maximumAccess: SharedFolderAccess) {
        self.id = id
        self.title = title
        self.directoryURL = directoryURL
        self.maximumAccess = maximumAccess
    }
}

/// A root visible to one package.
public struct SharedFolderRootInfo: Equatable, Sendable {
    /// The stable root identifier.
    public let id: String

    /// The display name, without the Mac path.
    public let title: String

    /// The effective access after package and root settings are combined.
    public let access: SharedFolderAccess

    /// Whether the root directory descriptor is currently usable.
    public let isAvailable: Bool
}

/// Metadata for one regular file or directory.
public struct SharedFolderEntry: Equatable, Sendable {
    /// The normalized path relative to its shared root.
    public let path: String

    /// The item's final path component.
    public let name: String

    /// Whether this item is a directory.
    public let isDirectory: Bool

    /// The file size in bytes, or zero for directories.
    public let sizeBytes: UInt64

    /// The modification time as milliseconds since the Unix epoch.
    public let modificationTimeMilliseconds: Int64

    /// The best-effort MIME type based on the file extension.
    public let mimeType: String
}

/// One bounded page of visible directory entries.
public struct SharedFolderPage: Equatable, Sendable {
    /// The visible entries in this page.
    public let entries: [SharedFolderEntry]

    /// An opaque continuation token, or an empty string on the last page.
    public let nextPageToken: String
}

/// The access requested when opening one shared file.
public enum SharedFolderOpenMode: Sendable {
    /// Open the file for reading.
    case read

    /// Open the file for writing without truncating it.
    case write

    /// Open the file for reading and writing.
    case readWrite

    /// Open and truncate the file for writing.
    case truncate

    fileprivate var needsWriteAccess: Bool {
        switch self {
        case .read:
            false
        case .write, .readWrite, .truncate:
            true
        }
    }

    fileprivate var flags: Int32 {
        switch self {
        case .read:
            O_RDONLY
        case .write:
            O_WRONLY
        case .readWrite:
            O_RDWR
        case .truncate:
            O_WRONLY | O_TRUNC
        }
    }
}

/// A host-allocated handle and the initial file size.
public struct SharedFolderOpenFile: Equatable, Sendable {
    /// The handle scoped to its opening package and this runtime.
    public let handle: UInt64

    /// The current file size in bytes.
    public let sizeBytes: UInt64
}

/// Serves user-selected folder roots to Android using descriptor-relative filesystem calls.
///
/// This actor owns the root and open-file descriptors. Filesystem operations run on a private
/// serial queue so file I/O does not block an actor executor. Every guest request must supply its
/// package identity; access is re-evaluated for each operation.
public actor SharedFolderService {
    /// Maximum directory entries returned in one page.
    public static let maximumPageEntries = 4_096

    /// Maximum bytes in one read or write range.
    public static let maximumRangeBytes = 1_048_576

    /// Maximum open handles retained for one package.
    public static let maximumOpenHandlesPerPackage = 64

    /// Maximum filesystem requests concurrently queued or running.
    public static let maximumInFlightRequests = 16

    private struct RootDescriptor: Sendable {
        let definition: SharedFolderRoot
        let fileDescriptor: Int32
        let unavailableProblem: FolderProblem?
    }

    private struct OpenHandle: Sendable {
        let packageID: String
        let rootID: String
        let fileDescriptor: Int32
        let isWritable: Bool
    }

    nonisolated let ioQueue = DispatchQueue(label: "io.apkrun.integration.shared-folders")
    private var roots: [String: RootDescriptor]
    private var packageAccess: [String: [String: SharedFolderAccess]]
    private var handles: [UInt64: OpenHandle] = [:]
    private var reservedHandlesByPackage: [String: Int] = [:]
    private var nextHandle: UInt64 = 1
    private var inFlightRequests = 0
    private var isStopped = false
    private var isReconfiguring = false
    private var inFlightWaiters: [CheckedContinuation<Void, Never>] = []

    var inFlightRequestCount: Int { inFlightRequests }

    /// Opens the configured roots and records their effective package access.
    ///
    /// A missing or privacy-denied root remains visible to its authorized packages as unavailable.
    /// Duplicate or malformed root IDs reject the entire configuration.
    public init(
        roots definitions: [SharedFolderRoot],
        packageAccess: [String: [String: SharedFolderAccess]] = [:]
    ) throws(IntegrationFailure) {
        var rootIDs = Set<String>()
        for definition in definitions {
            guard Self.isValidRootID(definition.id), rootIDs.insert(definition.id).inserted else {
                throw .invalidRootConfiguration
            }
        }

        var descriptors: [String: RootDescriptor] = [:]
        for definition in definitions {
            let opened = definition.directoryURL.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            if opened >= 0 {
                descriptors[definition.id] = RootDescriptor(
                    definition: definition,
                    fileDescriptor: opened,
                    unavailableProblem: nil
                )
            } else {
                descriptors[definition.id] = RootDescriptor(
                    definition: definition,
                    fileDescriptor: -1,
                    unavailableProblem: Self.folderProblem(for: errno)
                )
            }
        }
        self.roots = descriptors
        self.packageAccess = packageAccess
    }

    /// Returns roots visible to the package, with the lower of package and root access applied.
    public func listRoots(packageID: String) async throws(IntegrationFailure) -> [SharedFolderRootInfo] {
        try ensureRunning()
        return roots.values.compactMap { root in
            guard
                let access = Self.effectiveAccess(
                    packageAccess[packageID]?[root.definition.id] ?? .off,
                    rootMaximum: root.definition.maximumAccess
                ), access != .off
            else {
                return nil
            }
            return SharedFolderRootInfo(
                id: root.definition.id,
                title: root.definition.title,
                access: access,
                isAvailable: root.fileDescriptor >= 0
            )
        }
        .sorted { $0.id < $1.id }
    }

    /// Lists metadata for roots in the document picker without exposing file contents.
    ///
    /// Only roots granted to at least one package are included. The access shown is the
    /// greatest effective access among those packages.
    public func listRoots(
        context: SharedFolderListingContext
    ) async throws(IntegrationFailure) -> [SharedFolderRootInfo] {
        try ensureRunning()
        switch context {
        case .package(let packageID):
            return try await listRoots(packageID: packageID)
        case .documentPicker:
            return roots.values.compactMap { root in
                guard
                    let access = Self.maximumPackageAccess(
                        for: root.definition.id,
                        rootMaximum: root.definition.maximumAccess,
                        packageAccess: packageAccess
                    )
                else {
                    return nil
                }
                return SharedFolderRootInfo(
                    id: root.definition.id,
                    title: root.definition.title,
                    access: access,
                    isAvailable: root.fileDescriptor >= 0
                )
            }
            .sorted { $0.id < $1.id }
        }
    }

    /// Replaces all package access after settings or the global shared-folder switch changes.
    ///
    /// Requests already in flight are allowed to finish before changed package handles are
    /// closed. Handles for packages whose effective access changed are invalidated so a
    /// previously granted file descriptor cannot survive revocation or a downgrade.
    public func replacePackageAccess(
        _ newAccess: [String: [String: SharedFolderAccess]]
    ) async throws(IntegrationFailure) {
        try await replacePackageAccess(newAccess, for: nil)
    }

    /// Replaces one package's access without rescanning the other package policies.
    public func replacePackageAccess(
        _ newAccess: [String: SharedFolderAccess],
        for packageID: String
    ) async throws(IntegrationFailure) {
        var updated = packageAccess
        if newAccess.isEmpty {
            updated.removeValue(forKey: packageID)
        } else {
            updated[packageID] = newAccess
        }
        try await replacePackageAccess(updated, for: packageID)
    }

    /// Replaces the roots and package access after shared-folder settings change.
    ///
    /// The service pauses new work, waits for queued filesystem operations to drain, closes all
    /// package handles and previous root descriptors, then publishes the new configuration.
    public func replaceConfiguration(
        roots definitions: [SharedFolderRoot],
        packageAccess newAccess: [String: [String: SharedFolderAccess]]
    ) async throws(IntegrationFailure) {
        try ensureRunning()
        var rootIDs = Set<String>()
        for definition in definitions {
            guard Self.isValidRootID(definition.id), rootIDs.insert(definition.id).inserted else {
                throw .invalidRootConfiguration
            }
        }

        isReconfiguring = true
        defer { isReconfiguring = false }
        while inFlightRequests > 0 {
            await withCheckedContinuation { continuation in
                inFlightWaiters.append(continuation)
            }
        }
        // `runtimeDidStop()` can re-enter this actor while the drain is suspended and mark
        // the service stopped. Do not publish newly opened roots after shutdown has begun.
        guard !isStopped else {
            throw .transferFailed
        }

        var descriptors: [String: RootDescriptor] = [:]
        for definition in definitions {
            let opened = definition.directoryURL.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            if opened >= 0 {
                descriptors[definition.id] = RootDescriptor(
                    definition: definition,
                    fileDescriptor: opened,
                    unavailableProblem: nil
                )
            } else {
                descriptors[definition.id] = RootDescriptor(
                    definition: definition,
                    fileDescriptor: -1,
                    unavailableProblem: Self.folderProblem(for: errno)
                )
            }
        }

        let oldDescriptors =
            handles.values.map(\.fileDescriptor)
            + roots.values.map(\.fileDescriptor).filter { $0 >= 0 }
        handles.removeAll()
        reservedHandlesByPackage.removeAll()
        roots = descriptors
        packageAccess = newAccess
        await withCheckedContinuation { continuation in
            ioQueue.async {
                for descriptor in oldDescriptors {
                    _ = Darwin.close(descriptor)
                }
                continuation.resume()
            }
        }
    }

    /// Reopens any root whose selected path no longer names the directory held by its descriptor.
    ///
    /// This keeps availability and file operations aligned when a folder is removed, replaced, or
    /// restored at the same path. Requests pause while descriptors are checked and swapped.
    public func refreshChangedRootDescriptors() async throws(IntegrationFailure) {
        try ensureRunning()
        isReconfiguring = true
        defer { isReconfiguring = false }
        while inFlightRequests > 0 {
            await withCheckedContinuation { continuation in
                inFlightWaiters.append(continuation)
            }
        }
        guard !isStopped else {
            throw .transferFailed
        }
        inFlightRequests += 1
        defer { finishInFlightRequest() }

        let currentRoots = roots
        let refreshResult: (replacements: [String: RootDescriptor], changedRootIDs: Set<String>) =
            await withCheckedContinuation { continuation in
                ioQueue.async {
                    var replacements: [String: RootDescriptor] = [:]
                    var changedRootIDs = Set<String>()

                    for root in currentRoots.values {
                        let opened = root.definition.directoryURL.path.withCString {
                            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                        }
                        let replacement: RootDescriptor
                        if opened >= 0 {
                            replacement = RootDescriptor(
                                definition: root.definition,
                                fileDescriptor: opened,
                                unavailableProblem: nil
                            )
                        } else {
                            let openError = errno
                            replacement = RootDescriptor(
                                definition: root.definition,
                                fileDescriptor: -1,
                                unavailableProblem: Self.folderProblem(for: openError)
                            )
                        }

                        let matchesCurrentDescriptor: Bool
                        if root.fileDescriptor < 0, replacement.fileDescriptor < 0 {
                            matchesCurrentDescriptor = root.unavailableProblem == replacement.unavailableProblem
                        } else if root.fileDescriptor >= 0, replacement.fileDescriptor >= 0 {
                            matchesCurrentDescriptor = Self.sameDirectory(
                                root.fileDescriptor,
                                replacement.fileDescriptor
                            )
                        } else {
                            matchesCurrentDescriptor = false
                        }

                        if matchesCurrentDescriptor {
                            if replacement.fileDescriptor >= 0 {
                                _ = Darwin.close(replacement.fileDescriptor)
                            }
                        } else {
                            changedRootIDs.insert(root.definition.id)
                            replacements[root.definition.id] = replacement
                        }
                    }

                    continuation.resume(returning: (replacements, changedRootIDs))
                }
            }
        let replacements = refreshResult.replacements
        let changedRootIDs = refreshResult.changedRootIDs
        guard !isStopped else {
            let orphanedDescriptors = replacements.values
                .map(\.fileDescriptor)
                .filter { $0 >= 0 }
            await withCheckedContinuation { continuation in
                ioQueue.async {
                    for descriptor in orphanedDescriptors {
                        _ = Darwin.close(descriptor)
                    }
                    continuation.resume()
                }
            }
            throw .transferFailed
        }
        guard !changedRootIDs.isEmpty else { return }

        let affectedHandles = handles.filter { changedRootIDs.contains($0.value.rootID) }
        let descriptorsToClose =
            affectedHandles.values.map(\.fileDescriptor)
            + changedRootIDs.compactMap { roots[$0]?.fileDescriptor }.filter { $0 >= 0 }
        for handleID in affectedHandles.keys {
            handles[handleID] = nil
        }
        reservedHandlesByPackage.removeAll()
        roots.merge(replacements) { _, replacement in replacement }

        await withCheckedContinuation { continuation in
            ioQueue.async {
                for descriptor in descriptorsToClose {
                    _ = Darwin.close(descriptor)
                }
                continuation.resume()
            }
        }
    }

    /// Closes package file handles when Android stops while retaining configured root descriptors.
    public func closeAllOpenFiles() async {
        guard !isStopped, !isReconfiguring else { return }
        isReconfiguring = true
        defer { isReconfiguring = false }
        while inFlightRequests > 0 {
            await withCheckedContinuation { continuation in
                inFlightWaiters.append(continuation)
            }
        }
        let descriptors = handles.values.map(\.fileDescriptor)
        handles.removeAll()
        reservedHandlesByPackage.removeAll()
        await withCheckedContinuation { continuation in
            ioQueue.async {
                for descriptor in descriptors {
                    _ = Darwin.close(descriptor)
                }
                continuation.resume()
            }
        }
    }

    /// Lists one bounded page of regular files and directories.
    public func queryChildren(
        packageID: String,
        rootID: String,
        path: String,
        pageToken: String = "",
        pageSize: Int = SharedFolderService.maximumPageEntries
    ) async throws(IntegrationFailure) -> SharedFolderPage {
        let root = try authorizedRoot(packageID: packageID, rootID: rootID, write: false)
        return try await queryChildren(
            root: root,
            path: path,
            pageToken: pageToken,
            pageSize: pageSize
        )
    }

    /// Lists names and basic metadata in Android's document picker. File bytes still require a
    /// package-authorized open and range request.
    public func queryChildren(
        context: SharedFolderListingContext,
        rootID: String,
        path: String,
        pageToken: String = "",
        pageSize: Int = SharedFolderService.maximumPageEntries
    ) async throws(IntegrationFailure) -> SharedFolderPage {
        let root = try authorizedListingRoot(context: context, rootID: rootID)
        return try await queryChildren(
            root: root,
            path: path,
            pageToken: pageToken,
            pageSize: pageSize
        )
    }

    private func queryChildren(
        root: RootDescriptor,
        path: String,
        pageToken: String,
        pageSize: Int
    ) async throws(IntegrationFailure) -> SharedFolderPage {
        guard (1...Self.maximumPageEntries).contains(pageSize) else {
            throw .invalidRequest
        }
        let entryOffset: Int
        if pageToken.isEmpty {
            entryOffset = 0
        } else if let parsed = Int(pageToken), parsed >= 0 {
            entryOffset = parsed
        } else {
            throw .invalidRequest
        }

        let components = try Self.pathComponents(path)
        return try await performIO {
            do {
                let directory = try Self.openDirectory(
                    rootFD: root.fileDescriptor,
                    components: components,
                    rootName: root.definition.title
                )
                defer { _ = Darwin.close(directory) }

                guard let stream = fdopendir(dup(directory)) else {
                    throw Self.failureForCurrentErrno(rootName: root.definition.title)
                }
                defer { closedir(stream) }

                var entries: [SharedFolderEntry] = []
                entries.reserveCapacity(pageSize)
                var visibleEntryCount = 0
                var nextToken = ""
                while let entryPointer = readdir(stream) {
                    guard let name = Self.name(of: entryPointer), name != ".", name != ".." else {
                        continue
                    }
                    guard !Self.isHiddenOrPackage(name) else {
                        continue
                    }

                    let entryFD = dirfd(stream)
                    var info = Darwin.stat()
                    let status = name.withCString {
                        fstatat(entryFD, $0, &info, AT_SYMLINK_NOFOLLOW)
                    }
                    guard status == 0 else {
                        if errno == ENOENT {
                            continue
                        }
                        throw Self.failureForCurrentErrno(rootName: root.definition.title)
                    }

                    let type = info.st_mode & S_IFMT
                    guard type == S_IFDIR || type == S_IFREG else {
                        continue
                    }
                    visibleEntryCount += 1
                    if visibleEntryCount <= entryOffset {
                        continue
                    }
                    if entries.count == pageSize {
                        let nextOffset = entryOffset.addingReportingOverflow(entries.count)
                        guard !nextOffset.overflow else {
                            throw IntegrationFailure.invalidRequest
                        }
                        nextToken = String(nextOffset.partialValue)
                        break
                    }
                    let childPath = path.isEmpty ? name : "\(path)/\(name)"
                    entries.append(Self.entry(path: childPath, name: name, info: info))
                }
                return .success(SharedFolderPage(entries: entries, nextPageToken: nextToken))
            } catch let failure as IntegrationFailure {
                return .failure(failure)
            } catch {
                return .failure(.transferFailed)
            }
        }
    }

    /// Reads metadata after securely resolving a root-relative path.
    public func stat(
        packageID: String,
        rootID: String,
        path: String
    ) async throws(IntegrationFailure) -> SharedFolderEntry {
        let root = try authorizedRoot(packageID: packageID, rootID: rootID, write: false)
        let components = try Self.pathComponents(path)
        return try await performIO {
            do {
                if components.isEmpty {
                    var info = Darwin.stat()
                    guard fstat(root.fileDescriptor, &info) == 0 else {
                        throw Self.failureForCurrentErrno(rootName: root.definition.title)
                    }
                    return .success(Self.entry(path: "", name: root.definition.title, info: info))
                }
                let (parentFD, leaf) = try Self.openParent(
                    rootFD: root.fileDescriptor,
                    components: components,
                    rootName: root.definition.title
                )
                defer { _ = Darwin.close(parentFD) }
                var info = Darwin.stat()
                let status = leaf.withCString {
                    fstatat(parentFD, $0, &info, AT_SYMLINK_NOFOLLOW)
                }
                guard status == 0 else {
                    throw Self.failureForCurrentErrno(rootName: root.definition.title)
                }
                guard Self.isRegularFileOrDirectory(info.st_mode) else {
                    throw IntegrationFailure.pathRejected(.notRegularFile)
                }
                return .success(Self.entry(path: path, name: leaf, info: info))
            } catch let failure as IntegrationFailure {
                return .failure(failure)
            } catch {
                return .failure(.transferFailed)
            }
        }
    }

    /// Opens a regular file without following any path symlinks.
    public func openFile(
        packageID: String,
        rootID: String,
        path: String,
        mode: SharedFolderOpenMode
    ) async throws(IntegrationFailure) -> SharedFolderOpenFile {
        let root = try authorizedRoot(packageID: packageID, rootID: rootID, write: mode.needsWriteAccess)
        let components = try Self.pathComponents(path)
        guard let (parentComponents, leaf) = Self.parentAndLeaf(components) else {
            throw .pathRejected(.notRegularFile)
        }
        let openCount = handles.values.reduce(into: 0) { count, handle in
            if handle.packageID == packageID { count += 1 }
        }
        let reservedCount = reservedHandlesByPackage[packageID, default: 0]
        guard Self.canOpenHandle(openCount: openCount, reservedCount: reservedCount) else {
            throw .resourceExhausted
        }
        reservedHandlesByPackage[packageID] = reservedCount + 1
        defer {
            let remaining = reservedHandlesByPackage[packageID, default: 1] - 1
            if remaining == 0 {
                reservedHandlesByPackage.removeValue(forKey: packageID)
            } else {
                reservedHandlesByPackage[packageID] = remaining
            }
        }

        let opened = try await performIO {
            do {
                let parentFD = try Self.openDirectory(
                    rootFD: root.fileDescriptor,
                    components: parentComponents,
                    rootName: root.definition.title
                )
                defer { _ = Darwin.close(parentFD) }
                let fileFD = leaf.withCString {
                    openat(parentFD, $0, mode.flags | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                }
                guard fileFD >= 0 else {
                    throw Self.failureForCurrentErrno(rootName: root.definition.title)
                }

                var info = Darwin.stat()
                guard fstat(fileFD, &info) == 0 else {
                    let failure = Self.failureForCurrentErrno(rootName: root.definition.title)
                    _ = Darwin.close(fileFD)
                    throw failure
                }
                guard (info.st_mode & S_IFMT) == S_IFREG else {
                    _ = Darwin.close(fileFD)
                    throw IntegrationFailure.pathRejected(.notRegularFile)
                }
                if mode.needsWriteAccess, Self.setQuarantine(fileDescriptor: fileFD) != 0 {
                    _ = Darwin.close(fileFD)
                    throw IntegrationFailure.transferFailed
                }
                return .success((fileFD, UInt64(max(0, info.st_size))))
            } catch let failure as IntegrationFailure {
                return .failure(failure)
            } catch {
                return .failure(.transferFailed)
            }
        }

        guard !isStopped, !isReconfiguring else {
            await closeDescriptor(opened.0)
            throw .transferFailed
        }
        do {
            _ = try authorizedRoot(packageID: packageID, rootID: rootID, write: mode.needsWriteAccess)
        } catch {
            await closeDescriptor(opened.0)
            throw error
        }
        guard let handleID = allocateHandleID() else {
            await closeDescriptor(opened.0)
            throw .resourceExhausted
        }
        handles[handleID] = OpenHandle(
            packageID: packageID,
            rootID: rootID,
            fileDescriptor: opened.0,
            isWritable: mode.needsWriteAccess
        )
        return SharedFolderOpenFile(handle: handleID, sizeBytes: opened.1)
    }

    /// Reads at most 1 MiB from a package-owned open handle.
    public func readRange(
        packageID: String,
        handle handleID: UInt64,
        offset: UInt64,
        length: Int
    ) async throws(IntegrationFailure) -> Data {
        let handle = try authorizedHandle(packageID: packageID, handleID: handleID, write: false)
        let byteCount = try Self.validatedRange(offset: offset, length: length)
        return try await performIO {
            var data = Data(count: byteCount)
            let bytesRead = data.withUnsafeMutableBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                while true {
                    let result = pread(
                        handle.fileDescriptor,
                        baseAddress,
                        byteCount,
                        off_t(offset)
                    )
                    if result < 0, errno == EINTR {
                        continue
                    }
                    return result
                }
            }
            guard bytesRead >= 0 else {
                return .failure(.transferFailed)
            }
            data.count = bytesRead
            return .success(data)
        }
    }

    /// Writes at most 1 MiB to a package-owned open handle.
    public func writeRange(
        packageID: String,
        handle handleID: UInt64,
        offset: UInt64,
        data: Data
    ) async throws(IntegrationFailure) {
        let handle = try authorizedHandle(packageID: packageID, handleID: handleID, write: true)
        let byteCount = try Self.validatedRange(offset: offset, length: data.count)
        try await performIO {
            let written = data.withUnsafeBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                var total = 0
                while total < byteCount {
                    let count = pwrite(
                        handle.fileDescriptor,
                        baseAddress.advanced(by: total),
                        byteCount - total,
                        off_t(offset) + off_t(total)
                    )
                    if count < 0, errno == EINTR {
                        continue
                    }
                    guard count > 0 else {
                        return -1
                    }
                    total += count
                }
                return total
            }
            return written == byteCount ? .success(()) : .failure(.transferFailed)
        }
    }

    /// Closes one package-owned handle. Closing is allowed after access has been revoked.
    public func closeFile(
        packageID: String,
        handle handleID: UInt64,
        synchronize: Bool = false
    ) async throws(IntegrationFailure) {
        // Cleanup remains available after access revocation and while a policy update drains.
        guard !isStopped else { throw .transferFailed }
        guard let handle = handles[handleID], handle.packageID == packageID else {
            throw .packageAccessDenied
        }
        // Cleanup bypasses the normal request cap so a full read/write queue cannot strand a
        // descriptor or make connection teardown forget an open handle.
        inFlightRequests += 1
        defer { finishInFlightRequest() }
        handles.removeValue(forKey: handleID)
        let result: Result<Void, IntegrationFailure> = await withCheckedContinuation { continuation in
            ioQueue.async {
                if synchronize, handle.isWritable, fsync(handle.fileDescriptor) != 0 {
                    _ = Darwin.close(handle.fileDescriptor)
                    continuation.resume(returning: .failure(.transferFailed))
                    return
                }
                let status = Darwin.close(handle.fileDescriptor)
                continuation.resume(returning: status == 0 ? .success(()) : .failure(.transferFailed))
            }
        }
        try result.get()
    }

    /// Creates a new regular file or directory without replacing an existing item.
    public func createDocument(
        packageID: String,
        rootID: String,
        parentPath: String,
        name: String,
        isDirectory: Bool = false
    ) async throws(IntegrationFailure) -> SharedFolderEntry {
        let root = try authorizedRoot(packageID: packageID, rootID: rootID, write: true)
        let components = try Self.pathComponents(parentPath)
        try Self.validateLeaf(name)
        let relativePath = parentPath.isEmpty ? name : "\(parentPath)/\(name)"
        return try await performIO {
            do {
                let parentFD = try Self.openDirectory(
                    rootFD: root.fileDescriptor,
                    components: components,
                    rootName: root.definition.title
                )
                defer { _ = Darwin.close(parentFD) }
                if isDirectory {
                    guard mkdirat(parentFD, name, 0o700) == 0 else {
                        throw Self.failureForCurrentErrno(rootName: root.definition.title)
                    }
                    var info = Darwin.stat()
                    guard fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                        _ = unlinkat(parentFD, name, AT_REMOVEDIR)
                        throw Self.failureForCurrentErrno(rootName: root.definition.title)
                    }
                    return .success(Self.entry(path: relativePath, name: name, info: info))
                }

                let fileFD = name.withCString {
                    openat(parentFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
                }
                guard fileFD >= 0 else {
                    throw Self.failureForCurrentErrno(rootName: root.definition.title)
                }
                guard Self.setQuarantine(fileDescriptor: fileFD) == 0 else {
                    _ = Darwin.close(fileFD)
                    _ = unlinkat(parentFD, name, 0)
                    throw IntegrationFailure.transferFailed
                }
                var info = Darwin.stat()
                guard fstat(fileFD, &info) == 0 else {
                    let failure = Self.failureForCurrentErrno(rootName: root.definition.title)
                    _ = Darwin.close(fileFD)
                    _ = unlinkat(parentFD, name, 0)
                    throw failure
                }
                _ = Darwin.close(fileFD)
                return .success(Self.entry(path: relativePath, name: name, info: info))
            } catch let failure as IntegrationFailure {
                return .failure(failure)
            } catch {
                return .failure(.transferFailed)
            }
        }
    }

    /// Deletes a regular file or an empty directory after checking write access.
    public func deleteDocument(packageID: String, rootID: String, path: String) async throws(IntegrationFailure) {
        let root = try authorizedRoot(packageID: packageID, rootID: rootID, write: true)
        let components = try Self.pathComponents(path)
        guard let (parentComponents, leaf) = Self.parentAndLeaf(components) else {
            throw .pathRejected(.notRegularFile)
        }
        try await performIO {
            do {
                let parentFD = try Self.openDirectory(
                    rootFD: root.fileDescriptor,
                    components: parentComponents,
                    rootName: root.definition.title
                )
                defer { _ = Darwin.close(parentFD) }
                var info = Darwin.stat()
                guard leaf.withCString({ fstatat(parentFD, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                    throw Self.failureForCurrentErrno(rootName: root.definition.title)
                }
                guard Self.isRegularFileOrDirectory(info.st_mode) else {
                    throw IntegrationFailure.pathRejected(.notRegularFile)
                }
                let flags = (info.st_mode & S_IFMT) == S_IFDIR ? AT_REMOVEDIR : 0
                guard leaf.withCString({ unlinkat(parentFD, $0, flags) }) == 0 else {
                    throw Self.failureForCurrentErrno(rootName: root.definition.title)
                }
                return .success(())
            } catch let failure as IntegrationFailure {
                return .failure(failure)
            } catch {
                return .failure(.transferFailed)
            }
        }
    }

    /// Renames a regular file or directory within its existing parent without replacement.
    public func renameDocument(
        packageID: String,
        rootID: String,
        path: String,
        newName: String
    ) async throws(IntegrationFailure) {
        let root = try authorizedRoot(packageID: packageID, rootID: rootID, write: true)
        let components = try Self.pathComponents(path)
        guard let (parentComponents, oldName) = Self.parentAndLeaf(components) else {
            throw .pathRejected(.notRegularFile)
        }
        try Self.validateLeaf(newName)
        let _: Void = try await performIO {
            do {
                let parentFD = try Self.openDirectory(
                    rootFD: root.fileDescriptor,
                    components: parentComponents,
                    rootName: root.definition.title
                )
                defer { _ = Darwin.close(parentFD) }
                var info = Darwin.stat()
                guard oldName.withCString({ fstatat(parentFD, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                    throw Self.failureForCurrentErrno(rootName: root.definition.title)
                }
                guard Self.isRegularFileOrDirectory(info.st_mode) else {
                    throw IntegrationFailure.pathRejected(.notRegularFile)
                }
                let status = oldName.withCString { oldPointer in
                    newName.withCString { newPointer in
                        renameatx_np(parentFD, oldPointer, parentFD, newPointer, UInt32(RENAME_EXCL))
                    }
                }
                guard status == 0 else {
                    throw Self.failureForCurrentErrno(rootName: root.definition.title)
                }
                return .success(())
            } catch let failure as IntegrationFailure {
                return .failure(failure)
            } catch {
                return .failure(.transferFailed)
            }
        }
    }

    /// Closes every open file and root descriptor when this runtime stops.
    public func runtimeDidStop() async {
        guard !isStopped else { return }
        isStopped = true
        isReconfiguring = true
        while inFlightRequests > 0 {
            await withCheckedContinuation { continuation in
                inFlightWaiters.append(continuation)
            }
        }
        let openDescriptors =
            handles.values.map(\.fileDescriptor) + roots.values.map(\.fileDescriptor).filter { $0 >= 0 }
        handles.removeAll()
        roots.removeAll()
        await withCheckedContinuation { continuation in
            ioQueue.async {
                for descriptor in openDescriptors {
                    _ = Darwin.close(descriptor)
                }
                continuation.resume()
            }
        }
    }

    /// Combines package access with the root's maximum access.
    public nonisolated static func effectiveAccess(
        _ packageAccess: SharedFolderAccess,
        rootMaximum: SharedFolderAccess
    ) -> SharedFolderAccess? {
        switch packageAccess {
        case .off:
            nil
        case .readOnly where rootMaximum == .off:
            nil
        case .readOnly:
            .readOnly
        case .readWrite:
            rootMaximum
        }
    }

    private nonisolated static func maximumPackageAccess(
        for rootID: String,
        rootMaximum: SharedFolderAccess,
        packageAccess: [String: [String: SharedFolderAccess]]
    ) -> SharedFolderAccess? {
        packageAccess.values
            .compactMap { $0[rootID] }
            .compactMap { effectiveAccess($0, rootMaximum: rootMaximum) }
            .filter { $0 != .off }
            .max { $0.rawValue < $1.rawValue }
    }

    nonisolated static func canOpenHandle(openCount: Int, reservedCount: Int) -> Bool {
        guard openCount >= 0, reservedCount >= 0, openCount < maximumOpenHandlesPerPackage else {
            return false
        }
        return reservedCount < maximumOpenHandlesPerPackage - openCount
    }

    nonisolated static func hasInFlightCapacity(_ activeCount: Int) -> Bool {
        activeCount >= 0 && activeCount < maximumInFlightRequests
    }

    // MARK: - Authorization and request limits

    private func ensureRunning() throws(IntegrationFailure) {
        guard !isStopped, !isReconfiguring else {
            throw .transferFailed
        }
    }

    private func finishInFlightRequest() {
        inFlightRequests -= 1
        guard inFlightRequests == 0 else { return }
        let waiters = inFlightWaiters
        inFlightWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func authorizedRoot(
        packageID: String,
        rootID: String,
        write: Bool
    ) throws(IntegrationFailure) -> RootDescriptor {
        try ensureRunning()
        guard let root = roots[rootID] else {
            throw .packageAccessDenied
        }
        guard let packageSetting = packageAccess[packageID]?[rootID],
            let access = Self.effectiveAccess(packageSetting, rootMaximum: root.definition.maximumAccess),
            access != .off
        else {
            throw .packageAccessDenied
        }
        guard root.fileDescriptor >= 0 else {
            throw .folderUnavailable(
                root.unavailableProblem ?? .missing,
                name: root.definition.title
            )
        }
        if write, access != .readWrite {
            throw .readOnly
        }
        return root
    }

    private func authorizedListingRoot(
        context: SharedFolderListingContext,
        rootID: String
    ) throws(IntegrationFailure) -> RootDescriptor {
        try ensureRunning()
        switch context {
        case .package(let packageID):
            return try authorizedRoot(packageID: packageID, rootID: rootID, write: false)
        case .documentPicker:
            guard let root = roots[rootID] else {
                throw .packageAccessDenied
            }
            guard
                Self.maximumPackageAccess(
                    for: rootID,
                    rootMaximum: root.definition.maximumAccess,
                    packageAccess: packageAccess
                ) != nil
            else {
                throw .packageAccessDenied
            }
            guard root.fileDescriptor >= 0 else {
                throw .folderUnavailable(
                    root.unavailableProblem ?? .missing,
                    name: root.definition.title
                )
            }
            return root
        }
    }

    private func authorizedHandle(
        packageID: String,
        handleID: UInt64,
        write: Bool
    ) throws(IntegrationFailure) -> OpenHandle {
        try ensureRunning()
        guard let handle = handles[handleID], handle.packageID == packageID else {
            throw .packageAccessDenied
        }
        let root = try authorizedRoot(packageID: packageID, rootID: handle.rootID, write: write)
        if write, !handle.isWritable {
            throw .readOnly
        }
        _ = root
        return handle
    }

    private func replacePackageAccess(
        _ newAccess: [String: [String: SharedFolderAccess]],
        for packageID: String?
    ) async throws(IntegrationFailure) {
        try ensureRunning()

        let changedPackages: Set<String>
        if let packageID {
            guard packageAccess[packageID] != newAccess[packageID] else { return }
            changedPackages = [packageID]
        } else {
            changedPackages = Set(packageAccess.keys).union(newAccess.keys).filter {
                packageAccess[$0] != newAccess[$0]
            }
            guard !changedPackages.isEmpty else { return }
        }

        isReconfiguring = true
        defer { isReconfiguring = false }
        while inFlightRequests > 0 {
            await withCheckedContinuation { continuation in
                inFlightWaiters.append(continuation)
            }
        }
        guard !isStopped else { throw .transferFailed }

        let revokedDescriptors = handles.values.compactMap { handle in
            changedPackages.contains(handle.packageID) ? handle.fileDescriptor : nil
        }
        handles = handles.filter { !changedPackages.contains($0.value.packageID) }
        for package in changedPackages {
            packageAccess[package] = nil
        }
        for (package, access) in newAccess where packageID == nil || package == packageID {
            packageAccess[package] = access
        }

        await withCheckedContinuation { continuation in
            ioQueue.async {
                for descriptor in revokedDescriptors {
                    _ = Darwin.close(descriptor)
                }
                continuation.resume()
            }
        }
    }

    private func allocateHandleID() -> UInt64? {
        guard nextHandle != 0 else { return nil }
        let allocated = nextHandle
        nextHandle &+= 1
        while handles[allocated] != nil {
            guard nextHandle != 0 else { return nil }
            let next = nextHandle
            nextHandle &+= 1
            if next == allocated {
                return nil
            }
        }
        return allocated
    }

    private func performIO<Value: Sendable>(
        _ operation: @escaping @Sendable () -> Result<Value, IntegrationFailure>
    ) async throws(IntegrationFailure) -> Value {
        try ensureRunning()
        guard Self.hasInFlightCapacity(inFlightRequests) else {
            throw .resourceExhausted
        }
        inFlightRequests += 1
        defer { finishInFlightRequest() }

        let result: Result<Value, IntegrationFailure> = await withCheckedContinuation { continuation in
            ioQueue.async {
                continuation.resume(returning: operation())
            }
        }
        return try result.get()
    }

    private func closeDescriptor(_ descriptor: Int32) async {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                _ = Darwin.close(descriptor)
                continuation.resume()
            }
        }
    }

    private nonisolated static func sameDirectory(_ first: Int32, _ second: Int32) -> Bool {
        var firstInfo = Darwin.stat()
        var secondInfo = Darwin.stat()
        guard fstat(first, &firstInfo) == 0, fstat(second, &secondInfo) == 0 else {
            return false
        }
        return firstInfo.st_dev == secondInfo.st_dev
            && firstInfo.st_ino == secondInfo.st_ino
            && (firstInfo.st_mode & S_IFMT) == S_IFDIR
            && (secondInfo.st_mode & S_IFMT) == S_IFDIR
    }

    // MARK: - Safe paths and metadata

    private nonisolated static func pathComponents(_ path: String) throws(IntegrationFailure) -> [String] {
        guard !path.hasPrefix("/"), path.utf8.count <= 4_096,
            !path.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw .pathRejected(.outsideRoot)
        }
        if path.isEmpty {
            return []
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for component in components {
            guard !component.isEmpty else {
                throw .pathRejected(.outsideRoot)
            }
            if component == ".." {
                throw .pathRejected(.outsideRoot)
            }
            if component == "." || isHiddenOrPackage(component) {
                throw .pathRejected(.hidden)
            }
        }
        return components
    }

    private nonisolated static func validateLeaf(_ name: String) throws(IntegrationFailure) {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), name.utf8.count <= 255,
            !name.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw .pathRejected(.outsideRoot)
        }
        guard !isHiddenOrPackage(name) else {
            throw .pathRejected(.hidden)
        }
    }

    private nonisolated static func parentAndLeaf(_ components: [String]) -> ([String], String)? {
        guard let leaf = components.last else { return nil }
        return (Array(components.dropLast()), leaf)
    }

    private nonisolated static func openDirectory(
        rootFD: Int32,
        components: [String],
        rootName: String
    ) throws(IntegrationFailure) -> Int32 {
        var current = openat(rootFD, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard current >= 0 else {
            throw failureForCurrentErrno(rootName: rootName)
        }
        for component in components {
            let next = component.withCString {
                openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            if next < 0 {
                let failure = failureForCurrentErrno(rootName: rootName)
                _ = Darwin.close(current)
                throw failure
            }
            _ = Darwin.close(current)
            current = next
        }
        return current
    }

    private nonisolated static func openParent(
        rootFD: Int32,
        components: [String],
        rootName: String
    ) throws(IntegrationFailure) -> (Int32, String) {
        guard let leaf = parentAndLeaf(components)?.1 else {
            throw .pathRejected(.notRegularFile)
        }
        let parentComponents = Array(components.dropLast())
        let parentFD = try openDirectory(rootFD: rootFD, components: parentComponents, rootName: rootName)
        return (parentFD, leaf)
    }

    private nonisolated static func isValidRootID(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 128 else { return false }
        return id.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private nonisolated static func isHiddenOrPackage(_ name: String) -> Bool {
        guard !name.isEmpty else { return true }
        if name.hasPrefix(".") {
            return true
        }
        let folded = name.lowercased()
        return folded.hasSuffix(".app") || folded.hasSuffix(".photoslibrary")
    }

    private nonisolated static func name(of entry: UnsafeMutablePointer<dirent>) -> String? {
        withUnsafePointer(to: &entry.pointee.d_name.0) {
            String(validatingCString: $0)
        }
    }

    private nonisolated static func isRegularFileOrDirectory(_ mode: mode_t) -> Bool {
        let type = mode & S_IFMT
        return type == S_IFREG || type == S_IFDIR
    }

    private nonisolated static func entry(path: String, name: String, info: stat) -> SharedFolderEntry {
        let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
        let extensionName = URL(fileURLWithPath: name).pathExtension
        let mimeType = UTType(filenameExtension: extensionName)?.preferredMIMEType ?? "application/octet-stream"
        let seconds = Int64(info.st_mtimespec.tv_sec)
        let milliseconds = seconds.multipliedReportingOverflow(by: 1_000)
        let timestamp: Int64
        if milliseconds.overflow {
            timestamp = seconds < 0 ? Int64.min : Int64.max
        } else {
            let adjusted = milliseconds.partialValue.addingReportingOverflow(
                Int64(info.st_mtimespec.tv_nsec / 1_000_000)
            )
            timestamp = adjusted.overflow ? Int64.max : adjusted.partialValue
        }
        return SharedFolderEntry(
            path: path,
            name: name,
            isDirectory: isDirectory,
            sizeBytes: isDirectory ? 0 : UInt64(max(0, info.st_size)),
            modificationTimeMilliseconds: timestamp,
            mimeType: isDirectory ? "inode/directory" : mimeType
        )
    }

    private nonisolated static func validatedRange(offset: UInt64, length: Int) throws(IntegrationFailure) -> Int {
        guard length >= 0, length <= maximumRangeBytes, offset <= UInt64(Int64.max) else {
            throw .invalidRequest
        }
        let (_, overflow) = offset.addingReportingOverflow(UInt64(length))
        guard !overflow, offset + UInt64(length) <= UInt64(Int64.max) else {
            throw .invalidRequest
        }
        return length
    }

    // MARK: - POSIX errors and quarantine

    private nonisolated static func folderProblem(for error: Int32) -> FolderProblem {
        switch error {
        case EACCES, EPERM:
            .privacyDenied
        case ENODEV, ENXIO, EIO:
            .offline
        default:
            .missing
        }
    }

    private nonisolated static func failureForCurrentErrno(rootName: String) -> IntegrationFailure {
        switch errno {
        case ENOENT:
            .itemNotFound
        case EACCES, EPERM:
            .folderUnavailable(.privacyDenied, name: rootName)
        case ENODEV, ENXIO, EIO:
            .folderUnavailable(.offline, name: rootName)
        case EROFS:
            .readOnly
        case ELOOP, ENOTDIR:
            .pathRejected(.outsideRoot)
        case EEXIST, ENOTEMPTY, EINVAL, ENAMETOOLONG:
            .invalidRequest
        case EMFILE, ENFILE, ENOMEM, EDQUOT:
            .resourceExhausted
        default:
            .transferFailed
        }
    }

    private nonisolated static func setQuarantine(fileDescriptor: Int32) -> Int32 {
        let timestamp = String(Int(Date().timeIntervalSince1970), radix: 16)
        let value = "0081;\(timestamp);APKRun;\(UUID().uuidString)"
        let data = Data(value.utf8)
        return data.withUnsafeBytes { buffer in
            fsetxattr(fileDescriptor, "com.apple.quarantine", buffer.baseAddress, buffer.count, 0, 0)
        }
    }
}
