import Foundation
import GuestProtocol
import RuntimeCore

/// A guest agent that runs in memory. It speaks the frames of guest-protocol.md (through the same codec as the host),
/// and the test decides what it answers, when, and in which order.
final class InMemoryAgent: @unchecked Sendable {
    /// The channel that this agent says it serves.
    let channel: GPChannelKind

    private let lock = NSLock()
    private let toHost: AsyncStream<Data>
    private let toHostContinuation: AsyncStream<Data>.Continuation
    private var decoder = FrameDecoder()
    private var nextID: UInt64 = 1
    private var nextSequence: UInt64 = 1
    private var requestsSeen: [GPRequest] = []
    private var envelopesSeen: [GPEnvelope] = []
    private var held: [(id: UInt64, request: GPRequest)] = []

    /// Answers a request: the result to send, or nil to hold the request for ``releaseHeld`` or never answer it.
    var answer: @Sendable (GPRequest) -> GPResponse.OneOf_Result? = { _ in nil }

    init(channel: GPChannelKind) {
        self.channel = channel
        let stream = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        toHost = stream.stream
        toHostContinuation = stream.continuation
    }

    /// The host's end of the connection: the stream that the transport returns.
    func hostStream() -> any GuestByteStream {
        FakeHostStream(agent: self, frames: toHost)
    }

    /// Sends the agent's Hello. The major version, the channel, and the capabilities can be changed for a refusal.
    func sendHello(
        major: UInt32 = 1,
        minor: UInt32 = 0,
        channel: GPChannelKind? = nil,
        capabilities: [String] = ["core.v1", "display.v1", "launch.v1", "input.v1"]
    ) {
        var hello = GPHello()
        var version = GPProtocolVersion()
        version.major = major
        version.minor = minor
        hello.protocolVersion = version
        var info = GPAgentInfo()
        info.kind = .guestAgent
        info.versionCode = 1000
        info.versionName = "test"
        hello.agent = info
        var android = GPAndroidInfo()
        android.sdkInt = 37
        hello.android = android
        hello.capabilities = capabilities
        hello.channel = channel ?? self.channel
        hello.runtimeImageVersion = "test-image"
        send(body: .hello(hello))
    }

    /// Sends an event with the next sequence number of the connection.
    func sendEvent(_ kind: GPEvent.OneOf_Kind) {
        var event = GPEvent()
        lock.lock()
        event.seq = nextSequence
        nextSequence += 1
        lock.unlock()
        event.kind = kind
        send(body: .event(event))
    }

    /// Sends an event with a given sequence number, for the gap test.
    func sendEvent(seq: UInt64, _ kind: GPEvent.OneOf_Kind) {
        var event = GPEvent()
        event.seq = seq
        event.kind = kind
        send(body: .event(event))
    }

    /// Sends a response to the request with `id`.
    func respond(to id: UInt64, with result: GPResponse.OneOf_Result) {
        var response = GPResponse()
        response.result = result
        send(body: .response(response), replyTo: id)
    }

    /// Answers the held requests, in the reverse of their arrival when `reversed` is true, with `result` for each.
    func releaseHeld(reversed: Bool, _ result: (GPRequest) -> GPResponse.OneOf_Result) {
        let answers: [(id: UInt64, request: GPRequest)] = lock.withLock {
            let all = held
            held.removeAll()
            return reversed ? all.reversed() : all
        }
        for answer in answers {
            respond(to: answer.id, with: result(answer.request))
        }
    }

    /// Answers the oldest held request with `result`, and returns whether there was one.
    @discardableResult
    func releaseOldest(_ result: (GPRequest) -> GPResponse.OneOf_Result) -> Bool {
        let next: (id: UInt64, request: GPRequest)? = lock.withLock {
            guard !held.isEmpty else { return nil }
            return held.removeFirst()
        }
        guard let next else { return false }
        respond(to: next.id, with: result(next.request))
        return true
    }

    /// The requests that the host has sent, in order.
    var requests: [GPRequest] {
        lock.withLock { requestsSeen }
    }

    /// Every envelope that the host has sent, in order, including the HelloAck.
    var envelopes: [GPEnvelope] {
        lock.withLock { envelopesSeen }
    }

    /// The number of requests that have arrived and are not yet answered.
    var heldCount: Int {
        lock.withLock { held.count }
    }

    /// Closes the agent's side: the host's next read ends.
    func hangUp() {
        toHostContinuation.finish()
    }

    /// Takes the bytes that the host wrote to the agent.
    func receive(_ bytes: Data) {
        let bodies: [GPEnvelope] = lock.withLock {
            decoder.append(bytes)
            var found: [GPEnvelope] = []
            while let body = try? decoder.nextBody(), let envelope = try? FrameCodec.decodeBody(body) {
                found.append(envelope)
            }
            envelopesSeen.append(contentsOf: found)
            return found
        }
        for envelope in bodies {
            guard case .request(let request)? = envelope.body else {
                continue
            }
            lock.withLock { requestsSeen.append(request) }
            if let result = answer(request) {
                respond(to: envelope.id, with: result)
            } else {
                lock.withLock { held.append((envelope.id, request)) }
            }
        }
    }

    private func send(body: GPEnvelope.OneOf_Body, replyTo: UInt64 = 0) {
        var envelope = GPEnvelope()
        lock.lock()
        envelope.id = nextID
        nextID += 1
        lock.unlock()
        envelope.replyTo = replyTo
        envelope.body = body
        if let frame = try? FrameCodec.encode(envelope) {
            toHostContinuation.yield(frame)
        }
    }
}

/// The host's end of an in-memory connection.
private final class FakeHostStream: GuestByteStream, @unchecked Sendable {
    private let agent: InMemoryAgent
    private var frames: AsyncStream<Data>.AsyncIterator

    init(agent: InMemoryAgent, frames: AsyncStream<Data>) {
        self.agent = agent
        self.frames = frames.makeAsyncIterator()
    }

    func read() async throws -> Data? {
        await frames.next()
    }

    func write(_ bytes: Data) async throws {
        agent.receive(bytes)
    }

    func close() async {
        agent.hangUp()
    }
}

/// A transport that opens one in-memory agent per connection. The factory decides how each agent behaves.
final class InMemoryTransport: GuestTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var agentsOpened: [InMemoryAgent] = []
    private var refusals = 0
    private let configure: @Sendable (GuestEndpoint, InMemoryAgent, Int) -> Void

    /// Creates the transport. `configure` gets each agent and its 1-based connection number, and it sends the Hello.
    init(configure: @escaping @Sendable (GuestEndpoint, InMemoryAgent, Int) -> Void) {
        self.configure = configure
    }

    /// The agents that were opened, in order.
    var agents: [InMemoryAgent] {
        lock.withLock { agentsOpened }
    }

    /// Makes the next `count` opens fail.
    func refuseNext(_ count: Int) {
        lock.withLock { refusals = count }
    }

    func open(_ endpoint: GuestEndpoint) async throws -> any GuestByteStream {
        let refuse = lock.withLock { () -> Bool in
            if refusals > 0 {
                refusals -= 1
                return true
            }
            return false
        }
        if refuse {
            throw URLError(.cannotConnectToHost)
        }
        let agent = InMemoryAgent(channel: endpoint.channel)
        let number = lock.withLock { () -> Int in
            agentsOpened.append(agent)
            return agentsOpened.count
        }
        configure(endpoint, agent, number)
        return agent.hostStream()
    }
}
