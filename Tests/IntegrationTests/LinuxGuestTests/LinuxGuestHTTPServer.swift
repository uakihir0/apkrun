import Foundation
import Network

/// Serves the guest's HTTP 204 probe on every IPv4 host interface.
final class LinuxGuestHTTPServer: @unchecked Sendable {
    static let maximumHeaderLength = 16 * 1_024

    private let listener: NWListener
    private let connectionQueue = DispatchQueue(
        label: "io.apkrun.tests.linux-guest-http",
        attributes: .concurrent
    )
    private let startup = StartCompletion()
    private let connections = ActiveConnections()

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.any),
            port: .any
        )
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() async throws -> UInt16 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startup.install(continuation)
                guard !startup.isFinished else { return }

                listener.stateUpdateHandler = { [weak self, startup] state in
                    switch state {
                    case .ready:
                        guard let port = self?.listener.port?.rawValue else {
                            startup.finish(.failure(.posix(.EINVAL)))
                            self?.stop()
                            return
                        }
                        startup.finish(.success(port))
                    case .failed(let error):
                        startup.finish(.failure(error))
                        self?.stop()
                    case .cancelled:
                        startup.finish(.failure(.posix(.ECANCELED)))
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [connections, queue = connectionQueue] connection in
                    Self.receiveRequest(
                        on: connection,
                        queue: queue,
                        connections: connections
                    )
                }
                listener.start(queue: connectionQueue)
            }
        } onCancel: { [weak self, startup] in
            startup.finish(.failure(.posix(.ECANCELED)))
            self?.stop()
        }
    }

    func stop() {
        startup.finish(.failure(.posix(.ECANCELED)))
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        connections.cancelAll()
        listener.cancel()
    }

    deinit {
        stop()
    }

    private static func receiveRequest(
        on connection: NWConnection,
        queue: DispatchQueue,
        connections: ActiveConnections
    ) {
        guard connections.insert(connection) else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak connection] state in
            guard let connection else { return }
            switch state {
            case .failed, .cancelled:
                connections.remove(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)

        let completion = RequestCompletion(connection: connection, connections: connections)
        queue.asyncAfter(deadline: .now() + .seconds(10)) {
            completion.cancel()
        }
        receiveMore(
            on: connection,
            queue: queue,
            connections: connections,
            completion: completion,
            data: Data()
        )
    }

    private static func receiveMore(
        on connection: NWConnection,
        queue: DispatchQueue,
        connections: ActiveConnections,
        completion: RequestCompletion,
        data receivedData: Data
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) {
            data,
            _,
            isComplete,
            error in
            var requestData = receivedData
            if let data {
                requestData.append(data)
            }

            if let status = Self.completedRequestStatus(requestData) {
                completion.respond(status: status)
            } else if requestData.count >= Self.maximumHeaderLength {
                completion.respond(status: 431)
            } else if isComplete || error != nil {
                completion.respond(status: 400)
            } else {
                Self.receiveMore(
                    on: connection,
                    queue: queue,
                    connections: connections,
                    completion: completion,
                    data: requestData
                )
            }
        }
    }

    static func completedRequestStatus(_ requestData: Data) -> Int? {
        let headerTerminator = Data("\r\n\r\n".utf8)
        guard let headerRange = requestData.range(of: headerTerminator) else {
            return nil
        }
        let headerLength = requestData.distance(
            from: requestData.startIndex,
            to: headerRange.upperBound
        )
        guard headerLength <= maximumHeaderLength else {
            return 431
        }

        let requestHeaders = String(decoding: requestData[..<headerRange.lowerBound], as: UTF8.self)
        return isProbeRequest(requestHeaders) ? 204 : 404
    }

    private static func isProbeRequest(_ requestHeaders: String) -> Bool {
        guard let requestLine = requestHeaders.components(separatedBy: "\r\n").first else {
            return false
        }
        let fields = requestLine.split(separator: " ")
        return fields.count == 3
            && fields[0] == "GET"
            && fields[1] == "/generate_204"
            && (fields[2] == "HTTP/1.0" || fields[2] == "HTTP/1.1")
    }

    private final class StartCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<UInt16, NWError>?
        private var result: Result<UInt16, NWError>?

        var isFinished: Bool {
            lock.withLock { result != nil }
        }

        func install(_ continuation: CheckedContinuation<UInt16, NWError>) {
            let pendingResult: Result<UInt16, NWError>? = lock.withLock {
                if let result {
                    return result
                }
                self.continuation = continuation
                return nil
            }
            if let pendingResult {
                continuation.resume(with: pendingResult)
            }
        }

        func finish(_ result: Result<UInt16, NWError>) {
            let continuation: CheckedContinuation<UInt16, NWError>? = lock.withLock {
                guard self.result == nil else { return nil }
                self.result = result
                let continuation = self.continuation
                self.continuation = nil
                return continuation
            }
            continuation?.resume(with: result)
        }
    }

    private final class ActiveConnections: @unchecked Sendable {
        private let lock = NSLock()
        private var connections: [ObjectIdentifier: NWConnection] = [:]
        private var isStopped = false

        func insert(_ connection: NWConnection) -> Bool {
            lock.withLock {
                guard !isStopped else { return false }
                connections[ObjectIdentifier(connection)] = connection
                return true
            }
        }

        func remove(_ connection: NWConnection) {
            let wasTracked = lock.withLock {
                connections.removeValue(forKey: ObjectIdentifier(connection)) != nil
            }
            if wasTracked {
                connection.stateUpdateHandler = nil
            }
        }

        func cancel(_ connection: NWConnection) {
            remove(connection)
            connection.cancel()
        }

        func cancelAll() {
            let active = lock.withLock {
                isStopped = true
                let active = Array(connections.values)
                connections.removeAll()
                return active
            }
            for connection in active {
                connection.stateUpdateHandler = nil
                connection.cancel()
            }
        }
    }

    private final class RequestCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private let connection: NWConnection
        private let connections: ActiveConnections
        private var isFinished = false

        init(connection: NWConnection, connections: ActiveConnections) {
            self.connection = connection
            self.connections = connections
        }

        func respond(status: Int) {
            guard claimCompletion() else { return }
            connection.send(
                content: Self.response(status: status),
                completion: .contentProcessed { [connection, connections] _ in
                    connections.cancel(connection)
                }
            )
        }

        func cancel() {
            guard claimCompletion() else { return }
            connections.cancel(connection)
        }

        private func claimCompletion() -> Bool {
            lock.withLock {
                guard !isFinished else { return false }
                isFinished = true
                return true
            }
        }

        private static func response(status: Int) -> Data {
            let reason = status == 204 ? "No Content" : "Request Rejected"
            let contentLength = status == 204 ? "" : "Content-Length: 0\r\n"
            return Data(
                """
                HTTP/1.1 \(status) \(reason)\r
                \(contentLength)Connection: close\r
                \r
                """.utf8
            )
        }
    }
}
