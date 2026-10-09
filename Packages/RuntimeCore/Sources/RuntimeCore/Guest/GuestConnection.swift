import DiagnosticsCore
import Foundation
import GuestProtocol

/// What the handshake established (guest-protocol.md §5.1, §5.4).
public struct GuestSessionInfo: Equatable, Sendable {
    /// The protocol version that the agent speaks.
    public let agentProtocolVersion: ProtocolVersion
    /// The agent's `versionCode` from its Hello, which the provisioner compares with the bundled one.
    public let agentVersionCode: Int64
    /// The Android SDK level of the guest.
    public let androidSDKInt: Int32
    /// `ro.boot.apkrun.image`: the image version that the boot used.
    public let runtimeImageVersion: String
    /// The capabilities that both sides use on this connection (guest-protocol.md §5.3).
    public let enabledCapabilities: [String]
    /// The session token that the secondary connections of this session present (guest-protocol.md §5.4).
    public let sessionToken: Data

    /// Creates the information of one session.
    public init(
        agentProtocolVersion: ProtocolVersion,
        agentVersionCode: Int64,
        androidSDKInt: Int32,
        runtimeImageVersion: String,
        enabledCapabilities: [String],
        sessionToken: Data
    ) {
        self.agentProtocolVersion = agentProtocolVersion
        self.agentVersionCode = agentVersionCode
        self.androidSDKInt = androidSDKInt
        self.runtimeImageVersion = runtimeImageVersion
        self.enabledCapabilities = enabledCapabilities
        self.sessionToken = sessionToken
    }
}

