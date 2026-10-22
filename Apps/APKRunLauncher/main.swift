import AppKit
import RuntimeAPI
import RuntimeClient

@MainActor
private final class LauncherAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let statusLabel = NSTextField(labelWithString: "Connecting to APKRun…")
    private let packageLabel = NSTextField(labelWithString: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "APKRun Launcher"
        window.center()
        let contentView = NSStackView(views: [statusLabel, packageLabel])
        contentView.orientation = .vertical
        contentView.alignment = .leading
        contentView.spacing = 12
        contentView.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        self.window = window
        Task {
            await connectToRuntime()
        }
    }

    private func connectToRuntime() async {
        do {
            let client = try RuntimeControlClient(clientKind: .launcher)
            let status = try await client.runtimeStatus()
            statusLabel.stringValue = "Android runtime: \(status.runtimeState)"

            guard let packageID = requestedPackageID() else {
                return
            }
            let package = try await client.packageInfo(packageID: packageID)
            packageLabel.stringValue = package.summary.displayName
        } catch {
            statusLabel.stringValue = error.localizedDescription
        }
    }

    private func requestedPackageID() -> RuntimePackageID? {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let optionIndex = arguments.firstIndex(of: "--package"),
            arguments.indices.contains(optionIndex + 1)
        else {
            return nil
        }
        return RuntimePackageID(rawValue: arguments[optionIndex + 1])
    }
}

let application = NSApplication.shared
private let delegate = LauncherAppDelegate()
application.delegate = delegate
application.run()
