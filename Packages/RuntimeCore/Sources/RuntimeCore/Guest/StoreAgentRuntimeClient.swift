import CryptoKit
import DiagnosticsCore
import Foundation
import GuestProtocol
import RuntimeAPI

/// Protocol-facing Store Agent client used by RuntimeHost's APKStoreCore channel adapter.
///
/// It opens the control session first, then binds the artifacts session to the control token. APKStoreCore talks to
/// the Store Agent only through RuntimeHost's `StoreAgentChannel`; wire messages stay inside RuntimeCore.
public actor GuestStoreAgentClient {
    /// The Store Agent control connection and its token-bound artifact connection.
    private struct Session: Sendable {
        let control: GuestConnection
        let artifacts: GuestConnection
        let capabilities: Set<String>
        let generation: UUID
    }

    private struct InstallWaiter {
        let continuation: AsyncStream<GPInstallFinished>.Continuation
    }

    /// One MiB is the protocol's maximum chunk size (guest-protocol.md §10).
    public static let maximumChunkSize = 1_048_576
    /// The Android PackageInstaller protocol limits individual APKs to 2 GiB.
    public static let maximumArtifactSize: UInt64 = 2 * 1_024 * 1_024 * 1_024
    /// The host gives artifact writes a 30-second stall timeout (package-store.md §6.2).
    public static let artifactStallTimeout: Duration = .seconds(30)
    /// The Store Agent reports final PackageInstaller status within ten minutes (package-store.md §6.2).
    public static let defaultInstallOutcomeTimeout: Duration = .seconds(600)
    /// Control keepalive cadence and unanswered-ping timeout (guest-protocol.md §6).
    public static let defaultKeepaliveInterval: Duration = .seconds(5)
    private static let missedPingLimit = 3
    private static let sessionOpenRetryDelays: [Duration] = [
        .milliseconds(25),
        .milliseconds(50),
        .milliseconds(100),
        .milliseconds(200),
        .milliseconds(400),
        .milliseconds(400),
    ]

    /// The public event stream for PackageManager changes.
    public nonisolated let packageEvents: AsyncStream<RuntimeStorePackageEvent>
    /// Signals a lost session even when the package event stream remains open.
    public nonisolated let disconnectionEvents: AsyncStream<Void>

    /// The last capabilities negotiated on a Store Agent control session.
    public nonisolated var capabilities: RuntimeStoreCapabilities {
        state.snapshot.capabilities
    }

    /// Whether the current Store Agent control and artifact streams are both open.
    public nonisolated var isConnected: Bool {
        state.snapshot.isConnected
    }

    private let transport: StoreAgentProtocolTransport
    private let hostVersion: String
    private let logSink: (any LogSink)?
    private let installOutcomeTimeout: Duration
    private let keepaliveInterval: Duration
    private let state = RuntimeStoreAgentState()
    private let eventContinuation: AsyncStream<RuntimeStorePackageEvent>.Continuation
    private let disconnectionContinuation: AsyncStream<Void>.Continuation
    private var session: Session?
    private var connectionTask: Task<Session, any Error>?
    private var connectionAttemptID: UUID?
    private var eventTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var nextTransferID: UInt64 = 2
    private var transferInProgress = false
    private var transferWaiters: [CheckedContinuation<Void, Never>] = []
    private var installWaiters: [String: [UUID: InstallWaiter]] = [:]
    private var completedInstalls: [String: GPInstallFinished] = [:]

    /// Creates a lazy Store Agent channel over the supplied guest transport.
    public init(
        transport: any RuntimeGuestTransport,
        hostVersion: String = "dev",
        logSink: (any LogSink)? = nil,
        installOutcomeTimeout: Duration = GuestStoreAgentClient.defaultInstallOutcomeTimeout,
        keepaliveInterval: Duration = GuestStoreAgentClient.defaultKeepaliveInterval
    ) {
        self.transport = StoreAgentProtocolTransport(transport: transport)
        self.hostVersion = hostVersion
        self.logSink = logSink
        self.installOutcomeTimeout = installOutcomeTimeout
        self.keepaliveInterval = keepaliveInterval
        let stream = AsyncStream.makeStream(
            of: RuntimeStorePackageEvent.self,
            bufferingPolicy: .bufferingNewest(1_024)
        )
        packageEvents = stream.stream
        eventContinuation = stream.continuation
        let disconnections = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(8)
        )
        disconnectionEvents = disconnections.stream
        disconnectionContinuation = disconnections.continuation
    }

    /// Opens and handshakes both Store Agent endpoints before returning the channel.
    public static func connect(
        transport: any RuntimeGuestTransport,
        hostVersion: String = "dev",
        logSink: (any LogSink)? = nil,
        installOutcomeTimeout: Duration = GuestStoreAgentClient.defaultInstallOutcomeTimeout,
        keepaliveInterval: Duration = GuestStoreAgentClient.defaultKeepaliveInterval
    ) async throws -> GuestStoreAgentClient {
        let supervisor = GuestStoreAgentClient(
            transport: transport,
            hostVersion: hostVersion,
            logSink: logSink,
            installOutcomeTimeout: installOutcomeTimeout,
            keepaliveInterval: keepaliveInterval
        )
        _ = try await supervisor.connectedSession()
        return supervisor
    }

    /// Inspects an artifact set with Android's parser before installation.
    public func inspect(_ artifacts: [RuntimeStoreArtifactSpec], files: [URL]) async throws -> RuntimeStoreArchiveInfo {
        try await acquireTransfer()
        defer { releaseTransfer() }

        let validated = try Self.validateArtifactSet(artifacts, files: files)
        let active = try await connectedSession()
        try Self.requireCapability(.storeMetadata, in: active)
        let refs = try await streamArtifacts(validated, context: "inspect", on: active.artifacts)
        let result = try await active.control.send(GuestInspectArchive(artifacts: refs))
        return try Self.archiveInfo(result)
    }

    /// Installs a set only after Android's archive parser confirms package, version, and signing identity.
    public func install(_ request: RuntimeStoreInstallRequest, files: [URL]) async throws -> RuntimeStorePackageInfo {
        try await acquireTransfer()
        defer { releaseTransfer() }

        guard !request.allowDowngrade else {
            throw RuntimeStoreAgentFailure.downgradeNotSupported
        }
        guard request.versionCode >= 0 else {
            throw RuntimeStoreAgentFailure.invalidRuntimeVersionCode
        }
        let validated = try Self.validateArtifactSet(request.artifacts, files: files)
        let active = try await connectedSession()
        try Self.requireCapability(.storeMetadata, in: active)
        try Self.requireCapability(.storeInstall, in: active)

        let inspectionRefs = try await streamArtifacts(validated, context: "inspect", on: active.artifacts)
        let inspected = try Self.archiveInfo(
            await active.control.send(GuestInspectArchive(artifacts: inspectionRefs))
        )
        try Self.validate(inspected, against: request)

        var begin = GPInstallRequest()
        begin.expectedPackage = request.packageID.rawValue
        begin.expectedVersionCode = request.versionCode
        begin.expectedSignerSha256 = try Self.protocolSignerDigests(for: request)
        begin.mode = Self.installMode(request.mode)
        begin.requestUpdateOwnership = false
        begin.allowDowngrade = false
        begin.artifacts = try validated.map(Self.protocolArtifactSpec)
        // PackageManager.INSTALL_REASON_USER and PackageInstaller.PACKAGE_SOURCE_OTHER.
        begin.installReason = 4
        begin.packageSource = 1
        begin.enableRollback = false

        let started = try await active.control.send(GuestBeginInstall(begin))
        guard !started.installID.isEmpty else {
            throw RuntimeStoreAgentFailure.invalidInstallID
        }

        var commitRequested = false
        do {
            _ = try await streamArtifacts(validated, context: started.installID, on: active.artifacts)
            try Task.checkCancellation()

            // Register before CommitInstall: the agent may emit InstallFinished immediately after the response.
            let (waiterID, finishedEvents) = registerInstallWaiter(started.installID)
            try Task.checkCancellation()
            commitRequested = true
            _ = try await active.control.send(
                GuestCommitInstall(installID: started.installID),
                timeout: .seconds(120)
            )
            let finished = try await waitForInstallFinished(finishedEvents, installID: started.installID)
            unregisterInstallWaiter(started.installID, waiterID: waiterID)
            guard finished.installID == started.installID else {
                throw RuntimeStoreAgentFailure.installOutcomeMismatch
            }
            guard finished.status == .success else {
                throw RuntimeStoreAgentFailure.installFailed(
                    status: Int32(finished.status.rawValue),
                    legacyStatus: finished.legacyStatus,
                    message: finished.message
                )
            }
            guard finished.installedVersionCode == request.versionCode else {
                throw RuntimeStoreAgentFailure.installVersionMismatch(
                    expected: request.versionCode,
                    actual: finished.installedVersionCode
                )
            }

            let metadata = try await packageInfo(request.packageID)
            guard let metadata else {
                throw RuntimeStoreAgentFailure.packageNotInstalled(request.packageID)
            }
            guard metadata.packageID == request.packageID else {
                throw RuntimeStoreAgentFailure.packageMismatch(
                    expected: request.packageID,
                    actual: metadata.packageID
                )
            }
            guard metadata.versionCode == request.versionCode else {
                throw RuntimeStoreAgentFailure.installVersionMismatch(
                    expected: request.versionCode,
                    actual: metadata.versionCode
                )
            }
            guard Set(metadata.signingDigests) == Set(inspected.signingDigests) else {
                throw RuntimeStoreAgentFailure.signerMismatch
            }
            return metadata
        } catch {
            // The event stream is registered before CommitInstall and can outlive a cancelled caller.
            // Removing it here also releases its bounded buffer.
            if let waiters = installWaiters[started.installID] {
                installWaiters.removeValue(forKey: started.installID)
                for waiter in waiters.values {
                    waiter.continuation.finish()
                }
            }
            if !commitRequested {
                await abandonInstall(started.installID, on: active.control)
            }
            throw error
        }
    }

    /// Uninstalls through Android's PackageInstaller-backed Store Agent operation.
    public func uninstall(_ package: RuntimePackageID, keepData: Bool) async throws {
        let active = try await connectedSession()
        try Self.requireCapability(.storeInstall, in: active)
        let result = try await active.control.send(
            GuestUninstallPackage(package: package.rawValue, keepData: keepData)
        )
        guard result.status == .success else {
            throw RuntimeStoreAgentFailure.uninstallFailed(message: result.message)
        }
    }

    /// Returns validated PackageManager metadata, or nil when the package is absent.
    public func packageInfo(_ package: RuntimePackageID) async throws -> RuntimeStorePackageInfo? {
        let active = try await connectedSession()
        try Self.requireCapability(.storeMetadata, in: active)
        do {
            let result = try await active.control.send(GuestGetStorePackageMetadata(package: package.rawValue))
            let info = try Self.packageInfo(result)
            guard info.packageID == package else {
                throw RuntimeStoreAgentFailure.packageMismatch(expected: package, actual: info.packageID)
            }
            return info
        } catch let failure as GuestProtocolFailure {
            if case .remote(code: .notFound, message: _, operation: _) = failure {
                return nil
            }
            throw failure
        }
    }

    /// Lists Store Agent packages using Android's launcher-component metadata.
    public func listPackages(_ filter: RuntimeStorePackageFilter) async throws -> [RuntimeStorePackageSummary] {
        let guestFilter: GPManagedPackageFilter
        switch filter {
        case .launchable, .userInstalled, .all:
            guestFilter = .allUserInstalled
        }

        let active = try await connectedSession()
        try Self.requireCapability(.storeMetadata, in: active)
        let result = try await active.control.send(GuestListManagedPackages(filter: guestFilter))
        let packages = try result.packages.map { rawInfo in
            let info = try Self.packageInfo(rawInfo)
            return RuntimeStorePackageSummary(
                packageID: info.packageID,
                displayName: info.displayName,
                versionCode: info.versionCode,
                launchable: info.launchableComponent != nil,
                userInstalled: true
            )
        }
        return filter == .launchable ? packages.filter(\.launchable) : packages
    }

    /// Lists full metadata for all packages installed for the current Android user.
    public func listManagedPackages() async throws -> [RuntimeStorePackageInfo] {
        let active = try await connectedSession()
        try Self.requireCapability(.storeMetadata, in: active)
        let result = try await active.control.send(
            GuestListManagedPackages(filter: .allUserInstalled)
        )
        return try result.packages.map(Self.packageInfo)
    }

    /// Closes both streams and stops forwarding events.
    public func close() async {
        stopSessionTasks()
        connectionTask?.cancel()
        connectionTask = nil
        connectionAttemptID = nil
        let active = session
        session = nil
        markDisconnected()
        failAllInstallWaiters(RuntimeStoreAgentFailure.disconnected)
        if let active {
            await active.control.close()
            await active.artifacts.close()
        }
        disconnectionContinuation.finish()
    }

    private func connectedSession() async throws -> Session {
        if let session,
            await session.control.isUsable,
            await session.artifacts.isUsable
        {
            return session
        }

        if let session {
            stopSessionTasks()
            await session.control.close()
            await session.artifacts.close()
            self.session = nil
            failAllInstallWaiters(RuntimeStoreAgentFailure.disconnected)
        }
        markDisconnected()

        if let connectionTask {
            let attemptID = connectionAttemptID
            do {
                let active = try await connectionTask.value
                guard let attemptID, connectionAttemptID == attemptID else {
                    await active.control.close()
                    await active.artifacts.close()
                    throw RuntimeStoreAgentFailure.disconnected
                }
                installConnectedSession(active)
                return active
            } catch {
                if connectionAttemptID == attemptID {
                    self.connectionTask = nil
                    connectionAttemptID = nil
                    markDisconnected()
                }
                throw error
            }
        }

        let transport = self.transport
        let hostVersion = self.hostVersion
        let attemptID = UUID()
        let task = Task<Session, any Error> {
            try await Self.openSession(
                transport: transport,
                hostVersion: hostVersion,
                logSink: logSink
            )
        }
        connectionTask = task
        connectionAttemptID = attemptID
        do {
            let active = try await task.value
            guard connectionAttemptID == attemptID else {
                await active.control.close()
                await active.artifacts.close()
                throw RuntimeStoreAgentFailure.disconnected
            }
            installConnectedSession(active)
            return active
        } catch {
            if connectionAttemptID == attemptID {
                connectionTask = nil
                connectionAttemptID = nil
                markDisconnected()
            }
            throw error
        }
    }

    private static func openSession(
        transport: StoreAgentProtocolTransport,
        hostVersion: String,
        logSink: (any LogSink)?
    ) async throws -> Session {
        for attempt in 0...sessionOpenRetryDelays.count {
            let control = GuestConnection(
                endpoint: .storeControl,
                transport: transport,
                hostVersion: hostVersion,
                logSink: logSink
            )
            var artifacts: GuestConnection?
            do {
                let controlInfo = try await control.open()
                let openedArtifacts = GuestConnection(
                    endpoint: .storeArtifacts,
                    transport: transport,
                    presentedToken: controlInfo.sessionToken,
                    hostVersion: hostVersion,
                    logSink: logSink
                )
                artifacts = openedArtifacts
                _ = try await openedArtifacts.open()
                return Session(
                    control: control,
                    artifacts: openedArtifacts,
                    capabilities: Set(controlInfo.enabledCapabilities),
                    generation: UUID()
                )
            } catch {
                await artifacts?.close()
                await control.close()
                guard error == .disconnected, attempt < sessionOpenRetryDelays.count else {
                    throw error
                }
                try await Task.sleep(for: sessionOpenRetryDelays[attempt])
            }
        }
        throw GuestProtocolFailure.disconnected
    }

    private func installConnectedSession(_ active: Session) {
        guard session?.generation != active.generation else {
            return
        }
        connectionTask = nil
        session = active
        state.setCapabilities(Self.storeCapabilities(active.capabilities))
        state.setConnected(true)
        startEventPump(for: active)
        startKeepalive(for: active)
    }

    private func startEventPump(for active: Session) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in active.control.events {
                await self?.receive(event, from: active)
            }
            await self?.connectionEnded(generation: active.generation)
        }
    }

    private func startKeepalive(for active: Session) {
        keepaliveTask?.cancel()
        let interval = keepaliveInterval
        keepaliveTask = Task { [weak self] in
            var misses = 0
            var nonce: UInt64 = 0
            while !Task.isCancelled {
                let cycleStart = ContinuousClock.now
                nonce &+= 1
                do {
                    let pong = try await active.control.send(
                        GuestPing(nonce: nonce),
                        timeout: interval,
                        grace: .zero
                    )
                    guard pong.nonce == nonce else {
                        await self?.connectionEnded(generation: active.generation)
                        return
                    }
                    misses = 0
                } catch let failure as GuestProtocolFailure {
                    guard !Task.isCancelled else {
                        return
                    }
                    if await !active.control.isUsable {
                        await self?.connectionEnded(generation: active.generation)
                        return
                    }
                    if case .timeout(operation: "Ping") = failure {
                        misses += 1
                        if misses < Self.missedPingLimit {
                            // A timeout consumes the ping interval. Continue counting misses without adding delay.
                            continue
                        }
                    }
                    await self?.connectionEnded(generation: active.generation)
                    return
                } catch {
                    guard !Task.isCancelled else {
                        return
                    }
                    await self?.connectionEnded(generation: active.generation)
                    return
                }

                guard !Task.isCancelled else {
                    return
                }
                let elapsed = ContinuousClock.now - cycleStart
                if elapsed < interval {
                    try? await Task.sleep(for: interval - elapsed)
                }
            }
        }
    }

    private func receive(_ event: GPEvent, from active: Session) async {
        guard session?.generation == active.generation, let kind = event.kind else {
            return
        }
        switch kind {
        case .installFinished(let finished):
            deliver(finished)
        case .packageChanged(let package), .storePackageChanged(let package):
            do {
                eventContinuation.yield(try Self.packageEvent(package))
            } catch {
                await active.control.close()
                await connectionEnded(generation: active.generation)
            }
        default:
            break
        }
    }

    private func connectionEnded(generation: UUID) async {
        guard session?.generation == generation else {
            return
        }
        let ended = session
        markDisconnected()
        session = nil
        stopSessionTasks()
        failAllInstallWaiters(RuntimeStoreAgentFailure.disconnected)
        await ended?.control.close()
        await ended?.artifacts.close()
    }

    private func stopSessionTasks() {
        eventTask?.cancel()
        eventTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    private func markDisconnected() {
        if state.snapshot.isConnected {
            disconnectionContinuation.yield(())
        }
        state.setConnected(false)
    }

    private func deliver(_ finished: GPInstallFinished) {
        if let waiters = installWaiters.removeValue(forKey: finished.installID), !waiters.isEmpty {
            for waiter in waiters.values {
                waiter.continuation.yield(finished)
                waiter.continuation.finish()
            }
            return
        }

        completedInstalls[finished.installID] = finished
        if completedInstalls.count > 64, let oldest = completedInstalls.keys.first {
            completedInstalls.removeValue(forKey: oldest)
        }
    }

    private func registerInstallWaiter(_ installID: String) -> (UUID, AsyncStream<GPInstallFinished>) {
        let stream = AsyncStream.makeStream(
            of: GPInstallFinished.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let waiterID = UUID()
        if let finished = completedInstalls.removeValue(forKey: installID) {
            stream.continuation.yield(finished)
            stream.continuation.finish()
            return (waiterID, stream.stream)
        }
        installWaiters[installID, default: [:]][waiterID] = InstallWaiter(continuation: stream.continuation)
        return (waiterID, stream.stream)
    }

    private func unregisterInstallWaiter(_ installID: String, waiterID: UUID) {
        guard let waiter = installWaiters[installID]?.removeValue(forKey: waiterID) else {
            return
        }
        if installWaiters[installID]?.isEmpty == true {
            installWaiters.removeValue(forKey: installID)
        }
        waiter.continuation.finish()
    }

    private func waitForInstallFinished(
        _ events: AsyncStream<GPInstallFinished>,
        installID: String
    ) async throws -> GPInstallFinished {
        try await withThrowingTaskGroup(of: GPInstallFinished.self) { group in
            group.addTask {
                for await finished in events {
                    return finished
                }
                throw RuntimeStoreAgentFailure.disconnected
            }
            group.addTask { [installOutcomeTimeout] in
                try await Task.sleep(for: installOutcomeTimeout)
                throw RuntimeStoreAgentFailure.installOutcomeTimedOut(installID)
            }
            defer { group.cancelAll() }
            guard let finished = try await group.next() else {
                throw RuntimeStoreAgentFailure.installOutcomeTimedOut(installID)
            }
            return finished
        }
    }

    private func failAllInstallWaiters(_ failure: any Error) {
        let all = installWaiters.values.flatMap(\.values)
        installWaiters.removeAll()
        for waiter in all {
            _ = failure
            waiter.continuation.finish()
        }
    }

    private func abandonInstall(_ installID: String, on control: GuestConnection) async {
        _ = try? await control.send(GuestAbandonInstall(installID: installID))
    }

    private func streamArtifacts(
        _ artifacts: [ValidatedArtifact],
        context: String,
        on connection: GuestConnection
    ) async throws -> [GPArtifactRef] {
        var refs: [GPArtifactRef] = []
        refs.reserveCapacity(artifacts.count)
        for artifact in artifacts {
            try Task.checkCancellation()
            let transferID = try allocateTransferID()
            try await streamArtifact(artifact, transferID: transferID, context: context, on: connection)
            var ref = GPArtifactRef()
            ref.transferID = transferID
            ref.name = artifact.spec.name
            refs.append(ref)
        }
        return refs
    }

    private func streamArtifact(
        _ artifact: ValidatedArtifact,
        transferID: UInt64,
        context: String,
        on connection: GuestConnection
    ) async throws {
        var begin = GPBulkBegin()
        begin.kind = .installArtifact
        begin.name = artifact.spec.name
        begin.mimeType = "application/vnd.android.package-archive"
        begin.size = artifact.spec.size
        begin.sha256 = try Self.digestBytes(artifact.spec.sha256)
        begin.context = context
        var frame = GPBulkFrame()
        frame.transferID = transferID
        frame.kind = .begin(begin)

        var didBegin = false
        do {
            try await sendArtifactFrame(frame, transferID: transferID, on: connection)
            didBegin = true
            let handle = try FileHandle(forReadingFrom: artifact.file)
            defer { try? handle.close() }

            var hasher = SHA256()
            var total: UInt64 = 0
            while true {
                try Task.checkCancellation()
                guard let chunk = try handle.read(upToCount: Self.maximumChunkSize), !chunk.isEmpty else {
                    break
                }
                let nextTotal = total.addingReportingOverflow(UInt64(chunk.count))
                guard !nextTotal.overflow, nextTotal.partialValue <= artifact.spec.size else {
                    throw RuntimeStoreAgentFailure.artifactSizeMismatch(
                        name: artifact.spec.name,
                        expected: artifact.spec.size,
                        actual: nextTotal.partialValue
                    )
                }
                hasher.update(data: chunk)
                total = nextTotal.partialValue
                frame = GPBulkFrame()
                frame.transferID = transferID
                frame.kind = .chunk(chunk)
                try await sendArtifactFrame(frame, transferID: transferID, on: connection)
            }

            let digestHex = Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
            guard total == artifact.spec.size else {
                throw RuntimeStoreAgentFailure.artifactSizeMismatch(
                    name: artifact.spec.name,
                    expected: artifact.spec.size,
                    actual: total
                )
            }
            guard digestHex == artifact.spec.sha256 else {
                throw RuntimeStoreAgentFailure.artifactDigestMismatch(artifact.spec.name)
            }

            frame = GPBulkFrame()
            frame.transferID = transferID
            frame.kind = .end(GPBulkEnd())
            try await sendArtifactFrame(frame, transferID: transferID, on: connection)
            let acknowledgement = try await receiveAcknowledgement(for: transferID, on: connection)
            guard acknowledgement.status == .ok else {
                throw RuntimeStoreAgentFailure.bulkTransferRejected(
                    status: Int32(acknowledgement.status.rawValue)
                )
            }
        } catch {
            if didBegin {
                var abort = GPBulkFrame()
                abort.transferID = transferID
                var body = GPBulkAbort()
                body.reason = "host rejected artifact"
                abort.kind = .abort(body)
                try? await sendArtifactFrame(abort, transferID: transferID, on: connection)
            }
            throw error
        }
    }

    private func sendArtifactFrame(
        _ frame: GPBulkFrame,
        transferID: UInt64,
        on connection: GuestConnection
    ) async throws {
        do {
            try await connection.sendBulkFrame(frame, timeout: Self.artifactStallTimeout)
        } catch GuestProtocolFailure.timeout {
            throw RuntimeStoreAgentFailure.artifactTransferTimedOut(transferID)
        } catch {
            throw error
        }
    }

    private func receiveAcknowledgement(
        for transferID: UInt64,
        on connection: GuestConnection
    ) async throws -> GPBulkAck {
        try await withThrowingTaskGroup(of: GPBulkAck.self) { group in
            group.addTask {
                for await frame in connection.bulkFrames {
                    guard frame.transferID == transferID else {
                        throw RuntimeStoreAgentFailure.unexpectedBulkTransfer(frame.transferID)
                    }
                    guard case .ack(let ack)? = frame.kind else {
                        throw RuntimeStoreAgentFailure.unexpectedBulkFrame
                    }
                    return ack
                }
                throw GuestProtocolFailure.disconnected
            }
            group.addTask {
                try await Task.sleep(for: Self.artifactStallTimeout)
                throw RuntimeStoreAgentFailure.artifactTransferTimedOut(transferID)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw RuntimeStoreAgentFailure.artifactTransferTimedOut(transferID)
            }
            return result
        }
    }

    private func allocateTransferID() throws -> UInt64 {
        let id = nextTransferID
        guard id <= UInt64.max - 2 else {
            throw RuntimeStoreAgentFailure.transferIDExhausted
        }
        nextTransferID += 2
        return id
    }

    private func acquireTransfer() async throws {
        if !transferInProgress {
            transferInProgress = true
            return
        }
        await withCheckedContinuation { transferWaiters.append($0) }
        if Task.isCancelled {
            releaseTransfer()
            throw CancellationError()
        }
    }

    private func releaseTransfer() {
        if transferWaiters.isEmpty {
            transferInProgress = false
        } else {
            transferWaiters.removeFirst().resume()
        }
    }

    private static func validateArtifactSet(
        _ specs: [RuntimeStoreArtifactSpec],
        files: [URL]
    ) throws -> [ValidatedArtifact] {
        guard !specs.isEmpty else {
            throw RuntimeStoreAgentFailure.emptyArtifactSet
        }
        guard specs.count == files.count else {
            throw RuntimeStoreAgentFailure.artifactCountMismatch(expected: specs.count, actual: files.count)
        }
        var names = Set<String>()
        return try zip(specs, files).map { spec, file in
            guard Self.isValidArtifactName(spec.name), names.insert(spec.name).inserted else {
                throw RuntimeStoreAgentFailure.invalidArtifactName(spec.name)
            }
            guard spec.size <= maximumArtifactSize else {
                throw RuntimeStoreAgentFailure.artifactTooLarge(name: spec.name, size: spec.size)
            }
            guard file.isFileURL else {
                throw RuntimeStoreAgentFailure.invalidArtifactURL(file.absoluteString)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let number = attributes[.size] as? NSNumber else {
                throw RuntimeStoreAgentFailure.invalidArtifactURL(file.path)
            }
            let actual = number.uint64Value
            guard actual == spec.size else {
                throw RuntimeStoreAgentFailure.artifactSizeMismatch(
                    name: spec.name,
                    expected: spec.size,
                    actual: actual
                )
            }
            return ValidatedArtifact(spec: spec, file: file)
        }
    }

    private static func isValidArtifactName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 255, !name.contains("..") else {
            return false
        }
        return name.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || $0 == 95 || $0 == 45 || $0 == 46
        }
    }

    static func validate(_ archive: RuntimeStoreArchiveInfo, against request: RuntimeStoreInstallRequest) throws {
        guard archive.packageID == request.packageID else {
            throw RuntimeStoreAgentFailure.archivePackageMismatch(
                expected: request.packageID,
                actual: archive.packageID
            )
        }
        guard archive.versionCode == request.versionCode else {
            throw RuntimeStoreAgentFailure.archiveVersionMismatch(
                expected: request.versionCode,
                actual: archive.versionCode
            )
        }
        guard !archive.signingDigests.isEmpty else {
            throw RuntimeStoreAgentFailure.signerMismatch
        }
        guard request.expectedSignerDigests.isEmpty else {
            guard Set(request.expectedSignerDigests).count == request.expectedSignerDigests.count,
                Set(archive.signingDigests) == Set(request.expectedSignerDigests)
            else {
                throw RuntimeStoreAgentFailure.signerMismatch
            }
            return
        }
    }

    static func protocolSignerDigests(for request: RuntimeStoreInstallRequest) throws -> [Data] {
        try request.expectedSignerDigests.map(Self.digestBytes)
    }

    private static func archiveInfo(_ wire: GPArchiveInfo) throws -> RuntimeStoreArchiveInfo {
        guard let package = RuntimePackageID(rawValue: wire.package) else {
            throw RuntimeStoreAgentFailure.invalidRuntimePackageID(wire.package)
        }
        guard wire.versionCode >= 0 else {
            throw RuntimeStoreAgentFailure.invalidRuntimeVersionCode
        }
        guard wire.minSdk >= 0, wire.targetSdk >= 0, wire.signingSchemeVersion >= 0 else {
            throw RuntimeStoreAgentFailure.invalidArchiveMetadata
        }
        let signers = try validatedDigests(wire.signerSha256, package: wire.package, requireNonempty: true)
        return RuntimeStoreArchiveInfo(
            packageID: package,
            versionCode: wire.versionCode,
            versionName: wire.versionName.isEmpty ? nil : wire.versionName,
            splitNames: wire.splitNames,
            nativeABIs: wire.nativeAbis,
            minSDK: Int(wire.minSdk),
            targetSDK: Int(wire.targetSdk),
            signingDigests: signers,
            signingSchemeVersion: Int(wire.signingSchemeVersion)
        )
    }

    private static func packageInfo(_ wire: GPStorePackageInfo) throws -> RuntimeStorePackageInfo {
        guard let package = RuntimePackageID(rawValue: wire.package) else {
            throw RuntimeStoreAgentFailure.invalidRuntimePackageID(wire.package)
        }
        guard wire.versionCode >= 0 else {
            throw RuntimeStoreAgentFailure.invalidRuntimeVersionCode
        }
        guard wire.minSdk >= 0,
            wire.targetSdk >= 0,
            wire.signing.schemeVersion >= 0,
            wire.requestedPermissionsCount >= 0,
            wire.firstInstallTimeMs >= 0,
            wire.lastUpdateTimeMs >= 0
        else {
            throw RuntimeStoreAgentFailure.invalidPackageMetadata(wire.package)
        }
        guard wire.hasSigning else {
            throw RuntimeStoreAgentFailure.invalidSigningInfo(wire.package)
        }
        let signers = try validatedDigests(wire.signing.currentSha256, package: wire.package, requireNonempty: true)
        let lineage = try validatedDigests(wire.signing.pastSha256, package: wire.package, requireNonempty: false)
        let installer = try optionalRuntimePackageID(wire.installerOfRecord, field: "installer_of_record")
        let updateOwner = try optionalRuntimePackageID(wire.updateOwner, field: "update_owner")
        let initiating = try optionalRuntimePackageID(wire.initiatingPackage, field: "initiating_package")
        return RuntimeStorePackageInfo(
            packageID: package,
            displayName: wire.label.isEmpty ? wire.package : wire.label,
            versionCode: wire.versionCode,
            versionName: wire.versionName.isEmpty ? nil : wire.versionName,
            enabled: wire.enabled,
            launchableComponent: wire.launchableComponent.isEmpty ? nil : wire.launchableComponent,
            installerPackage: installer,
            firstInstallTime: date(milliseconds: wire.firstInstallTimeMs),
            lastUpdateTime: date(milliseconds: wire.lastUpdateTimeMs),
            targetSDK: Int(wire.targetSdk),
            minSDK: Int(wire.minSdk),
            signingDigests: signers,
            signingLineage: lineage,
            signingSchemeVersion: Int(wire.signing.schemeVersion),
            updateOwner: updateOwner,
            initiatingPackage: initiating,
            splitNames: wire.splits,
            nativeABIs: wire.nativeAbis,
            suspended: wire.suspended,
            requestedPermissionsCount: Int(wire.requestedPermissionsCount)
        )
    }

    private static func packageEvent(_ wire: GPPackageChanged) throws -> RuntimeStorePackageEvent {
        guard let package = RuntimePackageID(rawValue: wire.package) else {
            throw RuntimeStoreAgentFailure.invalidRuntimePackageID(wire.package)
        }
        guard wire.versionCode >= 0 else {
            throw RuntimeStoreAgentFailure.invalidRuntimeVersionCode
        }
        let kind: RuntimeStorePackageEvent.Kind
        switch wire.kind {
        case .added: kind = .added
        case .replaced: kind = .replaced
        case .removed: kind = .removed
        case .changed: kind = .changed
        case .unspecified, .UNRECOGNIZED:
            throw RuntimeStoreAgentFailure.invalidPackageEvent
        }
        return RuntimeStorePackageEvent(packageID: package, kind: kind, versionCode: wire.versionCode)
    }

    private static func optionalRuntimePackageID(_ rawValue: String, field: String) throws -> RuntimePackageID? {
        guard !rawValue.isEmpty else { return nil }
        guard let package = RuntimePackageID(rawValue: rawValue) else {
            throw RuntimeStoreAgentFailure.invalidPackageField(field, rawValue)
        }
        return package
    }

    private static func validatedDigests(
        _ values: [Data],
        package: String,
        requireNonempty: Bool
    ) throws -> [String] {
        guard !requireNonempty || !values.isEmpty else {
            throw RuntimeStoreAgentFailure.invalidSigningInfo(package)
        }
        let digests = try values.map { bytes -> String in
            guard bytes.count == 32 else {
                throw RuntimeStoreAgentFailure.invalidSigningDigest(package: package)
            }
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            return hex
        }
        guard Set(digests).count == digests.count else {
            throw RuntimeStoreAgentFailure.invalidSigningDigest(package: package)
        }
        return digests
    }

    private static func installMode(_ mode: RuntimeStoreInstallRequest.Mode) -> GPInstallMode {
        switch mode {
        case .installNew: .installNew
        case .update: .update
        case .reinstall: .reinstall
        }
    }

    private static func protocolArtifactSpec(_ artifact: ValidatedArtifact) throws -> GPArtifactSpec {
        var spec = GPArtifactSpec()
        spec.name = artifact.spec.name
        spec.size = artifact.spec.size
        spec.sha256 = try digestBytes(artifact.spec.sha256)
        return spec
    }

    private static func digestBytes(_ hex: String) throws -> Data {
        guard hex.utf8.count == 64,
            hex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else {
            throw RuntimeStoreAgentFailure.invalidDigest
        }
        var bytes = Data()
        bytes.reserveCapacity(32)
        var index = hex.startIndex
        for _ in 0..<32 {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw RuntimeStoreAgentFailure.invalidDigest
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private static func date(milliseconds: Int64) -> Date? {
        milliseconds == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }

    private static func requireCapability(_ capability: GuestCapability, in session: Session) throws {
        guard session.capabilities.contains(capability.rawValue) else {
            throw GuestProtocolFailure.capabilityMissing(capability: capability.rawValue)
        }
    }

    private static func storeCapabilities(_ negotiated: Set<String>) -> RuntimeStoreCapabilities {
        var result: RuntimeStoreCapabilities = []
        if negotiated.contains(GuestCapability.storeInstall.rawValue) {
            result.insert(.install)
        }
        if negotiated.contains(GuestCapability.storeMetadata.rawValue) {
            result.formUnion([.metadata, .inspect])
        }
        return result
    }
}

private struct ValidatedArtifact: Sendable {
    let spec: RuntimeStoreArtifactSpec
    let file: URL
}

private final class RuntimeStoreAgentState: @unchecked Sendable {
    struct Snapshot {
        var capabilities: RuntimeStoreCapabilities = []
        var isConnected = false
    }

    private let lock = NSLock()
    private var value = Snapshot()

    var snapshot: Snapshot {
        lock.withLock { value }
    }

    func setCapabilities(_ capabilities: RuntimeStoreCapabilities) {
        lock.withLock { value.capabilities = capabilities }
    }

    func setConnected(_ isConnected: Bool) {
        lock.withLock { value.isConnected = isConnected }
    }
}

/// Typed failures detected by the Store Agent channel before or after a guest request.
public enum RuntimeStoreAgentFailure: Error, Equatable, Sendable {
    case disconnected
    case emptyArtifactSet
    case artifactCountMismatch(expected: Int, actual: Int)
    case invalidArtifactName(String)
    case invalidArtifactURL(String)
    case artifactTooLarge(name: String, size: UInt64)
    case artifactSizeMismatch(name: String, expected: UInt64, actual: UInt64)
    case artifactDigestMismatch(String)
    case invalidDigest
    case invalidRuntimePackageID(String)
    case invalidRuntimeVersionCode
    case invalidArchiveMetadata
    case invalidPackageMetadata(String)
    case invalidSigningInfo(String)
    case invalidSigningDigest(package: String)
    case invalidPackageField(String, String)
    case invalidPackageEvent
    case archivePackageMismatch(expected: RuntimePackageID, actual: RuntimePackageID)
    case archiveVersionMismatch(expected: RuntimeVersionCode, actual: RuntimeVersionCode)
    case signerMismatch
    case downgradeNotSupported
    case invalidInstallID
    case installOutcomeTimedOut(String)
    case installOutcomeMismatch
    case installFailed(status: Int32, legacyStatus: String, message: String)
    case installVersionMismatch(expected: RuntimeVersionCode, actual: RuntimeVersionCode)
    case packageNotInstalled(RuntimePackageID)
    case packageMismatch(expected: RuntimePackageID, actual: RuntimePackageID)
    case uninstallFailed(message: String)
    case bulkTransferRejected(status: Int32)
    case unexpectedBulkTransfer(UInt64)
    case unexpectedBulkFrame
    case artifactTransferTimedOut(UInt64)
    case transferIDExhausted
}
