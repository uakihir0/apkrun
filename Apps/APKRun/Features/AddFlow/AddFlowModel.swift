import DiagnosticsCore
import Foundation
import RuntimeAPI
import RuntimeClient

/// Where the new Mac app goes (host-ui.md §6.1 Create Mac app row).
enum AddFlowLocation: String, CaseIterable {
    /// `~/Applications` ("Applications (for me)").
    case userApplications
    /// `/Applications` ("Applications (all users)", admins only).
    case allApplications
    /// A Save-panel choice ("Other…").
    case other
}

/// The sheet's stage (host-ui.md §6).
enum AddFlowStage: Equatable {
    /// `importPackage` is running.
    case inspecting
    /// The §6.1 review stage.
    case review
    /// `installImported` is running (§6.2).
    case installing
    /// The install finished; **Open ‹App›** and **Done** show.
    case installed
    /// A failure with the catalog message.
    case failed(String)
}

/// The add flow's model: one drag, one double-click, or **Add App…** opens
/// it; it previews, then installs (host-ui.md §6).
@MainActor
@Observable
final class AddFlowModel {
    /// Whether the sheet is presented.
    var isPresented = false
    private(set) var stage: AddFlowStage = .inspecting
    private(set) var preview: RuntimeImportPreview?
    /// The **Install**-side error, kept for **Try Again** (§6.2).
    private(set) var installError: String?
    /// A wrapper failure after a successful install (§6.2).
    private(set) var wrapperError: String?
    /// The token of a `wrapper.destinationNotAccessible` failure; while set,
    /// the sheet offers **Choose Another Location…** (wrapper.md §6.3).
    private(set) var wrapperStagingToken: String?

    // Review-stage controls.
    var updateChoice: UpdateChoice = .manual
    var createMacApp = true
    var macAppName = ""
    var location: AddFlowLocation = .userApplications
    /// The directory **Other…** picked (wrapper.md §6.3).
    var customDirectoryURL: URL?
    /// `wrappers.defaultLocation` (#80 controls it; `ask` leaves unselected).
    var defaultLocation: AddFlowLocation = .userApplications

    /// Detected provider suggestion; stays off until the user turns it on
    /// (update-system.md §4.7). Nil when the host detected none.
    private(set) var suggestedProvider: ProviderSpec?

    /// Whether a Mac app already exists for the inspected package. A
    /// reinstall or update never regenerates one (AGENTS.md §4 invariant 13); the row
    /// is offered again only when the previous one is gone.
    private(set) var hasMacApp = false

    /// Whether the sheet offers **Create Mac app** (host-ui.md §6.1). Only a
    /// fresh or uninspected package may create one; an existing Mac app is
    /// never regenerated or moved by an update (AGENTS.md §4 invariant 13).
    var showsMacAppRow: Bool {
        guard let preview else { return false }
        switch preview.relation {
        case .newPackage, .unknown:
            return true
        default:
            return !hasMacApp
        }
    }

    /// Whether the installed app can be launched from the sheet.
    private(set) var installedPackageID: RuntimePackageID?

    private let serviceFactory: @Sendable () throws -> any RuntimeService

    init(
        makeService: @escaping @Sendable () throws -> any RuntimeService = {
            try RuntimeControlClient(clientKind: .app)
        }
    ) {
        serviceFactory = makeService
    }

    /// The file extensions the add flow accepts (host-ui.md §3.2).
    static let acceptedExtensions: Set<String> = ["apk", "apks", "xapk", "apkm"]

    /// Begins an import from dropped or opened files. File handles, never
    /// paths (package-store.md §4.1).
    func begin(urls: [URL], origin: RuntimeImportOrigin = .addFlow) {
        let supported = urls.filter {
            Self.acceptedExtensions.contains($0.pathExtension.lowercased())
        }
        isPresented = true
        guard !supported.isEmpty else {
            stage = .failed("APKRun can add .apk, .apks, .xapk, and .apkm files.")
            return
        }
        stage = .inspecting
        preview = nil
        installError = nil
        wrapperError = nil
        wrapperStagingToken = nil
        installedPackageID = nil
        hasMacApp = false
        Task { await inspect(supported, origin: origin) }
    }

