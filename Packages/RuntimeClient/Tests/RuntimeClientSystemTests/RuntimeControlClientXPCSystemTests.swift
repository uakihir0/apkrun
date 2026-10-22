import Foundation
import RuntimeAPI
import Security
import Testing

@testable import RuntimeClient

@Test
func controlClientReconnectsAndReplaysSubscriptionsAfterAnonymousEndpointInvalidation() async throws {
    let firstServer = RuntimeClientXPCSystemTestServer()
    let secondServer = RuntimeClientXPCSystemTestServer()
    defer {
        firstServer.invalidate()
        secondServer.invalidate()
    }

    let configuration = try RuntimeControlClientConfiguration(
        clientKind: .cli,
        claimedIdentity: "io.apkrun.cli.systemtest",
        buildIdentity: .systemTest(
            daemonCodeSigningRequirement: try currentCodeSigningRequirement()
        )
    )
    let broker = RuntimeClientXPCSystemTestBroker(
        servers: [firstServer, secondServer]
    )
    defer { broker.invalidate() }
    let connectionFactory = RuntimeClientXPCSystemTestConnectionFactory(broker: broker)
    let client = RuntimeControlClient(
        configuration: configuration,
        connectionFactory: connectionFactory
    )
    let stream = try await client.subscribe(to: .operations)
    let eventsTask = Task { () -> [EventEnvelope] in
        var received: [EventEnvelope] = []
        for await event in stream {
            received.append(event)
            if received.count == 2 {
                break
            }
        }
        return received
    }
    defer { eventsTask.cancel() }

    try await firstServer.waitForSubscriptionCount(1)
    firstServer.invalidate()

    try await secondServer.waitForSubscriptionCount(1)
    let operationID = OperationID()
    let event = EventEnvelope(
        topic: .operations,
        seq: 1,
        time: Date(timeIntervalSince1970: 1_800_000_003),
        operationID: operationID,
        payload: .operations(.progress(operationID, OperationProgress(stage: "reconnected")))
    )
    secondServer.deliver(event)

    let received = try await withTimeout { await eventsTask.value }
    #expect(received.count == 2)
    #expect(received[0].topic == .operations)
    #expect(received[0].seq == 0)
    #expect(received[0].payload == .resyncRequired(.operations))
    #expect(received[1] == event)
    #expect(broker.endpointRequestCount == 2)
    #expect(firstServer.subscriptionCount == 1)
    #expect(secondServer.subscriptionCount == 1)
}

private enum RuntimeClientXPCSystemTestError: Error {
    case timeout
    case invalidCodeRequirement
}

private func currentCodeSigningRequirement() throws -> String {
    guard let executableURL = Bundle.main.executableURL else {
        throw RuntimeClientXPCSystemTestError.invalidCodeRequirement
    }
    var code: SecStaticCode?
    guard
        SecStaticCodeCreateWithPath(
            executableURL as CFURL,
            SecCSFlags(rawValue: 0),
            &code
        ) == errSecSuccess,
        let code
    else {
        throw RuntimeClientXPCSystemTestError.invalidCodeRequirement
    }

    var requirement: SecRequirement?
    guard
        SecCodeCopyDesignatedRequirement(
            code,
            SecCSFlags(rawValue: 0),
            &requirement
        ) == errSecSuccess,
        let requirement
    else {
        throw RuntimeClientXPCSystemTestError.invalidCodeRequirement
    }

    var text: CFString?
    guard SecRequirementCopyString(requirement, SecCSFlags(rawValue: 0), &text) == errSecSuccess,
        let text
    else {
        throw RuntimeClientXPCSystemTestError.invalidCodeRequirement
    }
    return text as String
}

private func withTimeout<Value: Sendable>(
    operation: @escaping @Sendable () async -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask {
            await operation()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(8))
            throw RuntimeClientXPCSystemTestError.timeout
        }
        guard let result = try await group.next() else {
            throw RuntimeClientXPCSystemTestError.timeout
        }
        group.cancelAll()
        return result
    }
}

