import APKStoreCore
import DiagnosticsCore
import Foundation
import ImageCore
import RuntimeCore

/// Connects the package store to the currently running embedded development runtime.
///
/// This adapter owns no package state. It asks the supervisor to make Android ready, then
/// builds a channel from the Guest Agent and the supervisor's private ADB forwarder.
public actor DevelopmentStoreRuntimeAccess: StoreRuntimeAccess {
    private let makeChannel: @Sendable () async throws -> any StoreAgentChannel
    private let readUserdataGeneration: @Sendable () async -> UUID?

    /// Creates an adapter for one embedded runtime.
    ///
    /// `instanceStore` and `image` must identify the same Android instance used by `supervisor`.
    public init(
        supervisor: RuntimeSupervisor,
        adbExecutable: URL,
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

            guard let agent = await supervisor.developmentGuestAgent else {
                throw DevelopmentStoreRuntimeAccessFailure.guestAgentUnavailable
            }
            guard let port = await supervisor.developmentADBClientHostPort else {
                throw DevelopmentStoreRuntimeAccessFailure.adbForwarderUnavailable
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
        let channel = try await makeChannel()
        return try await body(channel)
    }

    /// Returns the generation persisted with the instance's userdata image.
    public func userdataGeneration() async -> UUID? {
        await readUserdataGeneration()
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
}
