import Foundation
import OSLog

/// The unified-logging sink for one fixed subsystem and category.
struct OSLogSink: LogSink {
    let subsystem: LogSubsystem
    let category: String
    private let logger: Logger
    private let warningLogger: Logger

    /// Creates a unified logger for a fixed subsystem and category.
    init(subsystem: LogSubsystem, category: String) {
        self.subsystem = subsystem
        self.category = category
        logger = Logger(subsystem: subsystem.rawValue, category: category)
        warningLogger = Logger(
            subsystem: subsystem.rawValue,
            category: "\(category)\(OSLogCategory.warningSuffix)"
        )
    }

    /// Returns whether unified logging is collecting the requested level.
    func isEnabled(for level: LogLevel) -> Bool {
        (level == .warning ? warningLogger : logger).isEnabled(type: level.osLogType)
    }

    /// Writes public and private message representations with explicit OSLog privacy.
    func write(_ entry: LogEntry) {
        let activeLogger = entry.level == .warning ? warningLogger : logger
        let type = entry.level.osLogType
        if let privateText = entry.formattedPrivateMessage {
            activeLogger.log(
                level: type,
                "\(entry.formattedPublicMessage, privacy: .public)\u{1F}\(privateText, privacy: .private)"
            )
        } else {
            activeLogger.log(
                level: type,
                "\(entry.formattedPublicMessage, privacy: .public)"
            )
        }
    }
}

/// The process-wide production sink.
///
/// `APKLogger` gives each entry the subsystem and category of the logger that
/// wrote it. This sink sends each entry to that destination. A single fixed
/// `OSLogSink` would file every entry under its own category, so VM lifecycle
/// entries would not appear under `io.apkrun.vm` / `lifecycle`.
struct RoutingOSLogSink: LogSink {
    private let sinks = OSLogSinkCache()

    /// Writes the entry to the unified-log destination it names.
    func write(_ entry: LogEntry) {
        sinks.sink(subsystem: entry.subsystem, category: entry.category).write(entry)
    }
}

/// Keeps one `OSLogSink` per unified-log destination.
final class OSLogSinkCache: @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [String: OSLogSink] = [:]

    /// Returns the sink for a subsystem and category, creating it on first use.
    func sink(subsystem: LogSubsystem, category: String) -> OSLogSink {
        let key = "\(subsystem.rawValue)/\(category)"
        lock.lock()
        defer { lock.unlock() }
        if let existing = sinks[key] {
            return existing
        }
        let sink = OSLogSink(subsystem: subsystem, category: category)
        sinks[key] = sink
        return sink
    }
}

enum OSLogCategory {
    static let warningSuffix = ".__apkrun_warning"
}

extension LogLevel {
    fileprivate var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .notice: .default
        case .warning: .default
        case .error: .error
        case .fault: .fault
        }
    }
}
