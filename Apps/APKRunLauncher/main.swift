import AppKit
import Dispatch
import RuntimeAPI
import RuntimeClient
import WindowingCore

@MainActor
private final class LauncherAppDelegate: NSObject, NSApplicationDelegate {
    private let packageID: RuntimePackageID?
    private let argumentError: String?
    private let processStartNanoseconds = DispatchTime.now().uptimeNanoseconds
    private var controlClient: RuntimeControlClient?
    private var session: RuntimeSessionClient?
    private var inputSink: XPCInputSink?
    private var frameSource: XPCFrameSource?
    private var windowController: SessionWindowController?
    private var visibilityObserver: XPCWindowVisibilityObserver?
    private var isEndingSession = false

    init(arguments: [String]) {
        if arguments.count == 2,
            arguments[0] == "--package",
            let packageID = RuntimePackageID(rawValue: arguments[1])
        {
            self.packageID = packageID
            argumentError = nil
        } else {
            packageID = nil
            argumentError = "Usage: APKRunLauncher --package <android.package.id>"
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let packageID else {
            showLaunchFailure(argumentError ?? "A package ID is required.")
            return
        }

        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.frame.size ?? CGSize(width: 1440, height: 900)
        let visibleFrame = screen?.visibleFrame ?? CGRect(origin: .zero, size: screenFrame)
        let requestedSize = CGSize(
            width: min(480, visibleFrame.width * 0.9),
            height: min(850, visibleFrame.height * 0.9)
        )
        let requestSentNanoseconds = DispatchTime.now().uptimeNanoseconds
        let request = OpenSessionRequest(
            packageID: packageID,
            geometry: SessionDisplayGeometry(
                pointSize: SessionSize(width: requestedSize.width, height: requestedSize.height),
                backingScale: Double(screen?.backingScaleFactor ?? 1),
                zoom: 1
            ),
            screenSize: SessionSize(width: screenFrame.width, height: screenFrame.height),
            launchTiming: SessionLaunchTiming(
                processStart: processStartNanoseconds,
                requestSent: requestSentNanoseconds
            )
        )

        do {
            let client = try RuntimeControlClient(clientKind: .launcher)
            controlClient = client
            Task { [weak self] in
                do {
                    let bootstrap = try await client.openSession(request)
                    guard let self else {
                        bootstrap.session.invalidate()
                        return
                    }
                    self.showSession(bootstrap, packageID: packageID, screen: screen)
                } catch {
                    self?.showLaunchFailure(error.localizedDescription)
                }
            }
        } catch {
            showLaunchFailure(error.localizedDescription)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func showSession(
        _ bootstrap: RuntimeSessionBootstrap,
        packageID: RuntimePackageID,
        screen: NSScreen?
    ) {
        session = bootstrap.session
        guard let source = XPCFrameSource(bootstrap: bootstrap) else {
            Task {
                try? await bootstrap.session.closeSession(policy: .stop)
                bootstrap.session.invalidate()
                showLaunchFailure("The runtime returned an invalid display surface.")
            }
            return
        }
        frameSource = source
        let inputSink = XPCInputSink(
            session: bootstrap.session,
            inputPrefs: bootstrap.descriptor.inputPrefs
        )
        self.inputSink = inputSink
        let controller = SessionWindowController(
            source: source,
            title: packageID.rawValue,
            backingScale: CGFloat(screen?.backingScaleFactor ?? 1),
            inputSink: inputSink,
            allowsResize: false,
            onFocusChanged: { [weak inputSink] focused in
                inputSink?.focusChanged(focused)
            }
        )
        windowController = controller
        let visibilityObserver = XPCWindowVisibilityObserver(
            windowTitle: packageID.rawValue,
            session: bootstrap.session
        )
        self.visibilityObserver = visibilityObserver
        source.onSessionInvalidated = { [weak self] in
            self?.windowController?.close()
        }
        controller.onClose = { [weak self] in
            self?.endSession()
        }
        controller.show()
        visibilityObserver.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func endSession() {
        guard !isEndingSession else { return }
        isEndingSession = true
        visibilityObserver?.stop()
        visibilityObserver = nil
        frameSource?.stop()
        frameSource = nil
        inputSink = nil
        let closingSession = session
        session = nil
        windowController = nil
        guard let closingSession else {
            NSApp.terminate(nil)
            return
        }
        Task {
            try? await closingSession.closeSession(policy: .stop)
            closingSession.invalidate()
            NSApp.terminate(nil)
        }
    }

    private func showLaunchFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Unable to open Android app"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
        NSApp.terminate(nil)
    }
}

let application = NSApplication.shared
private let delegate = LauncherAppDelegate(arguments: Array(CommandLine.arguments.dropFirst()))
application.delegate = delegate
application.run()