    private func inspect(_ urls: [URL], origin: RuntimeImportOrigin) async {
        do {
            let handles = try urls.map { url -> FileHandle in
                _ = url.startAccessingSecurityScopedResource()
                return try FileHandle(forReadingFrom: url)
            }
            defer {
                for (index, handle) in handles.enumerated() {
                    try? handle.close()
                    urls[index].stopAccessingSecurityScopedResource()
                }
            }
            let sources = handles.enumerated().map {
                RuntimeImportSourceFile(
                    fileIndex: $0.offset, name: urls[$0.offset].lastPathComponent)
            }
            let request = RuntimeImportPackageRequest(files: sources, origin: origin)
            let preview = try await serviceFactory().importPackage(request, files: handles)
            self.preview = preview
            let globals = try? await serviceFactory()
                .getConfig(keys: ["wrappers.defaultLocation"])
            if let configured = globals?["wrappers.defaultLocation"] {
                defaultLocation = Self.location(for: configured)
            }
            // A list failure stays conservative: only a fresh or uninspected
            // package offers Create Mac app without a confirmed empty list
            // (wrapper.md §9.1, AGENTS.md §4 invariant 13).
            if let wrappers = try? await serviceFactory().listWrappers() {
                hasMacApp = wrappers.contains { $0.summary.packageID == preview.packageID }
            } else {
                hasMacApp = true
            }
            macAppName = preview.displayName
            // §4.7: the host's suggestion stays off until the user turns it on.
            suggestedProvider = preview.suggestedProvider.map { ProviderSpec(spec: $0) }
            location = defaultLocation
            stage = .review
        } catch {
            stage = .failed(Self.describe(error))
        }
    }

    /// Feeds a preview into the review stage without file IO (T0 tests).
    func inspectForTesting(
        _ preview: RuntimeImportPreview, hasMacApp: Bool = false
    ) async {
        self.preview = preview
        self.hasMacApp = hasMacApp
        macAppName = preview.displayName
        location = defaultLocation
        stage = .review
    }

    /// **Install** / **Reinstall** / **Update** (§6.2).
    func install() {
        guard let preview else { return }
        stage = .installing
        installError = nil
        // §6.1: without an update source only Manual is enabled.
        if suggestedProvider == nil { updateChoice = .manual }
        let authority: RuntimeUpdateAuthority = updateChoice == .manual ? .manual : .apkrun
        let options = RuntimeInstallOptions(
            authority: authority,
            createWrapper: false,
            provider: suggestedProvider,
            updateMode: updateChoice)
        Task { await runInstall(ticket: preview.ticket, options: options) }
    }

    /// Retries the wrapper step after a `wrapperError` (§6.2).
    func retryWrapper() {
        guard let packageID = installedPackageID else { return }
        stage = .installing
        wrapperError = nil
        wrapperStagingToken = nil
        Task { await runWrapper(packageID: packageID) }
    }

    /// **Choose Another Location…**: the user picks a directory this process
    /// can reach, moves the staged bundle there, and finishes with
    /// `placeStagedWrapper` (wrapper.md §6.3).
    func placeStagedWrapper(at directory: URL) {
        guard let token = wrapperStagingToken else { return }
        stage = .installing
        wrapperError = nil
        Task { await runPlaceStaged(token: token, directory: directory) }
    }

    private func runPlaceStaged(token: String, directory: URL) async {
        do {
            _ = directory.startAccessingSecurityScopedResource()
            defer { directory.stopAccessingSecurityScopedResource() }
            let service = try serviceFactory()
            let finalURL = try Self.placeStagedBundle(token: token, in: directory)
            let bookmark = try? finalURL.bookmarkData()
            _ = try await service.placeStagedWrapper(
                stagingToken: token,
                finalURL: finalURL,
                bookmark: bookmark?.base64EncodedString())
            wrapperStagingToken = nil
            stage = .installed
        } catch {
            wrapperError = Self.describe(error)
            stage = .installed
        }
    }

