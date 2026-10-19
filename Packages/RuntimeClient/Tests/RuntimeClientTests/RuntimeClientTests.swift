import Foundation
import RuntimeAPI
import Testing

@testable import RuntimeClient

@Test func controlClientAuthenticatesBrokerAndUsesOneControlEndpoint() async throws {
    let configuration = try RuntimeControlClientConfiguration(
        clientKind: .cli,
        claimedIdentity: "io.apkrun.cli.dev",
        buildIdentity: .development,
        clientVersion: "0.1.0",
        clientBuild: 1
    )
    let hello = RuntimeHelloReply(
        runtimeVersion: "0.1.0",
        runtimeBuild: 1,
        apiVersion: APIVersion.current,
        hostState: "running"
    )
    let status = RuntimeHostStatus(
        hostState: "running",
        runtimeState: "ready",
        bootProgress: nil,
        startupFailureStep: nil,
        startupFailureCode: nil,
        crashLoopActive: false,
        daemonPID: 42,
        imageVersion: "test-image"
    )
    let transport = try MockRuntimeTransport(hello: hello, status: status)
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)

    #expect(try await client.connect() == hello)
    #expect(try await client.runtimeStatus() == status)
    #expect(try await client.startRuntime() == status)
    #expect(try await client.stopRuntime() == status)

    let snapshot = transport.snapshot()
    #expect(snapshot.serviceName == "io.apkrun.apkrund.dev.xpc")
    #expect(snapshot.brokerRequirement == "identifier \"io.apkrun.apkrund.dev\"")
    #expect(snapshot.controlRequirement == snapshot.brokerRequirement)
    #expect(snapshot.controlConnections == 1)
    #expect(snapshot.brokerInvalidations == 1)

    let helloRequest = try JSONDecoder().decode(RuntimeHelloRequest.self, from: snapshot.helloRequests[0])
    #expect(helloRequest.clientKind == RuntimeClientKind.cli)
    #expect(helloRequest.claimedIdentity == "io.apkrun.cli.dev")
    #expect(helloRequest.apiVersion == APIVersion.current)
    #expect(helloRequest.clientVersion == "0.1.0")
    #expect(helloRequest.clientBuild == 1)

    let endpointRequest = try JSONDecoder().decode(RuntimeEndpointRequest.self, from: snapshot.endpointRequests[0])
    #expect(endpointRequest.kind == .control)
    #expect(endpointRequest.clientKind == RuntimeClientKind.cli)
    #expect(endpointRequest.claimedIdentity == "io.apkrun.cli.dev")

    #expect(snapshot.statusRequests.count == 1)
    #expect(snapshot.startRequests.count == 1)
    #expect(snapshot.stopRequests.count == 1)
    for data in snapshot.statusRequests + snapshot.startRequests + snapshot.stopRequests {
        let request = try JSONDecoder().decode(ControlRequestHeader.self, from: data)
        #expect(request.header.apiVersion == APIVersion.current)
        #expect(request.header.clientKind == RuntimeClientKind.cli)
    }
}

@Test func controlClientRejectsAnIncompatibleBrokerBeforeRequestingAnEndpoint() async throws {
    let configuration = try RuntimeControlClientConfiguration(
        clientKind: .app,
        claimedIdentity: "io.apkrun.APKRun.dev",
        buildIdentity: .development
    )
    let hello = RuntimeHelloReply(
        runtimeVersion: "2.0.0",
        runtimeBuild: 2,
        apiVersion: APIVersion(major: APIVersion.current.major + 1, minor: 0),
        hostState: "running"
    )
    let transport = try MockRuntimeTransport(hello: hello, status: nil)
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)

    do {
        _ = try await client.connect()
        Issue.record("The client accepted an incompatible daemon API version.")
    } catch {
        #expect(error == .apiVersionMismatch(client: APIVersion.current, server: hello.apiVersion))
    }

    let snapshot = transport.snapshot()
    #expect(snapshot.endpointRequests.isEmpty)
    #expect(snapshot.controlConnections == 0)
}

