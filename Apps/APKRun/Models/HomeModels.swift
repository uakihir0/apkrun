import Foundation
import RuntimeAPI
import RuntimeClient
import SwiftUI

/// The managed and unmanaged package inventory (host-ui.md §5.1, §5.4).
@MainActor
@Observable
final class PackageListModel: TopicPollingModel {
    private(set) var managed: [RuntimePackageSummary] = []
    private(set) var other: [RuntimePackageSummary] = []
    /// Icon PNGs by package, filled lazily as rows appear.
    private(set) var icons: [RuntimePackageID: Data] = [:]

    init(
        makeService: @escaping @Sendable () throws -> any RuntimeService = {
            try RuntimeControlClient(clientKind: .app)
        }
    ) {
        super.init(topics: [.packages, .sessions], makeService: makeService)
    }

    /// Reloads the full inventory. `filter: .all` covers both managed and
    /// other Android apps in one round trip (host-ui.md §5.4).
    override func reload() async {
        do {
            let list = try await requireService().listPackages(filter: .all)
            managed = list.packages.filter(\.managed)
            other = list.packages.filter { !$0.managed }
            markReachable()
        } catch {
            markUnreachable(error)
        }
    }

    /// The composed Mac icon for a row; fetched once per package.
    func icon(for packageID: RuntimePackageID) -> Data? {
        icons[packageID]
    }

    /// Fetches and caches the icon of one package (host-ui.md §5.3).
    func loadIcon(for packageID: RuntimePackageID) async {
        guard icons[packageID] == nil else { return }
        guard let png = try? await requireService().packageIcon(packageID: packageID) else { return }
        icons[packageID] = png
    }

    /// **Open** (host-ui.md §5.3): the registered valid wrapper if there is
    /// one, else the generic launcher — the daemon decides.
    func open(packageID: RuntimePackageID) async {
        _ = try? await requireService().launch(RuntimeLaunchRequest(packageID: packageID))
    }

    /// **Manage with APKRun** on an unmanaged row (host-ui.md §5.4).
    func adopt(packageID: RuntimePackageID) async {
        _ = try? await requireService().adoptPackage(
            RuntimeAdoptPackageRequest(packageID: packageID))
        await reload()
    }
}

/// Per-package update state and history (host-ui.md §5.1 Updates section).
@MainActor
@Observable
final class UpdatesModel: TopicPollingModel {
    private(set) var updates: [RuntimePackageID: PackageUpdateStatus] = [:]
    /// The newest update-history outcome per package ("failed", "rolledBack…").
    private(set) var lastOutcomes: [RuntimePackageID: UpdateHistoryEntry] = [:]

    /// The sidebar badge: available, waiting, or failed updates (§5.1).
    var badgeCount: Int {
        updates.values.filter { status in
            status.candidate != nil || !status.waiting.isEmpty
                || Self.isFailed(status.lastOutcome(in: lastOutcomes))
        }.count
    }

    init(
        makeService: @escaping @Sendable () throws -> any RuntimeService = {
            try RuntimeControlClient(clientKind: .app)
        }
    ) {
        super.init(topics: [.updates], makeService: makeService)
    }

    override func reload() async {
        do {
            let service = try requireService()
            let list = try await service.listUpdates()
            updates = Dictionary(uniqueKeysWithValues: list.map { ($0.packageID, $0) })
            let history = try await service.updateHistory(packageID: nil, limit: 50)
            var outcomes: [RuntimePackageID: UpdateHistoryEntry] = [:]
            for entry in history where outcomes[entry.packageID] == nil {
                outcomes[entry.packageID] = entry
            }
            lastOutcomes = outcomes
            markReachable()
        } catch {
            markUnreachable(error)
        }
    }

    /// **Update Now** (§5.3).
    func updateNow(packageID: RuntimePackageID) async {
        _ = try? await requireService().updatePackage(packageID: packageID)
        await reload()
    }

    /// **Check for Updates** from the context menu (§5.3).
    func checkForUpdates(packageID: RuntimePackageID) async {
        _ = try? await requireService().checkForUpdates(packages: [packageID])
        await reload()
    }

