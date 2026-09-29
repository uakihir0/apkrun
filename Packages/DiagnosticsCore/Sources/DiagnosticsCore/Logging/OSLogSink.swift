import OSLog

/// The production sink backed by Apple's unified logging system.
struct OSLogSink: LogSink {
    private let logger: Logger

    /// Creates a unified logger for a fixed subsystem and category.
    init(subsystem: LogSubsystem, category: String) {
        logger = Logger(subsystem: subsystem.rawValue, category: category)
    }

    /// Returns whether unified logging is collecting the requested level.
    func isEnabled(for level: LogLevel) -> Bool {
        logger.isEnabled(type: level.osLogType)
    }

    /// Writes public and private message representations with explicit OSLog privacy.
    func write(_ entry: LogEntry) {
        let type = entry.level.osLogType
        if let privateText = entry.formattedPrivateMessage {
            logger.log(
                level: type,
                "\(entry.formattedPublicMessage, privacy: .public)\u{1F}\(privateText, privacy: .private)"
            )
        } else {
            logger.log(level: type, "\(entry.formattedPublicMessage, privacy: .public)")
        }
    }
}

private extension LogLevel {
    var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .notice: .default
        case .error: .error
        case .fault: .fault
        }
    }
}
