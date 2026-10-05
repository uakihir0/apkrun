import Darwin
import Foundation

private enum DevConsoleOutputWriterFailure: Error {
    case getFlags(Int32)
    case setFlags(Int32)
}

// UNCHECKED-SENDABLE: writeLock serializes writes and restoration; counterLock protects droppedBytes.
/// Writes raw console bytes without letting terminal backpressure stall shutdown.
public final class DevConsoleOutputWriter: @unchecked Sendable {
    private let fileDescriptor: Int32
    private let originalFlags: Int32
    private let writeLock = NSLock()
    private let counterLock = NSLock()
    private var droppedBytes: UInt64 = 0
    private var writingIsCancelled = false
    private var isRestored = false

    /// Creates a writer and enables nonblocking writes on the file descriptor.
    public init(fileDescriptor: Int32) throws {
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0 else {
            throw DevConsoleOutputWriterFailure.getFlags(errno)
        }
        guard fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw DevConsoleOutputWriterFailure.setFlags(errno)
        }
        self.fileDescriptor = fileDescriptor
        originalFlags = flags
    }

    /// The bytes that could not be written before cancellation or an I/O error.
    public var droppedByteCount: UInt64 {
        counterLock.withLock { droppedBytes }
    }

    /// Writes as much as possible, checking cancellation while waiting for capacity.
    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        writeLock.lock()
        defer { writeLock.unlock() }

        guard !isRestored else {
            recordDroppedBytes(UInt64(data.count))
            return
        }
        guard !shouldStopWriting() else {
            recordDroppedBytes(UInt64(data.count))
            return
        }

        var writtenByteCount = 0
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            while writtenByteCount < bytes.count {
                guard !Task.isCancelled, !shouldStopWriting() else { break }
                let result = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: writtenByteCount),
                    bytes.count - writtenByteCount
                )
                if result > 0 {
                    writtenByteCount += result
                    continue
                }
                if result < 0, errno == EINTR {
                    continue
                }
                if result < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    var descriptor = pollfd(
                        fd: fileDescriptor,
                        events: Int16(POLLOUT),
                        revents: 0
                    )
                    let readiness = Darwin.poll(&descriptor, 1, 50)
                    if readiness >= 0 || errno == EINTR {
                        continue
                    }
                }
                break
            }
        }

        let remainingByteCount = data.count - writtenByteCount
        if remainingByteCount > 0 {
            recordDroppedBytes(UInt64(remainingByteCount))
        }
    }

    /// Stops current and future writes while keeping this consumer usable for accounting.
    public func cancelPendingWrites() {
        counterLock.withLock {
            writingIsCancelled = true
        }
    }

    /// Restores the file descriptor's original status flags.
    public func restore() {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !isRestored else { return }
        _ = fcntl(fileDescriptor, F_SETFL, originalFlags)
        isRestored = true
    }

    deinit {
        restore()
    }

    private func recordDroppedBytes(_ count: UInt64) {
        counterLock.withLock {
            droppedBytes &+= count
        }
    }

    private func shouldStopWriting() -> Bool {
        counterLock.withLock { writingIsCancelled }
    }
}