    private func runInstall(
        ticket: RuntimeImportTicket, options: RuntimeInstallOptions
    ) async {
        do {
            let service = try serviceFactory()
            let operationID = RuntimeAPI.OperationID()
            let handle = try await service.beginInstallImported(
                RuntimeInstallImportedRequest(ticket: ticket, options: options),
                operationID: operationID)
            let snapshot = try await Self.awaitTerminal(handle.operationID, using: service)
            guard case .succeeded(.package(let summary))? = snapshot.result else {
                if case .failed(let failure)? = snapshot.result { throw failure }
                throw RuntimeWireError(
                    domain: "runtime",
                    code: "runtime.unknownResult",
                    message: "The install finished without a result.",
                    remediation: "Try again. Report the operation ID if it keeps happening.",
                    parameters: ["operationID": operationID.rawValue.uuidString])
            }
            installedPackageID = summary.packageID
            if createMacApp && showsMacAppRow {
                await runWrapper(packageID: summary.packageID)
            } else {
                stage = .installed
            }
        } catch {
            installError = Self.describe(error)
            stage = .review
        }
    }

    /// The `wrapperCreate` operation with the sheet's name and location
    /// (host-ui.md §6.2 "Creating Mac app…").
    private func runWrapper(packageID: RuntimePackageID) async {
        do {
            let service = try serviceFactory()
            let name = macAppName.trimmingCharacters(in: .whitespaces)
            let request = WrapperRequest(
                packageID: packageID,
                destination: wireDestination,
                fileName: name.isEmpty ? nil : name,
                displayName: name.isEmpty ? nil : name,
                replace: .sameWrapper)
            let handle = try await service.createWrapper(request)
            let snapshot = try await Self.awaitTerminal(handle.operationID, using: service)
            switch snapshot.result {
            case .succeeded:
                stage = .installed
            case .failed(let failure):
                if failure.code == "wrapper.destinationNotAccessible",
                    let token = failure.parameters["stagingToken"]
                {
                    wrapperStagingToken = token
                }
                wrapperError = Self.describe(failure)
                stage = .installed
            default:
                wrapperError = nil
                stage = .installed
            }
        } catch {
            wrapperError = Self.describe(error)
            stage = .installed
        }
    }

    /// Maps `wrappers.defaultLocation` to a picker value (configuration.md
    /// §2.10); `ask` leaves the picker on the first choice, which the sheet
    /// still requires the user to confirm.
    static func location(for configured: String) -> AddFlowLocation {
        configured == "allUsersApplications" ? .allApplications : .userApplications
    }

    /// The `WrapperRequest` destination for the chosen location.
    private var wireDestination: WireWrapperDestination? {
        switch location {
        case .userApplications: .userApplications
        case .allApplications: .applications
        case .other:
            customDirectoryURL.map { .directory($0) } ?? .userApplications
        }
    }

