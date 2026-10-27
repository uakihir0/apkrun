import AppKit
import DiagnosticsCore
import Dispatch
import RuntimeAPI
import RuntimeClient
import WindowingCore

@MainActor
private final class LauncherAppDelegate: NSObject, NSApplicationDelegate {
    private let processStart = LauncherProcessTiming.processStartContinuousNanoseconds()
    private let logger = APKLogger(category: WrapperLogCategory.launcher)
    private var runtimeClient: RuntimeControlClient?
    private var identity: LauncherIdentity?
    private var packageDetails: RuntimePackageDetails?
    private var session: RuntimeOpenedSession?
    private var frameSource: XPCFrameSource?
    private var windowController: SessionWindowController?
    private var statusWindowController: LauncherStatusWindowController?
    private var aboutWindowController: LauncherAboutWindowController?
    private var restoredWindowContentSize: CGSize?
    private var runtimeVersion: String?
    private var messagesTask: Task<Void, Never>?
    private var closeRequestsTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var startingFeedbackTask: Task<Void, Never>?
    private var closeSessionTask: Task<Void, Never>?
    private var closeSessionDeadlineTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var sessionRequest: OpenSessionRequest?
    private var sessionPackageName: String?
    private var userClosedWindow = false
    private var isStarting = false
    private var isClosingSession = false
    private var isRestartingSession = false
    private var pendingTerminationReply = false
    private weak var windowToCloseAfterSession: SessionWindowController?
    private var isLoadingAboutDetails = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        LauncherMenus.install(
            appName: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "APKRun",
            showAbout: { [weak self] in self?.showAbout() },
            showInAPKRun: { [weak self] in self?.openAPKRun(for: self?.identity?.packageID) },
            openSettings: { [weak self] in self?.openAPKRunURL("apkrun://settings/general") },
            closeWindow: { [weak self] in self?.windowController?.performClose() },
            restartApp: { [weak self] in self?.restartApp() },
            canRestartApp: {
                [weak self] in
                self?.session != nil && self?.isClosingSession == false && self?.isRestartingSession == false
            },
            sendBack: { [weak self] in self?.sendBackKey() },
            openHelp: {
                if let url = URL(string: "https://github.com/uakihir0/apkrun/tree/main/docs") {
                    NSWorkspace.shared.open(url)
                }
            },
            reportProblem: { [weak self] in self?.reportProblem() }
        )
        identity = try? LauncherIdentity.load()
        startPackageSession()
        showStartingAfterDelay()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard session != nil || isClosingSession || isStarting else {
            return .terminateNow
        }
        pendingTerminationReply = true
        if isStarting {
            startupTask?.cancel()
            if let runtimeClient {
                Task {
                    await runtimeClient.cancelPendingApproval()
                }
            }
        } else {
            beginSessionClose()
        }
        return .terminateLater
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        LauncherMenus.dockMenu()
    }

    private func openPackageSession() async {
        guard !isStarting else { return }
        isStarting = true
        defer {
            isStarting = false
            if pendingTerminationReply {
                if session != nil {
                    beginSessionClose()
                } else {
                    completePendingTermination()
                }
            }
        }

        let loadedIdentity: LauncherIdentity
        do {
            loadedIdentity = try LauncherIdentity.load()
            identity = loadedIdentity
        } catch let failure as LauncherIdentity.Failure {
            logger.error("Launcher identity could not be read")
            switch failure {
            case .malformedWrapper, .packageMismatch:
                show(.damaged(appName: appName))
            case .genericPackageMissing:
                show(
                    .runtimeError(
                        appName: appName,
                        message: "APKRun could not identify the Android app to open.",
                        remediation: "Open this app from APKRun."
                    ))
            }
            return
        } catch {
            show(.damaged(appName: appName))
            return
        }

        guard !isTranslocated else {
            show(.translocated(appName: loadedIdentity.displayName))
            return
        }

        #if DEBUG
            if ProcessInfo.processInfo.environment["APKRUN_LAUNCHER_TEST_NO_RUNTIME"] == "1" {
                show(.required(appName: loadedIdentity.displayName))
                return
            }
        #endif

        restoredWindowContentSize = autosavedWindowContentSize(for: loadedIdentity)

        for attempt in 0...30 {
            guard !pendingTerminationReply else { return }
            do {
                try await openPackageSession(identity: loadedIdentity)
                return
            } catch {
                guard !pendingTerminationReply else { return }
                guard errorNeedsSetupRetry(error), attempt < 30 else {
                    show(screen(for: error, identity: loadedIdentity))
                    return
                }
                show(.setup(appName: loadedIdentity.displayName))
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
            }
        }
    }

    private func startPackageSession() {
        guard startupTask == nil else { return }
        startupTask = Task { [weak self] in
            guard let self else { return }
            await openPackageSession()
            startupTask = nil
            startingFeedbackTask?.cancel()
            startingFeedbackTask = nil
        }
    }

    private func showStartingAfterDelay() {
        startingFeedbackTask?.cancel()
        startingFeedbackTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
            guard let self, startupTask != nil, statusWindowController == nil else { return }
            show(.starting(appName: appName))
        }
    }

    private func openPackageSession(identity: LauncherIdentity) async throws {
        let connection = try await connect(identity: identity)
        guard !pendingTerminationReply else { return }
        let client = connection.client
        runtimeClient = client

        let hello = connection.hello
        runtimeVersion = hello.runtimeVersion
        aboutWindowController?.update(
            packageDetails: packageDetails,
            runtimeVersion: hello.runtimeVersion
        )
        if hello.hostState == "updating" {
            throw LauncherStartupError.setupRequired
        }

        let compatibility = LauncherCompatibility.evaluate(
            runtimeVersion: hello.runtimeVersion,
            serverAPI: hello.apiVersion,
            minimumRuntimeVersion: identity.document?.runtime.minimumVersion
                ?? LauncherBuild.minimumRuntimeVersion,
            launcherAPI: LauncherBuild.launcherAPI
        )
        switch compatibility {
        case .compatible:
            break
        case .runtimeTooOld, .runtimeAPITooOld:
            show(
                .minimumRuntime(
                    appName: identity.displayName,
                    version: identity.document?.runtime.minimumVersion.rawValue
                        ?? LauncherBuild.minimumRuntimeVersion.rawValue
                ))
            return
        case .launcherTooOld:
            show(.launcherTooOld(appName: identity.displayName))
            return
        }

        var packageName = identity.displayName
        packageDetails = nil
        if restoredWindowContentSize == nil {
            do {
                let details = try await client.packageInfo(packageID: identity.packageID)
                packageDetails = details
                packageName = details.summary.displayName
            } catch let error {
                if identity.document != nil, case .transportFailure = error {
                    do {
                        let details = try await client.packageInfo(packageID: identity.packageID)
                        packageDetails = details
                        packageName = details.summary.displayName
                    } catch let retryError {
                        if isWrapperApprovalCandidate(retryError) {
                            let approvedConnection = try await approveWrapper(identity: identity, using: client)
                            guard !pendingTerminationReply else { return }
                            runtimeClient = approvedConnection.client
                            let approvedDetails = try? await approvedConnection.client.packageInfo(
                                packageID: identity.packageID
                            )
                            guard !pendingTerminationReply else { return }
                            packageDetails = approvedDetails
                            let approvedPackageName = approvedDetails?.summary.displayName ?? identity.displayName
                            try await openSession(
                                identity: identity,
                                client: approvedConnection.client,
                                packageName: approvedPackageName
                            )
                            return
                        }
                    }
                }
            }
        }
        guard !pendingTerminationReply else { return }
        let request = makeSessionRequest(identity: identity)
        let openedSession = try await client.openSession(request)
        guard !pendingTerminationReply else {
            try? await openedSession.closeSession()
            return
        }
        try installOpenedSession(
            openedSession,
            request: request,
            packageName: packageName,
            identity: identity
        )
    }

    private func openSession(
        identity: LauncherIdentity,
        client: RuntimeControlClient,
        packageName: String
    ) async throws {
        guard !pendingTerminationReply else { return }
        let request = makeSessionRequest(identity: identity)
        let openedSession = try await client.openSession(request)
        guard !pendingTerminationReply else {
            try? await openedSession.closeSession()
            return
        }
        try installOpenedSession(
            openedSession,
            request: request,
            packageName: packageName,
            identity: identity
        )
    }

    private func installOpenedSession(
        _ openedSession: RuntimeOpenedSession,
        request: OpenSessionRequest,
        packageName: String,
        identity: LauncherIdentity
    ) throws {
        sessionRequest = request
        sessionPackageName = packageName
        userClosedWindow = false
        try installSession(
            openedSession,
            packageName: packageName,
            backingScale: CGFloat(request.geometry.backingScale),
            allowsResize: identity.document?.window?.resizable ?? true,
            identity: identity
        )
        logger.notice("Opened Android app window")
    }

    private func connect(
        identity: LauncherIdentity
    ) async throws -> (client: RuntimeControlClient, hello: RuntimeHelloReply) {
        let client = try makeClient(isWrapper: identity.document != nil)
        runtimeClient = client
        do {
            return (client, try await client.connect())
        } catch let error {
            guard identity.document != nil else { throw error }
            switch error {
            case .endpointRejected(.unknownClient):
                guard !pendingTerminationReply else {
                    throw RuntimeControlClientError.requestCancelled(operation: "launcherStartup")
                }
                return try await approveWrapper(identity: identity, using: client)
            case .transportFailure:
                let retryClient = try makeClient(isWrapper: true)
                runtimeClient = retryClient
                do {
                    return (retryClient, try await retryClient.connect())
                } catch let retryError {
                    guard isWrapperApprovalCandidate(retryError) else { throw retryError }
                    guard !pendingTerminationReply else {
                        throw RuntimeControlClientError.requestCancelled(operation: "launcherStartup")
                    }
                    return try await approveWrapper(identity: identity, using: retryClient)
                }
            default:
                throw error
            }
        }
    }

    private func isWrapperApprovalCandidate(_ error: RuntimeControlClientError) -> Bool {
        switch error {
        case .endpointRejected(.unknownClient), .transportFailure:
            true
        default:
            false
        }
    }

    private func approveWrapper(
        identity: LauncherIdentity,
        using client: RuntimeControlClient
    ) async throws -> (client: RuntimeControlClient, hello: RuntimeHelloReply) {
        show(.approvalPending(appName: identity.displayName))
        guard let bundleID = Bundle.main.bundleIdentifier,
            let request = RuntimeWrapperApprovalBrokerRequest(
                bundlePath: Bundle.main.bundleURL.standardizedFileURL.path,
                bundleID: bundleID,
                packageID: identity.packageID
            )
        else {
            throw LauncherStartupError.invalidWrapperIdentity
        }
        let outcome = try await client.requestApproval(request)
        guard outcome == .approved else {
            throw LauncherStartupError.approvalDenied
        }

        let approvedClient = try makeClient(isWrapper: true)
        runtimeClient = approvedClient
        return (approvedClient, try await approvedClient.connect())
    }

    private func makeClient(isWrapper: Bool) throws -> RuntimeControlClient {
        if isWrapper {
            return try RuntimeControlClient(wrapperDaemonBuildIdentity: LauncherBuild.daemonIdentity)
        }
        return try RuntimeControlClient(clientKind: .launcher)
    }

    private func makeSessionRequest(identity: LauncherIdentity) -> OpenSessionRequest {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 900)
        let defaultWidth =
            restoredWindowContentSize?.width
            ?? identity.document?.window?.defaultWidth.map(CGFloat.init)
            ?? min(480, visibleFrame.width * 0.9)
        let defaultHeight =
            restoredWindowContentSize?.height
            ?? identity.document?.window?.defaultHeight.map(CGFloat.init)
            ?? min(850, visibleFrame.height * 0.9)
        let pointSize = CGSize(
            width: min(max(320, defaultWidth), max(320, visibleFrame.width * 0.95)),
            height: min(max(400, defaultHeight), max(400, visibleFrame.height * 0.95))
        )
        let backingScale = Double(screen?.backingScaleFactor ?? 1)
        let launchTiming = processStart.flatMap { processStart in
            ContinuousClockTimestamp.nowNanoseconds().map { requestSent in
                LaunchTiming(processStart: processStart, requestSent: requestSent)
            }
        }
        return OpenSessionRequest(
            header: APIRequestHeader(clientKind: identity.document == nil ? .launcher : .wrapper),
            packageID: identity.packageID,
            geometry: DisplayGeometry(
                pointSize: DisplayPointSize(width: pointSize.width, height: pointSize.height),
                backingScale: backingScale,
                zoom: 1
            ),
            screenSize: DisplayPointSize(width: visibleFrame.width, height: visibleFrame.height),
            launchTiming: launchTiming
        )
    }

    private func installSession(
        _ openedSession: RuntimeOpenedSession,
        packageName: String,
        backingScale: CGFloat,
        allowsResize: Bool,
        identity: LauncherIdentity
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
            allowsResize: allowsResize,
            frameAutosaveName: identity.document == nil ? nil : "APKRunSessionWindow",
            existingWindow: statusWindowController?.takeWindowForSession(),
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
                        let outcome =
                            (error as? RuntimeControlClientError)?.sessionResizeResultIsUncertain == true
                            ? DisplayResizeOutcome.stateUncertain
                            : .rejected
                        completion(outcome)
                    }
                }
            }
        )
        window.onClose = { [weak self] in
            self?.windowWasClosed()
        }
        window.onShouldClose = { [weak self, weak window] in
            guard let self, let window else { return true }
            return self.shouldClose(window)
        }

        let previousWindow = windowController
        previousWindow?.onClose = nil
        statusWindowController = nil
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
        if case .booting = openedSession.descriptor.state {
            window.show(placeholderImmediately: true)
        } else {
            window.show()
        }
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

    private func shouldClose(_ window: SessionWindowController) -> Bool {
        guard session != nil else { return true }
        windowToCloseAfterSession = window
        beginSessionClose()
        return false
    }

    private func beginSessionClose() {
        guard !isClosingSession else { return }
        guard let activeSession = session else {
            finishSessionClose()
            return
        }

        isClosingSession = true
        closeSessionTask = Task { [weak self, activeSession] in
            do {
                try await activeSession.closeSession()
            } catch {
                self?.logger.error("The Android app session could not close cleanly")
            }
            self?.finishSessionClose()
        }
        closeSessionDeadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.finishSessionClose()
        }
    }

    private func finishSessionClose() {
        guard isClosingSession else { return }
        isClosingSession = false
        closeSessionDeadlineTask?.cancel()
        closeSessionDeadlineTask = nil
        closeSessionTask?.cancel()
        closeSessionTask = nil
        messagesTask?.cancel()
        messagesTask = nil
        closeRequestsTask?.cancel()
        closeRequestsTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        session = nil
        frameSource = nil

        let windowToClose = windowToCloseAfterSession
        windowToCloseAfterSession = nil
        if pendingTerminationReply {
            completePendingTermination()
        } else {
            windowToClose?.close()
        }
    }

    private func completePendingTermination() {
        guard pendingTerminationReply else { return }
        pendingTerminationReply = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    private func restartApp() {
        guard !isClosingSession, !isRestartingSession, let session else { return }
        isRestartingSession = true
        Task {
            defer { isRestartingSession = false }
            do {
                try await session.restartApp()
            } catch {
                logger.error("The Android app could not be restarted")
                let alert = NSAlert()
                alert.messageText = LauncherStrings.text("launcher.restart.failed.title")
                alert.informativeText = LauncherStrings.text(
                    "launcher.restart.failed.message",
                    arguments: [appName]
                )
                alert.alertStyle = .warning
                alert.addButton(withTitle: LauncherStrings.text("launcher.action.ok"))
                alert.runModal()
            }
        }
    }

    private func sessionStreamEnded(for window: SessionWindowController) {
        guard !userClosedWindow, !isClosingSession, windowController === window else { return }
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
                    let packageName = self.sessionPackageName,
                    let identity = self.identity
                else {
                    return
                }
                do {
                    let reopened = try await client.openSession(
                        LauncherProcessTiming.recoveryRequest(from: request)
                    )
                    guard !Task.isCancelled, !self.userClosedWindow, self.windowController === window else {
                        return
                    }
                    try self.installSession(
                        reopened,
                        packageName: packageName,
                        backingScale: CGFloat(request.geometry.backingScale),
                        allowsResize: identity.document?.window?.resizable ?? true,
                        identity: identity
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

    private var appName: String {
        identity?.displayName
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? "APKRun"
    }

    private var isTranslocated: Bool {
        Bundle.main.bundleURL.pathComponents.contains("AppTranslocation")
    }

    private func errorNeedsSetupRetry(_ error: any Error) -> Bool {
        if case LauncherStartupError.setupRequired = error {
            return true
        }
        guard let error = error as? RuntimeControlClientError else {
            return false
        }
        switch error {
        case .transportFailure, .requestTimedOut:
            return NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: LauncherBuild.hostAppBundleIdentifier
            ) != nil
        case .remoteFailure(let code, _):
            return code == "runtime.notProvisioned" || code == "runtime.serviceUnavailable"
        case .endpointRejected(.busy), .endpointRejected(.hostShuttingDown):
            return true
        case .invalidClientIdentity, .malformedReply, .apiVersionMismatch, .endpointRejected, .endpointMissing,
            .invalidRemoteProxy, .invalidXPCInterface, .operationResultUnknown, .requestCancelled, .encodingFailure:
            return false
        }
    }

    private func screen(for error: any Error, identity: LauncherIdentity) -> LauncherScreen {
        if let error = error as? LauncherStartupError {
            switch error {
            case .approvalDenied:
                return .approvalDenied(appName: identity.displayName)
            case .invalidWrapperIdentity:
                return .damaged(appName: identity.displayName)
            case .setupRequired:
                return .setup(appName: identity.displayName)
            }
        }
        guard let error = error as? RuntimeControlClientError else {
            return .runtimeError(
                appName: identity.displayName,
                message: error.localizedDescription,
                remediation: "Open APKRun and try again."
            )
        }
        switch error {
        case .apiVersionMismatch(_, let server):
            if LauncherBuild.launcherAPI.major > server.major,
                LauncherBuild.launcherAPI.major - server.major > 1
            {
                return .launcherTooOld(appName: identity.displayName)
            }
            if LauncherBuild.launcherAPI.major < server.major,
                server.major - LauncherBuild.launcherAPI.major > 1
            {
                return .launcherTooOld(appName: identity.displayName)
            }
            return .minimumRuntime(
                appName: identity.displayName,
                version: identity.document?.runtime.minimumVersion.rawValue
                    ?? LauncherBuild.minimumRuntimeVersion.rawValue
            )
        case .endpointRejected(.unknownClient) where identity.document != nil:
            return .approvalDenied(appName: identity.displayName)
        case .transportFailure:
            return NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: LauncherBuild.hostAppBundleIdentifier
            ) == nil
                ? .required(appName: identity.displayName)
                : .setup(appName: identity.displayName)
        case .remoteFailure(let code, let message):
            if code == "store.packageNotInstalled" || code == "package.notInstalled" {
                return .notInstalled(appName: identity.displayName)
            }
            if code == "runtime.notProvisioned" || code == "runtime.serviceUnavailable" {
                return .setup(appName: identity.displayName)
            }
            if code == "wrapper.bundleInvalid" {
                return .damaged(appName: identity.displayName)
            }
            return .runtimeError(
                appName: identity.displayName,
                message: message,
                remediation: "Open APKRun and try again."
            )
        case .invalidClientIdentity where identity.document != nil:
            return .damaged(appName: identity.displayName)
        default:
            return .runtimeError(
                appName: identity.displayName,
                message: error.localizedDescription,
                remediation: "Open APKRun and try again."
            )
        }
    }

    private func show(_ screen: LauncherScreen) {
        if let statusWindowController {
            statusWindowController.show(screen)
        } else {
            let controller = LauncherStatusWindowController(appName: screen.appName, screen: screen)
            controller.onAction = { [weak self] action in
                self?.perform(action)
            }
            controller.onQuit = {
                NSApp.terminate(nil)
            }
            statusWindowController = controller
        }
        statusWindowController?.showWindow()
    }

    private func showAbout() {
        guard let identity = self.identity ?? (try? LauncherIdentity.load()) else { return }
        self.identity = identity
        if let aboutWindowController {
            aboutWindowController.update(
                packageDetails: packageDetails,
                runtimeVersion: runtimeVersion ?? LauncherBuild.version
            )
            aboutWindowController.showWindow()
            loadAboutPackageDetailsIfNeeded(identity: identity)
            return
        }
        let controller = LauncherAboutWindowController(
            appName: identity.displayName,
            packageID: identity.packageID,
            packageDetails: packageDetails,
            runtimeVersion: runtimeVersion ?? LauncherBuild.version,
            launcherVersion: LauncherBuild.version,
            packageIcon: NSApp.applicationIconImage
        )
        aboutWindowController = controller
        controller.showWindow()
        loadAboutPackageDetailsIfNeeded(identity: identity)
    }

    private func loadAboutPackageDetailsIfNeeded(identity: LauncherIdentity) {
        guard packageDetails == nil, !isLoadingAboutDetails, let runtimeClient else { return }
        isLoadingAboutDetails = true
        Task { [weak self] in
            defer { self?.isLoadingAboutDetails = false }
            guard let details = try? await runtimeClient.packageInfo(packageID: identity.packageID),
                let self
            else {
                return
            }
            packageDetails = details
            aboutWindowController?.update(
                packageDetails: details,
                runtimeVersion: runtimeVersion ?? LauncherBuild.version
            )
        }
    }

    private func autosavedWindowContentSize(for identity: LauncherIdentity) -> CGSize? {
        guard identity.document != nil else { return nil }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 850),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.setFrameAutosaveName("APKRunSessionWindow")
        guard window.setFrameUsingName("APKRunSessionWindow") else { return nil }
        let size = window.contentRect(forFrameRect: window.frame).size
        guard size.width.isFinite, size.height.isFinite, size.width >= 320, size.height >= 400 else {
            return nil
        }
        return size
    }

    private func perform(_ action: LauncherAction) {
        switch action {
        case .getAPKRun:
            NSWorkspace.shared.open(LauncherBuild.downloadURL)
        case .openAPKRun:
            openAPKRun(for: identity?.packageID)
        case .checkForUpdates:
            openAPKRunURL("apkrun://settings/general")
        case .updateMacApp:
            openAPKRun(for: identity?.packageID)
        case .tryAgain:
            show(.setup(appName: identity?.displayName ?? appName))
            startPackageSession()
        }
    }

    private func openAPKRun(for packageID: RuntimePackageID?) {
        let route = packageID.map { "apkrun://package/\($0.rawValue)" }
        if let route, let url = URL(string: route) {
            NSWorkspace.shared.open(url)
            return
        }
        if let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: LauncherBuild.hostAppBundleIdentifier
        ) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(LauncherBuild.downloadURL)
        }
    }

    private func openAPKRunURL(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }

    private func reportProblem() {
        var components = URLComponents()
        components.scheme = "apkrun"
        components.host = "report"
        if let packageID = identity?.packageID {
            components.queryItems = [URLQueryItem(name: "package", value: packageID.rawValue)]
        }
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    private func sendBackKey() {
        guard let window = NSApp.keyWindow,
            let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false,
                keyCode: 53
            )
        else {
            return
        }
        NSApp.postEvent(event, atStart: false)
    }
}

private enum LauncherStartupError: Error {
    case approvalDenied
    case invalidWrapperIdentity
    case setupRequired
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
private let delegate = LauncherAppDelegate()
application.delegate = delegate
application.run()
