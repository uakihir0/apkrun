/// Sends each entry to a primary sink and any additional sinks.
public struct CompositeLogSink: LogSink {
    private let sinks: [any LogSink]

    /// Creates a sink fan-out. The first sink is the primary production sink.
    public init(primary: any LogSink, additional: [any LogSink] = []) {
        sinks = [primary] + additional
    }

    /// Returns true when any sink accepts the requested level.
    public func isEnabled(for level: LogLevel) -> Bool {
        sinks.contains { $0.isEnabled(for: level) }
    }

    /// Writes the entry to every configured sink.
    public func write(_ entry: LogEntry) {
        for sink in sinks where sink.isEnabled(for: entry.level) {
            sink.write(entry)
        }
    }
}
