import AppKit

@MainActor
private final class LauncherAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
}

let application = NSApplication.shared
private let delegate = LauncherAppDelegate()
application.delegate = delegate
application.run()
