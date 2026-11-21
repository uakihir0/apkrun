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

    // Review-stage controls.
    var updateChoice: UpdateChoice = .manual
    var createMacApp = true
    var macAppName = ""
    var location: AddFlowLocation = .userApplications
    /// `wrappers.defaultLocation` (#80 controls it; `ask` leaves unselected).
    var defaultLocation: AddFlowLocation = .userApplications

    /// Detected provider suggestion; stays off until the user turns it on
    /// (update-system.md §4.7). Nil when the host detected none.
    private(set) var suggestedProvider: ProviderSpec?

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
        installedPackageID = nil
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
            macAppName = preview.displayName
            location = defaultLocation
            stage = .review
        } catch {
            stage = .failed(Self.describe(error))
        }
    }

    /// Feeds a preview into the review stage without file IO (T0 tests).
    func inspectForTesting(_ preview: RuntimeImportPreview) async {
        self.preview = preview
        macAppName = preview.displayName
        location = defaultLocation
        stage = .review
    }

    /// **Install** / **Reinstall** / **Update** (§6.2).
    func install() {
        guard let preview else { return }
        stage = .installing
        installError = nil
        let authority: RuntimeUpdateAuthority = updateChoice == .manual ? .manual : .apkrun
        let options = RuntimeInstallOptions(
            authority: authority,
            createWrapper: createMacApp,
            provider: suggestedProvider,
            updateMode: updateChoice)
        Task { await runInstall(ticket: preview.ticket, options: options) }
    }

    private func runInstall(
        ticket: RuntimeImportTicket, options: RuntimeInstallOptions
    ) async {
        do {
            let summary = try await serviceFactory().installImported(
                RuntimeInstallImportedRequest(ticket: ticket, options: options))
            installedPackageID = summary.packageID
            stage = .installed
        } catch {
            installError = Self.describe(error)
            stage = .review
        }
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
        installedPackageID = nil
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