/// One connection to a guest endpoint (guest-protocol.md §5, §6, §13.1).
///
/// The host writes every frame through one writer task, so frames never interleave, and it reads the agent's
/// frames in one reader task. Up to ``maximumInFlight`` requests may be outstanding. Responses may arrive in any
/// order, and each is matched by its `reply_to`. A request with no answer by its deadline fails with
/// `timeout(operation:)`, and the connection stays open. A protocol violation closes the connection.
public actor GuestConnection {
    /// The endpoint of this connection.
    public nonisolated let endpoint: GuestEndpoint
    /// The events of the agent, in order. The stream finishes when the connection closes.
    public nonisolated let events: AsyncStream<GPEvent>

    /// The number of requests that may be in flight at once (guest-protocol.md §6).
    public static let maximumInFlight = 64
    /// How long the agent has to answer Hello, and then HelloAck (guest-protocol.md §5.1).
    public static let defaultHandshakeTimeout: Duration = .seconds(5)
    /// How long after the agent's own timeout the host gives up on a request (guest-protocol.md §4.1 and §6).
    static let responseGrace: Duration = .seconds(1)

    private let transport: any GuestTransport
    private let presentedToken: Data?
    private let hostVersion: String
    private let handshakeTimeout: Duration
    private let logger: APKLogger
    private let eventContinuation: AsyncStream<GPEvent>.Continuation
    private var outbound: AsyncStream<Data>.Continuation?
    private var decoder = FrameDecoder()
    private var nextEnvelopeID: UInt64 = 1
    private var lastAgentEnvelopeID: UInt64 = 0
    private var lastEventSequence: UInt64 = 0
    private var handshakeContinuation: CheckedContinuation<Result<GuestSessionInfo, GuestProtocolFailure>, Never>?
    private var handshakeTimer: Task<Void, Never>?
    private var pending: [UInt64: PendingCall] = [:]
    private var deadlines: [UInt64: Task<Void, Never>] = [:]
    private var abandoned: Set<UInt64> = []
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []
    private var tasks: [Task<Void, Never>] = []
    private var isStarted = false
    private var failure: GuestProtocolFailure?

    /// The session that the handshake established, or nil before it completes.
    public private(set) var sessionInfo: GuestSessionInfo?

    private struct PendingCall {
        let operationName: String
        let continuation: CheckedContinuation<Result<GPResponse.OneOf_Result, GuestProtocolFailure>, Never>
    }

    /// Creates a connection to `endpoint`. A control connection makes its own session token. A secondary
    /// connection presents the token of its control session, which it must be given.
    public init(
        endpoint: GuestEndpoint,
        transport: any GuestTransport,
        presentedToken: Data? = nil,
        hostVersion: String = "dev",
        handshakeTimeout: Duration = GuestConnection.defaultHandshakeTimeout,
        logSink: (any LogSink)? = nil
    ) {
        self.endpoint = endpoint
        logger = APKLogger(category: RuntimeLogCategory.agents, sink: logSink)
        self.transport = transport
        self.presentedToken = presentedToken
        self.hostVersion = hostVersion
        self.handshakeTimeout = handshakeTimeout
        let stream = AsyncStream.makeStream(of: GPEvent.self, bufferingPolicy: .bufferingNewest(1024))
        events = stream.stream
        eventContinuation = stream.continuation
    }

    /// Whether the connection can carry requests: the handshake completed and the connection is still open.
    public var isUsable: Bool {
        sessionInfo != nil && failure == nil
    }

    /// Opens the stream, reads the agent's Hello, and answers with HelloAck (guest-protocol.md §5.1). It fails with
    /// the typed failure of the handshake, and within ``handshakeTimeout`` at most.
    public func open() async throws(GuestProtocolFailure) -> GuestSessionInfo {
        guard !isStarted, failure == nil else {
            throw failure ?? .disconnected
        }
        isStarted = true
        if endpoint.isSecondary && presentedToken == nil {
            throw .handshakeFailed(.badToken)
        }
        let opened: any GuestByteStream
        do {
            opened = try await transport.open(endpoint)
        } catch {
            throw .disconnected
        }
        let result: Result<GuestSessionInfo, GuestProtocolFailure> = await withCheckedContinuation { continuation in
            if failure != nil {
                continuation.resume(returning: .failure(failure ?? .disconnected))
                Task { await opened.close() }
                return
            }
            handshakeContinuation = continuation
            let frames = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
            outbound = frames.continuation
            tasks.append(
                Task {
                    for await frame in frames.stream {
                        do {
                            try await opened.write(frame)
                        } catch {
                            // A write that fails ends the connection, and the requests that wait on it get the reason.
                            self.logger.warning(
                                "A frame could not be written to the guest: \(error.localizedDescription, .public)")
                            self.connectionLost(.disconnected)
                            break
                        }
                    }
                    await opened.close()
                }
            )
            tasks.append(Task { await self.readLoop(opened) })
            handshakeTimer = Task {
                try? await Task.sleep(for: self.handshakeTimeout)
                self.handshakeTimedOut()
            }
        }
        switch result {
        case .success(let info):
            return info
        case .failure(let reason):
            throw reason
        }
    }

    /// Sends one operation and waits for its result (guest-protocol.md §6). Cancelling the calling task sends a
    /// `Cancel` to the agent, and the answer that comes back is returned as usual.
    public func send<Operation: GuestOperation>(
        _ operation: Operation,
        timeout: Duration? = nil
    ) async throws(GuestProtocolFailure) -> Operation.Result {
        guard isUsable else {
            throw failure ?? .disconnected
        }
        await acquireSlot()
        if let failure {
            throw failure
        }
        let limit = timeout ?? operation.timeout
        let id = allocateEnvelopeID()
        var request = GPRequest()
        request.timeoutMs = UInt32(clamping: limit.wholeMilliseconds)
        request.op = operation.request()
        var envelope = GPEnvelope()
        envelope.id = id
        envelope.body = .request(request)
        let frame = try FrameCodec.encode(envelope)
        let outcome: Result<GPResponse.OneOf_Result, GuestProtocolFailure> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending[id] = PendingCall(operationName: operation.operationName, continuation: continuation)
                deadlines[id] = Task {
                    try? await Task.sleep(for: limit + Self.responseGrace)
                    self.expire(id)
                }
                outbound?.yield(frame)
            }
        } onCancel: {
            Task { await self.cancelRequest(id) }
        }
        switch outcome {
        case .failure(let reason):
            throw reason
        case .success(let result):
            if case .error(let guestError) = result {
                throw .remote(
                    code: guestError.code,
                    message: guestError.message,
                    operation: operation.operationName
                )
            }
            guard let value = Operation.decode(result) else {
                connectionLost(.malformedFrame)
                throw .malformedFrame
            }
            return value
        }
    }

    /// Closes the connection. The pending requests fail with `disconnected`, and the events stream finishes.
    public func close() {
        connectionLost(.disconnected)
    }

    // MARK: - Reading

    private func readLoop(_ opened: any GuestByteStream) async {
        while true {
            do {
                guard let bytes = try await opened.read() else {
                    connectionLost(.disconnected)
                    return
                }
                if !bytes.isEmpty {
                    try consume(bytes)
                }
            } catch let reason as GuestProtocolFailure {
                connectionLost(reason)
                return
            } catch {
                connectionLost(.disconnected)
                return
            }
            if failure != nil {
                return
            }
        }
    }

    private func consume(_ bytes: Data) throws(GuestProtocolFailure) {
        decoder.append(bytes)
        while let body = try decoder.nextBody() {
            let envelope = try FrameCodec.decodeBody(body)
            try handle(envelope)
        }
    }

    private func handle(_ envelope: GPEnvelope) throws(GuestProtocolFailure) {
        guard envelope.id > lastAgentEnvelopeID else {
            throw .malformedFrame
        }
        lastAgentEnvelopeID = envelope.id
        guard let body = envelope.body else {
            throw .malformedFrame
        }
        guard sessionInfo != nil else {
            // The agent speaks first, and nothing but its Hello may arrive before the handshake completes (§5.1).
            guard case .hello(let hello) = body else {
                throw .malformedFrame
            }
            try acceptHello(hello)
            return
        }
        switch body {
        case .response(let response):
            try deliver(response, replyTo: envelope.replyTo)
        case .event(let event):
            try deliver(event)
        case .inputAck:
            // The input acks belong to the input stream, which #024 uses.
            break
        default:
            throw .malformedFrame
        }
    }

    private func acceptHello(_ hello: GPHello) throws(GuestProtocolFailure) {
        let decision = GuestHandshake.evaluate(hello, expectedChannel: endpoint.channel)
        switch decision {
        case .accepted(let enabled, let agentVersion):
            let token = presentedToken ?? Self.randomToken()
            var ack = GPHelloAck()
            var version = GPProtocolVersion()
            version.major = UInt32(ProtocolVersion.host.major)
            version.minor = UInt32(ProtocolVersion.host.minor)
            ack.hostProtocolVersion = version
            ack.sessionToken = token
            ack.enabledCapabilities = enabled
            ack.hostVersion = hostVersion
            ack.outcome = .accepted(GPAccepted())
            sendEnvelope { envelope in envelope.body = .helloAck(ack) }
            let info = GuestSessionInfo(
                agentProtocolVersion: agentVersion,
                agentVersionCode: hello.agent.versionCode,
                androidSDKInt: hello.android.sdkInt,
                runtimeImageVersion: hello.runtimeImageVersion,
                enabledCapabilities: enabled,
                sessionToken: token
            )
            sessionInfo = info
            handshakeTimer?.cancel()
            handshakeContinuation?.resume(returning: .success(info))
            handshakeContinuation = nil
        case .rejected(let reason, let rejection):
            var ack = GPHelloAck()
            var rejected = GPRejected()
            rejected.reason = reason
            ack.outcome = .rejected(rejected)
            sendEnvelope { envelope in envelope.body = .helloAck(ack) }
            throw rejection
        case .invalid(let rejection):
            throw rejection
        }
    }

    private func deliver(_ response: GPResponse, replyTo: UInt64) throws(GuestProtocolFailure) {
        if let call = pending.removeValue(forKey: replyTo) {
            deadlines.removeValue(forKey: replyTo)?.cancel()
            releaseSlot()
            guard let result = response.result else {
                call.continuation.resume(returning: .failure(.malformedFrame))
                throw .malformedFrame
            }
            call.continuation.resume(returning: .success(result))
            return
        }
        if abandoned.remove(replyTo) != nil {
            // The answer to a request that already timed out. The host has stopped waiting for it.
            return
        }
        throw .malformedFrame
    }

    private func deliver(_ event: GPEvent) throws(GuestProtocolFailure) {
        guard event.seq == lastEventSequence + 1 else {
            throw .malformedFrame
        }
        lastEventSequence = event.seq
        eventContinuation.yield(event)
    }

    // MARK: - Requests

    private func expire(_ id: UInt64) {
        guard let call = pending.removeValue(forKey: id) else {
            return
        }
        deadlines.removeValue(forKey: id)
        abandoned.insert(id)
        releaseSlot()
        call.continuation.resume(returning: .failure(.timeout(operation: call.operationName)))
    }

    private func cancelRequest(_ id: UInt64) {
        guard pending[id] != nil else {
            return
        }
        sendEnvelope { envelope in
            var cancel = GPCancel()
            cancel.targetID = id
            envelope.body = .cancel(cancel)
        }
    }

    private func acquireSlot() async {
        while pending.count >= Self.maximumInFlight, failure == nil {
            await withCheckedContinuation { slotWaiters.append($0) }
        }
    }

    private func releaseSlot() {
        if !slotWaiters.isEmpty {
            slotWaiters.removeFirst().resume()
        }
    }

    // MARK: - Writing and failure

    private func allocateEnvelopeID() -> UInt64 {
        let id = nextEnvelopeID
        nextEnvelopeID += 1
        return id
    }

    /// Builds an envelope with the next host id and queues its frame for the writer task.
    private func sendEnvelope(_ build: (inout GPEnvelope) -> Void) {
        var envelope = GPEnvelope()
        envelope.id = allocateEnvelopeID()
        build(&envelope)
        guard let frame = try? FrameCodec.encode(envelope) else {
            return
        }
        outbound?.yield(frame)
    }

    private func handshakeTimedOut() {
        if sessionInfo == nil {
            connectionLost(.handshakeTimedOut)
        }
    }

    /// Ends the connection once: the handshake and every pending request fail with `reason`, and the streams end.
    /// The writer task closes the byte stream after the frames already queued, such as a rejection, have gone out.
    private func connectionLost(_ reason: GuestProtocolFailure) {
        guard failure == nil else {
            return
        }
        failure = reason
        logger.info(
            "The \(endpoint.developmentSocketName ?? "guest", .public) connection ended: \(reason.catalogName, .public)"
        )
        handshakeTimer?.cancel()
        if let continuation = handshakeContinuation {
            handshakeContinuation = nil
            continuation.resume(returning: .failure(reason))
        }
        let calls = pending.values
        pending.removeAll()
        for call in calls {
            call.continuation.resume(returning: .failure(reason))
        }
        for (_, timer) in deadlines {
            timer.cancel()
        }
        deadlines.removeAll()
        for waiter in slotWaiters {
            waiter.resume()
        }
        slotWaiters.removeAll()
        eventContinuation.finish()
        outbound?.finish()
    }

    private static func randomToken() -> Data {
        Data((0..<16).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
    }
}

extension GuestEndpoint {
    /// Whether a connection to this endpoint is secondary, and so presents the session token (guest-protocol.md §5.4).
    var isSecondary: Bool {
        switch self {
        case .guestControl, .storeControl: false
        case .guestInput, .guestBulk, .storeArtifacts, .developmentIME: true
        }
    }
}

extension Duration {
    /// The duration in whole milliseconds, rounded down.
    var wholeMilliseconds: Int64 {
        let parts = components
        return parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
    }
}
