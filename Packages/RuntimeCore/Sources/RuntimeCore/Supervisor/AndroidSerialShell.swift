import Foundation
import VirtualMachineCore

/// Runs commands on the Android serial shell on hvc1 (developer mode; android-image.md §7.1).
///
/// The init `console` service runs `sh` on `androidboot.console` (hvc1). Each
/// command is followed by a sentinel line with its exit status, and the reply
/// is everything the shell printed before the sentinel. Commands run one at a time.
public actor AndroidSerialShell {
    /// Why a command did not return.
    public enum Failure: Error, Equatable, Sendable {
        case timedOut
        case closed
        case inputUnavailable
    }

    /// One command's output and exit status.
    public struct Reply: Equatable, Sendable {
        /// What the command printed, without the echoed command line and the sentinel.
        public var output: String
        /// The command's exit status.
        public var status: Int
    }

    private let channel: ConsoleChannel
    private var received = ""
    private var waiter: CheckedContinuation<Void, Never>?
    private var isClosed = false
    private var sequence = 0
    private var readTask: Task<Void, Never>?

    /// Attaches to the shell's console channel; call before the VM starts to keep the prefix.
    public init(channel: ConsoleChannel) {
        self.channel = channel
        let stream = channel.makeByteStream()
        Task { await self.startReading(stream) }
    }

    private func startReading(_ stream: ConsoleByteStream) {
        readTask = Task { [weak self] in
            for await bytes in stream.stream {
                if bytes.isEmpty {
                    stream.acknowledgeDrainBarrier()
                    continue
                }
                await self?.append(String(decoding: bytes, as: UTF8.self))
                stream.acknowledgeConsumedBytes(bytes.count)
            }
            stream.acknowledgeStreamEnd()
            await self?.close()
        }
    }

    private func append(_ text: String) {
        received += text
        if received.count > 1_000_000 {
            received.removeFirst(received.count - 500_000)
        }
        waiter?.resume()
        waiter = nil
    }

    private func close() {
        isClosed = true
        waiter?.resume()
        waiter = nil
    }

    /// Runs one command and waits for its sentinel.
    public func run(_ command: String, timeout: Duration = .seconds(30)) async throws(Failure) -> Reply {
        sequence += 1
        let sentinel = "__APKRUN_END_\(sequence)__"
        received = ""
        do {
            try channel.writeHostInput(Data("\(command); echo \(sentinel) $?\n".utf8))
        } catch {
            throw .inputUnavailable
        }
        let deadline = ContinuousClock.now + timeout
        while true {
            let lines = received.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
            if let index = lines.firstIndex(where: { $0.hasPrefix(sentinel + " ") }) {
                let status = Int(lines[index].dropFirst(sentinel.count + 1)) ?? -1
                let body = lines[..<index].filter { !$0.contains(sentinel) }
                return Reply(output: body.joined(separator: "\n"), status: status)
            }
            if isClosed {
                throw .closed
            }
            if ContinuousClock.now >= deadline {
                throw .timedOut
            }
            await waitForOutput(until: deadline)
        }
    }

    private func waitForOutput(until deadline: ContinuousClock.Instant) async {
        let timer = Task { [weak self] in
            try? await Task.sleep(until: min(deadline, .now + .milliseconds(250)))
            await self?.wake()
        }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
        timer.cancel()
    }

    private func wake() {
        waiter?.resume()
        waiter = nil
    }
}