private final class RuntimeClientXPCSystemTestServer: @unchecked Sendable {
    private let listener: NSXPCListener
    private let delegate: RuntimeClientXPCSystemTestListenerDelegate

    init() {
        listener = NSXPCListener.anonymous()
        delegate = RuntimeClientXPCSystemTestListenerDelegate()
        listener.delegate = delegate
        listener.resume()
    }

    var endpoint: NSXPCListenerEndpoint {
        listener.endpoint
    }

    var subscriptionCount: Int {
        delegate.subscriptionCount
    }

    func waitForSubscriptionCount(_ expectedCount: Int) async throws {
        try await delegate.waitForSubscriptionCount(expectedCount)
    }

    func deliver(_ event: EventEnvelope) {
        delegate.deliver(event)
    }

    func invalidate() {
        listener.invalidate()
        delegate.invalidateConnection()
    }
}

private final class RuntimeClientXPCSystemTestListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var service: RuntimeClientXPCSystemTestControlService?

    var subscriptionCount: Int {
        lock.withLock { service?.subscriptionCount ?? 0 }
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        let service = RuntimeClientXPCSystemTestControlService(connection: connection)
        connection.remoteObjectInterface = NSXPCInterface(with: RuntimeEventSink.self)
        connection.exportedInterface = NSXPCInterface(with: RuntimeControlXPC.self)
        connection.exportedObject = service
        lock.withLock {
            self.connection = connection
            self.service = service
        }
        connection.resume()
        listener.invalidate()
        return true
    }

    func waitForSubscriptionCount(_ expectedCount: Int) async throws {
        let service = lock.withLock { self.service }
        guard let service else {
            throw RuntimeClientXPCSystemTestError.timeout
        }
        try await service.waitForSubscriptionCount(expectedCount)
    }

    func deliver(_ event: EventEnvelope) {
        lock.withLock { service }?.deliver(event)
    }

    func invalidateConnection() {
        let connection = lock.withLock { () -> NSXPCConnection? in
            defer { self.connection = nil }
            return self.connection
        }
        connection?.invalidate()
    }
}

private final class RuntimeClientXPCSystemTestControlService: NSObject, RuntimeControlXPC, @unchecked Sendable {
    private let lock = NSLock()
    private let eventSink: (any RuntimeEventSink)?
    private let subscriptions: AsyncStream<Int>
    private let subscriptionContinuation: AsyncStream<Int>.Continuation
    private var receivedSubscriptionCount = 0

    init(connection: NSXPCConnection) {
        let stream = AsyncStream.makeStream(of: Int.self, bufferingPolicy: .unbounded)
        subscriptions = stream.stream
        subscriptionContinuation = stream.continuation
        eventSink = connection.remoteObjectProxyWithErrorHandler { _ in } as? any RuntimeEventSink
        super.init()
    }

    var subscriptionCount: Int {
        lock.withLock { receivedSubscriptionCount }
    }

