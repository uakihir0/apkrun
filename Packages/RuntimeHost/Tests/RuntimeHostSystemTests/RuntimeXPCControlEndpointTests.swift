#if DEBUG
    import Foundation
    import DiagnosticsCore
    import RuntimeAPI
    import Testing

    @testable import RuntimeHost

    private final class RuntimeXPCTestEventSink: NSObject, RuntimeEventSink, @unchecked Sendable {
        private let lock = NSLock()
        private var handshakeCount = 0
        private var handshakeReplies: [(Bool) -> Void] = []
        private let handshakeCounts: AsyncStream<Int>
        private let handshakeCountContinuation: AsyncStream<Int>.Continuation

        override init() {
            let stream = AsyncStream.makeStream(of: Int.self, bufferingPolicy: .unbounded)
            handshakeCounts = stream.stream
            handshakeCountContinuation = stream.continuation
            super.init()
        }

        func handshake(reply: @escaping (Bool) -> Void) {
            let count = lock.withLock {
                handshakeCount += 1
                handshakeReplies.append(reply)
                return handshakeCount
            }
            handshakeCountContinuation.yield(count)
        }

        func deliver(_ batch: Data, reply: @escaping () -> Void) {
            reply()
        }

        func waitForHandshakes(_ expectedCount: Int) async throws {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await count in self.handshakeCounts {
                        if count >= expectedCount {
                            return
                        }
                    }
                }
                group.addTask {
                    do {
                        try await Task.sleep(for: .seconds(5))
                        throw RuntimeXPCSystemTestError.handshakeTimedOut
                    } catch is CancellationError {
                        return
                    }
                }
                try await group.next()
                group.cancelAll()
            }
        }

        func completeHandshakes() {
            let replies = lock.withLock {
                let replies = handshakeReplies
                handshakeReplies.removeAll()
                return replies
            }
            for reply in replies {
                reply(true)
            }
        }
    }

    private enum RuntimeXPCSystemTestError: Error {
        case handshakeTimedOut
        case controlProxyUnavailable
    }

    private enum RuntimeXPCControlOperation {
        case runtimeStatus
        case runtimeInfo
        case listSessions
        case packageInfo
        case configuration
        case updateConfiguration
        case startRuntime
        case subscribe

        func invoke(
            on proxy: RuntimeControlXPC,
            request: Data,
            reply: @escaping (Data) -> Void
        ) {
            switch self {
            case .runtimeStatus:
                proxy.runtimeStatus(request, reply: reply)
            case .runtimeInfo:
                proxy.runtimeInfo(request, reply: reply)
            case .listSessions:
                proxy.listSessions(request, reply: reply)
            case .packageInfo:
                proxy.packageInfo(request, reply: reply)
            case .configuration:
                proxy.configuration(request, reply: reply)
            case .updateConfiguration:
                proxy.updateConfiguration(request, reply: reply)
            case .startRuntime:
                proxy.startRuntime(request, reply: reply)
            case .subscribe:
                proxy.subscribe(request, reply: reply)
            }
        }
    }

    private final class RuntimeXPCControlTestClient: @unchecked Sendable {
        private let connection: NSXPCConnection

        init(endpoint: NSXPCListenerEndpoint, eventSink: RuntimeXPCTestEventSink) {
            connection = NSXPCConnection(listenerEndpoint: endpoint)
            connection.remoteObjectInterface = NSXPCInterface(with: RuntimeControlXPC.self)
            connection.exportedInterface = NSXPCInterface(with: RuntimeEventSink.self)
            connection.exportedObject = eventSink
            connection.resume()
        }

        func runtimeStatus(_ request: RuntimeStatusRequest) async throws -> RuntimeControlReply {
            try await call(request, operation: .runtimeStatus)
        }

        func startRuntime(_ request: StartRuntimeRequest) async throws -> RuntimeControlReply {
            try await call(request, operation: .startRuntime)
        }

        func runtimeInfo(_ request: RuntimeInfoControlRequest) async throws -> RuntimeInfoControlReply {
            try await call(request, operation: .runtimeInfo)
        }

        func listSessions(
            _ request: RuntimeListSessionsControlRequest
        ) async throws -> RuntimeListSessionsControlReply {
            try await call(request, operation: .listSessions)
        }

        func packageInfo(
            _ request: RuntimePackageInfoControlRequest
        ) async throws -> RuntimePackageInfoControlReply {
            try await call(request, operation: .packageInfo)
        }

        func configuration(
            _ request: RuntimeConfigurationControlRequest
        ) async throws -> RuntimeConfigurationControlReply {
            try await call(request, operation: .configuration)
        }

        func updateConfiguration(
            _ request: RuntimeUpdateConfigurationControlRequest
        ) async throws -> RuntimeUpdateConfigurationControlReply {
            try await call(request, operation: .updateConfiguration)
        }

        func subscribe(_ request: RuntimeSubscribeControlRequest) async throws -> RuntimeSubscribeControlReply {
            try await call(request, operation: .subscribe)
        }

        func invalidate() {
            connection.invalidate()
        }

        private func call<Request: Encodable, Reply: Decodable>(
            _ request: Request,
            operation: RuntimeXPCControlOperation
        ) async throws -> Reply {
            let requestData = try JSONEncoder().encode(request)
            let replyData: Data = try await withCheckedThrowingContinuation { continuation in
                let completion = RuntimeXPCReplyCompletion(continuation)
                guard
                    let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                        completion.finish(.failure(error))
                    }) as? RuntimeControlXPC
                else {
                    completion.finish(.failure(RuntimeXPCSystemTestError.controlProxyUnavailable))
                    return
                }
                operation.invoke(on: proxy, request: requestData) { data in
                    completion.finish(.success(data))
                }
            }
            return try JSONDecoder().decode(Reply.self, from: replyData)
        }
    }

    private final class RuntimeXPCReplyCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, any Error>?

        init(_ continuation: CheckedContinuation<Data, any Error>) {
            self.continuation = continuation
        }

        func finish(_ result: Result<Data, any Error>) {
            let continuation = lock.withLock {
                let continuation = self.continuation
                self.continuation = nil
                return continuation
            }
            continuation?.resume(with: result)
        }
    }

    private func makeRequestHeader(
        clientKind: RuntimeClientKind,
        apiVersion: APIVersion = .current
    ) -> APIRequestHeader {
        APIRequestHeader(apiVersion: apiVersion, clientKind: clientKind)
    }

    @Test
    func wrapperControlEndpointRejectsPackageInfoOutsideItsRegistration() async throws {
        let host = RuntimeHost()
        let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
        let otherPackageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.other"))
        let authorizer = WrapperAuthorizer(registrations: [
            WrapperRegistration(
                bundleID: "io.apkrun.android.io.apkrun.fixture.hellotext",
                packageID: packageID,
                codeSigningRequirement: "identifier \"io.apkrun.android.io.apkrun.fixture.hellotext\""
            )
        ])
        let server = RuntimeXPCAnonymousWrapperTestServer(
            host: host,
            bundleID: "io.apkrun.android.io.apkrun.fixture.hellotext",
            authorizer: authorizer
        )
        let eventSink = RuntimeXPCTestEventSink()
        let client = RuntimeXPCControlTestClient(endpoint: server.endpoint, eventSink: eventSink)
        defer {
            eventSink.completeHandshakes()
            client.invalidate()
            server.invalidate()
        }

        let ownedPackageReply = try await client.packageInfo(
            RuntimePackageInfoControlRequest(
                header: makeRequestHeader(clientKind: .wrapper),
                packageID: packageID
            )
        )
        let otherPackageReply = try await client.packageInfo(
            RuntimePackageInfoControlRequest(
                header: makeRequestHeader(clientKind: .wrapper),
                packageID: otherPackageID
            )
        )

        #expect(ownedPackageReply.error?.code != "runtime.notAuthorized")
        #expect(otherPackageReply.error?.code == "runtime.notAuthorized")
    }

    @Test
    func anonymousControlEndpointRejectsIncompatibleAPIVersion() async throws {
        let server = RuntimeXPCAnonymousControlTestServer(
            host: RuntimeHost(),
            clientKind: .app
        )
        let eventSink = RuntimeXPCTestEventSink()
        let client = RuntimeXPCControlTestClient(endpoint: server.endpoint, eventSink: eventSink)
        defer {
            eventSink.completeHandshakes()
            client.invalidate()
            server.invalidate()
        }

        let request = RuntimeStatusRequest(
            header: makeRequestHeader(
                clientKind: .app,
                apiVersion: APIVersion(major: APIVersion.current.major + 1, minor: 0)
            )
        )
        let reply = try await client.runtimeStatus(request)

        #expect(reply.error?.code == "runtime.apiVersionMismatch")
    }

    @Test
    func anonymousControlEndpointRejectsUnauthorizedOperationAndForgedClientKind() async throws {
        let server = RuntimeXPCAnonymousControlTestServer(
            host: RuntimeHost(),
            clientKind: .launcher
        )
        let eventSink = RuntimeXPCTestEventSink()
        let client = RuntimeXPCControlTestClient(endpoint: server.endpoint, eventSink: eventSink)
        defer {
            eventSink.completeHandshakes()
            client.invalidate()
            server.invalidate()
        }

        let forgedIdentityReply = try await client.runtimeStatus(
            RuntimeStatusRequest(header: makeRequestHeader(clientKind: .app))
        )
        let unauthorizedOperationReply = try await client.startRuntime(
            StartRuntimeRequest(header: makeRequestHeader(clientKind: .launcher))
        )

        #expect(forgedIdentityReply.error?.code == "runtime.notAuthorized")
        #expect(unauthorizedOperationReply.error?.code == "runtime.notAuthorized")
    }

    @Test
    func anonymousControlEndpointRejectsTheSixtyFifthInFlightRequest() async throws {
        let server = RuntimeXPCAnonymousControlTestServer(
            host: RuntimeHost(),
            clientKind: .app
        )
        let eventSink = RuntimeXPCTestEventSink()
        let client = RuntimeXPCControlTestClient(endpoint: server.endpoint, eventSink: eventSink)
        defer {
            eventSink.completeHandshakes()
            client.invalidate()
            server.invalidate()
        }

        let subscriptions = (0..<64).map { _ in
            Task {
                try await client.subscribe(
                    RuntimeSubscribeControlRequest(
                        header: makeRequestHeader(clientKind: .app),
                        topics: [.runtime]
                    )
                )
            }
        }
        try await eventSink.waitForHandshakes(64)

        let sixtyFifthReply = try await client.runtimeStatus(
            RuntimeStatusRequest(header: makeRequestHeader(clientKind: .app))
        )
        #expect(sixtyFifthReply.error?.code == "runtime.busy")

        eventSink.completeHandshakes()
        for subscription in subscriptions {
            let reply = try await subscription.value
            #expect(reply.error == nil)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func anonymousControlEndpointReadsAndUpdatesRuntimeConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuntimeXPCConfiguration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
        let host = RuntimeHost(paths: paths, environment: [:])
        try await host.start { ContinuousClock.now }

        let server = RuntimeXPCAnonymousControlTestServer(host: host, clientKind: .app)
        let eventSink = RuntimeXPCTestEventSink()
        let client = RuntimeXPCControlTestClient(endpoint: server.endpoint, eventSink: eventSink)
        let header = makeRequestHeader(clientKind: .app)

        do {
            let infoReply = try await client.runtimeInfo(
                RuntimeInfoControlRequest(
                    header: header,
                    request: RuntimeInfoRequest(resources: true, displays: true)
                )
            )
            #expect(infoReply.error == nil)
            #expect((infoReply.result?.sizing.cpuCount ?? 0) > 0)
            #expect(infoReply.result?.displays != nil)

            let sessionsReply = try await client.listSessions(RuntimeListSessionsControlRequest(header: header))
            #expect(sessionsReply.error == nil)
            #expect(sessionsReply.result?.isEmpty == true)

            let initialReply = try await client.configuration(RuntimeConfigurationControlRequest(header: header))
            #expect(initialReply.error == nil)
            #expect(initialReply.result?.entries.contains(where: { $0.key == "runtime.idleStopMinutes" }) == true)

            let updateReply = try await client.updateConfiguration(
                RuntimeUpdateConfigurationControlRequest(
                    header: header,
                    request: ConfigurationPatch(
                        patch: .object(["runtime": .object(["idleStopMinutes": .integer(15)])])
                    )
                )
            )
            #expect(updateReply.error == nil)
            let updatedIdleStop = updateReply.result?.entries.first {
                $0.key == "runtime.idleStopMinutes"
            }?.value
            #expect(updatedIdleStop == .integer(15))

            let readback = try await client.configuration(RuntimeConfigurationControlRequest(header: header))
            let readbackIdleStop = readback.result?.entries.first {
                $0.key == "runtime.idleStopMinutes"
            }?.value
            #expect(readbackIdleStop == .integer(15))
        } catch {
            eventSink.completeHandshakes()
            client.invalidate()
            server.invalidate()
            await host.shutdown()
            throw error
        }
        eventSink.completeHandshakes()
        client.invalidate()
        server.invalidate()
        await host.shutdown()
    }
#endif
