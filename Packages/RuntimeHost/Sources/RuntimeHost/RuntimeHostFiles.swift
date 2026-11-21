import CryptoKit
import Foundation
import GuestProtocol
import IntegrationCore
import RuntimeAPI
import RuntimeCore
import UniformTypeIdentifiers

/// A user-added shared folder root, persisted in `shared-folders.json`
/// (desktop-integration.md §6.4).
struct SharedFolderRecord: Codable, Sendable, Equatable {
    /// Stable root id (the guest addresses roots by it).
    var id: String
    /// The title the picker and Settings show.
    var name: String
    /// Security-scoped bookmark for the picked folder.
    var bookmark: Data
    /// The most the root grants: `readOnly` or `readWrite`.
    var access: String
    /// The resolved path at add time (display only; bookmarks can go stale).
    var path: String
}

/// The host side of `sharedFolders.roots` (configuration.md): the built-in
/// `shared` root plus at most 32 user-picked folders, each stored as a
/// security-scoped bookmark. The daemon resolves the bookmarks — the
/// folders stay accessible after reboot without a sandbox of their own —
/// and the resolved URLs feed ``SharedFolderService``.
actor SharedFolderRegistry {
    /// The built-in root id (`~/Library/Application Support/APKRun/Shared/`).
    static let builtInID = "shared"
    /// At most this many user-added roots (desktop-integration.md §6.4).
    static let userRootLimit = 32

    /// `Application Support/APKRun/shared-folders.json`.
    private let fileURL: URL
    private var records: [SharedFolderRecord] = []

    /// Creates the registry at `fileURL`, loading any stored roots.
    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
            let stored = try? JSONDecoder().decode([SharedFolderRecord].self, from: data)
        {
            records = stored
        }
    }

    /// `Application Support/APKRun/Shared/` — the built-in root.
    var builtInURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("Shared", isDirectory: true)
    }

    /// The resolved roots for ``SharedFolderService``; the built-in folder
    /// is created on first use.
    func roots() -> [SharedFolderRoot] {
        var result = [
            SharedFolderRoot(
                rootID: Self.builtInID, title: "Shared",
                url: builtInURL, maxAccess: .readWrite)
        ]
        for record in records {
            let url = resolve(record.bookmark) ?? URL(fileURLWithPath: record.path)
            result.append(
                SharedFolderRoot(
                    rootID: record.id, title: record.name,
                    url: url,
                    maxAccess: record.access == "readWrite" ? .readWrite : .readOnly))
        }
        return result
    }

    /// The control-op view: every root with its live availability.
    func folders() -> [SharedFolder] {
        var result = [
            SharedFolder(
                id: Self.builtInID, name: "Shared", path: builtInURL.path,
                access: "readWrite", builtIn: true,
                availability: Self.availability(of: builtInURL))
        ]
        for record in records {
            let url = resolve(record.bookmark) ?? URL(fileURLWithPath: record.path)
            result.append(
                SharedFolder(
                    id: record.id, name: record.name, path: url.path,
                    access: record.access, builtIn: false,
                    availability: Self.availability(of: url)))
        }
        return result
    }

    /// Adds a picked folder. The refusal reasons come from
    /// desktop-integration.md §6.4: volume roots, the home folder, anything
    /// inside ~/Library, hidden paths, and the 32-root limit.
    func add(bookmark: Data, access: String) throws(IntegrationFailure) -> SharedFolder {
        guard let url = resolve(bookmark) else {
            throw .folderUnavailable(problem: .missing)
        }
        let standardized = url.standardizedFileURL
        try refuse(unacceptable: standardized)
        let path = standardized.path
        let level = access == "readWrite" ? "readWrite" : "readOnly"
        if let existing = records.first(where: {
            (resolve($0.bookmark) ?? URL(fileURLWithPath: $0.path)).standardizedFileURL.path == path
        }) {
            return SharedFolder(
                id: existing.id, name: existing.name, path: path,
                access: existing.access, builtIn: false,
                availability: Self.availability(of: url))
        }
        guard records.count < Self.userRootLimit else {
            throw .folderRefused(reason: .limitReached)
        }
        let record = SharedFolderRecord(
            id: UUID().uuidString.lowercased(),
            name: standardized.lastPathComponent,
            bookmark: bookmark, access: level, path: path)
        records.append(record)
        try persist()
        return SharedFolder(
            id: record.id, name: record.name, path: path,
            access: level, builtIn: false,
            availability: Self.availability(of: url))
    }

    /// Removes a user-added root; the built-in root stays.
    func remove(id: String) throws(IntegrationFailure) {
        guard id != Self.builtInID else {
            throw .folderUnavailable(problem: .missing)
        }
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw .folderUnavailable(problem: .missing)
        }
        records.remove(at: index)
        try persist()
    }

    /// Changes a root's own access cap.
    func setAccess(id: String, access: String) throws(IntegrationFailure) -> SharedFolder {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw .folderUnavailable(problem: .missing)
        }
        records[index].access = access == "readWrite" ? "readWrite" : "readOnly"
        try persist()
        let record = records[index]
        let url = resolve(record.bookmark) ?? URL(fileURLWithPath: record.path)
        return SharedFolder(
            id: record.id, name: record.name, path: url.path,
            access: record.access, builtIn: false,
            availability: Self.availability(of: url))
    }

    // MARK: Bookmarks and refusals

    private func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale)
        else { return nil }
        // The daemon is not sandboxed; startAccessing is still needed so the
        // bookmark's resource is claimed for the lifetime of the process.
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    private func refuse(unacceptable url: URL) throws(IntegrationFailure) {
        let path = url.standardizedFileURL.path
        let components = url.standardizedFileURL.pathComponents
        // A volume root: "/", "/Volumes", or "/Volumes/<name>".
        if path == "/" || (components.count <= 3 && components.first == "/" && path.hasPrefix("/Volumes"))
            || path == "/Volumes"
        {
            throw .folderRefused(reason: .volumeRoot)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path == home { throw .folderRefused(reason: .homeFolder) }
        if path.hasPrefix(home + "/Library") { throw .folderRefused(reason: .insideLibrary) }
        if components.contains(where: { $0.hasPrefix(".") }) {
            throw .folderRefused(reason: .hidden)
        }
    }

    /// `available`, `missing`, or `privacyDenied` (runtime-api.md §11.1).
    static func availability(of url: URL) -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return "missing"
        }
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if descriptor < 0 {
            return "privacyDenied"
        }
        close(descriptor)
        return "available"
    }

    private func persist() throws(IntegrationFailure) {
        do {
            let data = try JSONEncoder().encode(records)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw .transferFailed(detail: "shared-folders.json")
        }
    }
}