    func waitForSubscriptionCount(_ expectedCount: Int) async throws {
        if subscriptionCount >= expectedCount {
            return
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await count in self.subscriptions {
                    if count >= expectedCount {
                        return
                    }
                }
                throw RuntimeClientXPCSystemTestError.timeout
            }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw RuntimeClientXPCSystemTestError.timeout
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    func deliver(_ event: EventEnvelope) {
        guard let eventSink,
            let data = Self.encode([event])
        else {
            return
        }
        eventSink.deliver(data) {}
    }

    func runtimeStatus(_ request: Data, reply: @escaping (Data) -> Void) {
        let status = RuntimeHostStatus(
            hostState: "running",
            runtimeState: "ready",
            bootProgress: nil,
            startupFailureStep: nil,
            startupFailureCode: nil,
            crashLoopActive: false,
            daemonPID: Int32(ProcessInfo.processInfo.processIdentifier),
            imageVersion: "xpc-system-test"
        )
        reply(Self.encode(RuntimeControlReply(status: status)) ?? Data())
    }

    func runtimeInfo(_ request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
    func listSessions(_ request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
    func configuration(_ request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
    func updateConfiguration(_ request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
    func startRuntime(_ request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
    func stopRuntime(_ request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
    func restartRuntime(_ request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
    func resetRuntime(_ request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
    func listPackages(_ request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
    func packageInfo(_ request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
    func importPackage(_ request: Data, files: [FileHandle], reply: @escaping (Data) -> Void) { reply(Data()) }
    func beginInstallImported(_ request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
    func beginUninstallPackage(_ request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
    func cancelOperation(_ request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
    func listOperations(_ request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
    func operationStatus(_ request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }

    func subscribe(_ request: Data, reply: @escaping (Data) -> Void) {
        guard let decoded = try? JSONDecoder().decode(RuntimeSubscribeControlRequest.self, from: request),
            let eventSink
        else {
            reply(Data())
            return
        }
        let count = lock.withLock {
            receivedSubscriptionCount += 1
            return receivedSubscriptionCount
        }
        eventSink.handshake { [subscriptionContinuation] accepted in
            guard accepted,
                let response = Self.encode(RuntimeSubscribeControlReply(result: decoded.topics))
            else {
                reply(Data())
                return
            }
            reply(response)
            subscriptionContinuation.yield(count)
        }
    }

    func unsubscribe(_ request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
    func installImported(_ request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
    func launch(_ request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }
    func terminate(_ request: Data, reply: @escaping (Data) -> Void) { reply(Data()) }

    private static func encode<Value: Encodable>(_ value: Value) -> Data? {
        try? JSONEncoder().encode(value)
    }
}

private final class RuntimeClientXPCSystemTestBroker: RuntimeBrokerChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var servers: [RuntimeClientXPCSystemTestServer]
    private var nextEndpointIndex = 0

    init(servers: [RuntimeClientXPCSystemTestServer]) {
        self.servers = servers
    }

    var endpointRequestCount: Int {
        lock.withLock { nextEndpointIndex }
    }

    func hello(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        Self.encode(
            RuntimeHelloReply(
                runtimeVersion: "0.1.0",
                runtimeBuild: 1,
                apiVersion: .current,
                hostState: "running"
            )
        )
    }

    func requestEndpoint(_ request: Data) async throws(RuntimeControlClientError) -> RuntimeBrokerEndpointReply {
        let endpoint = lock.withLock { () -> NSXPCListenerEndpoint in
            let server: RuntimeClientXPCSystemTestServer
            if servers.indices.contains(nextEndpointIndex) {
                server = servers[nextEndpointIndex]
            } else {
                server = RuntimeClientXPCSystemTestServer()
                servers.append(server)
            }
            nextEndpointIndex += 1
            return server.endpoint
        }
        return RuntimeBrokerEndpointReply(
            data: Self.encode(RuntimeEndpointReply.granted),
            endpoint: RuntimeXPCListenerEndpoint(value: endpoint)
        )
    }

    func invalidate() {
        let servers = lock.withLock { self.servers }
        for server in servers {
            server.invalidate()
        }
    }

    private static func encode<Value: Encodable>(_ value: Value) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }
}

private struct RuntimeClientXPCSystemTestConnectionFactory: RuntimeXPCConnectionFactory {
    let broker: RuntimeClientXPCSystemTestBroker

    func makeBroker(
        serviceName: String,
        signingRequirement: String
    ) throws(RuntimeControlClientError) -> any RuntimeBrokerChannel {
        broker
    }

    func makeControl(
        endpoint: RuntimeXPCListenerEndpoint,
        signingRequirement: String,
        eventSink: RuntimeEventSinkReceiver
    ) throws(RuntimeControlClientError) -> any RuntimeControlChannel {
        try SystemRuntimeXPCConnectionFactory().makeControl(
            endpoint: endpoint,
            signingRequirement: signingRequirement,
            eventSink: eventSink
        )
    }
}
