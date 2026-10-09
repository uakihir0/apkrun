import Foundation
import VirtualMachineCore

/// A developer console of a running Android boot, for the dev console socket (#014).
///
/// `output` carries the guest's bytes in order, and `send` writes host input to the guest. The
/// relay keeps reading the console even when no client is attached, so an absent client never
/// holds back the guest. Bytes that nobody reads are dropped, newest kept.
public final class DevConsoleEndpoint: Sendable {
    /// The console's device name in the guest: `hvc0` (the kernel console) or `hvc1` (the serial shell).
    public let name: String
    /// The guest's bytes, in order. One consumer reads this stream.
    public let output: AsyncStream<Data>
    private let channel: ConsoleChannel

    /// Attaches a relay to `channel`. `RuntimeSupervisor` creates the endpoints while it attaches
    /// the consoles of a boot.
    init(name: String, channel: ConsoleChannel) {
        self.name = name
        self.channel = channel
        let relay = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(256))
        output = relay.stream
        let bytes = channel.makeByteStream()
        Task {
            for await chunk in bytes.stream {
                if chunk.isEmpty {
                    bytes.acknowledgeDrainBarrier()
                    continue
                }
                relay.continuation.yield(chunk)
                bytes.acknowledgeConsumedBytes(chunk.count)
            }
            bytes.acknowledgeStreamEnd()
            relay.continuation.finish()
        }
    }

    /// Writes `data` to the guest's console. Throws when the console takes no host input.
    public func send(_ data: Data) throws {
        try channel.writeHostInput(data)
    }
}