/// The ``FileTransferChannel`` over the live session's control and bulk
/// connections (desktop-integration.md §6.2–§6.3). `sendImport` streams each
/// dropped file as a `.file` bulk transfer, then the `ImportFiles` request
/// carries the transfer IDs. `resolveExport` answers the offer and, when
/// accepted, writes the streamed file into the save panel's handle after
/// the SHA-256 check and marks it quarantined (§6.3).
struct HostFileTransferChannel: FileTransferChannel {
    /// The supervisor of the current guest session.
    var supervisor: @Sendable () async -> GuestAgentSupervisor?
    /// The session's `.guestBulk` channel.
    var bulk: @Sendable () async throws -> GuestBulkChannel

    func sendImport(
        package: RuntimePackageID, displayID: Int,
        handles: [FileHandle], infos: [ImportFileInfo]
    ) async throws(IntegrationFailure) -> ImportResult {
        guard let supervisor = await supervisor() else { throw .guestUnavailable }
        let channel: GuestBulkChannel
        do {
            channel = try await bulk()
        } catch {
            throw .guestUnavailable
        }
        var refs: [GPFileRef] = []
        do {
            for (handle, info) in zip(handles, infos) {
                var ref = GPFileRef()
                ref.name = info.name
                ref.mimeType = Self.mimeType(for: info)
                ref.size = UInt64(max(0, info.size))
                ref.transferID = try await channel.sendFile(
                    handle, size: info.size, name: info.name,
                    kind: .file, mimeType: ref.mimeType)
                refs.append(ref)
            }
        } catch {
            throw .transferFailed(detail: "upload")
        }
        do {
            let result = try await supervisor.send(
                GuestImportFiles(
                    package: package.rawValue, displayID: Int32(displayID), files: refs))
            return ImportResult(
                contentURIs: result.contentUri,
                disposition: result.disposition == .savedToDownloads
                    ? "savedToDownloads" : "shared")
        } catch {
            throw .transferFailed(detail: "ImportFiles")
        }
    }

