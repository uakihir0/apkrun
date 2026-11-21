@preconcurrency import Foundation
import RuntimeAPI

/// Client for apkrund's frozen `.maintenance` endpoint (runtime-api.md §12.1).
///
/// Used by APKRun.app's `SelfUpdateController` (§3.7), the Settings banner
/// (§7.3), and `apkrun self-update` (§8.2). The endpoint answers in every
/// host state and between builds, so the client tolerates any RuntimeAPI
/// major: it only requires the broker to grant the endpoint.
public final class MaintenanceControlClient: Sendable {
    private let configuration: RuntimeControlClientConfiguration
    private let connectionFactory: any RuntimeXPCConnectionFactory

    /// Creates a client for the current signed APKRun process.
    public init(
        clientKind: RuntimeClientKind,
        claimedIdentity: String? = nil
    ) throws(RuntimeControlClientError) {
        configuration = try RuntimeControlClientConfiguration.current(
            clientKind: clientKind,
            claimedIdentity: claimedIdentity
        )
        connectionFactory = SystemRuntimeXPCConnectionFactory()
    }

    init(
        configuration: RuntimeControlClientConfiguration,
        connectionFactory: any RuntimeXPCConnectionFactory
    ) {
        self.configuration = configuration
        self.connectionFactory = connectionFactory
    }

    /// Sends one maintenance operation and returns the decoded reply. The
    /// broker grants `.maintenance` in every host state, so no API-version
    /// check happens here (§12.1).
    public func perform(
        _ operation: MaintenanceControlRequest
    ) async throws(RuntimeControlClientError) -> MaintenanceControlReply {
        let data: Data
        do {
            data = try JSONEncoder().encode(operation)
        } catch {
            throw .encodingFailure
        }
        let replyData = try await performRaw(data)
        do {
            return try JSONDecoder().decode(MaintenanceControlReply.self, from: replyData)
        } catch {
            throw .malformedReply
        }
    }

    /// Convenience for `completeHostUpdate` (§3.6 finishing step). Idempotent.
    public func completeHostUpdate() async throws(RuntimeControlClientError) -> MaintenanceControlReply {
        try await perform(request(operation: .completeHostUpdate))
    }

    /// Convenience for `maintenanceStatus` (§7.3 banner, §8.2 CLI).
    public func status() async throws(RuntimeControlClientError) -> MaintenanceStatus {
        let reply = try await perform(request(operation: .maintenanceStatus))
        guard let status = reply.status else {
            if let error = reply.error {
                throw .remoteFailure(
                    code: error.code, message: error.message,
                    parameters: error.parameters)
            }
            throw .malformedReply
        }
        return status
    }

    /// Convenience for `restartForUpdate` (§7.3 Restart Now, §8.2 finish).
    public func restartForUpdate(
        closeSessions: Bool
    ) async throws(RuntimeControlClientError) -> MaintenanceControlReply {
        try await perform(
            request(
                operation: .restartForUpdate,
                restart: RestartForUpdateRequest(closeSessions: closeSessions)))
    }

    private func request(
        operation: MaintenanceControlOperation,
        hostUpdate: HostUpdateRequest? = nil,
        restart: RestartForUpdateRequest? = nil
    ) -> MaintenanceControlRequest {
        MaintenanceControlRequest(
            header: APIRequestHeader(clientKind: configuration.clientKind),
            operation: operation,
            hostUpdate: hostUpdate,
            restart: restart)
    }

    private func performRaw(_ data: Data) async throws(RuntimeControlClientError) -> Data {
        let broker = try connectionFactory.makeBroker(
            serviceName: configuration.serviceName,
            signingRequirement: configuration.daemonCodeSigningRequirement
        )
        defer { broker.invalidate() }
        // The maintenance endpoint must work between builds (§12.1); a plain
        // hello keeps the broker's connection bookkeeping, and the API check
        // of the control client is intentionally skipped.
        let helloRequest = RuntimeHelloRequest(
            clientKind: configuration.clientKind,
            claimedIdentity: configuration.claimedIdentity,
            apiVersion: APIVersion.current,
            clientVersion: configuration.clientVersion,
            clientBuild: configuration.clientBuild
        )
        _ = try await broker.hello(try Self.encode(helloRequest))
        let endpointReply = try await broker.requestEndpoint(
            try Self.encode(
                RuntimeEndpointRequest(
                    kind: .maintenance,
                    clientKind: configuration.clientKind,
                    claimedIdentity: configuration.claimedIdentity,
                    apiVersion: APIVersion.current)))
        let disposition = try Self.decode(RuntimeEndpointReply.self, from: endpointReply.data)
        switch disposition {
        case .rejected(let rejection):
            throw .endpointRejected(rejection)
        case .granted:
            guard let endpoint = endpointReply.endpoint else {
                throw .endpointMissing
            }
            let channel = try connectionFactory.makeMaintenance(
                endpoint: endpoint,
                signingRequirement: configuration.daemonCodeSigningRequirement)
            defer { channel.invalidate() }
            return try await channel.perform(data)
        }
    }

    private static func encode(_ value: some Encodable) throws(RuntimeControlClientError) -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw .encodingFailure
        }
    }

    private static func decode<T: Decodable>(
        _ type: T.Type, from data: Data
    ) throws(RuntimeControlClientError) -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw .malformedReply
        }
    }
}

protocol RuntimeMaintenanceChannel: AnyObject, Sendable {
    func perform(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func invalidate()
}

final class XPCMaintenanceChannel: RuntimeMaintenanceChannel, @unchecked Sendable {
    private let connection: NSXPCConnection

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    func perform(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    let nsError = error as NSError
                    finish(
                        .failure(
                            .transportFailure(domain: nsError.domain, code: nsError.code)))
                } as? any RuntimeMaintenanceXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.perform(request) { response in finish(.success(response)) }
        }
    }

    func invalidate() {
        connection.invalidate()
    }
}
