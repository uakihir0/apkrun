import CoreGraphics
import CryptoKit
import Darwin
import DiagnosticsCore
import Foundation
import InputCore
import IntegrationCore
import RuntimeAPI
import RuntimeCore
import UniformTypeIdentifiers

struct PreparedFileImport {
    let handle: FileHandle
    let transferID: UInt64
    let name: String
    let mimeType: String
    let size: UInt64
    let sha256: Data
}

private struct UnhashedFileImport {
    let handle: FileHandle
    let name: String
    let mimeType: String
    let size: UInt64
}

private struct PendingFileExport {
    let guestOffer: DevelopmentGuestExportOffer
    let sessionID: UUID
    let createdAt: ContinuousClock.Instant
}

struct DaemonOpenedWindowSession: @unchecked Sendable {
    let session: AppSessionSnapshot
    let lease: DisplayLease
}

struct RuntimeWindowSessionContext: Sendable {
    let opened: DaemonOpenedWindowSession
    let service: DaemonHeadlessSessionService
}

protocol RuntimeSessionWindowOperations: Sendable {
    func frameDisplayed(sessionID: UUID, message: FrameDisplayedMessage) async
    func visibilityChanged(sessionID: UUID, visible: Bool) async
    func focusChanged(sessionID: UUID, focused: Bool) async
    func sendInput(sessionID: UUID, batch: InputBatch) async
    func closeSession(sessionID: UUID, policy: SessionClosePolicy?) async throws(RuntimeWireError)
}

