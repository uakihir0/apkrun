import Foundation
import RuntimeAPI
import RuntimeClient

/// The app page's model (host-ui.md §2.2, §7): the package record, its
/// resolved `settings.json`, integration status, update state, history, and
/// wrapper row. Every control writes at once through
/// `updatePackageSettings`; there is no Save button.
@Observable
@MainActor
final class PackageDetailModel {
    /// The sections of the app page; `rawValue` is the `apkrun://` route
    /// name (host-ui.md §3.1, §7).
    enum PageSection: String, CaseIterable, Identifiable {
        case general
        case window
        case input
        case integrations
        case updates
        case macApp = "mac-app"
        case storage

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .window: "Window"
            case .input: "Input"
            case .integrations: "Integrations"
            case .updates: "Updates"
            case .macApp: "Mac App"
            case .storage: "Storage"
            }
        }
    }

    let packageID: RuntimePackageID
    var section: PageSection

    private(set) var details: RuntimePackageDetails?
    private(set) var settings: PackageSettingsWire?
    private(set) var integrations: IntegrationStatus?
    private(set) var updateStatus: PackageUpdateStatus?
    private(set) var history: [UpdateHistoryEntry] = []
    private(set) var wrapper: WrapperListEntryWire?
    private(set) var runningSession: WireSessionSummary?
    private(set) var icon: Data?
    private(set) var loadError: String?
    var busy = false

    /// The confirmation the **Updated by** → `external` choice asks first
    /// (§7.5, update-system.md §2.1).
    var confirmExternalAuthority = false
    var confirmRollback = false
    var showsUninstall = false
    var showsRepair = false
    /// Set briefly after a write to a next-session key (§7).
    private(set) var appliesNextOpenNotice = false

    private let serviceFactory: @Sendable () throws -> any RuntimeService

    init(
        packageID: RuntimePackageID,
        section: PageSection = .general,
        makeService: @escaping @Sendable () throws -> any RuntimeService = {
            try RuntimeControlClient(clientKind: .app)
        }
    ) {
        self.packageID = packageID
        self.section = section
        serviceFactory = makeService
    }

    private func service() throws -> any RuntimeService { try serviceFactory() }

    var displayName: String {
        details?.summary.displayName ?? packageID.rawValue
    }

    var running: Bool {
        guard let phase = runningSession?.phase else { return false }
        return phase == .running || phase == .backgrounded
    }

    /// Loads every field the page shows (§2.2).
    func load() async {
        do {
            async let detailsResult = service().packageInfo(packageID: packageID)
            async let settingsResult = service().packageSettings(packageID)
            async let integrationsResult = service().integrationStatus(packageID: packageID)
            async let historyResult = service().updateHistory(packageID: packageID, limit: 5)
            async let updatesResult = service().listUpdates()
            async let wrappersResult = service().listWrappers()
            async let sessionsResult = service().listSessions()
            async let iconResult = service().packageIcon(packageID: packageID)
            details = try await detailsResult
            settings = try await settingsResult
            integrations = try await integrationsResult
            history = (try await historyResult)
            updateStatus = try await updatesResult.first { $0.packageID == packageID }
            wrapper = try await wrappersResult.first {
                $0.summary.packageID == packageID
            }
            runningSession = try await sessionsResult.first {
                $0.packageID == packageID
            }
            icon = try await iconResult
            loadError = nil
        } catch {
            loadError = Self.describe(error)
        }
    }

    /// The resolved row of a `settings.json` key.
    func entry(_ key: String) -> PackageSettingWire? {
        settings?.entries.first { $0.key == key }
    }

    /// The effective value of a key (`""` before the settings arrive).
    func value(_ key: String) -> String {
        entry(key)?.value ?? ""
    }

    /// Whether the key's effective value is a compatibility recommendation
    /// ("Recommended for this app", §7).
    func isRecommended(_ key: String) -> Bool {
        entry(key)?.source == "recommended"
    }

    /// Whether the key has a stored user value **Reset** can clear.
    func isCustomized(_ key: String) -> Bool {
        entry(key)?.stored != nil
    }

    /// Writes one key (§7: at once, no Save button).
    func set(_ key: String, _ value: String) {
        applyPatch(set: [key: value], clear: [])
    }

    /// **Reset** one key to its recommendation or default (§7).
    func reset(_ key: String) {
        applyPatch(set: [:], clear: [key])
    }

    private func applyPatch(set: [String: String], clear: [String]) {
        busy = true
        Task {
            do {
                settings = try await service().updatePackageSettings(
                    packageID,
                    patch: RuntimePackageSettingsPatch(set: set, clear: clear))
                let changed = Set(set.keys).union(clear)
                appliesNextOpenNotice =
                    settings?.entries.contains {
                        changed.contains($0.key) && !$0.appliesLive
                    } ?? false
            } catch {
                loadError = Self.describe(error)
            }
            busy = false
        }
    }

    /// **Open** launches the app (§7 header).
    func open() {
        Task {
            do {
                _ = try await service().launch(RuntimeLaunchRequest(packageID: packageID))
            } catch {
                loadError = Self.describe(error)
            }
        }
    }

    /// **Update Now** (§7 header, §7.5): installs the ready update.
    func updateNow() {
        Task {
            do {
                _ = try await service().updatePackage(packageID: packageID)
            } catch {
                loadError = Self.describe(error)
            }
        }
    }

    /// **Check Now** / **Check for Updates** (§7.5, §7 header menu): runs a
    /// check only; installing stays with **Update Now**.
    func checkNow() {
        Task {
            do {
                _ = try await service().checkForUpdates(packages: [packageID])
            } catch {
                loadError = Self.describe(error)
            }
        }
    }

    /// The authority the **Updated by** picker shows (§7.5): `apkrun` and
    /// `manual` read as **APKRun**; `googlePlay` is a read-only row.
    var displayedAuthority: AuthorityChoice {
        switch updateStatus?.authority {
        case "external": .external
        case "googlePlay": .googlePlay
        default: .apkrun
        }
    }

    /// **Updated by** → **Another app store in Android** asks first (§7.5).
    func pickAuthority(_ choice: AuthorityChoice) {
        if choice == .external, displayedAuthority != .external {
            confirmExternalAuthority = true
            return
        }
        Task {
            do {
                updateStatus = try await service().setUpdateAuthority(
                    packageID: packageID, authority: choice)
            } catch {
                loadError = Self.describe(error)
            }
        }
    }

    func confirmExternal() {
        confirmExternalAuthority = false
        Task {
            do {
                updateStatus = try await service().setUpdateAuthority(
                    packageID: packageID, authority: .external)
            } catch {
                loadError = Self.describe(error)
            }
        }
    }

    /// The update mode (`automatic`/`notifyOnly`) writes `update.mode` and
    /// the record's authority and provider together (§7.5).
    func setMode(_ choice: UpdateChoice) {
        Task {
            do {
                updateStatus = try await service().setUpdatePolicy(
                    packageID: packageID, policy: UpdatePolicy(choice: choice))
            } catch {
                loadError = Self.describe(error)
            }
        }
    }

    /// **Roll Back to ‹version›…** (§7.5).
    func rollback() {
        confirmRollback = false
        Task {
            do {
                _ = try await service().rollbackPackage(
                    packageID: packageID, allowDataLoss: false)
            } catch {
                loadError = Self.describe(error)
            }
        }
    }

    /// Pending §7.1 edits applied by the next **Update Mac App**.
    var pendingDisplayName: String?
    /// A picked custom icon file for the next **Update Mac App**.
    var pendingIconFile: FileHandle?
    /// **Android Icon** drops a custom icon on the next **Update Mac App**.
    var pendingAndroidIcon = false
    /// **Rename…** opens the name dialog (GeneralSection).
    var showsRename = false
    /// The dialog's edit buffer.
    var renameText = ""

    /// **Update Mac App** = `refreshWrapper` (§7.6), carrying the pending
    /// §7.1 name/icon edit when one is staged.
    func refreshWrapper() {
        let change = WrapperRefreshWire(
            displayName: pendingDisplayName,
            icon: pendingIconFile != nil,
            androidIcon: pendingAndroidIcon)
        let iconFile = pendingIconFile
        Task {
            do {
                _ = try await service().refreshWrapper(
                    packageID: packageID, change: change, iconFile: iconFile)
                pendingDisplayName = nil
                pendingIconFile = nil
                pendingAndroidIcon = false
                wrapper = try await service().listWrappers().first {
                    $0.summary.packageID == packageID
                }
            } catch {
                loadError = Self.describe(error)
            }
        }
    }

    /// **Make Local Mac App** (§7.6): regenerates the portable wrapper as
    /// `kind: local`, dropping `bootstrap/` (wrapper-json.md §3.1).
    func makeLocal() {
        Task {
            do {
                _ = try await service().refreshWrapper(
                    packageID: packageID,
                    change: WrapperRefreshWire(makeLocal: true),
                    iconFile: nil)
                wrapper = try await service().listWrappers().first {
                    $0.summary.packageID == packageID
                }
            } catch {
                loadError = Self.describe(error)
            }
        }
    }

    func createWrapper() {
        Task {
            do {
                _ = try await service().createWrapper(packageID: packageID)
            } catch {
                loadError = Self.describe(error)
            }
        }
    }

    func removeWrapper() {
        Task {
            do {
                _ = try await service().removeWrapper(packageID: packageID, trash: true)
                wrapper = nil
            } catch {
                loadError = Self.describe(error)
            }
        }
    }

    /// **Repair…** for a broken package (§7.7).
    func repair() {
        showsRepair = false
        Task {
            do {
                _ = try await service().repairPackage(packageID: packageID)
            } catch {
                loadError = Self.describe(error)
            }
        }
    }

    /// **Remove from APKRun** forgets a broken package (§7.7).
    func forget() {
        uninstall(RuntimeUninstallOptions(keepData: false, trashWrappers: false, forget: true))
    }

    func uninstall(_ options: RuntimeUninstallOptions) {
        showsUninstall = false
        Task {
            do {
                _ = try await service().beginUninstallPackage(
                    RuntimeUninstallPackageRequest(packageID: packageID, options: options),
                    operationID: OperationID())
            } catch {
                loadError = Self.describe(error)
            }
        }
    }

    /// A byte count as the §7.1/§7.7 size row shows it.
    static func sizeText(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func describe(_ error: any Error) -> String {
        if let wire = error as? RuntimeWireError {
            return wire.remediation.map { "\(wire.message) \($0)" } ?? wire.message
        }
        if let client = error as? RuntimeControlClientError {
            if case .remoteFailure(_, let message, _) = client { return message }
            return "APKRun's background service couldn't answer."
        }
        return error.localizedDescription
    }
}