    /// Whether the newest history outcome is a failure kind (§5.3 row 3).
    nonisolated static func isFailed(_ entry: UpdateHistoryEntry?) -> Bool {
        guard let outcome = entry?.outcome else { return false }
        return entry?.failure != nil
            || outcome.hasPrefix("failed")
            || outcome.hasPrefix("rolledBack")
            || outcome.hasPrefix("skipped")
    }
}

extension PackageUpdateStatus {
    /// The newest history outcome recorded for this package.
    func lastOutcome(in outcomes: [RuntimePackageID: UpdateHistoryEntry]) -> UpdateHistoryEntry? {
        outcomes[packageID]
    }
}

/// Live app sessions; the runtime header's "‹N› apps running" (§5.2).
@MainActor
@Observable
final class SessionsModel: TopicPollingModel {
    private(set) var sessions: [WireSessionSummary] = []

    /// Sessions on screen or still taking input (§5.2).
    var runningCount: Int {
        sessions.filter { $0.phase == .running || $0.phase == .backgrounded }.count
    }

    /// The phase of a package's session, when one runs.
    func phase(for packageID: RuntimePackageID) -> WireSessionPhase? {
        sessions.first(where: { $0.packageID == packageID })?.phase
    }

    init(
        makeService: @escaping @Sendable () throws -> any RuntimeService = {
            try RuntimeControlClient(clientKind: .app)
        }
    ) {
        super.init(topics: [.sessions], makeService: makeService)
    }

    override func reload() async {
        do {
            sessions = try await requireService().listSessions()
            markReachable()
        } catch {
            markUnreachable(error)
        }
    }
}

/// The toolbar's operation indicator (§5.1).
@MainActor
@Observable
final class OperationCenter: TopicPollingModel {
    private(set) var operations: [OperationSnapshot] = []

    /// Operations still running.
    var active: [OperationSnapshot] {
        operations.filter { $0.result == nil }
    }

    init(
        makeService: @escaping @Sendable () throws -> any RuntimeService = {
            try RuntimeControlClient(clientKind: .app)
        }
    ) {
        super.init(topics: [.operations], makeService: makeService)
    }

    override func reload() async {
        do {
            operations = try await requireService().listOperations()
            markReachable()
        } catch {
            markUnreachable(error)
        }
    }
}

/// The wrapper check rows of wrapper.md §9.1; reloads on a 60 s timer while
/// the window is key and on `wrappers` topic events (host-ui.md §5.3 row 6).
@MainActor
@Observable
final class WrapperListModel: TopicPollingModel {
    private(set) var entries: [RuntimePackageID: WrapperListEntryWire] = [:]

    init(
        makeService: @escaping @Sendable () throws -> any RuntimeService = {
            try RuntimeControlClient(clientKind: .app)
        }
    ) {
        super.init(topics: [.wrappers], makeService: makeService)
    }

    override func reload() async {
        do {
            let list = try await requireService().listWrappers()
            entries = Dictionary(
                uniqueKeysWithValues: list.map { ($0.summary.packageID, $0) })
            markReachable()
        } catch {
            markUnreachable(error)
        }
    }

    /// The row's wrapper entry, when the package has a registered wrapper.
    func entry(for packageID: RuntimePackageID) -> WrapperListEntryWire? {
        entries[packageID]
    }

    /// **Update Mac App** (§5.3 row 7) / **Create Mac App** (row 6).
    func refreshWrapper(packageID: RuntimePackageID) async {
        _ = try? await requireService().refreshWrapper(packageID: packageID)
        invalidateService()
        await reload()
    }
}

/// The sidebar sections of the main window (host-ui.md §5.1).
enum HomeSection: String, Hashable, CaseIterable {
    case apps = "Apps"
    case updates = "Updates"
    case other = "Other Android Apps"
}

/// The row sort orders of the toolbar's sort menu (§5.1).
enum HomeSort: String, CaseIterable {
    case name = "Name"
    case recentlyUsed = "Recently Used"
    case recentlyUpdated = "Recently Updated"
}

