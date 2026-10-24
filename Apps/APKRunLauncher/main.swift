import AppKit
import DiagnosticsCore
import Dispatch
import RuntimeAPI
import RuntimeClient
import WindowingCore

@MainActor
private final class LauncherAppDelegate: NSObject, NSApplicationDelegate {
    private let processStart = DispatchTime.now().uptimeNanoseconds
    private let logger = APKLogger(category: WrapperLogCategory.launcher)
    private var runtimeClient: RuntimeControlClient?
    private var session: RuntimeOpenedSession?
    private var frameSource: XPCFrameSource?
    private var windowController: SessionWindowController?
    private var messagesTask: Task<Void, Never>?
    private var closeRequestsTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var sessionRequest: OpenSessionRequest?
    private var sessionPackageName: String?
    private var userClosedWindow = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { [weak self] in
            await self?.openPackageSession()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func openPackageSession() async {
        do {
            guard let packageID = Self.packageID(from: ProcessInfo.processInfo.arguments) else {
                throw LauncherStartupError.invalidPackageArgument
            }
            let client = try RuntimeControlClient(clientKind: .launcher)
            runtimeClient = client
            _ = try await client.connect()

            let packageName =
                (try? await client.packageInfo(packageID: packageID).summary.displayName)
                ?? packageID.rawValue
            let screen = NSScreen.main ?? NSScreen.screens.first
            let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 900)
            let pointSize = Self.initialPointSize(in: visibleFrame.size)
            let backingScale = Double(screen?.backingScaleFactor ?? 1)
            let requestSent = DispatchTime.now().uptimeNanoseconds
            let request = OpenSessionRequest(
                header: APIRequestHeader(clientKind: .launcher),
                packageID: packageID,
                geometry: DisplayGeometry(
                    pointSize: DisplayPointSize(width: pointSize.width, height: pointSize.height),
                    backingScale: backingScale,
                    zoom: 1
                ),
                screenSize: DisplayPointSize(width: visibleFrame.width, height: visibleFrame.height),
                launchTiming: LaunchTiming(processStart: processStart, requestSent: requestSent)
            )
            let openedSession = try await client.openSession(request)
            sessionRequest = request
            sessionPackageName = packageName
            userClosedWindow = false
            try installSession(openedSession, packageName: packageName, backingScale: CGFloat(backingScale))
            logger.notice("Opened Android app window")
        } catch {
            logger.error("Could not open Android app window")
            let alert = NSAlert()
            alert.messageText = "Couldn’t Open Android App"
            alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    private func installSession(
        _ openedSession: RuntimeOpenedSession,
        packageName: String,
        backingScale: CGFloat
    ) throws {
        let source = try XPCFrameSource(
            descriptor: openedSession.descriptor,
            surfaces: openedSession.surfaces,
            onFrameDisplayed: { [weak openedSession] message in
                openedSession?.frameDisplayed(message)
            },
            onVisibilityChanged: { [weak openedSession] message in
                openedSession?.visibilityChanged(message)
            }
        )
        let window = SessionWindowController(
            source: source,
            title: packageName,
            backingScale: backingScale,
            allowsResize: openedSession.descriptor.windowPrefs.resizable,
            onGeometryChanged: { [weak openedSession] pointSize, scale, zoom, completion in
                guard let openedSession else {
                    completion(.rejected)
                    return
                }
                let geometry = DisplayGeometry(
                    pointSize: DisplayPointSize(width: pointSize.width, height: pointSize.height),
                    backingScale: Double(scale),
                    zoom: zoom
                )
                Task { @MainActor in
                    do {
                        let result = try await openedSession.resize(geometry)
                        let outcome: DisplayResizeOutcome =
                            switch result {
                            case .applied: .applied
                            case .unchanged: .unchanged
                            case .rejected: .rejected
                            case .stateUncertain: .stateUncertain
                            }
                        completion(outcome)
                    } catch {
                        completion(.rejected)
                    }
                }
            }
        )
        window.onClose = { [weak self] in
            self?.windowWasClosed()
        }

        let previousWindow = windowController
        previousWindow?.onClose = nil
        session = openedSession
        frameSource = source
        windowController = window
        messagesTask = Task { [weak self, weak openedSession] in
            guard let openedSession else { return }
            for await message in openedSession.messages {
                guard !Task.isCancelled else { return }
                source.receive(message)
            }
            guard !Task.isCancelled else { return }
            self?.sessionStreamEnded(for: window)
        }
        closeRequestsTask = Task { [weak openedSession] in
            guard let openedSession else { return }
            for await closeRequest in openedSession.closeRequests {
                guard !Task.isCancelled else { return }
                window.close()
                closeRequest.acknowledge()
                return
            }
        }
        window.show()
        NSApp.activate(ignoringOtherApps: true)
        previousWindow?.close()
    }

    private func windowWasClosed() {
        userClosedWindow = true
        recoveryTask?.cancel()
        recoveryTask = nil
        messagesTask?.cancel()
        messagesTask = nil
        closeRequestsTask?.cancel()
        closeRequestsTask = nil
        session = nil
        frameSource = nil
        windowController = nil
    }

    private func sessionStreamEnded(for window: SessionWindowController) {
        guard !userClosedWindow, windowController === window else { return }
        window.setTitle("APKRun restarted — reopening…")
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self, weak window] in
            let recoveryStarted = ContinuousClock.now
            var retryDelay = Duration.seconds(1)
            var hasShownFailure = false
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: retryDelay)
                } catch {
                    return
                }
                guard let self, let window, !Task.isCancelled, !self.userClosedWindow,
                    self.windowController === window,
                    let client = self.runtimeClient,
                    let request = self.sessionRequest,
                    let packageName = self.sessionPackageName
                else {
                    return
                }
                do {
                    let reopened = try await client.openSession(request)
                    guard !Task.isCancelled, !self.userClosedWindow, self.windowController === window else {
                        return
                    }
                    try self.installSession(
                        reopened,
                        packageName: packageName,
                        backingScale: CGFloat(request.geometry.backingScale)
                    )
                    self.recoveryTask = nil
                    return
                } catch {
                    retryDelay = min(retryDelay * 2, .seconds(5))
                    if !hasShownFailure, recoveryStarted.duration(to: .now) >= .seconds(15) {
                        window.setTitle("APKRun is still reconnecting…")
                        window.showFailure(
                            message: "APKRun could not reconnect to its background service.",
                            remediation: "Keep this window open while APKRun retries."
                        )
                        hasShownFailure = true
                    }
                }
            }
        }
    }

    private static func packageID(from arguments: [String]) -> RuntimePackageID? {
        guard let flag = arguments.firstIndex(of: "--package"),
            arguments.indices.contains(flag + 1),
            let packageID = RuntimePackageID(rawValue: arguments[flag + 1]),
            arguments[(flag + 2)...].allSatisfy({ $0 != "--package" })
        else {
            return nil
        }
        return packageID
    }

    private static func initialPointSize(in visibleSize: CGSize) -> CGSize {
        CGSize(
            width: min(480, visibleSize.width * 0.9),
            height: min(850, visibleSize.height * 0.9)
        )
    }
}

private enum LauncherStartupError: LocalizedError {
    case invalidPackageArgument

    var errorDescription: String? {
        switch self {
        case .invalidPackageArgument:
            "APKRunLauncher requires --package followed by a valid Android package ID."
        }
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
private let delegate = LauncherAppDelegate()
application.delegate = delegate
application.run()