@Test func controlClientExplainsWhenTheDaemonIsShuttingDown() async throws {
    let configuration = try RuntimeControlClientConfiguration(
        clientKind: .cli,
        claimedIdentity: "io.apkrun.cli.dev",
        buildIdentity: .development
    )
    let hello = RuntimeHelloReply(
        runtimeVersion: "0.1.0",
        runtimeBuild: 1,
        apiVersion: APIVersion.current,
        hostState: "shuttingDown"
    )
    let transport = try MockRuntimeTransport(
        hello: hello,
        status: nil,
        endpointRejection: .hostShuttingDown
    )
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)

    do {
        _ = try await client.connect()
        Issue.record("The client accepted an endpoint request while the daemon was shutting down.")
    } catch {
        #expect(error == .endpointRejected(.hostShuttingDown))
        #expect(error.errorDescription == "APKRun's background service is stopping. Try again in a moment.")
    }

    let snapshot = transport.snapshot()
    #expect(snapshot.endpointRequests.count == 1)
    #expect(snapshot.controlConnections == 0)
    #expect(snapshot.brokerInvalidations == 1)
}

@Test func controlClientReconnectsAfterAControlTransportFailureWithoutReplayingIt() async throws {
    let configuration = try RuntimeControlClientConfiguration(
        clientKind: .cli,
        claimedIdentity: "io.apkrun.cli.dev",
        buildIdentity: .development
    )
    let hello = RuntimeHelloReply(
        runtimeVersion: "0.1.0",
        runtimeBuild: 1,
        apiVersion: APIVersion.current,
        hostState: "running"
    )
    let status = RuntimeHostStatus(
        hostState: "running",
        runtimeState: "ready",
        bootProgress: nil,
        startupFailureStep: nil,
        startupFailureCode: nil,
        crashLoopActive: false,
        daemonPID: 42,
        imageVersion: "test-image"
    )
    let transport = try MockRuntimeTransport(hello: hello, status: status)
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)

    #expect(try await client.runtimeStatus() == status)
    transport.failNextStatus()
    do {
        _ = try await client.runtimeStatus()
        Issue.record("The mock transport failure was not returned to the caller.")
    } catch {
        #expect(error == .transportFailure(domain: "NSCocoaErrorDomain", code: 4099))
    }
    #expect(try await client.runtimeStatus() == status)

    let snapshot = transport.snapshot()
    #expect(snapshot.brokerConnections == 2)
    #expect(snapshot.controlConnections == 2)
    #expect(snapshot.brokerInvalidations == 3)
    #expect(snapshot.statusRequests.count == 3)
}

@Test func clientConfigurationsBindReleaseDaemonToTeamAndIdentifier() throws {
    let release = try RuntimeControlClientConfiguration(
        clientKind: .app,
        claimedIdentity: "io.apkrun.APKRun",
        buildIdentity: .release(teamIdentifier: "ABCDE12345")
    )
    let updateTest = try RuntimeControlClientConfiguration(
        clientKind: .app,
        claimedIdentity: "io.apkrun.APKRun.updatetest",
        buildIdentity: .releaseUpdateTest(teamIdentifier: "ABCDE12345")
    )

    #expect(release.serviceName == "io.apkrun.apkrund.xpc")
    #expect(
        release.daemonCodeSigningRequirement
            == "anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\" and identifier \"io.apkrun.apkrund\""
    )
    #expect(updateTest.serviceName == "io.apkrun.apkrund.updatetest.xpc")
    #expect(
        updateTest.daemonCodeSigningRequirement
            == "anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\" and identifier \"io.apkrun.apkrund.updatetest\""
    )
}

private struct ControlRequestHeader: Decodable {
    let header: APIRequestHeader
}