    func resolveExport(
        offerID: String, package: RuntimePackageID,
        accept: Bool, writeTo: FileHandle?
    ) async throws(IntegrationFailure) {
        guard let supervisor = await supervisor() else { throw .guestUnavailable }
        var start: GPExportStart
        do {
            start = try await supervisor.send(
                GuestResolveExport(
                    offerID: UInt64(offerID) ?? 0,
                    decision: accept ? .accept : .decline))
        } catch {
            throw .transferFailed(detail: "ResolveExport")
        }
        guard accept, let handle = writeTo, start.hasTransferID else { return }
        let channel: GuestBulkChannel
        do {
            channel = try await bulk()
        } catch {
            throw .guestUnavailable
        }
        guard let transfer = await channel.transfer(start.transferID, timeout: .seconds(30)) else {
            throw .transferFailed(detail: "no transfer")
        }
        do {
            try Self.write(transfer: transfer, into: handle)
        } catch {
            try? handle.truncate(atOffset: 0)
            throw .transferFailed(detail: "write")
        }
        Self.quarantine(handle: handle, agent: "APKRun")
    }

    /// Streams the transfer into the save file and verifies its digest
    /// (guest-protocol.md §7.4, desktop-integration.md §6.3).
    static func write(transfer: GuestInboundTransfer, into handle: FileHandle) throws {
        var hasher = SHA256()
        if let url = transfer.fileURL {
            defer { try? FileManager.default.removeItem(at: url) }
            let reader = try FileHandle(forReadingFrom: url)
            defer { try? reader.close() }
            while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
                try handle.write(contentsOf: chunk)
            }
        } else if let bytes = transfer.bytes {
            hasher.update(data: bytes)
            try handle.write(contentsOf: bytes)
        }
        if let expected = transfer.sha256, !expected.isEmpty,
            Data(hasher.finalize()) != expected
        {
            throw CocoaError(.fileWriteFileExists)
        }
        try handle.synchronize()
    }

    /// `com.apple.quarantine` "APKRun" (desktop-integration.md §6.3).
    static func quarantine(handle: FileHandle, agent: String) {
        let value = "0003;\(String(UInt(Date().timeIntervalSince1970), radix: 16));\(agent);"
        value.withCString { pointer in
            _ = fsetxattr(
                handle.fileDescriptor, "com.apple.quarantine", pointer,
                strlen(pointer) + 1, 0, 0)
        }
    }

    /// The drop's MIME type from its UTI.
    static func mimeType(for info: ImportFileInfo) -> String {
        UTType(info.uti)?.preferredMIMEType
            ?? UTType(filenameExtension: URL(fileURLWithPath: info.name).pathExtension)?
            .preferredMIMEType
            ?? "application/octet-stream"
    }
}

