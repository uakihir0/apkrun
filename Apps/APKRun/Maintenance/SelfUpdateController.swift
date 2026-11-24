import AppKit
import RuntimeAPI
import RuntimeClient
import Sparkle

/// Owns Sparkle for APKRun.app (runtime-maintenance.md §3.2). Settings are
/// the source of truth: `maintenance.checkAutomatically`,
/// `maintenance.installAPKRunAutomatically`, and `maintenance.channel` are
/// applied at start and on every `configurationChanged` that carries a
/// `maintenance.*` key. Sparkle's own UserDefaults are never read back.
@MainActor
final class SelfUpdateController: NSObject {
    /// The one controller for the process (§3.2).
    static let shared = SelfUpdateController()

    /// The Settings pane's status line and Check Now button read this.
    let status = SelfUpdateModel()

    /// Sparkle is created lazily by `start`; nil in development builds.
    private var updaterController: SPUStandardUpdaterController?
    private let delegate = SelfUpdateDelegate()
    private let coordinator = UpdateInstallCoordinator()

    private let settings: () async throws -> [String: String]
    private let makeControl: () throws -> RuntimeControlClient
    private var eventsTask: Task<Void, Never>?

    init(
        settings: (@Sendable () async throws -> [String: String])? = nil,
        makeControl: (() throws -> RuntimeControlClient)? = nil
    ) {
        self.makeControl = makeControl ?? { try RuntimeControlClient(clientKind: .app) }
        self.settings =
            settings ?? {
                try await RuntimeControlClient(clientKind: .app).getConfig(keys: nil)
            }
        super.init()
        delegate.installCoordinator = coordinator
        delegate.status = status
        delegate.noteToDaemon = { [weak self] note in
            await self?.noteToDaemon(note)
        }
    }

    /// Whether this build carries a feed (Release builds only; §3.2's
    /// development-build paragraph).
    static var feedAvailable: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String != nil
    }

    /// Starts Sparkle. No-op without `SUFeedURL` or on `--notify` /
    /// approval-only launches (§3.2, host-ui.md §3.3).
    func start() {
        let arguments = CommandLine.arguments.dropFirst()
        guard Self.feedAvailable,
            !arguments.contains("--notify"),
            !arguments.contains("--approve")
        else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil)
        updaterController = controller
        Task { await applySettings() }
        watchConfigurationChanges()
    }

    /// The Settings pane's Check Now button (§3.2).
    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    /// Applies the `maintenance.*` settings to Sparkle (§3.2's source-of-
    /// truth paragraph).
    func applySettings() async {
        guard let values = try? await settings() else { return }
        applySettings(values: values)
    }

    /// The pure settings → Sparkle mapping (T0 seam: SelfUpdateSettings).
    func applySettings(values: [String: String]) {
        let mapped = SelfUpdateSettings(values: values)
        updaterController?.updater.automaticallyChecksForUpdates =
            mapped.checkAutomatically
        updaterController?.updater.automaticallyDownloadsUpdates =
            mapped.downloadAutomatically
        delegate.allowedChannels = mapped.allowedChannels
    }

    /// Re-applies settings when a `configurationChanged` with a
    /// `maintenance.*` key arrives on the runtime topic (configuration.md
    /// §2.6's "live" annotation).
    private func watchConfigurationChanges() {
        eventsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let client = try? makeControl(),
                    let stream = try? await client.subscribe(to: .runtime)
                else {
                    try? await Task.sleep(for: .seconds(10))
                    continue
                }
                for await envelope in stream {
                    if Task.isCancelled { return }
                    if case .runtime(let change) = envelope.payload,
                        case .configurationChanged(let keys) = change,
                        keys.contains(where: { $0.hasPrefix("maintenance.") })
                    {
                        await self.applySettings()
                    }
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Reports Sparkle's result to apkrund so the menu bar and CLI see the
    /// same status (§3.2, runtime-api.md §12.2).
    private func noteToDaemon(_ note: SelfUpdateNoteDraft) async {
        guard let client = try? makeControl() else { return }
        try? await client.noteSelfUpdateStatus(
            found: note.found,
            pendingOnQuit: note.pendingOnQuit,
            checkedAt: note.checkedAt)
    }
}

/// What the delegate asks the controller to forward to apkrund.
struct SelfUpdateNoteDraft: Sendable {
    let found: AvailableRelease?
    let pendingOnQuit: Bool
    let checkedAt: Date
}

/// `SPUUpdaterDelegate` for §3.2's delegate table. Kept a separate NSObject
/// so tests can drive it without a running app.
@MainActor
final class SelfUpdateDelegate: NSObject, SPUUpdaterDelegate {
    /// `SelfUpdateSettings.allowedChannels` (§3.2's delegate table).
    var allowedChannels: Set<String> = []
    /// The §3.5 handshake runner.
    weak var installCoordinator: UpdateInstallCoordinator?
    /// The Settings pane model.
    var status: SelfUpdateModel?
    /// Forwarded to `noteSelfUpdateStatus` by the controller.
    var noteToDaemon: (@MainActor (SelfUpdateNoteDraft) async -> Void)?

    /// §3.2: `["beta"]` when `maintenance.channel == beta`, else empty.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        allowedChannels
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let release = Self.release(from: item)
        status?.foundUpdate(release)
        let draft = SelfUpdateNoteDraft(
            found: release, pendingOnQuit: false, checkedAt: Date())
        Task { await noteToDaemon?(draft) }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        status?.checked(found: nil)
        let draft = SelfUpdateNoteDraft(
            found: nil, pendingOnQuit: false, checkedAt: Date())
        Task { await noteToDaemon?(draft) }
    }

    /// §3.5: hold Sparkle's install block and run the handshake.
    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        let release = Self.release(from: item)
        Task { @MainActor [weak self] in
            await self?.installCoordinator?.beginInstall(
                release: release, installHandler: installHandler)
        }
        return true
    }

    /// §3.2: an automatic update installs on quit. Settings shows it and
    /// apkrund is told through `pendingOnQuit`.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let release = Self.release(from: item)
        status?.pendingOnQuit(release)
        installCoordinator?.notePendingOnQuit(release)
        status?.installNowHandler = { [weak self] in
            Task { @MainActor in
                await self?.installCoordinator?.beginInstall(
                    release: release, installHandler: immediateInstallHandler)
            }
        }
        let draft = SelfUpdateNoteDraft(
            found: release, pendingOnQuit: true, checkedAt: Date())
        Task { await noteToDaemon?(draft) }
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        status?.checked(found: nil)
        Task { @MainActor [weak self] in
            // A marker may already exist; abort is idempotent (§3.2).
            await self?.installCoordinator?.abortPendingHostUpdate()
        }
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        status?.checked(found: nil)
        Task { @MainActor [weak self] in
            await self?.installCoordinator?.abortPendingHostUpdate()
        }
    }

    /// `SUAppcastItem` → `AvailableRelease` (runtime-api.md §12.2).
    static func release(from item: SUAppcastItem) -> AvailableRelease {
        AvailableRelease(
            version: item.displayVersionString,
            build: Int(item.versionString) ?? 0,
            channel: item.channel,
            minimumSystemVersion: item.minimumSystemVersion,
            releaseNotesURL: item.releaseNotesURL?.absoluteString,
            publishedAt: item.date)
    }
}
