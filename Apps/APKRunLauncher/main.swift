import AppKit
import Foundation
import RuntimeClient

/// `dataRoot/settings.json` → `developer.enabled` (configuration.md §1.2). The
/// frame-statistics menu item exists only in developer mode (#71).
private struct LauncherSettings {
    static var developerEnabled: Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/APKRun/settings.json")
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let developer = object["developer"] as? [String: Any]
        else {
            return false
        }
        return developer["enabled"] as? Bool ?? false
    }
}

/// Polls `frameStatistics` once a second and presents fps / dropped /
/// readbacks (diagnostics.md §9.3, #71).
@MainActor
private final class FrameStatisticsController {
    private var panel: NSPanel?
    private var field: NSTextField?
    private var timer: Timer?

    func toggle() {
        if panel != nil {
            hide()
        } else {
            show()
        }
    }

    var isVisible: Bool { panel != nil }

    private func show() {
        let field = NSTextField(labelWithString: "frame statistics: —")
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.translatesAutoresizingMaskIntoConstraints = false
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 44),
            styleMask: [.titled, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = LauncherStrings.text("Frame Statistics")
        panel.isFloatingPanel = true
        panel.level = .floating
        guard let contentView = panel.contentView else { return }
        contentView.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: 12),
            field.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        panel.orderFront(nil)
        self.panel = panel
        self.field = field
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task { await poll() }
    }

    private func hide() {
        timer?.invalidate()
        timer = nil
        panel?.close()
        panel = nil
        field = nil
    }

    private func poll() async {
        guard let field else { return }
        do {
            let client = try RuntimeControlClient(clientKind: .launcher)
            let sessions = try await client.frameStatistics()
            guard !sessions.isEmpty else {
                field.stringValue = LauncherStrings.text("no app session")
                return
            }
            field.stringValue = sessions.map { session in
                let display = session.displayID.map { " d\($0)" } ?? ""
                return String(
                    format: "%@%@: %.0f fps, dropped %llu, readbacks %llu",
                    session.packageID.rawValue, display, session.fps,
                    session.droppedFrames, session.hostReadbacks)
            }.joined(separator: "   ")
        } catch {
            field.stringValue = LauncherStrings.text("frameStatistics: \(error.localizedDescription)")
        }
    }
}

@MainActor
private final class LauncherAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var bootstrapInstall: BootstrapInstallController?
    private var notificationPoster: NotificationPoster?
    private let frameStatistics = FrameStatisticsController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "Quit APKRun Launcher", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        if LauncherSettings.developerEnabled {
            viewMenu.addItem(
                withTitle: "Show Frame Statistics",
                action: #selector(toggleFrameStatistics(_:)),
                keyEquivalent: ""
            )
            .target = self
        }
        // Help > Report a Problem… opens the app's diagnostics report sheet
        // (diagnostics.md §8.5); the URL only opens the sheet.
        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpItem.submenu = helpMenu
        helpMenu.addItem(
            withTitle: "Report a Problem…",
            action: #selector(openProblemReport(_:)),
            keyEquivalent: ""
        )
        .target = self

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = LauncherStrings.text("APKRun Launcher")
        window.center()
        window.contentView = NSView()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        // TODO(#45): install a ClipboardController once the launcher owns a
        // session window (WrapperIdentity + openSession); the session window is
        // built by #45.
        let bootstrapInstall = BootstrapInstallController()
        self.bootstrapInstall = bootstrapInstall
        // Foreground launchers relay notifications on a regular (not
        // background) slot; the app keeps running when the stream ends.
        if let client = try? RuntimeControlClient(
            clientKind: .wrapper, claimedIdentity: nil)
        {
            let poster = NotificationPoster(client: client, background: false)
            notificationPoster = poster
            Task { await poster.run() }
        }
        Task {
            // Screen N: `openSession` on an uninstalled portable package
            // returns `packageNotInstalled`; the launcher offers the bundled
            // install and then repeats `openSession` (retried by #45).
            _ = await bootstrapInstall.offerInstall()
        }
    }

    @objc private func openProblemReport(_ sender: NSMenuItem) {
        var components = URLComponents(string: "apkrun://report")
        if let packageID = bootstrapInstall?.bundledPackageID {
            components?.queryItems = [
                URLQueryItem(name: "package", value: packageID)
            ]
        }
        if let url = components?.url {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleFrameStatistics(_ sender: NSMenuItem) {
        frameStatistics.toggle()
        sender.title =
            frameStatistics.isVisible
            ? "Hide Frame Statistics" : "Show Frame Statistics"
    }
}

/// `--apkrun-background notifications` (wrapper.md §5.8): apkrund starts the
/// wrapper only to relay Android notifications. `.accessory` is set before a
/// Dock tile appears, no window or menu is created, and the app quits 30 s
/// after the last delivered notification.
@MainActor
private final class BackgroundNotificationDelegate: NSObject, NSApplicationDelegate {
    private var poster: NotificationPoster?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The wrapper claims its own bundle ID; the generic launcher claims
        // the mapped ID of `--package <id>` (wrapper.md §5.2 step 1).
        var claimedIdentity: String? = nil
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--package"),
            arguments.indices.contains(index + 1)
        {
            claimedIdentity = LauncherBundleIDMapper.map(arguments[index + 1])
        }
        let client: RuntimeControlClient
        do {
            client = try RuntimeControlClient(
                clientKind: .wrapper, claimedIdentity: claimedIdentity)
        } catch {
            NSApp.terminate(nil)
            return
        }
        let poster = NotificationPoster(client: client)
        self.poster = poster
        Task { await poster.run() }
    }
}

let application = NSApplication.shared
private let launchArguments = ProcessInfo.processInfo.arguments
private let backgroundNotifications =
    launchArguments.firstIndex(of: "--apkrun-background").map {
        launchArguments.indices.contains($0 + 1) ? launchArguments[$0 + 1] : ""
    } == "notifications"
private let launcherDelegate: LauncherAppDelegate = MainActor.assumeIsolated {
    LauncherAppDelegate()
}
private let backgroundDelegate: BackgroundNotificationDelegate = MainActor.assumeIsolated {
    BackgroundNotificationDelegate()
}
application.delegate = backgroundNotifications ? backgroundDelegate : launcherDelegate
application.run()
