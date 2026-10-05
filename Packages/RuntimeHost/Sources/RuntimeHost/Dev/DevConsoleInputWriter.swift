import Foundation

/// Keeps blocking serial-port writes off the interactive console event loop.
final class DevConsoleInputWriter: Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    private let writerTask: Task<Void, Never>

    init(
        capacity: Int = 16,
        write: @escaping @Sendable (Data) throws -> Void,
        onFailure: @escaping @Sendable () -> Void
    ) {
        precondition(capacity > 0)
        let input = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingOldest(capacity)
        )
        continuation = input.continuation
        writerTask = Task.detached(priority: .userInitiated) {
            for await bytes in input.stream {
                guard !Task.isCancelled else { return }
                do {
                    try write(bytes)
                } catch {
                    if !Task.isCancelled {
                        onFailure()
                    }
                    input.continuation.finish()
                    return
                }
            }
        }
    }

    /// Adds one input chunk without waiting for a blocked guest-pipe write.
    func enqueue(_ bytes: Data) -> Bool {
        if case .enqueued = continuation.yield(bytes) {
            return true
        }
        return false
    }

    /// Stops accepting input and skips queued chunks after the current write.
    func cancel() {
        continuation.finish()
        writerTask.cancel()
    }

    /// Waits for all accepted writes to finish.
    func waitForCompletion() async {
        await writerTask.value
    }
}