/// The shared home-screen state: the models of §5.2 plus the router.
@MainActor
@Observable
final class HomeModel {
    let packages: PackageListModel
    let updates: UpdatesModel
    let sessions: SessionsModel
    let operations: OperationCenter
    let wrappers: WrapperListModel
    let runtimeStatus: RuntimeStatusModel

    /// The sidebar selection; `apkrun://` routes land here.
    var selection: HomeSection = .apps
    /// The package a `package/<id>` route selects, or an "isn't installed" id.
    var selectedPackage: RuntimePackageID?
    var missingPackageID: String?
    /// The ImportPreview a drop or Add App… shows (full add flow is #79).
    var pendingImport: RuntimeImportPreview?
    /// Settings pane a `settings/<pane>` route asks for.
    var requestedSettingsPane: String?
    /// A refused drop's message (§5.5).
    var dropError: String?

    private let serviceFactory: @Sendable () throws -> any RuntimeService

    init(
        makeService: @escaping @Sendable () throws -> any RuntimeService = {
            try RuntimeControlClient(clientKind: .app)
        }
    ) {
        serviceFactory = makeService
        packages = PackageListModel(makeService: makeService)
        updates = UpdatesModel(makeService: makeService)
        sessions = SessionsModel(makeService: makeService)
        operations = OperationCenter(makeService: makeService)
        wrappers = WrapperListModel(makeService: makeService)
        runtimeStatus = RuntimeStatusModel()
    }

    /// Starts every model's loop; the views call this from `.task`.
    func start() {
        packages.start()
        updates.start()
        sessions.start()
        operations.start()
        wrappers.start()
        runtimeStatus.start()
    }

    /// Whether the unreachable-service banner shows (§5.2 Restart Service).
    var serviceUnreachable: Bool {
        packages.serviceUnreachable && runtimeStatus.status == nil
            && runtimeStatus.lastError != nil
    }

    /// Applies an `apkrun://` route. URLs only navigate (§3.1).
    func apply(_ route: AppRoute) {
        switch route {
        case .home:
            selection = .apps
        case .updates:
            selection = .updates
        case .package(let packageID, _):
            selection = .apps
            if packages.managed.contains(where: { $0.packageID == packageID }) {
                selectedPackage = packageID
                missingPackageID = nil
            } else {
                missingPackageID = packageID.rawValue
            }
        case .settings(let pane):
            requestedSettingsPane = pane
        case .setup:
            selection = .apps
        }
    }

    /// **Restart Service** on the unreachable banner: relaunch apkrund via
    /// SMAppService and reconnect every model.
    func restartService() {
        packages.invalidateService()
        updates.invalidateService()
        sessions.invalidateService()
        operations.invalidateService()
        wrappers.invalidateService()
        Task {
            await packages.reload()
            await updates.reload()
            await sessions.reload()
            await operations.reload()
            await wrappers.reload()
            await runtimeStatus.refresh()
        }
    }

    /// Imports dropped or picked files and shows the preview summary (§5.5);
    /// the real add sheet is #79.
    func importFiles(_ urls: [URL]) {
        let allowed: Set<String> = ["apk", "apks", "xapk", "apkm"]
        let supported = urls.filter { allowed.contains($0.pathExtension.lowercased()) }
        guard !supported.isEmpty else {
            dropError = "APKRun can add .apk, .apks, .xapk, and .apkm files."
            return
        }
        do {
            let handles = try supported.map { try FileHandle(forReadingFrom: $0) }
            let sources = handles.enumerated().map {
                RuntimeImportSourceFile(fileIndex: $0.offset, name: supported[$0.offset].lastPathComponent)
            }
            let request = RuntimeImportPackageRequest(files: sources, origin: .dropOnHome)
            Task {
                do {
                    let preview = try await serviceFactory().importPackage(request, files: handles)
                    pendingImport = preview
                } catch {
                    dropError = error.localizedDescription
                }
                for handle in handles {
                    try? handle.close()
                }
            }
        } catch {
            dropError = error.localizedDescription
        }
    }

    /// Discards a preview the user dismissed.
    func discardPendingImport() {
        guard let ticket = pendingImport?.ticket else { return }
        pendingImport = nil
        Task { try? await serviceFactory().discardImport(RuntimeDiscardImportRequest(ticket: ticket)) }
    }
}
