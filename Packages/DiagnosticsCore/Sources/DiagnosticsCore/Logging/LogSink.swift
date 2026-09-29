/// Receives structured entries produced by `APKLogger`.
public protocol LogSink: Sendable {
    /// Returns whether an entry at this level should be rendered.
    func isEnabled(for level: LogLevel) -> Bool

    /// Writes an already-rendered entry.
    func write(_ entry: LogEntry)
}

extension LogSink {
    /// Defaults custom sinks to accepting every level.
    public func isEnabled(for level: LogLevel) -> Bool {
        true
    }
}
