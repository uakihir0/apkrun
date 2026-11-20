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
        panel.title = "Frame Statistics"
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
                field.stringValue = "no app session"
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
            field.stringValue = "frameStatistics: \(error.localizedDescription)"
        }
    }
}

@MainActor
private final class LauncherAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
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

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "APKRun Launcher"
        window.center()
        window.contentView = NSView()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    @objc private func toggleFrameStatistics(_ sender: NSMenuItem) {
        frameStatistics.toggle()
        sender.title =
            frameStatistics.isVisible
            ? "Hide Frame Statistics" : "Show Frame Statistics"
    }
}

let application = NSApplication.shared
private let delegate: LauncherAppDelegate = MainActor.assumeIsolated {
    LauncherAppDelegate()
}
application.delegate = delegate
application.run()
