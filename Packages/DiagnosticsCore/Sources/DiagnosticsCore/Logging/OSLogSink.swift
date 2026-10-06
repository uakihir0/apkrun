import OSLog

/// The production sink backed by Apple's unified logging system.
struct OSLogSink: LogSink {
    private let logger: Logger
    private let warningLogger: Logger

    /// Creates a unified logger for a fixed subsystem and category.
    init(subsystem: LogSubsystem, category: String) {
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