/// A counting permit for the §7.5 dispatcher's 16-in-flight cap.
private actor RequestBudget {
    private var used = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    func acquire() async {
        if used < limit {
            used += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty {
            used -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

extension RuntimeHost {
    // MARK: Services

    /// The shared-folder roots store (`shared-folders.json`).
    func sharedFolderRegistry() -> SharedFolderRegistry {
        if let sharedFolderRegistryLazy { return sharedFolderRegistryLazy }
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("APKRun", isDirectory: true)
        let registry = SharedFolderRegistry(
            fileURL: support.appendingPathComponent("shared-folders.json"))
        sharedFolderRegistryLazy = registry
        return registry
    }

    /// The §6.2–6.3 drop/export service over the live session.
    func fileTransferService() -> FileTransferService {
        if let fileTransferServiceLazy { return fileTransferServiceLazy }
        let settings = integrationSettings
        let policy = IntegrationPolicy(
            source: IntegrationSettingsSource(
                packageValue: { kind, packageID in
                    settings.packageValue(packageID.rawValue, kind.rawValue)
                },
                globalEnabled: { kind in
                    settings.globalEnabled(kind.rawValue)
                },
                supported: { capability in
                    settings.supports(capability)
                }
            )
        )
        let channel = HostFileTransferChannel(
            supervisor: { [weak self] in
                await self?.runtimeSupervisorForIntegrations()?
                    .developmentGuestAgent?.supervisor
            },
            bulk: { [weak self] in
                guard let self else { throw IntegrationFailure.guestUnavailable }
                return try await self.clipboardBulkChannel()
            })
        let service = FileTransferService(
            policy: policy,
            channel: channel,
            onExportOffered: { [weak self] sessionID, offer in
                guard let self else { return }
                await self.eventHub.publishIntegrationChange(
                    .exportOffered(
                        sessionID: sessionID,
                        packageID: offer.sourcePackage,
                        offer: ExportOffer(
                            offerID: offer.offerID, name: offer.name,
                            size: offer.size, type: offer.type)))
            })
        fileTransferServiceLazy = service
        return service
    }

    /// The §6.4 document provider the agent's `Host*` ops call.
    func sharedFolderService() -> SharedFolderService {
        if let sharedFolderServiceLazy { return sharedFolderServiceLazy }
        let settings = integrationSettings
        let service = SharedFolderService(
            source: SharedFolderService.Source(
                roots: { [weak self] in
                    await self?.sharedFolderRegistry().roots() ?? []
                },
                valueForPackage: { packageID in
                    // The global switch wins over the stored package value
                    // (configuration.md §2.2).
                    guard settings.globalEnabled("sharedFolders") else { return "off" }
                    return settings.packageValue(packageID.rawValue, "sharedFolders") ?? "off"
                }))
        sharedFolderServiceLazy = service
        return service
    }

    // MARK: Session operations (runtime-api.md §11.2)

    /// `importFiles`: the wrapper's drop. The session must belong to the
    /// calling package (NFR-SEC-07); `target` accepts only `shareToApp`.
    public func importFiles(
        sessionID: UUID,
        files: [FileHandle],
        infos: [ImportFileInfo],
        target: String,
        callerPackageID: RuntimePackageID?
    ) async throws -> ImportResult {
        guard target == "shareToApp" else {
            throw RuntimeWireError.runtime(
                "invalidArgument", message: "Unknown import target \(target).")
        }
        guard
            let raw = await sessionServiceForIntegrations()?.packageID(forSession: sessionID),
            let package = RuntimePackageID(rawValue: raw)
        else {
            throw RuntimeWireError.runtime(
                "sessionNotFound", message: "No running session for that drop.")
        }
        if let callerPackageID, callerPackageID != package {
            throw RuntimeWireError.runtime(
                "packageMismatch", message: "The session belongs to another package.")
        }
        let displayID =
            await sessionSnapshotsForIntegrations()
            .first { $0.id == .app(sessionID) }?.displayID ?? -1
        do {
            return try await fileTransferService().importFiles(
                sessionID: sessionID, package: package, displayID: Int(displayID),
                handles: files, infos: infos, windowIsKey: true)
        } catch let failure as IntegrationFailure {
            throw Self.integrationWireError(failure)
        }
    }

    /// `acceptExport`: the save panel's answer. `target` is the open file
    /// the panel returned; nil declines (§6.3).
    public func acceptExport(
        sessionID: UUID,
        offerID: String,
        fileIndex: Int?,
        target: FileHandle?,
        callerPackageID: RuntimePackageID?
    ) async throws {
        guard let callerPackageID else {
            throw RuntimeWireError.runtime(
                "packageMismatch", message: "Exports are answered by the app's window.")
        }
        do {
            try await fileTransferService().acceptExport(
                offerID: offerID, sessionID: sessionID,
                callerPackageID: callerPackageID, writeTo: target)
        } catch let failure as IntegrationFailure {
            throw Self.integrationWireError(failure)
        }
    }

    // MARK: Shared-folder control operations (runtime-api.md §11.1)

    /// `sharedFolders`: every root with live availability.
    public func sharedFolders() async throws -> [SharedFolder] {
        await sharedFolderRegistry().folders()
    }

    /// `addSharedFolder`: the picker's bookmark becomes a root (§6.4).
    public func addSharedFolder(bookmark: Data, access: String) async throws -> SharedFolder {
        do {
            let folder = try await sharedFolderRegistry().add(
                bookmark: bookmark, access: access)
            await sharedFoldersChanged()
            return folder
        } catch let failure as IntegrationFailure {
            throw Self.integrationWireError(failure)
        }
    }

    /// `removeSharedFolder`: a user-added root leaves `roots`.
    public func removeSharedFolder(id: String) async throws {
        do {
            try await sharedFolderRegistry().remove(id: id)
            await sharedFoldersChanged()
        } catch let failure as IntegrationFailure {
            throw Self.integrationWireError(failure)
        }
    }

    /// `setSharedFolderAccess`: the root's own access cap.
    public func setSharedFolderAccess(id: String, access: String) async throws -> SharedFolder {
        do {
            let folder = try await sharedFolderRegistry().setAccess(id: id, access: access)
            await sharedFoldersChanged()
            return folder
        } catch let failure as IntegrationFailure {
            throw Self.integrationWireError(failure)
        }
    }

    /// `sharedFoldersChanged` + `configurationChanged` events, then the
    /// updated access map to the agent (§6.4, runtime-api.md §11.1).
    private func sharedFoldersChanged() async {
        await eventHub.publishIntegrationChange(.sharedFoldersChanged)
        await eventHub.publishRuntimeChange(
            .configurationChanged(keys: ["sharedFolders.roots"]))
        await pushSharedFolderAccess()
    }

    /// Pushes `SetSharedFolderAccess` (op 52): the roots and each package's
    /// `integrations.sharedFolders` value (§6.4).
    func pushSharedFolderAccess() async {
        guard let supervisor = runtimeSupervisorForIntegrations(),
            let agent = await supervisor.developmentGuestAgent
        else { return }
        var roots: [GPSharedRoot] = []
        for root in await sharedFolderRegistry().roots() {
            var gp = GPSharedRoot()
            gp.rootID = root.rootID
            gp.title = root.title
            gp.maxAccess = root.maxAccess == .readWrite ? .readWrite : .readOnly
            roots.append(gp)
        }
        var access: [String: String] = [:]
        if let service = packageServiceForIntegrations() {
            let result = try? await service.listPackages(RuntimeListPackagesRequest())
            for summary in result?.packages ?? [] {
                let value =
                    (try? await service.packageIntegrationSettings(
                        for: summary.packageID.rawValue))?
                    .value("integrations.sharedFolders") ?? "off"
                if value == "readOnly" || value == "readWrite" {
                    access[summary.packageID.rawValue] = value
                }
            }
        }
        _ = try? await agent.supervisor.send(
            GuestSetSharedFolderAccess(roots: roots, access: access))
    }

    // MARK: Relays

    /// Starts the export-offer relay and the agent→host `Host*` document
    /// request loop once the agent is ready; pushes the access map on each
    /// (re)connection (§6.4).
    func startFileServices() {
        guard exportRelayTask == nil, let supervisor = runtimeSupervisorForIntegrations()
        else { return }
        exportRelayTask = Task.detached { [weak self] in
            guard let self else { return }
            var agent = await supervisor.developmentGuestAgent
            while !Task.isCancelled, let current = agent {
                await self.pushSharedFolderAccess()
                await self.startSharedFolderRequestLoop(agent: current)
                for await offer in current.exportOfferedEvents {
                    guard !Task.isCancelled else { return }
                    await self.handleExportOffer(offer)
                }
                agent = nil
                while !Task.isCancelled, agent == nil {
                    try? await Task.sleep(for: .seconds(1))
                    let next = await supervisor.developmentGuestAgent
                    if let next, next !== current {
                        agent = next
                    }
                }
            }
            await self.clearFileRelayTasks()
        }
    }

    /// Clears the finished relay tasks so `startFileServices` re-arms.
    private func clearFileRelayTasks() {
        exportRelayTask = nil
        sharedFolderRequestTask?.cancel()
        sharedFolderRequestTask = nil
    }

    /// Ends the file relays.
    func stopFileServices() {
        exportRelayTask?.cancel()
        exportRelayTask = nil
        sharedFolderRequestTask?.cancel()
        sharedFolderRequestTask = nil
    }

    /// Routes one `ExportFileOffered` event to the session on its display
    /// (§6.3). With no matching session the offer declines at once.
    private func handleExportOffer(_ offer: GPExportFileOffered) async {
        let snapshots = await sessionSnapshotsForIntegrations()
        guard
            let session = snapshots.first(where: {
                $0.displayID == offer.displayID
                    && $0.packageID == offer.sourcePackage
            }),
            case .app(let sessionID) = session.id,
            let package = RuntimePackageID(rawValue: offer.sourcePackage)
        else {
            try? await fileTransferService().exportOffered(
                FileExportOffer(
                    offerID: String(offer.offerID), sessionID: UUID(),
                    sourcePackage: RuntimePackageID(rawValue: offer.sourcePackage)
                        ?? RuntimePackageID(rawValue: "unknown")!,
                    name: offer.name,
                    size: Self.offerSize(offer.size),
                    type: offer.mimeType),
                hasSession: false)
            return
        }
        try? await fileTransferService().exportOffered(
            FileExportOffer(
                offerID: String(offer.offerID), sessionID: sessionID,
                sourcePackage: package, name: offer.name,
                size: Self.offerSize(offer.size),
                type: offer.mimeType),
            hasSession: true)
    }

    /// `size` of `ExportFileOffered`; the agent sends -1 for an unknown
    /// size, which decodes as `UInt64.max`.
    private static func offerSize(_ size: UInt64) -> Int64? {
        size > 0 && size <= UInt64(Int64.max) ? Int64(size) : nil
    }

    /// Consumes `agentRequests` of the session's bulk channel and answers
    /// each through ``SharedFolderService`` (§7.5). At most 16 requests run
    /// concurrently; the channel caps it transport-side too.
    private func startSharedFolderRequestLoop(agent: DevelopmentGuestAgent) async {
        sharedFolderRequestTask?.cancel()
        sharedFolderRequestTask = Task.detached { [weak self] in
            guard let self else { return }
            do {
                let channel = try await self.clipboardBulkChannel()
                let budget = RequestBudget(limit: 16)
                for await (id, request) in channel.agentRequests {
                    guard !Task.isCancelled else { return }
                    await budget.acquire()
                    Task {
                        await self.answerSharedFolderRequest(
                            id: id, request: request, channel: channel)
                        await budget.release()
                    }
                }
            } catch {
                // Channel closed; the relay restarts on the next agent.
            }
        }
    }

    /// Maps one `Host*` request to its service call and replies with the
    /// response payload or `GPGuestError` (§7.5).
    private func answerSharedFolderRequest(
        id: UInt64, request: GPRequest, channel: GuestBulkChannel
    ) async {
        let service = sharedFolderService()
        var result: GPResponse.OneOf_Result
        do {
            switch request.op {
            case .hostListRoots(let op):
                let roots = try await service.listRoots(
                    package: packageID(op.package))
                var list = GPRootList()
                list.roots = roots.map { Self.rootInfo($0) }
                result = .hostListRoots(list)
            case .hostQueryChildren(let op):
                let page = try await service.queryChildren(
                    package: packageID(op.package), rootID: op.rootID,
                    path: op.path, pageToken: op.pageToken)
                var gpPage = GPDocPage()
                gpPage.entries = page.entries.map { Self.docInfo($0) }
                gpPage.nextPageToken = page.nextPageToken
                result = .hostQueryChildren(gpPage)
            case .hostStat(let op):
                let info = try await service.stat(
                    package: packageID(op.package), rootID: op.rootID, path: op.path)
                result = .hostStat(Self.docInfo(info))
            case .hostOpenFile(let op):
                let mode = try Self.openMode(op.mode)
                let (handle, size) = try await service.openFile(
                    package: packageID(op.package), rootID: op.rootID,
                    path: op.path, mode: mode)
                var opened = GPOpenFile()
                opened.handle = handle
                opened.size = UInt64(max(0, size))
                result = .hostOpenFile(opened)
            case .hostReadRange(let op):
                let data = try await service.readRange(
                    handle: op.handle, offset: Int64(op.offset), length: Int(op.length))
                var range = GPReadRangeResult()
                range.data = data
                result = .hostReadRange(range)
            case .hostWriteRange(let op):
                try await service.writeRange(
                    handle: op.handle, offset: Int64(op.offset), data: op.data)
                result = .hostWriteRange(GPEmpty())
            case .hostCloseFile(let op):
                try await service.closeFile(handle: op.handle, fsync: op.fsync)
                result = .hostCloseFile(GPEmpty())
            case .hostCreateDocument(let op):
                let info = try await service.createDocument(
                    package: packageID(op.package), rootID: op.rootID,
                    parentPath: op.parentPath, name: op.name,
                    isDirectory: op.isDir)
                result = .hostCreateDocument(Self.docInfo(info))
            case .hostDeleteDocument(let op):
                try await service.deleteDocument(
                    package: packageID(op.package), rootID: op.rootID, path: op.path)
                result = .hostDeleteDocument(GPEmpty())
            case .hostRenameDocument(let op):
                let info = try await service.renameDocument(
                    package: packageID(op.package), rootID: op.rootID,
                    path: op.path, newName: op.newName)
                result = .hostRenameDocument(Self.docInfo(info))
            default:
                var error = GPGuestError()
                error.code = .invalidArgument
                error.message = "not a shared-folder request"
                result = .error(error)
            }
        } catch let failure as SharedFolderFailure {
            var error = GPGuestError()
            error.code = Self.guestErrorCode(failure.code)
            error.message = failure.failure?.localizedDescription ?? failure.code.rawValue
            result = .error(error)
        } catch {
            var error = GPGuestError()
            error.code = .internal
            result = .error(error)
        }
        try? await channel.respond(replyTo: id, result: result)
    }

    private func packageID(_ raw: String) -> RuntimePackageID {
        RuntimePackageID(rawValue: raw) ?? RuntimePackageID(rawValue: "invalid")!
    }

    // MARK: Conversions

    private static func rootInfo(_ info: SharedRootInfo) -> GPRootInfo {
        var gp = GPRootInfo()
        gp.rootID = info.rootID
        gp.title = info.title
        gp.access = info.access == .readWrite ? .readWrite : .readOnly
        gp.available = info.available
        gp.bytesFree = UInt64(max(0, info.bytesFree))
        return gp
    }

    private static func docInfo(_ info: SharedDocInfo) -> GPDocInfo {
        var gp = GPDocInfo()
        gp.path = info.path
        gp.name = info.name
        gp.isDir = info.isDirectory
        gp.size = UInt64(max(0, info.size))
        gp.mtimeMs = info.mtimeMilliseconds
        gp.mimeType = info.mimeType
        return gp
    }

    private static func openMode(_ mode: GPOpenMode) throws(SharedFolderFailure)
        -> SharedOpenMode
    {
        switch mode {
        case .read: return .read
        case .write: return .write
        case .readWrite: return .readWrite
        case .truncate: return .truncate
        default: throw SharedFolderFailure(.invalidArgument)
        }
    }

    private static func guestErrorCode(_ code: SharedFolderFailure.Code) -> GPGuestErrorCode {
        switch code {
        case .invalidArgument: return .invalidArgument
        case .notFound: return .notFound
        case .permissionDenied: return .permissionDenied
        case .unavailable: return .unavailable
        case .resourceExhausted: return .resourceExhausted
        case .internal: return .internal
        }
    }

    /// The session snapshots for display/package resolution.
    func sessionSnapshotsForIntegrations() async -> [AppSessionSnapshot] {
        await sessionServiceForIntegrations()?.sessionSnapshots() ?? []
    }
}
