import APKStoreCore
import DiagnosticsCore
import Foundation
import ImageCore
import RuntimeCore

/// Connects the package store to the currently running embedded development runtime.
///
/// This adapter owns no package state. It asks the supervisor to make Android ready, then
/// builds a channel from the Guest Agent and the supervisor's current ADB forwarder.
public actor DevelopmentStoreRuntimeAccess: StoreRuntimeAccess {
    private let makeChannel: @Sendable () async throws -> any StoreAgentChannel
    private let readUserdataGeneration: @Sendable () async -> UUID?
    private var cachedChannel: (any StoreAgentChannel)?
    private var cachedChannelCreationID: UUID?
    private var channelCreationTask: Task<any StoreAgentChannel, any Error>?
    private var channelCreationID: UUID?
    private var channelCreationWaiterCount = 0
    private var channelCreationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    /// Creates an adapter for one embedded runtime.
    ///
    /// `instanceStore` and `image` must identify the same Android instance used by `supervisor`.
    public init(
        supervisor: RuntimeSupervisor,
        adbExecutable: URL?,
        instanceStore: InstanceStore,
        image: InstalledImage,
        logSink: (any LogSink)? = nil,
        startRuntimeIfNeeded: Bool = true
    ) {
        makeChannel = {
            if startRuntimeIfNeeded {
                try await supervisor.ensureReady(.cli)
            } else if await supervisor.state != .ready {
                throw DevelopmentStoreRuntimeAccessFailure.runtimeNotReady
            }

            if image.manifest.kind == .apkrun {
                let transport = VsockGuestTransport { port, timeout in
                    try await supervisor.connect(vsockPort: port, timeout: timeout)
                }
                return try await StoreAgentSupervisor.connect(transport: transport, logSink: logSink)
            }

            guard let agent = await supervisor.developmentGuestAgent else {
                throw DevelopmentStoreRuntimeAccessFailure.guestAgentUnavailable
            }
            guard let port = await supervisor.developmentADBHostPort else {
                throw DevelopmentStoreRuntimeAccessFailure.adbForwarderUnavailable
            }
            guard let adbExecutable else {
                throw DevelopmentStoreRuntimeAccessFailure.adbExecutableUnavailable
            }

            let adb = AdbClient(
                executable: adbExecutable,
                endpoint: AdbClient.loopbackEndpoint(port: port),
                logSink: logSink
            )
            // DevBoot owns the connection lifecycle. Checking state avoids adb disconnect/connect,
            // which would disrupt the Guest Agent's own client on this endpoint.
            try await adb.awaitDevice(timeout: .seconds(10))
            return await ADBStoreAgentChannel.connectedToCurrentImage(agent: agent, adb: adb)
        }
        readUserdataGeneration = {
            try? await instanceStore.load(image: image)?.userdataGeneration
        }
    }

    /// Runs an operation through the ADB channel for the active embedded runtime.
    public func withStoreAgent<T: Sendable>(
        _ operation: UUID,
        _ body: @Sendable (any StoreAgentChannel) async throws -> T
    ) async throws -> T {
        _ = operation
        let channel = try await storeAgentChannel()
        return try await body(channel)
    }

    /// Returns the generation persisted with the instance's userdata image.
    public func userdataGeneration() async -> UUID? {
        await readUserdataGeneration()
    }

    /// Closes the persistent Store Agent session before the runtime is detached.
    public func close() async {
        let channel = cachedChannel
        cachedChannel = nil
        cachedChannelCreationID = nil
        channelCreationID = nil
        channelCreationTask?.cancel()
        channelCreationTask = nil
        await channel?.close()
    }

    private func storeAgentChannel() async throws -> any StoreAgentChannel {
        if let cachedChannel, cachedChannel.isConnected {
            return cachedChannel
        }
        if let cachedChannel {
            await cachedChannel.close()
            self.cachedChannel = nil
            cachedChannelCreationID = nil
        }

        let task: Task<any StoreAgentChannel, any Error>
        let creationID: UUID
        let isWaiter: Bool
        if let channelCreationTask, let channelCreationID {
            task = channelCreationTask
            creationID = channelCreationID
            channelCreationWaiterCount += 1
            resumeChannelCreationWaiters()
            isWaiter = true
        } else {
            creationID = UUID()
            let factory = makeChannel
            task = Task { try await factory() }
            channelCreationID = creationID
            channelCreationTask = task
            isWaiter = false
        }
        defer {
            if isWaiter {
                channelCreationWaiterCount -= 1
            }
        }

        do {
            let createdChannel = try await task.value
            if channelCreationID == creationID {
                cachedChannel = createdChannel
                cachedChannelCreationID = creationID
                channelCreationID = nil
                channelCreationTask = nil
                return createdChannel
            }
            if cachedChannelCreationID == creationID,
                let cachedChannel,
                cachedChannel.isConnected
            {
                return cachedChannel
            }
            await createdChannel.close()
            throw DevelopmentStoreRuntimeAccessFailure.runtimeNotReady
        } catch {
            if channelCreationID == creationID {
                channelCreationID = nil
                channelCreationTask = nil
            }
            throw error
        }
    }

    private func resumeChannelCreationWaiters() {
        let ready = channelCreationWaiters.filter { $0.0 <= channelCreationWaiterCount }
        channelCreationWaiters.removeAll { $0.0 <= channelCreationWaiterCount }
        for waiter in ready {
            waiter.1.resume()
        }
    }

    func waitForChannelCreationWaitersForTesting(_ count: Int) async {
        guard channelCreationWaiterCount < count else { return }
        await withCheckedContinuation { continuation in
            channelCreationWaiters.append((count, continuation))
        }
    }

    init(
        makeChannel: @escaping @Sendable () async throws -> any StoreAgentChannel,
        readUserdataGeneration: @escaping @Sendable () async -> UUID?
    ) {
        self.makeChannel = makeChannel
        self.readUserdataGeneration = readUserdataGeneration
    }
}

/// A development runtime that cannot provide the guest package channel.
public enum DevelopmentStoreRuntimeAccessFailure: Error, Sendable, Equatable {
    /// The caller requested a live package query without allowing Android to start.
    case runtimeNotReady
    /// The boot completed without a Guest Agent.
    case guestAgentUnavailable
    /// The development ADB loopback forwarder is not active.
    case adbForwarderUnavailable
    /// A stock image requires an ADB executable, but none was provided.
    case adbExecutableUnavailable
}
