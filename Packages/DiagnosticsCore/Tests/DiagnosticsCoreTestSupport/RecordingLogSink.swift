import DiagnosticsCore
import Foundation

/// A thread-safe log sink for deterministic tests of logging clients.
public final class RecordingLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEntries: [LogEntry] = []
    private let minimumLevel: LogLevel

    /// Creates a sink that records entries at or above `minimumLevel`.
    public init(minimumLevel: LogLevel = .debug) {
        self.minimumLevel = minimumLevel
    }

    /// A point-in-time copy of all recorded entries.
    public var entries: [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return storedEntries
    }

    /// Returns whether the sink records the requested level.
    public func isEnabled(for level: LogLevel) -> Bool {
        level >= minimumLevel
    }

    /// Stores an entry for later assertions.
    public func write(_ entry: LogEntry) {
        lock.lock()
        storedEntries.append(entry)
        lock.unlock()
    }
}
