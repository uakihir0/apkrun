import CoreFoundation
import Darwin
import DiagnosticsCore
import Foundation
import GuestProtocol
import IntegrationCore
import RuntimeAPI

/// Owns persisted shared-folder bookmarks, security scopes, package policy, and the filesystem service.
actor SharedFolderConfigurationService {
    typealias BookmarkResolver = @Sendable (Data) throws -> (url: URL, isStale: Bool)
    typealias BookmarkCreator = @Sendable (URL) throws -> Data
    typealias SecurityScopeStarter = @Sendable (URL) -> Bool
    typealias SecurityScopeStopper = @Sendable (URL) -> Void

    private struct StoredRoot: Equatable {
        var id: String
        var bookmark: Data
        var access: RuntimeAPI.SharedFolderAccess
    }

    private struct ResolvedRoot {
        let url: URL
        let scopeStarted: Bool
        let availability: SharedFolderAvailability
    }

    nonisolated let fileService: SharedFolderService

    private let paths: APKRunPaths
    private let homeDirectory: URL
    private let resolveBookmark: BookmarkResolver
    private let createBookmark: BookmarkCreator
    private let startSecurityScope: SecurityScopeStarter
    private let stopSecurityScope: SecurityScopeStopper
    private var roots: [StoredRoot]
    private var resolvedRoots: [String: ResolvedRoot]
    private var isClosed = false

    private init(
        paths: APKRunPaths,
        homeDirectory: URL,
        resolveBookmark: @escaping BookmarkResolver,
        createBookmark: @escaping BookmarkCreator,
        startSecurityScope: @escaping SecurityScopeStarter,
        stopSecurityScope: @escaping SecurityScopeStopper,
        roots: [StoredRoot],
        resolvedRoots: [String: ResolvedRoot],
        fileService: SharedFolderService
    ) {
        self.paths = paths
        self.homeDirectory = homeDirectory
        self.resolveBookmark = resolveBookmark
        self.createBookmark = createBookmark
        self.startSecurityScope = startSecurityScope
        self.stopSecurityScope = stopSecurityScope
        self.roots = roots
        self.resolvedRoots = resolvedRoots
        self.fileService = fileService
    }

    /// Loads the shared-folder roots and opens their security-scoped URLs.
    static func open(
        paths: APKRunPaths,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        resolveBookmark: @escaping BookmarkResolver = resolveSecurityScopedBookmark,
        createBookmark: @escaping BookmarkCreator = makeSecurityScopedBookmark,
        startSecurityScope: @escaping SecurityScopeStarter = { $0.startAccessingSecurityScopedResource() },
        stopSecurityScope: @escaping SecurityScopeStopper = { $0.stopAccessingSecurityScopedResource() }
    ) async throws -> SharedFolderConfigurationService {
        try FileManager.default.createDirectory(
            at: paths.sharedDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let document = try readSettingsDocument(at: paths.settingsFile)
        var roots = try storedRoots(from: document)
        var resolvedRoots: [String: ResolvedRoot] = [:]

        for index in roots.indices {
            let entry = roots[index]
            let (resolvedURL, isStale) = try resolveBookmark(entry.bookmark)
            let checkedURL = try selectableURL(
                resolvedURL,
                homeDirectory: homeDirectory,
                requireExistingDirectory: false
            )
            let scopeStarted = startSecurityScope(checkedURL)
            let availability = availability(of: checkedURL, scopeStarted: scopeStarted)
            if isStale {
                roots[index].bookmark = try createBookmark(checkedURL)
            }
            resolvedRoots[entry.id] = ResolvedRoot(
                url: checkedURL,
                scopeStarted: scopeStarted,
                availability: availability
            )
        }

        if roots != (try storedRoots(from: document)) {
            try writeSettingsDocument(
                document,
                roots: roots,
                to: paths.settingsFile
            )
        }

        let packageAccess = try readPackageAccess(paths: paths, document: document)
        let definitions = rootDefinitions(
            sharedURL: paths.sharedDirectory,
            roots: roots,
            resolvedRoots: resolvedRoots
        )
        let service = try SharedFolderService(roots: definitions, packageAccess: packageAccess)
        return SharedFolderConfigurationService(
            paths: paths,
            homeDirectory: homeDirectory,
            resolveBookmark: resolveBookmark,
            createBookmark: createBookmark,
            startSecurityScope: startSecurityScope,
            stopSecurityScope: stopSecurityScope,
            roots: roots,
            resolvedRoots: resolvedRoots,
            fileService: service
        )
    }

    /// Lists the configured roots, including roots that are temporarily unavailable.
    func listFolders() throws(RuntimeWireError) -> [SharedFolder] {
        try requireOpen()
        let builtInAvailable = Self.availability(of: paths.sharedDirectory, scopeStarted: true)
        var result = [
            SharedFolder(
                id: "shared",
                name: "Shared",
                path: paths.sharedDirectory.path,
                access: .readWrite,
                builtIn: true,
                availability: builtInAvailable
            )
        ]
        result += roots.compactMap { root in
            guard let resolved = resolvedRoots[root.id] else { return nil }
            return SharedFolder(
                id: root.id,
                name: resolved.url.lastPathComponent,
                path: resolved.url.path,
                access: root.access,
                builtIn: false,
                availability: resolved.availability
            )
        }
        return result
    }

    /// Adds one bookmark selected by a RuntimeAPI client.
    func add(_ request: AddSharedFolderRequest) async throws(RuntimeWireError) -> SharedFolder {
        try requireOpen()
        guard !request.bookmark.isEmpty, request.bookmark.count <= Self.maximumBookmarkBytes else {
            throw Self.malformedRequestError
        }
        guard roots.count < Self.maximumUserRoots else {
            throw Self.wireError(for: .folderRefused(.limitReached, name: "folder"))
        }

        let resolved: (url: URL, isStale: Bool)
        do {
            resolved = try resolveBookmark(request.bookmark)
        } catch {
            throw Self.malformedRequestError
        }
        let selectedURL: URL
        do {
            selectedURL = try Self.selectableURL(
                resolved.url,
                homeDirectory: homeDirectory,
                requireExistingDirectory: true
            )
        } catch let failure as IntegrationFailure {
            throw Self.wireError(for: failure)
        } catch {
            throw Self.malformedRequestError
        }
        guard startSecurityScope(selectedURL) else {
            throw Self.wireError(for: .folderUnavailable(.privacyDenied, name: selectedURL.lastPathComponent))
        }

        let id = UUID().uuidString.lowercased()
        let bookmark: Data
        do {
            bookmark = try createBookmark(selectedURL)
        } catch {
            stopSecurityScope(selectedURL)
            throw Self.malformedRequestError
        }
        let newRoot = StoredRoot(id: id, bookmark: bookmark, access: request.access)
        let candidateRoots = roots + [newRoot]
        var candidateResolved = resolvedRoots
        candidateResolved[id] = ResolvedRoot(
            url: selectedURL,
            scopeStarted: true,
            availability: .available
        )

        do {
            try await persistAndReplaceService(roots: candidateRoots, resolved: candidateResolved)
        } catch let failure as IntegrationFailure {
            stopSecurityScope(selectedURL)
            throw Self.wireError(for: failure)
        } catch {
            try? Self.writeSettingsDocument(
                Self.readSettingsDocument(at: paths.settingsFile),
                roots: roots,
                to: paths.settingsFile
            )
            stopSecurityScope(selectedURL)
            throw Self.settingsUnreadableError
        }
        roots = candidateRoots
        resolvedRoots = candidateResolved
        return SharedFolder(
            id: id,
            name: selectedURL.lastPathComponent,
            path: selectedURL.path,
            access: request.access,
            builtIn: false,
            availability: .available
        )
    }

    /// Removes a user-selected root, stopping its security scope after descriptor replacement.
    func remove(_ id: String) async throws(RuntimeWireError) {
        try requireOpen()
        guard id != "shared", roots.contains(where: { $0.id == id }) else {
            throw Self.malformedRequestError
        }
        let removedRoot = resolvedRoots[id]
        let candidateRoots = roots.filter { $0.id != id }
        var candidateResolved = resolvedRoots
        candidateResolved[id] = nil
        do {
            try await persistAndReplaceService(roots: candidateRoots, resolved: candidateResolved)
        } catch let failure as IntegrationFailure {
            throw Self.wireError(for: failure)
        } catch {
            throw Self.settingsUnreadableError
        }
        roots = candidateRoots
        resolvedRoots = candidateResolved
        if let removedRoot, removedRoot.scopeStarted {
            stopSecurityScope(removedRoot.url)
        }
    }

    /// Changes one user-selected root's maximum access.
    func setAccess(_ request: SetSharedFolderAccessRequest) async throws(RuntimeWireError) -> SharedFolder {
        try requireOpen()
        guard request.id != "shared", let index = roots.firstIndex(where: { $0.id == request.id }),
            let resolved = resolvedRoots[request.id]
        else {
            throw Self.malformedRequestError
        }
        var candidateRoots = roots
        candidateRoots[index].access = request.access
        do {
            try await persistAndReplaceService(roots: candidateRoots, resolved: resolvedRoots)
        } catch let failure as IntegrationFailure {
            throw Self.wireError(for: failure)
        } catch {
            throw Self.settingsUnreadableError
        }
        roots = candidateRoots
        return SharedFolder(
            id: request.id,
            name: resolved.url.lastPathComponent,
            path: resolved.url.path,
            access: request.access,
            builtIn: false,
            availability: resolved.availability
        )
    }

    /// Builds the current package grant list for the guest document provider.
    func guestPolicy() throws(RuntimeWireError) -> (roots: [GPSharedRoot], access: [GPPackageAccess]) {
        try requireOpen()
        do {
            let document = try Self.readSettingsDocument(at: paths.settingsFile)
            let packageAccess = try Self.readPackageAccess(paths: paths, document: document)
            let definitions = Self.rootDefinitions(
                sharedURL: paths.sharedDirectory,
                roots: roots,
                resolvedRoots: resolvedRoots
            )
            let wireRoots = definitions.map { definition in
                var root = GPSharedRoot()
                root.rootID = definition.id
                root.title = definition.title
                root.maxAccess = definition.maximumAccess == .readWrite ? .readWrite : .readOnly
                return root
            }
            let wireAccess = packageAccess.keys.sorted().compactMap { packageID -> GPPackageAccess? in
                guard let byRoot = packageAccess[packageID],
                    let value = byRoot.values.first(where: { $0 != .off })
                else { return nil }
                var access = GPPackageAccess()
                access.package = packageID
                access.access = value == .readWrite ? .readWrite : .readOnly
                return access
            }
            return (wireRoots, wireAccess)
        } catch let failure as IntegrationFailure {
            throw Self.wireError(for: failure)
        } catch {
            throw Self.settingsUnreadableError
        }
    }

    /// Resolves the package settings and current global switches for the RuntimeAPI query.
    func integrationStatus(packageID: RuntimePackageID) throws(RuntimeWireError) -> IntegrationStatus {
        try requireOpen()
        do {
            let document = try Self.readSettingsDocument(at: paths.settingsFile)
            let global = try Self.globalIntegrations(from: document)
            let defaults = try Self.integrationDefaults(from: document)
            let settings = try Self.packageIntegrations(paths: paths, packageID: packageID.rawValue)
            let items = IntegrationKind.allCases.map { kind -> IntegrationItemStatus in
                let key = kind.rawValue
                let defaultValue: JSONValue
                switch kind {
                case .clipboard, .notifications, .files:
                    defaultValue = .bool(true)
                case .links:
                    defaultValue = .string("ask")
                case .sharedFolders:
                    defaultValue = .string("off")
                case .microphone:
                    defaultValue = .bool(false)
                }

                let value = settings[key] ?? defaults[key] ?? defaultValue
                let isEnabled = global[key] ?? true
                let decision = isEnabled ? Self.decision(for: kind, value: value) : .deny(.globallyOff)
                let source: SettingSource
                if settings[key] != nil {
                    source = .user
                } else if defaults[key] != nil, value != defaultValue {
                    source = .recommended
                } else {
                    source = .default
                }
                return IntegrationItemStatus(
                    kind: kind,
                    value: value,
                    source: isEnabled ? source : .globalSwitch,
                    decision: decision,
                    support: .unknown,
                    macPermission: Self.macPermission(for: kind)
                )
            }
            return IntegrationStatus(packageID: packageID, items: items)
        } catch let failure as IntegrationFailure {
            throw Self.wireError(for: failure)
        } catch {
            throw Self.settingsUnreadableError
        }
    }

    /// Closes open file descriptors after Android stops but preserves configured roots for restart.
    func runtimeDidStop() async {
        await fileService.closeAllOpenFiles()
    }

    /// Stops root security scopes and releases the service at daemon shutdown.
    func shutdown() async {
        guard !isClosed else { return }
        isClosed = true
        await fileService.runtimeDidStop()
        for root in resolvedRoots.values where root.scopeStarted {
            stopSecurityScope(root.url)
        }
        resolvedRoots.removeAll()
    }

    private func replaceServiceConfiguration(
        roots: [StoredRoot],
        resolved: [String: ResolvedRoot]
    ) async throws(IntegrationFailure) {
        let document: [String: Any]
        do {
            document = try Self.readSettingsDocument(at: paths.settingsFile)
        } catch {
            throw .settingsUnreadable
        }
        let packageAccess = try Self.readPackageAccess(paths: paths, document: document)
        try await fileService.replaceConfiguration(
            roots: Self.rootDefinitions(sharedURL: paths.sharedDirectory, roots: roots, resolvedRoots: resolved),
            packageAccess: packageAccess
        )
    }

    private func persistAndReplaceService(
        roots candidateRoots: [StoredRoot],
        resolved candidateResolved: [String: ResolvedRoot]
    ) async throws(IntegrationFailure) {
        let originalDocument: [String: Any]
        do {
            originalDocument = try Self.readSettingsDocument(at: paths.settingsFile)
            try Self.writeSettingsDocument(originalDocument, roots: candidateRoots, to: paths.settingsFile)
        } catch {
            throw .settingsUnreadable
        }
        do {
            try await replaceServiceConfiguration(roots: candidateRoots, resolved: candidateResolved)
        } catch {
            do {
                try Self.writeSettingsDocument(originalDocument, roots: roots, to: paths.settingsFile)
            } catch {
                throw .settingsUnreadable
            }
            throw error
        }
    }

    private func requireOpen() throws(RuntimeWireError) {
        guard !isClosed else {
            throw .runtime("hostShuttingDown", message: "APKRun's background service is stopping.")
        }
    }

    private static let maximumUserRoots = 32
    private static let maximumBookmarkBytes = 1_048_576

    private static let malformedRequestError = RuntimeWireError.runtime(
        "malformedRequest",
        message: "APKRun's background service couldn't read the shared-folder request."
    )

    private static let settingsUnreadableError = RuntimeWireError(
        domain: "integration",
        code: "integration.settingsUnreadable",
        message: "APKRun couldn't read the shared-folder settings safely.",
        remediation: "Restart APKRun. If the problem continues, contact support."
    )

    private static func wireError(for failure: IntegrationFailure) -> RuntimeWireError {
        let message: String
        let remediation: String
        switch failure {
        case .folderRefused(let reason, _):
            switch reason {
            case .volumeRoot:
                message = "A volume root can't be shared."
            case .homeFolder:
                message = "The home folder can't be shared."
            case .insideLibrary:
                message = "Folders inside Library can't be shared."
            case .hidden:
                message = "Hidden folders can't be shared."
            case .limitReached:
                message = "APKRun can share up to 32 added folders."
            }
            remediation = "Choose a different folder in Settings → Files."
        case .folderUnavailable(let problem, _):
            switch problem {
            case .missing:
                message = "The selected shared folder is missing."
            case .privacyDenied:
                message = "macOS hasn't granted APKRun access to the selected folder."
            case .offline:
                message = "The selected shared folder's volume is offline."
            }
            remediation = "Choose the folder again or allow APKRun to access it in System Settings."
        case .settingsUnreadable:
            return settingsUnreadableError
        default:
            message = "The shared-folder request couldn't be completed."
            remediation = "Check the Files settings, then retry."
        }
        return RuntimeWireError(
            domain: failure.domain.rawValue,
            code: failure.qualifiedCode,
            message: message,
            remediation: remediation
        )
    }

    private static func rootDefinitions(
        sharedURL: URL,
        roots: [StoredRoot],
        resolvedRoots: [String: ResolvedRoot]
    ) -> [SharedFolderRoot] {
        var definitions = [
            SharedFolderRoot(
                id: "shared",
                title: "Shared",
                directoryURL: sharedURL,
                maximumAccess: .readWrite
            )
        ]
        definitions += roots.compactMap { root in
            guard let resolved = resolvedRoots[root.id] else { return nil }
            return SharedFolderRoot(
                id: root.id,
                title: resolved.url.lastPathComponent,
                directoryURL: resolved.scopeStarted ? resolved.url : unavailableURL(for: root.id),
                maximumAccess: root.access == .readWrite ? .readWrite : .readOnly
            )
        }
        return definitions
    }

    private static func unavailableURL(for rootID: String) -> URL {
        URL(fileURLWithPath: "/dev/null/apkrun-\(rootID)", isDirectory: true)
    }

    private static func selectableURL(
        _ selectedURL: URL,
        homeDirectory: URL,
        requireExistingDirectory: Bool
    ) throws(IntegrationFailure) -> URL {
        let selected = selectedURL.standardizedFileURL
        let resolved = selected.resolvingSymlinksInPath().standardizedFileURL
        let name = resolved.lastPathComponent.isEmpty ? "folder" : resolved.lastPathComponent
        let path = resolved.path
        let home = homeDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let library = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .standardizedFileURL.path

        let components = resolved.pathComponents.filter { $0 != "/" }
        guard !components.contains(where: { $0.hasPrefix(".") }) else {
            throw .folderRefused(.hidden, name: name)
        }
        guard path != home else {
            throw .folderRefused(.homeFolder, name: name)
        }
        guard !Self.isSameOrDescendant(path, of: library) else {
            throw .folderRefused(.insideLibrary, name: name)
        }

        let volumeIsRoot = (try? resolved.resourceValues(forKeys: [.volumeIsRootKey]).volumeIsRoot) ?? false
        guard path != "/", !volumeIsRoot else {
            throw .folderRefused(.volumeRoot, name: name)
        }
        if requireExistingDirectory {
            var info = stat()
            guard lstat(resolved.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
                throw .folderUnavailable(Self.problem(for: errno), name: name)
            }
        }
        return resolved
    }

    private static func isSameOrDescendant(_ path: String, of parent: String) -> Bool {
        path == parent || path.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }

    private static func availability(of url: URL, scopeStarted: Bool) -> SharedFolderAvailability {
        guard scopeStarted else { return .privacyDenied }
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if url.path.hasPrefix("/Volumes/") { return .offline }
            return errno == EACCES ? .privacyDenied : .missing
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return .missing }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == EACCES || errno == EPERM { return .privacyDenied }
            if errno == ENODEV { return .offline }
            return .unknown
        }
        _ = Darwin.close(descriptor)
        return .available
    }

    private static func problem(for error: Int32) -> FolderProblem {
        switch error {
        case EACCES, EPERM:
            .privacyDenied
        case ENODEV:
            .offline
        default:
            .missing
        }
    }

    private static func decision(for kind: IntegrationKind, value: JSONValue) -> WireIntegrationDecision {
        switch kind {
        case .clipboard, .notifications, .files, .microphone:
            if case .bool(true) = value { return .allow }
            return .deny(.packageOff)
        case .sharedFolders:
            if case .string("readOnly") = value { return .allow }
            if case .string("readWrite") = value { return .allow }
            return .deny(.packageOff)
        case .links:
            if case .string("ask") = value { return .ask }
            if case .string("mac") = value { return .allow }
            return .deny(.packageOff)
        }
    }

    private static func macPermission(for kind: IntegrationKind) -> MacPermissionState? {
        switch kind {
        case .notifications, .microphone:
            .unknown
        case .clipboard, .links, .files, .sharedFolders:
            nil
        }
    }

    private static func readSettingsDocument(at url: URL) throws -> [String: Any] {
        guard let data = try readRegularFile(at: url, missingIsEmpty: true) else {
            return ["schemaVersion": 2]
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IntegrationFailure.settingsUnreadable
        }
        return object
    }

    private static func storedRoots(from document: [String: Any]) throws(IntegrationFailure) -> [StoredRoot] {
        guard let rawSharedFolders = document["sharedFolders"] else { return [] }
        guard let sharedFolders = rawSharedFolders as? [String: Any] else {
            throw .settingsUnreadable
        }
        guard let rawRoots = sharedFolders["roots"] else { return [] }
        guard let storedRoots = rawRoots as? [[String: Any]], storedRoots.count <= maximumUserRoots else {
            throw .settingsUnreadable
        }
        var identifiers = Set<String>()
        return try storedRoots.map { root in
            guard let id = root["id"] as? String, let uuid = UUID(uuidString: id),
                id.lowercased() == uuid.uuidString.lowercased(), id != "shared",
                identifiers.insert(id).inserted,
                let base64 = root["bookmark"] as? String, let bookmark = Data(base64Encoded: base64),
                !bookmark.isEmpty, bookmark.count <= maximumBookmarkBytes,
                let accessString = root["access"] as? String,
                let access = RuntimeAPI.SharedFolderAccess(rawValue: accessString)
            else {
                throw .settingsUnreadable
            }
            return StoredRoot(id: id, bookmark: bookmark, access: access)
        }
    }

    private static func readPackageAccess(
        paths: APKRunPaths,
        document: [String: Any]
    ) throws(IntegrationFailure) -> [String: [String: IntegrationCore.SharedFolderAccess]] {
        let global = try globalIntegrations(from: document)
        let defaults = try integrationDefaults(from: document)
        let globalEnabled = global["sharedFolders"] ?? true
        let entries = try packageDirectoryNames(at: paths.packagesDirectory)
        var result: [String: [String: IntegrationCore.SharedFolderAccess]] = [:]
        for packageID in entries {
            let settings = try packageIntegrations(paths: paths, packageID: packageID)
            let policy: IntegrationCore.SharedFolderAccess
            if !globalEnabled {
                policy = .off
            } else {
                switch settings["sharedFolders"] ?? defaults["sharedFolders"] {
                case nil, .string("off"):
                    policy = .off
                case .string("readOnly"):
                    policy = .readOnly
                case .string("readWrite"):
                    policy = .readWrite
                default:
                    throw .settingsUnreadable
                }
            }
            if policy != .off {
                var byRoot: [String: IntegrationCore.SharedFolderAccess] = ["shared": policy]
                for rootID in try storedRoots(from: document).map(\.id) {
                    byRoot[rootID] = policy
                }
                result[packageID] = byRoot
            }
        }
        return result
    }

    private static func globalIntegrations(from document: [String: Any]) throws(IntegrationFailure) -> [String: Bool] {
        guard let rawIntegrations = document["integrations"] else { return [:] }
        guard let integrations = rawIntegrations as? [String: Any] else {
            throw .settingsUnreadable
        }
        guard let rawEnabled = integrations["enabled"] else { return [:] }
        guard let enabled = rawEnabled as? [String: Any] else { throw .settingsUnreadable }
        var values: [String: Bool] = [:]
        for key in IntegrationKind.allCases.map(\.rawValue) {
            guard let rawValue = enabled[key] else { continue }
            guard let value = rawValue as? Bool else { throw .settingsUnreadable }
            values[key] = value
        }
        return values
    }

    private static func integrationDefaults(from document: [String: Any]) throws(IntegrationFailure)
        -> [String: JSONValue]
    {
        guard let rawIntegrations = document["integrations"] else { return [:] }
        guard let integrations = rawIntegrations as? [String: Any] else {
            throw .settingsUnreadable
        }
        guard let rawDefaults = integrations["defaults"] else { return [:] }
        return try parsedIntegrationSettings(rawDefaults)
    }

    private static func packageIntegrations(
        paths: APKRunPaths,
        packageID: String
    ) throws(IntegrationFailure) -> [String: JSONValue] {
        let settingsURL = paths.packageSettingsFile(packageID: packageID)
        guard let data = try readRegularFile(at: settingsURL, missingIsEmpty: true) else { return [:] }
        guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .settingsUnreadable
        }
        guard let rawIntegrations = document["integrations"] else { return [:] }
        return try parsedIntegrationSettings(rawIntegrations)
    }

    private static func parsedIntegrationSettings(_ rawSettings: Any) throws(IntegrationFailure)
        -> [String: JSONValue]
    {
        guard let settings = rawSettings as? [String: Any] else { throw .settingsUnreadable }
        var values: [String: JSONValue] = [:]
        for (key, value) in settings where IntegrationKind(rawValue: key) != nil {
            guard let converted = try? jsonValue(value) else { throw .settingsUnreadable }
            values[key] = converted
        }
        for (key, value) in values {
            let valid: Bool
            switch IntegrationKind(rawValue: key) {
            case .clipboard, .notifications, .files, .microphone:
                if case .bool = value { valid = true } else { valid = false }
            case .links:
                if case .string(let string) = value, ["ask", "mac", "android"].contains(string) {
                    valid = true
                } else {
                    valid = false
                }
            case .sharedFolders:
                if case .string(let string) = value, ["off", "readOnly", "readWrite"].contains(string) {
                    valid = true
                } else {
                    valid = false
                }
            case nil:
                valid = true
            }
            guard valid else { throw .settingsUnreadable }
        }
        return values
    }

    private static func packageDirectoryNames(at directory: URL) throws(IntegrationFailure) -> [String] {
        let descriptor = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return [] }
            throw .settingsUnreadable
        }
        defer { _ = Darwin.close(descriptor) }
        guard let stream = fdopendir(dup(descriptor)) else { throw .settingsUnreadable }
        defer { closedir(stream) }
        var names: [String] = []
        while let rawEntry = readdir(stream) {
            var entry = rawEntry.pointee
            let name = withUnsafePointer(to: &entry.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != "..", !name.hasPrefix("."),
                RuntimePackageID(rawValue: name) != nil
            else {
                continue
            }
            var info = stat()
            guard name.withCString({ fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0,
                (info.st_mode & S_IFMT) == S_IFDIR
            else {
                continue
            }
            names.append(name)
        }
        return names.sorted()
    }

    private static func jsonValue(_ value: Any) throws -> JSONValue {
        if value is NSNull { return .null }
        if let value = value as? String { return .string(value) }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
            let number = value.doubleValue
            guard number.isFinite else { throw IntegrationFailure.settingsUnreadable }
            return .number(number)
        }
        if let value = value as? [Any] { return .array(try value.map(jsonValue)) }
        if let value = value as? [String: Any] {
            return .object(try value.mapValues(jsonValue))
        }
        throw IntegrationFailure.settingsUnreadable
    }

    private static func readRegularFile(at url: URL, missingIsEmpty: Bool) throws -> Data? {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            if errno == ENOENT, missingIsEmpty { return nil }
            throw IntegrationFailure.settingsUnreadable
        }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
            info.st_size >= 0, info.st_size <= 1_048_576
        else {
            throw IntegrationFailure.settingsUnreadable
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw IntegrationFailure.settingsUnreadable }
            offset += count
        }
        return Data(bytes)
    }

    private static func writeSettingsDocument(
        _ original: [String: Any],
        roots: [StoredRoot],
        to url: URL
    ) throws {
        var document = original
        var sharedFolders = document["sharedFolders"] as? [String: Any] ?? [:]
        sharedFolders["roots"] = roots.map { root in
            [
                "id": root.id,
                "bookmark": root.bookmark.base64EncodedString(),
                "access": root.access.rawValue,
            ]
        }
        document["sharedFolders"] = sharedFolders
        if document["schemaVersion"] == nil {
            document["schemaVersion"] = 2
        }
        guard JSONSerialization.isValidJSONObject(document) else {
            throw IntegrationFailure.settingsUnreadable
        }
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".settings-sharedfolders-\(UUID().uuidString)")
        let descriptor = temporaryURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else { throw IntegrationFailure.settingsUnreadable }
        defer {
            _ = Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw IntegrationFailure.settingsUnreadable }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, rename(temporaryURL.path, url.path) == 0 else {
            throw IntegrationFailure.settingsUnreadable
        }
    }

    private static func resolveSecurityScopedBookmark(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }

    private static func makeSecurityScopedBookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }
}
