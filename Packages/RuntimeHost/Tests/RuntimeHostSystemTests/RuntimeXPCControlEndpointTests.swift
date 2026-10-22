#if DEBUG
    import Foundation
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
#endif