    /// Moves the staged `.app` into a directory the user picked (the same
    /// path `Wrap.placeStaged` takes for the CLI, wrapper.md §6.3): a temp
    /// name in the destination folder, then an atomic swap. A conflicting
    /// item is replaced only when it is this package's own wrapper.
    private static func placeStagedBundle(token: String, in directory: URL) throws -> URL {
        let stagingDir = APKRunPaths().wrapperStagingDirectory
            .appendingPathComponent(token, isDirectory: true)
        let stagedBundles =
            (try? FileManager.default.contentsOfDirectory(
                at: stagingDir, includingPropertiesForKeys: nil
            ))?.filter { $0.pathExtension == "app" } ?? []
        guard let stagedBundle = stagedBundles.first else {
            throw RuntimeWireError(
                domain: "wrapper",
                code: "wrapper.destinationNotAccessible",
                message: "The staged Mac app is no longer waiting to be placed.")
        }
        let finalURL = directory.appendingPathComponent(
            stagedBundle.lastPathComponent, isDirectory: true)
        let fileManager = FileManager.default
        let destinationExists = fileManager.fileExists(atPath: finalURL.path)
        if destinationExists {
            let existingPackage = plistPackageID(of: finalURL)
            guard existingPackage != nil,
                existingPackage == plistPackageID(of: stagedBundle)
            else {
                throw RuntimeWireError(
                    domain: "wrapper",
                    code: "wrapper.nameConflict",
                    message: "An item named \(finalURL.lastPathComponent) already exists there.",
                    remediation: "Choose another name or location. APKRun never replaces it.",
                    parameters: ["file": finalURL.lastPathComponent])
            }
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(
            ".\(finalURL.lastPathComponent).apkrun-\(UUID().uuidString)",
            isDirectory: true)
        try fileManager.moveItem(at: stagedBundle, to: temp)
        do {
            if destinationExists {
                _ = try fileManager.replaceItemAt(finalURL, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: finalURL)
            }
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
        return finalURL
    }

    /// Reads `APKRunPackageID` from a bundle's Info.plist; nil means the item
    /// is not an APKRun wrapper (or is unreadable).
    private static func plistPackageID(of bundle: URL) -> String? {
        let plistURL = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
            let plist = try? PropertyListSerialization.propertyList(
                from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["APKRunPackageID"] as? String
    }

    /// Polls an operation until its snapshot carries a terminal result.
    private static func awaitTerminal(
        _ operationID: RuntimeAPI.OperationID, using service: any RuntimeService
    ) async throws -> OperationSnapshot {
        while !Task.isCancelled {
            let snapshot = try await service.operationStatus(operationID)
            if snapshot.result != nil { return snapshot }
            try await Task.sleep(for: .milliseconds(300))
        }
        throw CancellationError()
    }

    /// **Done** / dismiss: discards the ticket and closes the sheet. Work in
    /// progress keeps running in the operation center (§6.2).
    func dismiss() {
        if let ticket = preview?.ticket, stage != .installed {
            Task {
                try? await serviceFactory().discardImport(
                    RuntimeDiscardImportRequest(ticket: ticket))
            }
        }
        isPresented = false
        preview = nil
        installError = nil
        wrapperError = nil
        wrapperStagingToken = nil
        installedPackageID = nil
        hasMacApp = false
    }

    /// **Open ‹App›** on the installed stage.
    func openInstalled() {
        guard let packageID = installedPackageID else { return }
        Task {
            _ = try? await serviceFactory().launch(
                RuntimeLaunchRequest(packageID: packageID))
        }
    }

    /// A user-facing message for a typed failure.
    static func describe(_ error: any Error) -> String {
        if let wire = error as? RuntimeWireError {
            if let remediation = wire.remediation {
                return "\(wire.message) \(remediation)"
            }
            return wire.message
        }
        return error.localizedDescription
    }
}

/// The §6.1 relation sheet text and button.
struct AddFlowSheet: Equatable {
    /// The sentence above the controls; nil for `newPackage`'s full review.
    var headline: String?
    /// The primary action's label; nil means only **Done**.
    var action: String?
    /// Whether the review controls (updates, Mac app) show.
    var showsOptions: Bool

    /// Maps an `ImportRelation` to its sheet (host-ui.md §6.1 table).
    init(relation: RuntimeImportRelation, displayName: String, version: String) {
        switch relation {
        case .newPackage, .unknown:
            headline = nil
            action = "Install"
            showsOptions = true
        case .sameAsInstalled:
            headline = "\(displayName) \(version) is already installed."
            action = nil
            showsOptions = false
        case .reinstallSameVersion:
            headline = "Reinstall \(displayName) \(version)?"
            action = "Reinstall"
            showsOptions = true
        case .update(let from):
            headline = "Update \(displayName) from \(from) to \(version)?"
            action = "Update"
            showsOptions = true
        case .downgrade(let from):
            headline =
                "\(displayName) \(version) is older than the installed \(from)."
            action = nil
            showsOptions = false
        case .otherSigner:
            headline =
                "\(displayName) is signed by a different developer than the installed copy."
            action = nil
            showsOptions = false
        case .uninstalledWithData(let version):
            headline = "Reinstall \(displayName) and restore its data?"
            action = "Reinstall"
            showsOptions = true
            _ = version
        }
    }
}
