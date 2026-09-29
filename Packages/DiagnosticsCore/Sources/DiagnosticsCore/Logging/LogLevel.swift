/// A level used by the APKRun logging facade.
public enum LogLevel: String, CaseIterable, Comparable, Sendable {
    /// High-volume diagnostic detail.
    case debug

    /// State changes and operation timings.
    case info

    /// A user-visible outcome.
    case notice

    /// An operation failed.
    case error

    /// An invariant was violated.
    case fault

    /// Compares levels in increasing severity order.
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .notice: 2
        case .error: 3
        case .fault: 4
        }
    }
}