private final class MockRuntimeTransport: RuntimeXPCConnectionFactory, RuntimeBrokerChannel, RuntimeControlChannel,
    @unchecked Sendable
{
    private let helloData: Data
    private let endpointData: Data
    private let endpoint: RuntimeXPCListenerEndpoint?
    private let statusData: Data
    private let lock = NSLock()
    private var serviceNameValue: String?
    private var brokerRequirementValue: String?
    private var controlRequirementValue: String?
    private var helloRequestsValue: [Data] = []
    private var endpointRequestsValue: [Data] = []
    private var statusRequestsValue: [Data] = []
    private var startRequestsValue: [Data] = []
    private var stopRequestsValue: [Data] = []
    private var brokerConnectionsValue = 0
    private var controlConnectionsValue = 0
    private var brokerInvalidationsValue = 0
    private var failNextStatusValue = false

    init(
        hello: RuntimeHelloReply,
        status: RuntimeHostStatus?,
        endpointRejection: RuntimeEndpointRejection? = nil
    ) throws {
        helloData = try JSONEncoder().encode(hello)
        if let endpointRejection {
            endpointData = try JSONEncoder().encode(RuntimeEndpointReply.rejected(endpointRejection))
            endpoint = nil
        } else {
            endpointData = try JSONEncoder().encode(RuntimeEndpointReply.granted)
            endpoint = RuntimeXPCListenerEndpoint(value: NSObject())
        }
        if let status {
            statusData = try JSONEncoder().encode(RuntimeControlReply(status: status))
        } else {
            statusData = try JSONEncoder().encode(
                RuntimeControlReply(error: RuntimeControlError(code: "runtime.test", message: "test failure"))
            )
        }
    }

    func makeBroker(
        serviceName: String,
        signingRequirement: String
    ) throws(RuntimeControlClientError) -> any RuntimeBrokerChannel {
        lock.withLock {
            brokerConnectionsValue += 1
            serviceNameValue = serviceName
            brokerRequirementValue = signingRequirement
        }
        return self
    }

    func makeControl(
        endpoint: RuntimeXPCListenerEndpoint,
        signingRequirement: String
    ) throws(RuntimeControlClientError) -> any RuntimeControlChannel {
        guard endpoint.value is NSObject else {
            throw .malformedReply
        }
        lock.withLock {
            controlRequirementValue = signingRequirement
            controlConnectionsValue += 1
        }
        return self
    }

    func hello(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        lock.withLock { helloRequestsValue.append(request) }
        return helloData
    }

    func requestEndpoint(_ request: Data) async throws(RuntimeControlClientError) -> RuntimeBrokerEndpointReply {
        lock.withLock { endpointRequestsValue.append(request) }
        return RuntimeBrokerEndpointReply(
            data: endpointData,
            endpoint: endpoint
        )
    }

    func invalidate() {
        lock.withLock { brokerInvalidationsValue += 1 }
    }

    func runtimeStatus(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        let shouldFail = lock.withLock {
            statusRequestsValue.append(request)
            defer { failNextStatusValue = false }
            return failNextStatusValue
        }
        if shouldFail {
            throw .transportFailure(domain: "NSCocoaErrorDomain", code: 4099)
        }
        return statusData
    }

    func startRuntime(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        lock.withLock { startRequestsValue.append(request) }
        return statusData
    }

    func stopRuntime(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        lock.withLock { stopRequestsValue.append(request) }
        return statusData
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                serviceName: serviceNameValue,
                brokerRequirement: brokerRequirementValue,
                controlRequirement: controlRequirementValue,
                helloRequests: helloRequestsValue,
                endpointRequests: endpointRequestsValue,
                statusRequests: statusRequestsValue,
                startRequests: startRequestsValue,
                stopRequests: stopRequestsValue,
                brokerConnections: brokerConnectionsValue,
                controlConnections: controlConnectionsValue,
                brokerInvalidations: brokerInvalidationsValue
            )
        }
    }

    func failNextStatus() {
        lock.withLock { failNextStatusValue = true }
    }

    struct Snapshot {
        let serviceName: String?
        let brokerRequirement: String?
        let controlRequirement: String?
        let helloRequests: [Data]
        let endpointRequests: [Data]
        let statusRequests: [Data]
        let startRequests: [Data]
        let stopRequests: [Data]
        let brokerConnections: Int
        let controlConnections: Int
        let brokerInvalidations: Int
    }
}