/// Launches CLI-owned sessions on secondary displays before the daemon has a window client (#33).
///
/// This service owns no window. It drains each lease's frame stream and acknowledges frames as discarded, then marks
/// the session running as soon as Android confirms the launch operation.
public actor DaemonHeadlessSessionService:
    RuntimeSessionService,
    RuntimeSessionWindowOperations,
    PackageMutationSessionHandling
{
    private let guestAgent: any DaemonHeadlessGuestAgent
    private let displayPool: DisplayPool
    private let registry: SessionRegistry
    private let displayConfiguration: DisplayConfiguration
    private let fileIntegrationEnabled: @Sendable (RuntimePackageID) async throws(RuntimeWireError) -> Bool
    private let exportOfferDelivery: @Sendable (UUID, ExportOffer) async -> Bool
    private var sessionsByPackage: [String: SessionID] = [:]
    private var pendingFileExports: [UUID: PendingFileExport] = [:]
    private var frameDrainers: [SessionID: Task<Void, Never>] = [:]
    private var inputRouter: InputRouter?
    private var taskEventMonitor: Task<Void, Never>?
    private var guestResynchronizationHandlerID: UUID?
    private var hasExportOfferHandler = false
    private var reconciliationTasks: [UUID: Task<Void, Never>] = [:]
    private var operationInFlight = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownCallWaiters: [CheckedContinuation<Void, Never>] = []
    private var resynchronizationWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeResynchronizations = 0
    private var isShuttingDown = false
    private var didCompleteShutdown = false

    /// Creates the daemon's Guest Agent-backed headless session service.
    public init(
        guestAgent: DevelopmentGuestAgent,
        displayPool: DisplayPool,
        fileIntegrationEnabled: @escaping @Sendable (RuntimePackageID) async throws(RuntimeWireError) -> Bool = { _ in
            false
        },
        exportOfferDelivery: @escaping @Sendable (UUID, ExportOffer) async -> Bool = { _, _ in false },
        logSink: (any LogSink)? = nil
    ) {
        self.guestAgent = guestAgent
        self.displayPool = displayPool
        self.fileIntegrationEnabled = fileIntegrationEnabled
        self.exportOfferDelivery = exportOfferDelivery
        registry = SessionRegistry(logSink: logSink)
        displayConfiguration = Self.defaultDisplayConfiguration
    }

    init(
        guestAgent: any DaemonHeadlessGuestAgent,
        displayPool: DisplayPool,
        registry: SessionRegistry,
        displayConfiguration: DisplayConfiguration,
        fileIntegrationEnabled: @escaping @Sendable (RuntimePackageID) async throws(RuntimeWireError) -> Bool = { _ in
            false
        },
        exportOfferDelivery: @escaping @Sendable (UUID, ExportOffer) async -> Bool = { _, _ in false }
    ) {
        self.guestAgent = guestAgent
        self.displayPool = displayPool
        self.registry = registry
        self.displayConfiguration = displayConfiguration
        self.fileIntegrationEnabled = fileIntegrationEnabled
        self.exportOfferDelivery = exportOfferDelivery
    }

    /// Stops background observers before Android is shut down by the daemon.
    func shutdown() async {
        if didCompleteShutdown {
            return
        }
        if isShuttingDown {
            await withCheckedContinuation { continuation in
                shutdownCallWaiters.append(continuation)
            }
            return
        }
        isShuttingDown = true
        if hasExportOfferHandler {
            hasExportOfferHandler = false
            await guestAgent.setExportOfferHandler(nil)
        }
        let pendingOffers = pendingFileExports.values.map(\.guestOffer)
        pendingFileExports.removeAll()
        for offer in pendingOffers {
            _ = try? await guestAgent.resolveExport(offerID: offer.offerID, decision: .decline)
        }
        if let handlerID = guestResynchronizationHandlerID {
            guestResynchronizationHandlerID = nil
            await guestAgent.removeResynchronizationHandler(handlerID)
        }
        if let taskEventMonitor {
            self.taskEventMonitor = nil
            taskEventMonitor.cancel()
            await taskEventMonitor.value
        }
        await waitForOperationsToFinish()
        await waitForResynchronizationsToFinish()
        let tasks = Array(reconciliationTasks.values)
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }
        let drainers = Array(frameDrainers.values)
        frameDrainers.removeAll()
        for drainer in drainers {
            drainer.cancel()
        }
        for drainer in drainers {
            await drainer.value
        }
        didCompleteShutdown = true
        let waiters = shutdownCallWaiters
        shutdownCallWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Starts a package on a leased secondary display and returns after Android confirms the launch.
    public func launch(_ request: RuntimeLaunchRequest) async throws(RuntimeWireError) -> RuntimeLaunchResult {
        try await launch(request, displayConfiguration: displayConfiguration, drainsFrames: true)
    }

    /// Opens a window-backed app session with the requested native geometry and leaves frame ownership to its
    /// authenticated session endpoint.
    func openWindowSession(_ request: OpenSessionRequest) async throws(RuntimeWireError) -> DaemonOpenedWindowSession {
        let configuration = DisplayConfiguration(
            geometry: DisplayGeometry(
                pointSize: CGSize(
                    width: request.geometry.pointSize.width,
                    height: request.geometry.pointSize.height
                ),
                backingScale: request.geometry.backingScale,
                zoom: request.geometry.zoom
            )
        )
        let launchRequest = RuntimeLaunchRequest(packageID: request.packageID)
        _ = try await launch(launchRequest, displayConfiguration: configuration, drainsFrames: false)

        guard let session = await registry.session(packageID: request.packageID.rawValue),
            let lease = await registry.displayLease(session.id)
        else {
            throw .runtime(
                "sessionNotFound",
                message: "The Android app started without an active display session.",
                remediation: "Close the app window and launch it again."
            )
        }

        await stopDrainingFrames(for: session.id)
        guard case .app(let sessionID) = session.id else {
            throw .runtime("internal", message: "The window session has an unsupported session identity.")
        }
        do {
            try await registerWindowInput(for: session)
        } catch {
            try? await closeSession(sessionID: sessionID, policy: .stop)
            throw error
        }
        await visibilityChanged(sessionID: sessionID, visible: true)
        let visibleSession = await registry.session(session.id) ?? session
        return DaemonOpenedWindowSession(session: visibleSession, lease: lease)
    }

    private func launch(
        _ request: RuntimeLaunchRequest,
        displayConfiguration: DisplayConfiguration,
        drainsFrames: Bool
    ) async throws(RuntimeWireError) -> RuntimeLaunchResult {
        guard await acquireOperation() else {
            throw Self.shuttingDownError
        }
        defer { releaseOperation() }
        await ensureGuestObservation()
        guard !isShuttingDown else {
            throw Self.shuttingDownError
        }

        let packageID = request.packageID.rawValue
        if let existing = await registry.session(packageID: packageID) {
            sessionsByPackage[packageID] = existing.id
            return try await launchExisting(existing, drainsFrames: drainsFrames)
        }

        let isInstalled: Bool
        do throws(GuestAgentFailure) {
            isInstalled = try await guestAgent.isInstalled(packageID)
        } catch {
            throw Self.wireError(for: error)
        }
        guard isInstalled else {
            throw .runtime(
                "packageNotInstalled",
                message: "This app is not installed in Android.",
                remediation: "Install the app first, then launch it again."
            )
        }

        let session: AppSessionSnapshot
        do throws(SessionRegistryFailure) {
            session = try await registry.requestLeased(
                packageID: packageID,
                configuration: displayConfiguration,
                displayPool: displayPool
            )
        } catch {
            throw Self.wireError(for: error)
        }
        sessionsByPackage[packageID] = session.id
        guard session.state == .acquiringDisplay,
            let lease = await registry.displayLease(session.id)
        else {
            return try await launchExisting(session, drainsFrames: drainsFrames)
        }
        if drainsFrames {
            startDrainingFrames(from: lease)
        }

        let launching: AppSessionSnapshot
        do throws(SessionRegistryFailure) {
            launching = try await registry.transition(session.id, to: .launching)
        } catch {
            await endFailedLaunch(session.id)
            throw Self.wireError(for: error)
        }

        let report: GuestLaunchReport
        do throws(GuestAgentFailure) {
            report = try await guestAgent.launch(package: packageID, displayID: launching.displayID)
        } catch {
            if !Self.isTransientLaunchFailure(error) {
                await endFailedLaunch(session.id)
            }
            throw Self.wireError(for: error)
        }

        guard let completed = await registry.launchCompleted(packageID: packageID, taskID: report.taskID) else {
            if let current = await registry.session(session.id), Self.isEnded(current.state) {
                await stopDrainingFrames(for: session.id)
                return try Self.launchResult(for: current)
            }
            if let current = await registry.session(session.id),
                current.state == .running || current.state == .backgrounded
            {
                return try Self.launchResult(for: current)
            }
            await endFailedLaunch(session.id)
            throw .runtime("internal", message: "The app launch result could not be associated with its session.")
        }
        guard !Self.isEnded(completed.state) else {
            await stopDrainingFrames(for: session.id)
            return try Self.launchResult(for: completed)
        }

        let running: AppSessionSnapshot
        do throws(SessionRegistryFailure) {
            running = try await registry.transition(session.id, to: .running)
        } catch {
            if let current = await registry.session(session.id), Self.isEnded(current.state) {
                await stopDrainingFrames(for: session.id)
                return try Self.launchResult(for: current)
            }
            await endFailedLaunch(session.id)
            throw Self.wireError(for: error)
        }
        return try Self.launchResult(for: running)
    }

    /// Stops package tasks and completes the session, releasing its secondary-display lease.
    public func terminate(_ request: RuntimeTerminateRequest) async throws(RuntimeWireError) -> RuntimeTerminateResult {
        guard await acquireOperation() else {
            throw Self.shuttingDownError
        }
        defer { releaseOperation() }
        await ensureGuestObservation()
        guard !isShuttingDown else {
            throw Self.shuttingDownError
        }

        let packageID = request.packageID.rawValue
        guard let current = await registry.session(packageID: packageID) else {
            return try await Self.terminateWithoutSession(request, using: guestAgent)
        }
        let isInstalled: Bool
        do throws(GuestAgentFailure) {
            isInstalled = try await guestAgent.isInstalled(packageID)
        } catch {
            throw Self.wireError(for: error)
        }
        guard isInstalled else {
            throw Self.packageNotInstalledError
        }
        var shouldForceStop = true
        if current.state != .closing {
            do throws(SessionRegistryFailure) {
                _ = try await registry.transition(current.id, to: .closing)
            } catch {
                guard let latest = await registry.session(current.id), Self.isEnded(latest.state) else {
                    throw Self.wireError(for: error)
                }
                shouldForceStop = false
            }
        }

        if shouldForceStop {
            let stopped: Bool
            do throws(GuestAgentFailure) {
                stopped = try await guestAgent.forceStopApplication(package: packageID)
            } catch {
                _ = await registry.stopFailed(packageID: packageID)
                throw Self.wireError(for: error)
            }
            guard stopped else {
                _ = await registry.stopFailed(packageID: packageID)
                throw Self.guestTasksStillRunningError
            }
        }

        await stopDrainingFrames(for: current.id)
        _ = await registry.stopCompleted(sessionID: current.id)
        forgetSession(packageID: packageID, sessionID: current.id)
        return RuntimeTerminateResult(packageID: request.packageID, hadSession: true)
    }

    /// Reports whether this package still owns a live app session.
    func hasActiveSession(packageID: RuntimePackageID) async -> Bool {
        await registry.session(packageID: packageID.rawValue) != nil
    }

    /// Transfers a file drop to the exact live session that owns the target window.
    public func importFiles(
        _ request: ImportFilesRequest,
        files: [FileHandle]
    ) async throws(RuntimeWireError) -> ImportResult {
        guard await acquireOperation() else {
            throw Self.shuttingDownError
        }
        defer { releaseOperation() }
        guard !isShuttingDown else { throw Self.shuttingDownError }

        let sessionID = SessionID.app(request.sessionID)
        guard let session = await registry.session(sessionID),
            session.state == .running || session.state == .backgrounded,
            let packageID = RuntimePackageID(rawValue: session.packageID)
        else {
            throw .runtime(
                "guestAgentUnavailable",
                message: "The app session is no longer available for file sharing.",
                remediation: "Open the app again, then retry the drop."
            )
        }

        let isEnabled: Bool
        do {
            isEnabled = try await fileIntegrationEnabled(packageID)
        } catch {
            throw error
        }
        guard isEnabled else {
            throw Self.integrationWireError(.filesDisabled)
        }

        let prepared = try Self.validateFileDrop(files, metadata: request.files, packageID: packageID)
        let transferStartedAt = ContinuousClock().now
        var transferredBytes: UInt64 = 0
        defer {
            let completedAt = ContinuousClock().now
            let duration = transferStartedAt.duration(to: completedAt).components
            let durationMilliseconds =
                Double(duration.seconds) * 1_000
                + Double(duration.attoseconds) / 1_000_000_000_000_000
            Perf.mark(
                .fileTransfer,
                at: completedAt,
                [
                    "bytes": .integer(Int64(clamping: transferredBytes)),
                    "durationMs": .double(durationMilliseconds),
                ]
            )
        }
        var guestFiles: [GuestFileReference] = []
        guestFiles.reserveCapacity(prepared.count)
        for item in prepared {
            do {
                try await guestAgent.transferFile(
                    item.handle,
                    transferID: item.transferID,
                    name: item.name,
                    mimeType: item.mimeType,
                    size: item.size,
                    sha256: item.sha256
                )
            } catch {
                throw Self.wireError(for: error)
            }
            transferredBytes += item.size
            guestFiles.append(
                GuestFileReference(
                    transferID: item.transferID,
                    name: item.name,
                    mimeType: item.mimeType,
                    size: item.size
                )
            )
        }

        do {
            let result = try await guestAgent.importFiles(
                package: session.packageID,
                displayID: session.displayID,
                files: guestFiles
            )
            let disposition: ImportDisposition
            let uriAuthority: String
            let uriPathPrefix: String
            switch result.disposition {
            case .shared:
                disposition = .shared
                uriAuthority = "io.apkrun.guest.files"
                uriPathPrefix = "/shared/"
            case .savedToDownloads:
                disposition = .savedToDownloads
                uriAuthority = "media"
                uriPathPrefix = "/external/downloads/"
            default: throw Self.integrationWireError(.transferFailed)
            }
            guard result.contentURIs.count == guestFiles.count,
                result.contentURIs.allSatisfy({
                    Self.isValidContentURI($0, authority: uriAuthority, pathPrefix: uriPathPrefix)
                })
            else {
                throw Self.integrationWireError(.transferFailed)
            }
            return ImportResult(contentURIs: result.contentURIs, disposition: disposition)
        } catch let error as RuntimeWireError {
            throw error
        } catch {
            throw Self.wireError(for: error)
        }
    }

    /// Accepts or declines a guest file offer bound to the exact session captured by the XPC endpoint.
    public func acceptExport(
        _ request: AcceptExportRequest,
        file: FileHandle?
    ) async throws(RuntimeWireError) {
        guard await acquireOperation() else {
            throw Self.shuttingDownError
        }
        defer { releaseOperation() }
        guard !isShuttingDown else { throw Self.shuttingDownError }

        pruneExpiredExportOffers()
        guard let pending = pendingFileExports[request.offerID],
            pending.sessionID == request.sessionID
        else {
            throw Self.integrationWireError(.transferFailed)
        }
        pendingFileExports[request.offerID] = nil

        guard let file else {
            do {
                _ = try await guestAgent.resolveExport(
                    offerID: pending.guestOffer.offerID,
                    decision: .decline
                )
            } catch {
                throw Self.wireError(for: error)
            }
            return
        }

        guard let session = await registry.session(SessionID.app(request.sessionID)),
            session.state == .running || session.state == .backgrounded,
            session.packageID == pending.guestOffer.sourcePackage,
            session.displayID == pending.guestOffer.displayID,
            let packageID = RuntimePackageID(rawValue: session.packageID)
        else {
            _ = try? await guestAgent.resolveExport(
                offerID: pending.guestOffer.offerID,
                decision: .decline
            )
            throw Self.integrationWireError(.transferFailed)
        }

        do {
            guard try await fileIntegrationEnabled(packageID) else {
                throw Self.integrationWireError(.filesDisabled)
            }
        } catch let error as RuntimeWireError {
            _ = try? await guestAgent.resolveExport(
                offerID: pending.guestOffer.offerID,
                decision: .decline
            )
            throw error
        } catch {
            _ = try? await guestAgent.resolveExport(
                offerID: pending.guestOffer.offerID,
                decision: .decline
            )
            throw Self.integrationWireError(.transferFailed)
        }

        let receiver: GuestBulkFileReceiver
        do {
            receiver = try await guestAgent.prepareExportFileReceive(
                expectedSize: pending.guestOffer.size,
                destination: file
            )
        } catch {
            _ = try? await guestAgent.resolveExport(
                offerID: pending.guestOffer.offerID,
                decision: .decline
            )
            throw Self.wireError(for: error)
        }

        do {
            let started = try await guestAgent.resolveExport(
                offerID: pending.guestOffer.offerID,
                decision: .accept
            )
            guard let transferID = started.transferID else {
                await receiver.cancel()
                throw Self.integrationWireError(.transferFailed)
            }
            try await receiver.bind(transferID: transferID)
            try await receiver.receiveToDestination()
        } catch let error as RuntimeWireError {
            await receiver.cancel()
            throw error
        } catch {
            await receiver.cancel()
            throw Self.integrationWireError(.transferFailed)
        }
    }

    /// Closes an active session with the package-removal reason before the store uninstalls Android's package.
    func endSessionForPackageUninstall(_ request: RuntimeTerminateRequest) async throws(RuntimeWireError) {
        guard await acquireOperation() else {
            throw Self.shuttingDownError
        }
        defer { releaseOperation() }
        await ensureGuestObservation()
        guard !isShuttingDown else {
            throw Self.shuttingDownError
        }

        let packageID = request.packageID.rawValue
        guard let current = await registry.session(packageID: packageID) else { return }
        var shouldForceStop = true
        if current.state != .closing {
            do throws(SessionRegistryFailure) {
                _ = try await registry.transition(current.id, to: .closing)
            } catch {
                guard let latest = await registry.session(current.id), Self.isEnded(latest.state) else {
                    throw Self.wireError(for: error)
                }
                shouldForceStop = false
            }
        }

        if shouldForceStop {
            let stopped: Bool
            do throws(GuestAgentFailure) {
                stopped = try await guestAgent.forceStopApplication(package: packageID)
            } catch {
                _ = await registry.stopFailed(packageID: packageID)
                throw Self.wireError(for: error)
            }
            guard stopped else {
                _ = await registry.stopFailed(packageID: packageID)
                throw Self.guestTasksStillRunningError
            }
        }

        await stopDrainingFrames(for: current.id)
        _ = await registry.stopCompleted(sessionID: current.id, endReason: .packageUninstalled)
        forgetSession(packageID: packageID, sessionID: current.id)
    }

    static func terminateWithoutSession(
        _ request: RuntimeTerminateRequest,
        using guestAgent: any DaemonHeadlessGuestAgent
    ) async throws(RuntimeWireError) -> RuntimeTerminateResult {
        let isInstalled: Bool
        do throws(GuestAgentFailure) {
            isInstalled = try await guestAgent.isInstalled(request.packageID.rawValue)
        } catch {
            throw Self.wireError(for: error)
        }
        guard isInstalled else {
            throw Self.packageNotInstalledError
        }
        let stopped: Bool
        do throws(GuestAgentFailure) {
            stopped = try await guestAgent.forceStopApplication(package: request.packageID.rawValue)
        } catch {
            throw Self.wireError(for: error)
        }
        guard stopped else {
            throw Self.guestTasksStillRunningError
        }
        return RuntimeTerminateResult(packageID: request.packageID, hadSession: false)
    }

    private func launchExisting(
        _ session: AppSessionSnapshot,
        drainsFrames: Bool
    ) async throws(RuntimeWireError) -> RuntimeLaunchResult {
        switch session.state {
        case .running, .backgrounded:
            if drainsFrames, let lease = await registry.displayLease(session.id) {
                startDrainingFrames(from: lease)
            }
            return try Self.launchResult(for: session)
        case .launching:
            if drainsFrames, let lease = await registry.displayLease(session.id) {
                startDrainingFrames(from: lease)
            }
            if let taskID = session.taskIDs.sorted().first {
                let completed = await registry.launchCompleted(packageID: session.packageID, taskID: taskID)
                let latest: AppSessionSnapshot
                if let completed {
                    latest = completed
                } else if let current = await registry.session(session.id) {
                    latest = current
                } else {
                    latest = session
                }
                if Self.isEnded(latest.state) {
                    await stopDrainingFrames(for: session.id)
                    return try Self.launchResult(for: latest)
                }
                let running: AppSessionSnapshot
                do throws(SessionRegistryFailure) {
                    running = try await registry.transition(session.id, to: .running)
                } catch {
                    throw Self.wireError(for: error)
                }
                return try Self.launchResult(for: running)
            }
            return try await launchExistingPendingSession(session)
        case .requested, .waitingForRuntime, .acquiringDisplay, .closing, .ended:
            throw Self.wireError(for: .sessionAlreadyExists(packageID: session.packageID))
        }
    }

    func frameDisplayed(sessionID: UUID, message: FrameDisplayedMessage) async {
        guard let lease = await registry.displayLease(.app(sessionID)),
            let generation = UInt32(exactly: lease.pool.generation),
            generation == message.generation
        else {
            return
        }
        lease.pool.frameDisplayed(sequence: message.frameSeq)
    }

    func visibilityChanged(sessionID: UUID, visible: Bool) async {
        let id = SessionID.app(sessionID)
        guard let session = await registry.session(id),
            let lease = await registry.displayLease(id)
        else {
            return
        }
        lease.pool.visibilityChanged(isVisible: visible)

        let nextState: AppSessionState = visible ? .running : .backgrounded
        let updated: AppSessionSnapshot
        if session.state == nextState {
            updated = session
        } else {
            do throws(SessionRegistryFailure) {
                updated = try await registry.transition(id, to: nextState)
            } catch {
                return
            }
        }
        await inputRouter?.setState(updated.state, for: id)
        if !visible {
            await inputRouter?.focusChanged(id, focused: false)
        }
    }

    func focusChanged(sessionID: UUID, focused: Bool) async {
        guard let inputRouter else {
            return
        }
        await inputRouter.focusChanged(.app(sessionID), focused: focused)
    }

    func sendInput(sessionID: UUID, batch: InputBatch) async {
        guard !batch.events.isEmpty,
            batch.events.count <= 512,
            let inputRouter
        else {
            return
        }
        await inputRouter.route(WireInputConversion.events(batch.events), from: .app(sessionID))
    }

    func closeSession(sessionID: UUID, policy: SessionClosePolicy?) async throws(RuntimeWireError) {
        let id = SessionID.app(sessionID)
        guard let session = await registry.session(id) else {
            throw .runtime(
                "sessionNotFound",
                message: "This app window no longer has an active Android session.",
                remediation: "Open the app again from Finder or the APKRun command line."
            )
        }

        if policy == .keepRunning {
            await visibilityChanged(sessionID: sessionID, visible: false)
            await inputRouter?.unregister(id)
            return
        }

        guard await acquireOperation() else {
            throw Self.shuttingDownError
        }
        defer { releaseOperation() }
        await ensureGuestObservation()
        guard !isShuttingDown else {
            throw Self.shuttingDownError
        }

        let current = await registry.session(id) ?? session
        guard !Self.isEnded(current.state) else {
            await stopDrainingFrames(for: id)
            await inputRouter?.unregister(id)
            return
        }
        do throws(SessionRegistryFailure) {
            if current.state != .closing {
                _ = try await registry.transition(id, to: .closing)
            }
        } catch {
            throw Self.wireError(for: error)
        }

        let stopped: Bool
        do throws(GuestAgentFailure) {
            stopped = try await guestAgent.forceStopApplication(package: current.packageID)
        } catch {
            _ = await registry.stopFailed(packageID: current.packageID)
            throw Self.wireError(for: error)
        }
        guard stopped else {
            _ = await registry.stopFailed(packageID: current.packageID)
            throw Self.guestTasksStillRunningError
        }

        await stopDrainingFrames(for: id)
        await inputRouter?.focusChanged(id, focused: false)
        await inputRouter?.unregister(id)
        _ = await registry.stopCompleted(sessionID: id, endReason: .userClosed)
        forgetSession(packageID: current.packageID, sessionID: id)
    }

    private func registerWindowInput(for session: AppSessionSnapshot) async throws(RuntimeWireError) {
        let router: InputRouter
        if let inputRouter {
            router = inputRouter
        } else {
            let channel: any InputChannel
            do throws(GuestAgentFailure) {
                channel = try await guestAgent.openInputChannel()
            } catch {
                throw Self.wireError(for: error)
            }
            let guestAgent = self.guestAgent
            router = InputRouter(
                channel: channel,
                focusDisplay: { displayID in
                    try await guestAgent.focusDisplay(displayID: displayID)
                }
            )
            inputRouter = router
        }

        if let failure = await router.register(
            session: session.id,
            displayID: session.displayID,
            state: session.state
        ) {
            throw .runtime(
                "internal",
                message: "The Android display could not be registered for window input (\(failure)).",
                remediation: "Restart Android, then open the app again."
            )
        }
    }

    private func launchExistingPendingSession(
        _ session: AppSessionSnapshot
    ) async throws(RuntimeWireError) -> RuntimeLaunchResult {
        let report: GuestLaunchReport
        do throws(GuestAgentFailure) {
            report = try await guestAgent.launch(package: session.packageID, displayID: session.displayID)
        } catch {
            if !Self.isTransientLaunchFailure(error) {
                await endFailedLaunch(session.id)
            }
            throw Self.wireError(for: error)
        }

        guard let completed = await registry.launchCompleted(packageID: session.packageID, taskID: report.taskID) else {
            if let current = await registry.session(session.id), Self.isEnded(current.state) {
                await stopDrainingFrames(for: session.id)
                return try Self.launchResult(for: current)
            }
            if let current = await registry.session(session.id),
                current.state == .running || current.state == .backgrounded
            {
                return try Self.launchResult(for: current)
            }
            throw .runtime("internal", message: "The app launch result could not be associated with its session.")
        }
        guard !Self.isEnded(completed.state) else {
            await stopDrainingFrames(for: session.id)
            return try Self.launchResult(for: completed)
        }

        let running: AppSessionSnapshot
        do throws(SessionRegistryFailure) {
            running = try await registry.transition(session.id, to: .running)
        } catch {
            if let current = await registry.session(session.id), Self.isEnded(current.state) {
                await stopDrainingFrames(for: session.id)
                return try Self.launchResult(for: current)
            }
            throw Self.wireError(for: error)
        }
        return try Self.launchResult(for: running)
    }

    private func ensureGuestObservation() async {
        guard !isShuttingDown else {
            return
        }
        if !hasExportOfferHandler {
            await guestAgent.setExportOfferHandler { [weak self] offer in
                await self?.receiveExportOffer(offer)
            }
            hasExportOfferHandler = true
        }
        if taskEventMonitor == nil {
            let events = await guestAgent.taskEventStream()
            guard !isShuttingDown, taskEventMonitor == nil else {
                return
            }
            let monitor = Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled else {
                        return
                    }
                    await self?.receiveTaskEvent(event)
                }
            }
            taskEventMonitor = monitor
        }
        guard !isShuttingDown, guestResynchronizationHandlerID == nil else {
            return
        }
        let handlerID = await guestAgent.addResynchronizationHandler { [weak self] snapshot in
            await self?.reconcileGuestSnapshot(snapshot)
        }
        if isShuttingDown || guestResynchronizationHandlerID != nil {
            await guestAgent.removeResynchronizationHandler(handlerID)
        } else {
            guestResynchronizationHandlerID = handlerID
        }
    }

    private func receiveExportOffer(_ offer: DevelopmentGuestExportOffer) async {
        guard !isShuttingDown,
            offer.size <= GuestBulkFileReceiver.maximumTransferSize,
            Self.isValidExportMIMEType(offer.mimeType),
            let session = await registry.session(packageID: offer.sourcePackage),
            session.state == .running || session.state == .backgrounded,
            session.displayID == offer.displayID,
            case .app(let sessionID) = session.id,
            let packageID = RuntimePackageID(rawValue: session.packageID)
        else {
            _ = try? await guestAgent.resolveExport(offerID: offer.offerID, decision: .decline)
            return
        }

        let filesEnabled: Bool
        do {
            filesEnabled = try await fileIntegrationEnabled(packageID)
        } catch {
            _ = try? await guestAgent.resolveExport(offerID: offer.offerID, decision: .decline)
            return
        }
        guard filesEnabled, !isShuttingDown else {
            _ = try? await guestAgent.resolveExport(offerID: offer.offerID, decision: .decline)
            return
        }

        pruneExpiredExportOffers()
        guard pendingFileExports.count < DevelopmentGuestAgent.maximumPendingExportOffers else {
            _ = try? await guestAgent.resolveExport(offerID: offer.offerID, decision: .decline)
            return
        }

        let hostOfferID = UUID()
        let safeName = FileNameSanitizer.sanitize(offer.name, packageID: session.packageID)
        let exportOffer = ExportOffer(
            offerID: hostOfferID,
            name: safeName,
            size: Int64(offer.size),
            type: offer.mimeType
        )
        pendingFileExports[hostOfferID] = PendingFileExport(
            guestOffer: offer,
            sessionID: sessionID,
            createdAt: .now
        )
        let delivered = await exportOfferDelivery(sessionID, exportOffer)
        guard !delivered,
            pendingFileExports.removeValue(forKey: hostOfferID) != nil
        else {
            return
        }
        _ = try? await guestAgent.resolveExport(offerID: offer.offerID, decision: .decline)
    }

    private func pruneExpiredExportOffers(now: ContinuousClock.Instant = .now) {
        let expiration = DevelopmentGuestAgent.defaultExportOfferLifetime
        pendingFileExports = pendingFileExports.filter { _, pending in
            pending.createdAt.duration(to: now) < expiration
        }
    }

    private func receiveTaskEvent(_ event: DevelopmentGuestTaskEvent) async {
        guard !isShuttingDown else {
            return
        }
        let packageID: String
        switch event {
        case .appeared(let package, _), .vanished(let package, _):
            packageID = package
        }
        guard let current = await registry.session(packageID: packageID), !isShuttingDown else {
            return
        }

        switch event {
        case .appeared(let package, let taskID):
            guard await registry.taskAppeared(packageID: package, taskID: taskID)?.state == .launching,
                !isShuttingDown
            else {
                return
            }
            let completed = await registry.launchCompleted(packageID: package, taskID: taskID)
            let latest: AppSessionSnapshot
            if let completed {
                latest = completed
            } else if let current = await registry.session(current.id) {
                latest = current
            } else {
                return
            }
            guard latest.state == .launching, !isShuttingDown else {
                return
            }
            do throws(SessionRegistryFailure) {
                _ = try await registry.transition(latest.id, to: .running)
            } catch {
                return
            }
        case .vanished(let package, let taskID):
            let updated = await registry.taskVanished(packageID: package, taskID: taskID)
            if let updated, Self.isEnded(updated.state) {
                await stopDrainingFrames(for: updated.id)
                forgetSession(packageID: package, sessionID: updated.id)
            }
        }
    }

    private func reconcileGuestSnapshot(_ guestSnapshot: GuestSnapshotState) async {
        guard !isShuttingDown else {
            return
        }
        activeResynchronizations += 1
        defer { scheduleResynchronizationCompletion() }
        for sessionID in Array(sessionsByPackage.values) {
            guard !isShuttingDown, await registry.session(sessionID) != nil else {
                continue
            }
            let result: SessionReconciliationResult
            do throws(SessionRegistryFailure) {
                result = try await registry.reconcile(sessionID: sessionID, against: guestSnapshot)
            } catch {
                continue
            }
            if Self.isEnded(result.session.state) {
                await stopDrainingFrames(for: result.session.id)
                forgetSession(packageID: result.session.packageID, sessionID: sessionID)
                continue
            }
            guard !isShuttingDown else {
                return
            }
            if result.session.state == .launching,
                let taskID = result.session.taskIDs.sorted().first
            {
                scheduleObservedLaunch(sessionID: sessionID, taskID: taskID)
            }
            if result.action == .relaunchApplication {
                scheduleRelaunch(sessionID: sessionID)
            }
        }
    }

    private func scheduleResynchronizationCompletion() {
        let taskKey = UUID()
        let task = Task { [weak self, registry = self.registry] in
            await registry.waitForPendingDisplayReleases()
            await self?.finishResynchronization()
            await self?.removeReconciliationTask(taskKey)
        }
        reconciliationTasks[taskKey] = task
    }

    private func scheduleObservedLaunch(sessionID: SessionID, taskID: Int32) {
        let taskKey = UUID()
        let task = Task { [weak self] in
            await self?.completeObservedLaunch(sessionID: sessionID, taskID: taskID)
            await self?.removeReconciliationTask(taskKey)
        }
        reconciliationTasks[taskKey] = task
    }

    private func scheduleRelaunch(sessionID: SessionID) {
        let taskKey = UUID()
        let task = Task { [weak self] in
            await self?.relaunchAfterResynchronization(sessionID: sessionID)
            await self?.removeReconciliationTask(taskKey)
        }
        reconciliationTasks[taskKey] = task
    }

    private func removeReconciliationTask(_ taskKey: UUID) {
        reconciliationTasks[taskKey] = nil
    }

    private func completeObservedLaunch(sessionID: SessionID, taskID: Int32) async {
        guard await acquireOperation() else {
            return
        }
        defer { releaseOperation() }

        guard let current = await registry.session(sessionID),
            current.state == .launching,
            current.taskIDs.contains(taskID),
            !isShuttingDown
        else {
            return
        }
        do throws(SessionRegistryFailure) {
            _ = try await registry.transition(sessionID, to: .running)
        } catch {
            if let latest = await registry.session(sessionID), Self.isEnded(latest.state) {
                await stopDrainingFrames(for: sessionID)
                forgetSession(packageID: current.packageID, sessionID: sessionID)
            }
        }
    }

    private func relaunchAfterResynchronization(sessionID: SessionID) async {
        guard await acquireOperation() else {
            return
        }
        defer { releaseOperation() }

        guard let current = await registry.session(sessionID),
            current.state == .launching,
            current.taskIDs.isEmpty,
            !isShuttingDown
        else {
            return
        }
        let report: GuestLaunchReport
        do throws(GuestAgentFailure) {
            report = try await guestAgent.launch(package: current.packageID, displayID: current.displayID)
        } catch {
            if !isShuttingDown, !Self.isTransientLaunchFailure(error) {
                await endFailedLaunch(sessionID)
            }
            return
        }
        guard !isShuttingDown else {
            return
        }

        let completed = await registry.launchCompleted(packageID: current.packageID, taskID: report.taskID)
        let latest: AppSessionSnapshot
        if let completed {
            latest = completed
        } else if let session = await registry.session(sessionID) {
            latest = session
        } else {
            return
        }
        guard !Self.isEnded(latest.state) else {
            await stopDrainingFrames(for: sessionID)
            forgetSession(packageID: current.packageID, sessionID: sessionID)
            return
        }
        guard latest.state == .launching else {
            return
        }
        do throws(SessionRegistryFailure) {
            _ = try await registry.transition(sessionID, to: .running)
        } catch {
            if let session = await registry.session(sessionID), Self.isEnded(session.state) {
                await stopDrainingFrames(for: sessionID)
                forgetSession(packageID: current.packageID, sessionID: sessionID)
            }
        }
    }

    private func startDrainingFrames(from lease: DisplayLease) {
        guard frameDrainers[lease.session] == nil else {
            return
        }
        let pool = lease.pool
        frameDrainers[lease.session] = Task.detached {
            for await frame in pool.frames {
                guard !Task.isCancelled else {
                    return
                }
                if case .frameReady(_, _, let sequence) = frame {
                    pool.frameDisplayed(sequence: sequence)
                }
            }
        }
    }

    private func stopDrainingFrames(for sessionID: SessionID) async {
        guard let task = frameDrainers.removeValue(forKey: sessionID) else {
            return
        }
        task.cancel()
        await task.value
    }

    private func endFailedLaunch(_ sessionID: SessionID) async {
        await stopDrainingFrames(for: sessionID)
        guard let current = await registry.session(sessionID) else {
            return
        }
        if !Self.isEnded(current.state) {
            _ = try? await registry.transition(sessionID, to: .ended(.error(.runtimeFailed)))
        }
        forgetSession(packageID: current.packageID, sessionID: sessionID)
    }

    private func forgetSession(packageID: String, sessionID: SessionID) {
        if sessionsByPackage[packageID] == sessionID {
            sessionsByPackage[packageID] = nil
        }
    }

    private func releaseOperation() {
        if operationWaiters.isEmpty || activeResynchronizations > 0 {
            operationInFlight = false
            let waiters = shutdownWaiters
            shutdownWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        } else {
            operationWaiters.removeFirst().resume()
        }
    }

    private func finishResynchronization() {
        activeResynchronizations -= 1
        guard activeResynchronizations == 0 else {
            return
        }
        let waiters = resynchronizationWaiters
        resynchronizationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !operationInFlight, !operationWaiters.isEmpty else {
            return
        }
        operationInFlight = true
        operationWaiters.removeFirst().resume()
    }

    private func waitForResynchronizationsToFinish() async {
        guard activeResynchronizations > 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            resynchronizationWaiters.append(continuation)
        }
    }

    private func waitForOperationsToFinish() async {
        guard operationInFlight else {
            return
        }
        await withCheckedContinuation { continuation in
            shutdownWaiters.append(continuation)
        }
    }

    private func acquireOperation() async -> Bool {
        guard !isShuttingDown, !Task.isCancelled else {
            return false
        }
        if !operationInFlight, activeResynchronizations == 0 {
            operationInFlight = true
            return true
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
        guard !isShuttingDown, !Task.isCancelled else {
            releaseOperation()
            return false
        }
        return true
    }

    private static let shuttingDownError = RuntimeWireError.runtime(
        "hostShuttingDown",
        message: "The app session service is shutting down.",
        remediation: "Try again after the runtime has started."
    )

    private static func launchResult(for session: AppSessionSnapshot) throws(RuntimeWireError) -> RuntimeLaunchResult {
        guard case .app(let sessionID) = session.id,
            let packageID = RuntimePackageID(rawValue: session.packageID)
        else {
            throw .runtime("internal", message: "APKRun could not identify the app session.")
        }
        let phase: RuntimeSessionPhase
        switch session.state {
        case .running, .backgrounded: phase = .running
        case .launching: phase = .launching
        case .requested: phase = .starting
        case .waitingForRuntime: phase = .booting
        case .acquiringDisplay: phase = .waitingForPackage
        case .closing, .ended: phase = .ended
        }
        return RuntimeLaunchResult(sessionID: sessionID, packageID: packageID, state: phase)
    }

    private static func isEnded(_ state: AppSessionState) -> Bool {
        if case .ended = state { true } else { false }
    }

    private static func isTransientLaunchFailure(_ failure: GuestAgentFailure) -> Bool {
        switch failure {
        case .connectTimedOut:
            true
        case .operationFailed(let reason):
            reason == "disconnected"
                || reason == "handshakeTimedOut"
                || reason.hasPrefix("timeout.")
                || reason.hasPrefix("agentUnavailable.")
        case .bundleMissing, .installFailed, .startFailed, .stopped, .handshakeFailed, .requiredAgentUnavailable, .adb:
            false
        }
    }

    static func validateFileDrop(
        _ handles: [FileHandle],
        metadata: [ImportFileInfo],
        packageID: RuntimePackageID
    ) throws(RuntimeWireError) -> [PreparedFileImport] {
        guard !handles.isEmpty else {
            throw integrationWireError(.emptyFileSet)
        }
        guard handles.count == metadata.count,
            metadata.enumerated().allSatisfy({ index, item in item.fileIndex == index })
        else {
            throw integrationWireError(.invalidMetadata)
        }
        guard handles.count <= FileTransferLimits.maximumFileCount else {
            throw integrationWireError(
                .tooManyFiles(count: handles.count, limit: FileTransferLimits.maximumFileCount)
            )
        }

        var unhashed: [UnhashedFileImport] = []
        var limitItems: [FileTransferItem] = []
        unhashed.reserveCapacity(handles.count)
        limitItems.reserveCapacity(handles.count)

        for (index, item) in metadata.enumerated() {
            guard item.size >= 0, !item.uti.isEmpty, item.uti.utf8.count <= 255,
                !item.uti.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else {
                throw integrationWireError(.invalidMetadata)
            }
            let handle = handles[index]
            var status = stat()
            guard Darwin.fstat(handle.fileDescriptor, &status) == 0,
                status.st_mode & S_IFMT == S_IFREG,
                status.st_size >= 0
            else {
                throw integrationWireError(.invalidFileHandle)
            }
            guard UInt64(item.size) == UInt64(status.st_size) else {
                throw integrationWireError(.invalidMetadata)
            }

            let safeName = FileNameSanitizer.sanitize(item.name, packageID: packageID.rawValue)
            let size = UInt64(status.st_size)
            limitItems.append(FileTransferItem(name: safeName, sizeBytes: size))
            let uti = UTType(item.uti)
            let fileExtension = (safeName as NSString).pathExtension
            let mimeType =
                uti?.preferredMIMEType
                ?? UTType(filenameExtension: fileExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            unhashed.append(UnhashedFileImport(handle: handle, name: safeName, mimeType: mimeType, size: size))
        }

        do {
            _ = try FileTransferLimits.validate(limitItems)
        } catch {
            throw integrationWireError(error)
        }

        var transferIDs = Set<UInt64>()
        return try unhashed.map { item in
            let digest = try hashFile(item.handle, expectedSize: item.size)
            let transferID = makeTransferID(excluding: transferIDs)
            transferIDs.insert(transferID)
            return PreparedFileImport(
                handle: item.handle,
                transferID: transferID,
                name: item.name,
                mimeType: item.mimeType,
                size: item.size,
                sha256: digest
            )
        }
    }

    private static func hashFile(
        _ handle: FileHandle,
        expectedSize: UInt64
    ) throws(RuntimeWireError) -> Data {
        var hasher = SHA256()
        var offset: UInt64 = 0
        while offset < expectedSize {
            let requested = Int(min(UInt64(1_048_576), expectedSize - offset))
            var chunk = [UInt8](repeating: 0, count: requested)
            let count = chunk.withUnsafeMutableBytes { buffer in
                Darwin.pread(
                    handle.fileDescriptor,
                    buffer.baseAddress,
                    requested,
                    off_t(offset)
                )
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else {
                throw integrationWireError(.invalidFileHandle)
            }
            hasher.update(data: Data(chunk.prefix(count)))
            offset += UInt64(count)
        }

        var currentStatus = stat()
        guard Darwin.fstat(handle.fileDescriptor, &currentStatus) == 0,
            currentStatus.st_mode & S_IFMT == S_IFREG,
            currentStatus.st_size >= 0,
            UInt64(currentStatus.st_size) == expectedSize
        else {
            throw integrationWireError(.invalidFileHandle)
        }
        return Data(hasher.finalize())
    }

    private static func makeTransferID(excluding existing: Set<UInt64>) -> UInt64 {
        var candidate = UInt64.random(in: 1...(UInt64.max / 2)) << 1
        while existing.contains(candidate) {
            candidate = UInt64.random(in: 1...(UInt64.max / 2)) << 1
        }
        return candidate
    }

    static func isValidContentURI(_ value: String, authority: String, pathPrefix: String) -> Bool {
        guard value.utf8.count <= 2_048,
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            let components = URLComponents(string: value),
            components.scheme == "content",
            components.host == authority,
            components.user == nil,
            components.password == nil,
            components.port == nil,
            components.query == nil,
            components.fragment == nil,
            components.percentEncodedPath.hasPrefix(pathPrefix)
        else {
            return false
        }
        let pathComponents = components.percentEncodedPath.split(separator: "/")
        if pathPrefix == "/shared/" {
            return pathComponents.count == 2
                && pathComponents[0] == "shared"
                && UUID(uuidString: String(pathComponents[1])) != nil
        }
        return pathComponents.count == 3
            && pathComponents[0] == "external"
            && pathComponents[1] == "downloads"
            && !pathComponents[2].isEmpty
            && pathComponents[2].allSatisfy(\.isNumber)
    }

    private static func isValidExportMIMEType(_ value: String) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return value.utf8.count <= 255
            && components.count == 2
            && components.allSatisfy { !$0.isEmpty }
            && !value.unicodeScalars.contains {
                CharacterSet.whitespacesAndNewlines.contains($0)
                    || CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func integrationWireError(_ failure: IntegrationFailure) -> RuntimeWireError {
        let message: String
        let remediation: String?
        switch failure {
        case .emptyFileSet, .invalidMetadata, .invalidFileHandle:
            message = "APKRun couldn't verify the dropped files."
            remediation = "Choose the files again and retry the drop."
        case .filesDisabled:
            message = "File sharing is turned off for this app."
            remediation = "Turn on Files in the app's APKRun settings, then retry."
        case .tooManyFiles:
            message = "The drop contains more files than APKRun can send at once."
            remediation = "Choose up to 20 files, then retry."
        case .fileTooLarge:
            message = "A dropped file exceeds APKRun's transfer limit."
            remediation = "Choose files smaller than 2 GiB each and 4 GiB total."
        case .transferFailed:
            message = "APKRun couldn't deliver the dropped files to Android."
            remediation = "Check that Android is running, then retry the drop."
        case .folderUnavailable, .pathRejected, .packageAccessDenied, .readOnly, .resourceExhausted, .itemNotFound,
            .invalidRequest, .invalidRootConfiguration:
            message = "The file integration request couldn't be completed."
            remediation = "Check the file integration settings, then retry."
        }
        return RuntimeWireError(
            domain: failure.domain.rawValue,
            code: failure.qualifiedCode,
            message: message,
            remediation: remediation
        )
    }

    private static let defaultDisplayConfiguration = DisplayConfiguration(
        geometry: DisplayGeometry(
            pointSize: CGSize(width: 480, height: 850),
            backingScale: 1
        )
    )

    private static func wireError(for failure: SessionRegistryFailure) -> RuntimeWireError {
        switch failure {
        case .invalidPackageIdentifier:
            .runtime("invalidPackageID", message: "The Android package identifier is invalid.")
        case .displayInUse(let packageID):
            .runtime(
                "primaryDisplayBusy",
                message: "\(packageID) is already using the compatibility window mode.",
                remediation: "Close \(packageID) or switch it to the standard secondary display mode."
            )
        case .sessionAlreadyExists(let packageID):
            .runtime(
                "sessionAlreadyExists",
                message: "\(packageID) already has a live app session on another display.",
                remediation: "Close its current app session before requesting another display."
            )
        case .displayPool(let failure):
            wireError(for: failure)
        case .sessionNotFound, .invalidTransition:
            .runtime("internal", message: "The app session is in an invalid state.")
        }
    }

    private static func wireError(for failure: DisplayPoolFailure) -> RuntimeWireError {
        switch failure {
        case .exhausted:
            .runtime(
                "displayPoolExhausted",
                message: "APKRun could not allocate an Android app display.",
                remediation: "Close another Android app window and retry."
            )
        case .attachFailed:
            .runtime(
                "displayAttachFailed",
                message: "Android couldn't create a window for the app.",
                remediation: "Restart Android. If it happens again, create a diagnostics report."
            )
        case .staleLease:
            .runtime("internal", message: "The Android display lease is no longer current.")
        case .invalidGeometry:
            .runtime("displayGeometryInvalid", message: "The requested app window size is invalid.")
        case .reconfigureFailed(let stateUncertain):
            .runtime(
                "displayReconfigureFailed",
                message: "Android did not confirm the requested app window size.",
                remediation: stateUncertain
                    ? "Restart Android before reusing this display."
                    : "The previous display mode was restored. Try resizing again."
            )
        case .guest(.unavailable):
            .runtime(
                "guestAgentUnavailable",
                message: "The Android Guest Agent is unavailable.",
                remediation: "Boot Android with the development Guest Agent, then retry."
            )
        case .guest(.operationFailed):
            .runtime(
                "guestAgentOperationFailed",
                message: "The Android Guest Agent could not apply the display policy.",
                remediation: "Restart Android and try again."
            )
        case .graphics(let failure):
            RuntimeWireError(
                domain: "graphics",
                code: "graphics.\(failure.code)",
                message: "APKRun couldn't prepare the graphics display.",
                remediation: "Restart Android. If the problem continues, create a diagnostics report."
            )
        case .primaryDisplayBusy:
            .runtime("primaryDisplayBusy", message: "Another app is already using the compatibility display.")
        case .primaryDisplayUnavailable:
            .runtime(
                "displayAttachFailed",
                message: "The compatibility display has no active graphics presenter."
            )
        }
    }

    static let guestTasksStillRunningError = RuntimeWireError.runtime(
        "guestAgentOperationFailed",
        message: "Android still reports tasks for this app.",
        remediation: "Wait for the app to close, then try again."
    )

    static let packageNotInstalledError = RuntimeWireError.runtime(
        "packageNotInstalled",
        message: "This app is not installed in Android.",
        remediation: "Install the app first, then try again."
    )

    static func wireError(for failure: GuestAgentFailure) -> RuntimeWireError {
        switch failure {
        case .bundleMissing:
            .runtime(
                "guestAgentBundleMissing",
                message: "APKRun can't find the Guest Agent for Android.",
                remediation: "Build the Guest Agent or restore the bundled agent, then try again."
            )
        case .installFailed(let reason):
            .runtime(
                "guestAgentInstallFailed",
                message: "Android didn't install the Guest Agent: \(reason).",
                remediation: "Check the install reason, fix Android, then try again."
            )
        case .startFailed:
            .runtime(
                "guestAgentStartFailed",
                message: "The Guest Agent didn't start.",
                remediation: "Restart Android and try again."
            )
        case .connectTimedOut:
            .runtime(
                "guestAgentConnectTimedOut",
                message: "APKRun couldn't connect to the Guest Agent within 30 seconds.",
                remediation: "Restart Android and try again."
            )
        case .stopped:
            .runtime(
                "guestAgentStopped",
                message: "The Guest Agent start was stopped before it answered.",
                remediation: "Start Android again and retry."
            )
        case .handshakeFailed(let reason):
            .runtime(
                "guestAgentHandshakeFailed",
                message: "The Guest Agent refused the connection: \(reason).",
                remediation: "Update APKRun and Android so they use the same Guest Agent protocol."
            )
        case .requiredAgentUnavailable:
            .runtime(
                "requiredAgentUnavailable",
                message: "The Guest Agent in Android isn't available.",
                remediation: "Restart Android."
            )
        case .adb:
            .runtime(
                "guestAgentOperationFailed",
                message: "The Android Guest Agent could not complete the app operation.",
                remediation: "Check the Android runtime and try again."
            )
        case .operationFailed(let reason):
            .runtime(
                "guestAgentOperationFailed",
                message: "The Guest Agent didn't complete the request: \(reason).",
                remediation: "Try again. If it fails again, restart Android."
            )
        }
    }

    private static func wireError(for failure: DevelopmentGuestExportReceiveFailure) -> RuntimeWireError {
        switch failure {
        case .guestAgent(let failure):
            wireError(for: failure)
        case .fileTransfer:
            integrationWireError(.transferFailed)
        }
    }
}

protocol DaemonHeadlessGuestAgent: EmbeddedSessionGuestAgent {
    func openInputChannel() async throws(GuestAgentFailure) -> any InputChannel
    func taskEventStream() async -> AsyncStream<DevelopmentGuestTaskEvent>
    func setExportOfferHandler(
        _ handler: (@Sendable (DevelopmentGuestExportOffer) async -> Void)?
    ) async
    func resolveExport(
        offerID: UUID,
        decision: GuestExportDecision
    ) async throws(GuestAgentFailure) -> GuestExportStart
    func prepareExportFileReceive(
        expectedSize: UInt64,
        destination: FileHandle
    ) async throws(DevelopmentGuestExportReceiveFailure) -> GuestBulkFileReceiver
    func transferFile(
        _ fileHandle: FileHandle,
        transferID: UInt64,
        name: String,
        mimeType: String,
        size: UInt64,
        sha256: Data
    ) async throws(GuestAgentFailure)
    func importFiles(
        package: String,
        displayID: Int32,
        files: [GuestFileReference]
    ) async throws(GuestAgentFailure) -> GuestFileImportResult
}

extension DaemonHeadlessGuestAgent {
    func openInputChannel() async throws(GuestAgentFailure) -> any InputChannel {
        throw .operationFailed(reason: "agentUnavailable.input")
    }
}

extension DevelopmentGuestAgent: DaemonHeadlessGuestAgent {
    func openInputChannel() async throws(GuestAgentFailure) -> any InputChannel {
        try await inputChannel()
    }

    func taskEventStream() async -> AsyncStream<DevelopmentGuestTaskEvent> {
        taskEvents
    }
}
