import Foundation

/// A normalized host log record produced by unified logging or a file mirror.
public struct LogRecord: Codable, Equatable, Hashable, Sendable {
    /// The timestamp as emitted by unified logging or the file mirror.
    public let timestamp: String
    /// The normalized log level.
    public let level: String
    /// The logging subsystem.
    public let subsystem: String
    /// The logging category.
    public let category: String
    /// The public portion of the log message.
    public let message: String

    /// Creates a normalized host log record.
    public init(
        timestamp: String,
        level: String,
        subsystem: String,
        category: String,
        message: String
    ) {
        self.timestamp = timestamp
        self.level = level
        self.subsystem = subsystem
        self.category = category
        self.message = message
    }

    /// Formats the record as one human-readable line.
    public var humanLine: String {
        [
            timestamp,
            level,
            "\(subsystem)/\(category)",
            message,
        ]
        .map(Self.escapeTerminalControls)
        .joined(separator: " ")
    }

    /// Formats the record as one newline-delimited JSON object.
    public var jsonLine: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
            let result = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return Self.escapeJSONFormattingScalars(in: result)
    }

    private static func escapeTerminalControls(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0x09:
                return "\\t"
            case 0x0A:
                return "\\n"
            case 0x0D:
                return "\\r"
            default:
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator:
                    return "\\u{\(String(scalar.value, radix: 16).uppercased())}"
                default:
                    return String(scalar)
                }
            }
        }
        .joined()
    }

    private static func escapeJSONFormattingScalars(in json: String) -> String {
        json.unicodeScalars.map { scalar in
            switch scalar.properties.generalCategory {
            case .format, .lineSeparator, .paragraphSeparator:
                return Self.jsonEscape(for: scalar.value)
            default:
                return String(scalar)
            }
        }
        .joined()
    }

    private static func jsonEscape(for value: UInt32) -> String {
        if value <= 0xFFFF {
            return "\\u" + value.hexadecimal(paddingTo: 4)
        }
        let adjusted = value - 0x1_0000
        let high = 0xD800 + (adjusted >> 10)
        let low = 0xDC00 + (adjusted & 0x3FF)
        return "\\u" + high.hexadecimal(paddingTo: 4) + "\\u" + low.hexadecimal(paddingTo: 4)
    }
}

extension UInt32 {
    fileprivate func hexadecimal(paddingTo width: Int) -> String {
        let digits = String(self, radix: 16).uppercased()
        return String(repeating: "0", count: Swift.max(0, width - digits.count)) + digits
    }
}

extension LogRecord {
    fileprivate var estimatedUTF8ByteCount: Int {
        timestamp.utf8.count
            + level.utf8.count
            + subsystem.utf8.count
            + category.utf8.count
            + message.utf8.count
    }
}

/// Options for reading host logs.
public struct LogReadOptions: Sendable {
    /// Whether to keep the command open and stream new entries.
    public let follow: Bool
    /// The maximum history age, expressed as seconds, minutes, hours, or days.
    public let since: String?
    /// An optional subsystem prefix within `io.apkrun`.
    public let subsystem: String?
    /// An optional minimum log level.
    public let level: LogLevel?
    /// An absolute lower bound for a history query.
    public let startingAt: Date?
    fileprivate let minimumTimestamp: Date?

    /// Creates options for reading host logs.
    public init(
        follow: Bool = false,
        since: String? = nil,
        subsystem: String? = nil,
        level: LogLevel? = nil,
        startingAt: Date? = nil
    ) {
        self.follow = follow
        self.since = since
        self.subsystem = subsystem
        self.level = level
        self.startingAt = startingAt
        minimumTimestamp = nil
    }

    fileprivate init(
        follow: Bool = false,
        since: String? = nil,
        subsystem: String? = nil,
        level: LogLevel? = nil,
        startingAt: Date? = nil,
        minimumTimestamp: Date?
    ) {
        self.follow = follow
        self.since = since
        self.subsystem = subsystem
        self.level = level
        self.startingAt = startingAt
        self.minimumTimestamp = minimumTimestamp
    }
}

/// Failures raised when a log-read request is invalid.
public enum LogReaderError: Error, Equatable, Sendable {
    /// The requested duration is malformed or exceeds the supported maximum.
    case invalidDuration
}

/// The result of running `/usr/bin/log`.
public struct LogCommandResult: Sendable {
    /// The process exit status.
    public let exitCode: Int32
    /// Captured standard output, when output capture is enabled.
    public let standardOutput: Data
    /// Captured standard error, when output capture is enabled.
    public let standardError: Data
    /// Whether the initial-output deadline expired.
    public let timedOut: Bool

    /// Creates a result for a completed or timed-out log command.
    public init(
        exitCode: Int32,
        standardOutput: Data = Data(),
        standardError: Data = Data(),
        timedOut: Bool = false
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
    }
}

/// An injectable process boundary used by `LogReader`.
public protocol LogCommandRunning: Sendable {
    /// Runs the system log command and delivers output as it becomes available.
    ///
    /// For stream commands, `onReady` is called after the subscription is confirmed or output arrives.
    func run(
        arguments: [String],
        initialOutputTimeout: Duration?,
        captureOutput: Bool,
        onStarted: @escaping @Sendable () -> Void,
        onReady: @escaping @Sendable () -> Void,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> LogCommandResult
}

/// Runs the system `log` tool and streams its output without a shell.
public final class SystemLogCommandRunner: LogCommandRunning {
    private let executableURL: URL
    private let signalsReadinessOverride: Bool?

    /// Creates a runner for `/usr/bin/log`.
    public convenience init() {
        self.init(executableURL: URL(fileURLWithPath: "/usr/bin/log"))
    }

    init(executableURL: URL, signalsReadiness: Bool? = nil) {
        self.executableURL = executableURL
        signalsReadinessOverride = signalsReadiness
    }

    /// Runs the command, optionally timing out if it produces no initial output.
    public func run(
        arguments: [String],
        initialOutputTimeout: Duration?,
        captureOutput: Bool,
        onStarted: @escaping @Sendable () -> Void,
        onReady: @escaping @Sendable () -> Void,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> LogCommandResult {
        let execution = LogProcessExecution(
            executableURL: executableURL,
            arguments: arguments,
            initialOutputTimeout: initialOutputTimeout,
            captureOutput: captureOutput,
            signalsReadiness: signalsReadinessOverride ?? (arguments.first == "stream"),
            onStarted: onStarted,
            onReady: onReady,
            onOutput: onOutput
        )
        return try await withTaskCancellationHandler {
            try await execution.run()
        } onCancel: {
            execution.cancel()
        }
    }
}

/// Reads unified logs and falls back to the public daemon log mirrors.
public struct LogReader: Sendable {
    private let paths: APKRunPaths
    private let runner: any LogCommandRunning
    private static let maximumDurationSeconds: TimeInterval = 30 * 86_400
    private static let timestampParser = LogTimestampParser()

    /// Creates a log reader using the given filesystem paths and process runner.
    public init(paths: APKRunPaths, runner: any LogCommandRunning = SystemLogCommandRunner()) {
        self.paths = paths
        self.runner = runner
    }

    /// Reads normalized entries; follow mode retries exits and falls back to a snapshot if startup fails.
    @discardableResult
    public func read(
        _ options: LogReadOptions = LogReadOptions(),
        onEvent: @escaping @Sendable (LogReadEvent) -> Void
    ) async throws -> LogReadReport {
        if let since = options.since, !Self.isValidDuration(since) {
            throw LogReaderError.invalidDuration
        }
        if options.follow {
            return try await readFollowing(options, onEvent: onEvent)
        }
        return try await readSnapshot(options, onEvent: onEvent).report
    }

    /// Validates the simple duration grammar accepted by `log show --last`.
    public static func isValidDuration(_ value: String) -> Bool {
        guard
            value.range(
                of: #"^[1-9][0-9]*(?:s|m|h|d)$"#,
                options: .regularExpression
            ) != nil,
            let amount = Double(value.dropLast()),
            amount.isFinite
        else {
            return false
        }
        let multiplier: Double
        switch value.last {
        case "s": multiplier = 1
        case "m": multiplier = 60
        case "h": multiplier = 3_600
        case "d": multiplier = 86_400
        default: return false
        }
        return amount <= maximumDurationSeconds / multiplier
    }

    private func readSnapshot(
        _ options: LogReadOptions,
        onEvent: @escaping @Sendable (LogReadEvent) -> Void
    ) async throws -> LogSnapshotRead {
        let snapshotOptions = optionsWithFixedHistoryWindow(options)
        let accumulator = LogRecordAccumulator(options: snapshotOptions, onEvent: onEvent)
        let queryStartedAt = Date()
        let result = try await runCommand(
            arguments: commandArguments(for: snapshotOptions),
            initialOutputTimeout: .seconds(30),
            captureOutput: false,
            onStarted: {},
            onReady: {},
            onOutput: accumulator.append
        )
        accumulator.finishPendingLine()
        let commandSucceeded = result.exitCode == 0 && !result.timedOut
        let shouldReadMirrors = !commandSucceeded || accumulator.entryCount == 0
        let mirrorsAvailable =
            shouldReadMirrors
            ? emitMirrors(
                snapshotOptions,
                accumulator: accumulator,
                onEvent: onEvent,
                after: accumulator.watermark,
                coversOlderRecords: commandSucceeded
            )
            : false
        let report = LogReadReport(
            emittedEntries: accumulator.entryCount,
            usedMirrors: mirrorsAvailable,
            commandAttempts: 1,
            hasReadableSource: commandSucceeded || accumulator.entryCount > 0 || mirrorsAvailable,
            unifiedLogQuerySucceeded: commandSucceeded
        )
        return LogSnapshotRead(
            report: report,
            watermark: accumulator.watermark,
            queryStartedAt: queryStartedAt
        )
    }

    private func optionsWithFixedHistoryWindow(_ options: LogReadOptions) -> LogReadOptions {
        guard options.minimumTimestamp == nil,
            options.startingAt == nil,
            let duration = Self.durationSeconds(options.since ?? "1h")
        else {
            return options
        }
        return LogReadOptions(
            follow: options.follow,
            since: options.since,
            subsystem: options.subsystem,
            level: options.level,
            startingAt: options.startingAt,
            minimumTimestamp: Date().addingTimeInterval(-duration)
        )
    }

    private func readFollowing(
        _ options: LogReadOptions,
        onEvent: @escaping @Sendable (LogReadEvent) -> Void
    ) async throws -> LogReadReport {
        let followStartedAt = Date()
        let historyDuration = options.since ?? "1h"
        let historyCutoff = followStartedAt.addingTimeInterval(
            -(Self.durationSeconds(historyDuration) ?? 3_600)
        )
        let historyQueryStart = Date(
            timeIntervalSince1970: floor(historyCutoff.timeIntervalSince1970) - 1
        )
        let historyOptions = LogReadOptions(
            since: historyDuration,
            subsystem: options.subsystem,
            level: options.level,
            startingAt: historyQueryStart,
            minimumTimestamp: historyCutoff
        )
        let liveOptions = LogReadOptions(
            follow: true,
            subsystem: options.subsystem,
            level: options.level
        )
        let handoff = LogReadEventHandoff(onEvent: onEvent)
        var historyReport: LogReadReport?
        var lastCoverageTime: Date?
        var attempts = 0
        var usedMirrors = false
        var hasReadableSource = false
        var consecutiveStreamFailures = 0
        var consecutiveStartFailures = 0
        var retryDelay: Duration = .seconds(1)
        var hasUnresolvedStreamGap = false

        do {
            try await withTaskCancellationHandler {
                while true {
                    let startSignal = LogCommandStartSignal()
                    let accumulator = LogRecordAccumulator(options: liveOptions, onEvent: handoff.receiveLive)
                    let arguments = commandArguments(for: liveOptions)
                    var didRunInitialHistory = false
                    var initialHistoryCoveredWindow = false
                    var initialHistoryQueryStartedAt: Date?
                    var reconnectCatchupQueryStartedAt: Date?
                    var reconnectCatchupCoveredInterval = false
                    var reconciledCheckpointWithCompleteQuery = false
                    let (result, streamStarted, streamEndedAt) =
                        try await withThrowingTaskGroup(of: (LogCommandResult, Date).self) { group in
                            group.addTask {
                                defer { startSignal.markFinished() }
                                let result = try await self.runCommand(
                                    arguments: arguments,
                                    initialOutputTimeout: .seconds(30),
                                    captureOutput: false,
                                    onStarted: {},
                                    onReady: {
                                        handoff.beginCatchup()
                                        startSignal.markReady()
                                    },
                                    onOutput: accumulator.append
                                )
                                accumulator.finishPendingLine()
                                return (result, Date())
                            }

                            let didBecomeReady = await startSignal.wait()
                            if didBecomeReady, historyReport == nil {
                                didRunInitialHistory = true
                                let fullHistory = try await self.readSnapshot(
                                    historyOptions, onEvent: handoff.receiveHistory)
                                initialHistoryQueryStartedAt = fullHistory.queryStartedAt
                                historyReport = LogReadReport(
                                    emittedEntries: handoff.entryCount,
                                    usedMirrors: fullHistory.report.usedMirrors,
                                    commandAttempts: fullHistory.report.commandAttempts,
                                    hasReadableSource: fullHistory.report.hasReadableSource,
                                    unifiedLogQuerySucceeded: fullHistory.report.unifiedLogQuerySucceeded
                                )
                                usedMirrors = historyReport?.usedMirrors ?? false
                                hasReadableSource = historyReport?.hasReadableSource ?? false
                                initialHistoryCoveredWindow =
                                    fullHistory.report.unifiedLogQuerySucceeded
                                    && !fullHistory.report.usedMirrors
                                handoff.finishHistory(
                                    hasCompleteHistory: initialHistoryCoveredWindow,
                                    coverageWatermark: fullHistory.watermark,
                                    coverageStartTimestamp: historyOptions.minimumTimestamp
                                )
                            } else if didBecomeReady {
                                let catchupOptions = self.reconnectCatchupOptions(
                                    for: options,
                                    startingAt: lastCoverageTime ?? followStartedAt,
                                    minimumTimestamp: historyCutoff
                                )
                                handoff.beginHistoryOverlap(coveringSince: catchupOptions.startingAt)
                                let overlapHistory = try await self.readSnapshot(
                                    catchupOptions,
                                    onEvent: handoff.receiveHistoryOverlap
                                )
                                reconnectCatchupQueryStartedAt = overlapHistory.queryStartedAt
                                handoff.finishCatchup(
                                    hasCompleteHistory: overlapHistory.report.unifiedLogQuerySucceeded
                                        && !overlapHistory.report.usedMirrors,
                                    coverageWatermark: overlapHistory.watermark,
                                    coverageStartTimestamp: catchupOptions.startingAt
                                )
                                if let previous = historyReport {
                                    historyReport = LogReadReport(
                                        emittedEntries: handoff.entryCount,
                                        usedMirrors: previous.usedMirrors
                                            || overlapHistory.report.usedMirrors,
                                        commandAttempts: previous.commandAttempts
                                            + overlapHistory.report.commandAttempts,
                                        hasReadableSource: previous.hasReadableSource
                                            || overlapHistory.report.hasReadableSource,
                                        unifiedLogQuerySucceeded: previous.unifiedLogQuerySucceeded
                                            || overlapHistory.report.unifiedLogQuerySucceeded
                                    )
                                }
                                usedMirrors = usedMirrors || overlapHistory.report.usedMirrors
                                hasReadableSource =
                                    hasReadableSource || overlapHistory.report.hasReadableSource
                                reconnectCatchupCoveredInterval =
                                    overlapHistory.report.unifiedLogQuerySucceeded
                                    && !overlapHistory.report.usedMirrors
                                if reconnectCatchupCoveredInterval {
                                    hasUnresolvedStreamGap = false
                                } else {
                                    hasUnresolvedStreamGap = true
                                }
                            }
                            attempts += 1
                            guard let (result, endedAt) = try await group.next() else {
                                return (LogCommandResult(exitCode: -1), didBecomeReady, Date())
                            }
                            return (result, didBecomeReady, endedAt)
                        }

                    if didRunInitialHistory {
                        if initialHistoryCoveredWindow,
                            let initialHistoryQueryStartedAt
                        {
                            lastCoverageTime = max(initialHistoryQueryStartedAt, streamEndedAt)
                            hasUnresolvedStreamGap = false
                            reconciledCheckpointWithCompleteQuery = true
                        } else {
                            lastCoverageTime =
                                historyOptions.startingAt
                                ?? historyOptions.minimumTimestamp
                                ?? followStartedAt
                            hasUnresolvedStreamGap = true
                        }
                    } else if reconnectCatchupCoveredInterval,
                        let reconnectCatchupQueryStartedAt
                    {
                        lastCoverageTime = max(reconnectCatchupQueryStartedAt, streamEndedAt)
                        reconciledCheckpointWithCompleteQuery = true
                    }

                    if accumulator.entryCount > 0
                        || (streamStarted && result.exitCode == 0 && !result.timedOut)
                    {
                        hasReadableSource = true
                        consecutiveStreamFailures = 0
                    } else {
                        consecutiveStreamFailures += 1
                    }
                    consecutiveStartFailures = streamStarted ? 0 : consecutiveStartFailures + 1

                    if !streamStarted, historyReport == nil {
                        guard consecutiveStartFailures >= 3 else {
                            try await Task.sleep(for: retryDelay)
                            retryDelay = .seconds(min(retryDelay.components.seconds * 2, 30))
                            continue
                        }

                        let report = try await readSnapshot(
                            historyOptions,
                            onEvent: handoff.receiveHistory
                        )
                        historyReport = report.report
                        usedMirrors = report.report.usedMirrors
                        hasReadableSource = report.report.hasReadableSource
                        handoff.finishHistory(
                            hasCompleteHistory: report.report.unifiedLogQuerySucceeded
                                && !report.report.usedMirrors,
                            coverageWatermark: report.watermark,
                            coverageStartTimestamp: historyOptions.minimumTimestamp
                        )
                        lastCoverageTime = Date()
                        break
                    }

                    if !streamStarted, historyReport != nil, consecutiveStartFailures >= 3 {
                        let catchupOptions = reconnectCatchupOptions(
                            for: options,
                            startingAt: lastCoverageTime ?? followStartedAt,
                            minimumTimestamp: historyCutoff
                        )
                        handoff.beginHistoryOverlap(coveringSince: catchupOptions.startingAt)
                        let report = try await readSnapshot(
                            catchupOptions,
                            onEvent: handoff.receiveHistoryOverlap
                        )
                        handoff.finishCatchup(
                            hasCompleteHistory: report.report.unifiedLogQuerySucceeded
                                && !report.report.usedMirrors,
                            coverageWatermark: report.watermark,
                            coverageStartTimestamp: catchupOptions.startingAt
                        )
                        if let previous = historyReport {
                            historyReport = LogReadReport(
                                emittedEntries: handoff.entryCount,
                                usedMirrors: previous.usedMirrors || report.report.usedMirrors,
                                commandAttempts: previous.commandAttempts
                                    + report.report.commandAttempts,
                                hasReadableSource: previous.hasReadableSource
                                    || report.report.hasReadableSource,
                                unifiedLogQuerySucceeded: previous.unifiedLogQuerySucceeded
                                    || report.report.unifiedLogQuerySucceeded
                            )
                        }
                        usedMirrors = usedMirrors || report.report.usedMirrors
                        hasReadableSource = hasReadableSource || report.report.hasReadableSource
                        break
                    }

                    let mirrorAccumulator = LogRecordAccumulator(
                        options: liveOptions, onEvent: handoff.receiveLive)
                    let mirrorReadable = emitMirrors(
                        liveOptions,
                        accumulator: mirrorAccumulator,
                        onEvent: handoff.receiveLive,
                        after: handoff.currentWatermark,
                        coversOlderRecords: handoff.hasCompleteHistoryCoverage
                    )
                    usedMirrors = usedMirrors || mirrorReadable
                    hasReadableSource = mirrorReadable || hasReadableSource
                    if streamStarted {
                        if !hasUnresolvedStreamGap, !reconciledCheckpointWithCompleteQuery {
                            lastCoverageTime = streamEndedAt
                        }
                        hasUnresolvedStreamGap = true
                    }

                    if !hasReadableSource, consecutiveStreamFailures >= 3 {
                        break
                    }
                    if consecutiveStartFailures >= 3 {
                        break
                    }
                    try await Task.sleep(for: retryDelay)
                    retryDelay = .seconds(min(retryDelay.components.seconds * 2, 30))
                }
            } onCancel: {
                handoff.cancelBuffering()
            }
        } catch is CancellationError {
            handoff.cancelAndWait()
            throw CancellationError()
        }

        handoff.finishHistory()
        handoff.waitForDelivery()
        return LogReadReport(
            emittedEntries: handoff.entryCount,
            usedMirrors: usedMirrors,
            commandAttempts: attempts + (historyReport?.commandAttempts ?? 0),
            hasReadableSource: hasReadableSource,
            unifiedLogQuerySucceeded: historyReport?.unifiedLogQuerySucceeded ?? false
        )
    }

    private func reconnectCatchupOptions(
        for options: LogReadOptions,
        startingAt date: Date,
        minimumTimestamp: Date
    ) -> LogReadOptions {
        let startOfSecond = floor(date.timeIntervalSince1970)
        let overlapStart = Date(timeIntervalSince1970: startOfSecond - 1)
        return LogReadOptions(
            subsystem: options.subsystem,
            level: options.level,
            startingAt: overlapStart,
            minimumTimestamp: minimumTimestamp
        )
    }

    private func runCommand(
        arguments: [String],
        initialOutputTimeout: Duration?,
        captureOutput: Bool,
        onStarted: @escaping @Sendable () -> Void,
        onReady: @escaping @Sendable () -> Void,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> LogCommandResult {
        do {
            return try await runner.run(
                arguments: arguments,
                initialOutputTimeout: initialOutputTimeout,
                captureOutput: captureOutput,
                onStarted: onStarted,
                onReady: onReady,
                onOutput: onOutput
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return LogCommandResult(
                exitCode: -1,
                standardError: Data(String(describing: error).utf8)
            )
        }
    }

    private func commandArguments(for options: LogReadOptions) -> [String] {
        var predicate = #"subsystem BEGINSWITH "io.apkrun""#
        if let subsystem = options.subsystem {
            let escaped =
                subsystem
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            predicate += " AND subsystem BEGINSWITH \"\(escaped)\""
        }

        var arguments = [options.follow ? "stream" : "show"]
        if let startingAt = options.startingAt {
            arguments += ["--start", Self.logQueryTimestamp(startingAt)]
        } else if !options.follow {
            let since = options.since ?? "1h"
            if Self.isValidDuration(since) {
                arguments += ["--last", since]
            }
        }
        arguments += ["--predicate", predicate, "--style", "ndjson"]
        switch options.level {
        case .info:
            arguments.append("--info")
        case .debug:
            arguments.append("--debug")
        default:
            break
        }
        return arguments
    }

    private func emitMirrors(
        _ options: LogReadOptions,
        accumulator: LogRecordAccumulator,
        onEvent: @Sendable (LogReadEvent) -> Void,
        after initialWatermark: LogRecordWatermark,
        coversOlderRecords: Bool
    ) -> Bool {
        let urls = [
            paths.daemonLogRotationFile(index: 2),
            paths.daemonLogRotationFile(index: 1),
            paths.daemonLogFile,
        ]
        let mirrors = urls.compactMap { url -> [LogRecord]? in
            Self.readMirror(at: url)
        }
        guard !mirrors.isEmpty else { return false }

        onEvent(.usingMirrors)
        var watermark = initialWatermark
        var baselineTimestamp = initialWatermark.latestTimestamp
        var baselineCounts = initialWatermark.recordsAtLatestTimestamp
        var replayCounts: [LogRecord: Int] = [:]
        for records in mirrors {
            for record in records where Self.matches(record, options: options) {
                guard
                    Self.shouldEmitReplay(
                        record,
                        watermark: &watermark,
                        baselineTimestamp: &baselineTimestamp,
                        baselineCounts: &baselineCounts,
                        replayCounts: &replayCounts,
                        coversOlderTimestamps: coversOlderRecords
                    )
                else {
                    continue
                }
                accumulator.emit(record)
            }
        }
        return true
    }

    fileprivate static func matches(_ record: LogRecord, options: LogReadOptions) -> Bool {
        if let subsystem = options.subsystem, !record.subsystem.hasPrefix(subsystem) {
            return false
        }
        if let minimumLevel = options.level {
            guard let recordLevel = LogLevel(rawValue: record.level),
                recordLevel >= minimumLevel
            else {
                return false
            }
        }
        guard let timestamp = parseTimestamp(record.timestamp) else { return false }
        if let startingAt = options.startingAt, timestamp < startingAt {
            return false
        }
        if let minimumTimestamp = options.minimumTimestamp, timestamp < minimumTimestamp {
            return false
        }
        if options.minimumTimestamp == nil,
            options.startingAt == nil,
            let since = options.since ?? (options.follow ? nil : "1h"),
            let duration = durationSeconds(since),
            timestamp < Date().addingTimeInterval(-duration)
        {
            return false
        }
        return true
    }

    fileprivate static func parseTimestamp(_ value: String) -> Date? {
        timestampParser.date(from: value)
    }

    private static func durationSeconds(_ value: String) -> TimeInterval? {
        guard isValidDuration(value),
            let amount = Double(value.dropLast())
        else {
            return nil
        }
        return switch value.last {
        case "s": amount
        case "m": amount * 60
        case "h": amount * 3_600
        case "d": amount * 86_400
        default: nil
        }
    }

    private static func logQueryTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
        return formatter.string(from: date)
    }

    private static func readMirror(at url: URL) -> [LogRecord]? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return contents.split(whereSeparator: \.isNewline).compactMap { line in
            let pieces = line.split(
                maxSplits: 3, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard pieces.count == 4 else { return nil }
            let source = pieces[2].split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard source.count == 2 else { return nil }
            let message = String(pieces[3]).components(separatedBy: "\u{1F}").first ?? ""
            return LogRecord(
                timestamp: String(pieces[0]),
                level: String(pieces[1]),
                subsystem: String(source[0]),
                category: String(source[1]),
                message: message
            )
        }
    }

    fileprivate static func shouldEmitReplay(
        _ record: LogRecord,
        watermark: inout LogRecordWatermark,
        baselineTimestamp: inout Date?,
        baselineCounts: inout [LogRecord: Int],
        replayCounts: inout [LogRecord: Int],
        coversOlderTimestamps: Bool
    ) -> Bool {
        guard let timestamp = parseTimestamp(record.timestamp) else {
            return true
        }
        if let latestTimestamp = watermark.latestTimestamp {
            if timestamp < latestTimestamp {
                return !coversOlderTimestamps
            }
            if timestamp > latestTimestamp {
                watermark.reset(at: timestamp)
                baselineTimestamp = timestamp
                baselineCounts.removeAll(keepingCapacity: true)
                replayCounts.removeAll(keepingCapacity: true)
            }
        } else {
            watermark.reset(at: timestamp)
            baselineTimestamp = timestamp
            baselineCounts.removeAll(keepingCapacity: true)
            replayCounts.removeAll(keepingCapacity: true)
        }

        if baselineTimestamp != timestamp {
            baselineTimestamp = timestamp
            baselineCounts = watermark.recordsAtLatestTimestamp
            replayCounts.removeAll(keepingCapacity: true)
        }
        let baselineCount = baselineCounts[record, default: 0]
        let replayCount: Int
        if baselineCount > 0 {
            replayCount = min(replayCounts[record, default: 0] + 1, baselineCount + 1)
            replayCounts[record] = replayCount
        } else {
            replayCount = 1
        }
        guard replayCount > baselineCount else {
            return false
        }
        watermark.observe(record)
        return true
    }
}

/// One event emitted while reading logs.
public enum LogReadEvent: Sendable {
    /// A normalized host log entry.
    case entry(LogRecord)
    /// At least one readable file mirror is included in the results.
    case usingMirrors
}

/// Summary of a completed log read.
public struct LogReadReport: Equatable, Sendable {
    /// The number of normalized log entries delivered to the caller.
    public let emittedEntries: Int
    /// Whether readable file mirrors contributed entries.
    public let usedMirrors: Bool
    /// The number of unified-log process attempts.
    public let commandAttempts: Int
    /// Whether any unified-log or file-mirror source was readable.
    public let hasReadableSource: Bool
    /// Whether a unified-log history query completed successfully.
    public let unifiedLogQuerySucceeded: Bool
}

private struct LogSnapshotRead {
    let report: LogReadReport
    let watermark: LogRecordWatermark
    let queryStartedAt: Date
}

// UNCHECKED-SENDABLE: The lock protects both mutable date formatters.
private final class LogTimestampParser: @unchecked Sendable {
    private let lock = NSLock()
    private let iso8601 = ISO8601DateFormatter()
    private let iso8601WithFractionalSeconds = ISO8601DateFormatter()
    private let legacy = DateFormatter()

    init() {
        iso8601WithFractionalSeconds.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        legacy.locale = Locale(identifier: "en_US_POSIX")
        legacy.calendar = Calendar(identifier: .gregorian)
        legacy.timeZone = TimeZone(secondsFromGMT: 0)
    }

    func date(from value: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        if let date = iso8601WithFractionalSeconds.date(from: value) ?? iso8601.date(from: value) {
            return date
        }
        for format in ["yyyy-MM-dd HH:mm:ss.SSSSSSZ", "yyyy-MM-dd HH:mm:ssZ"] {
            legacy.dateFormat = format
            if let date = legacy.date(from: value) {
                return date
            }
        }
        return nil
    }
}

private struct LogRecordWatermark {
    private static let maximumBoundaryRecords = 4_096
    private static let maximumBoundaryBytes = 1_048_576
    private(set) var latestTimestamp: Date?
    private(set) var recordsAtLatestTimestamp: [LogRecord: Int] = [:]
    private var boundaryByteCount = 0

    mutating func reset(at timestamp: Date) {
        latestTimestamp = timestamp
        recordsAtLatestTimestamp.removeAll(keepingCapacity: true)
        boundaryByteCount = 0
    }

    mutating func observe(_ record: LogRecord) {
        guard let timestamp = LogReader.parseTimestamp(record.timestamp) else { return }
        if let latestTimestamp {
            guard timestamp >= latestTimestamp else { return }
            if timestamp > latestTimestamp {
                reset(at: timestamp)
            }
        } else {
            reset(at: timestamp)
        }
        if let occurrenceCount = recordsAtLatestTimestamp[record] {
            recordsAtLatestTimestamp[record] =
                occurrenceCount == .max ? .max : occurrenceCount + 1
            return
        }
        guard recordsAtLatestTimestamp.count < Self.maximumBoundaryRecords,
            boundaryByteCount + record.estimatedUTF8ByteCount <= Self.maximumBoundaryBytes
        else {
            return
        }
        recordsAtLatestTimestamp[record] = 1
        boundaryByteCount += record.estimatedUTF8ByteCount
    }
}

private struct RecentLogRecordWindow {
    private struct Entry {
        let record: LogRecord
        let byteCount: Int
    }

    private static let maximumEntries = 4_096
    private static let defaultMaximumBytes = 1_048_576
    private let maximumByteCount: Int
    private var entries: [Entry] = []
    private var byteCount = 0

    init(maximumByteCount: Int = Self.defaultMaximumBytes) {
        self.maximumByteCount = maximumByteCount
    }

    mutating func append(_ record: LogRecord) {
        let size = record.estimatedUTF8ByteCount
        guard size <= maximumByteCount else { return }

        entries.append(Entry(record: record, byteCount: size))
        byteCount += size
        while entries.count > Self.maximumEntries || byteCount > maximumByteCount {
            byteCount -= entries.removeFirst().byteCount
        }
    }

    func occurrenceCounts(since timestamp: Date?) -> [LogRecord: Int] {
        entries.reduce(into: [:]) { counts, entry in
            if let timestamp {
                guard
                    let recordTimestamp = LogReader.parseTimestamp(entry.record.timestamp),
                    recordTimestamp >= timestamp
                else {
                    return
                }
            }
            counts[entry.record, default: 0] += 1
        }
    }
}

// UNCHECKED-SENDABLE: The condition and delivery lock protect shared state and serialize callbacks.
private final class LogReadEventHandoff: @unchecked Sendable {
    // A full pipe naturally throttles the producer while history is being read.
    private static let maximumBufferedLiveEvents = 4_096
    private static let maximumBufferedLiveBytes = 4_194_304
    private static let bufferedEventOverheadBytes = 64
    private let condition = NSCondition()
    private let deliveryLock = NSLock()
    private let onEvent: @Sendable (LogReadEvent) -> Void
    private var historyIsComplete = false
    private var catchupIsActive = false
    private var cancelled = false
    private var bufferedLiveEvents: [LogReadEvent] = []
    private var bufferedLiveEventBytes = 0
    // Keeps only the record keys already in the bounded live queue.
    private var bufferedLiveOccurrenceCounts: [LogRecord: Int] = [:]
    private var bufferedWatermark = LogRecordWatermark()
    private var historyWatermark = LogRecordWatermark()
    private var historyCoverageStartTimestamp: Date?
    private var overlapWatermark = LogRecordWatermark()
    private var overlapBaselineTimestamp: Date?
    private var overlapBaselineCounts: [LogRecord: Int] = [:]
    private var overlapReplayCounts: [LogRecord: Int] = [:]
    private var overlapRecentBaselineCounts: [LogRecord: Int] = [:]
    private var overlapRecentReplayCounts: [LogRecord: Int] = [:]
    private var bufferedReplayBaselineCounts: [LogRecord: Int] = [:]
    private var bufferedReplayCounts: [LogRecord: Int] = [:]
    private var isDeliveringBufferedReplay = false
    private var recentRecords = RecentLogRecordWindow()
    private var bufferedReplaySourceRecords: RecentLogRecordWindow
    private var liveRecordsAtHistoryTimestamp: [LogRecord: Int] = [:]
    private var watermark = LogRecordWatermark()
    private var historyCoversOlderRecords = false
    private var emittedRecords = 0
    private var didEmitMirrorNotice = false

    init(onEvent: @escaping @Sendable (LogReadEvent) -> Void) {
        self.onEvent = onEvent
        bufferedReplaySourceRecords = RecentLogRecordWindow(
            maximumByteCount: Self.maximumBufferedLiveBytes
        )
    }

    var entryCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return emittedRecords
    }

    var currentWatermark: LogRecordWatermark {
        condition.lock()
        defer { condition.unlock() }
        return historyIsComplete ? watermark : bufferedWatermark
    }

    var hasCompleteHistoryCoverage: Bool {
        condition.lock()
        defer { condition.unlock() }
        return historyCoversOlderRecords
    }

    func receiveHistory(_ event: LogReadEvent) {
        deliveryLock.lock()
        condition.lock()
        guard !cancelled, !historyIsComplete else {
            condition.unlock()
            deliveryLock.unlock()
            return
        }
        let shouldDeliver = acceptHistoryEventLocked(event)
        condition.unlock()
        if shouldDeliver {
            onEvent(event)
        }
        deliveryLock.unlock()
    }

    func beginHistoryOverlap(coveringSince timestamp: Date?) {
        deliveryLock.lock()
        condition.lock()
        overlapWatermark = watermark
        overlapBaselineTimestamp = watermark.latestTimestamp
        overlapBaselineCounts = watermark.recordsAtLatestTimestamp
        overlapReplayCounts.removeAll(keepingCapacity: true)
        overlapRecentBaselineCounts = recentRecords.occurrenceCounts(since: timestamp)
        overlapRecentReplayCounts.removeAll(keepingCapacity: true)
        bufferedReplayBaselineCounts.removeAll(keepingCapacity: true)
        bufferedReplayCounts.removeAll(keepingCapacity: true)
        bufferedReplaySourceRecords = RecentLogRecordWindow(
            maximumByteCount: Self.maximumBufferedLiveBytes
        )
        condition.unlock()
        deliveryLock.unlock()
    }

    func beginCatchup() {
        condition.lock()
        guard !cancelled else {
            condition.unlock()
            return
        }
        catchupIsActive = true
        condition.unlock()
    }

    func receiveHistoryOverlap(_ event: LogReadEvent) {
        deliveryLock.lock()
        condition.lock()
        guard !cancelled else {
            condition.unlock()
            deliveryLock.unlock()
            return
        }

        let shouldDeliver: Bool
        switch event {
        case .entry(let record):
            let timestamp = LogReader.parseTimestamp(record.timestamp)
            bufferedReplaySourceRecords.append(record)
            recordBufferedReplayOccurrenceLocked(record)
            let recentBaselineCount = overlapRecentBaselineCounts[record, default: 0]
            if timestamp == overlapBaselineTimestamp {
                let baselineCount = max(
                    recentBaselineCount,
                    overlapBaselineCounts[record, default: 0]
                )
                if baselineCount > 0 {
                    let nextReplayCount = min(
                        overlapRecentReplayCounts[record, default: 0] + 1,
                        baselineCount + 1
                    )
                    overlapRecentReplayCounts[record] = nextReplayCount
                    shouldDeliver = nextReplayCount > baselineCount
                } else {
                    shouldDeliver = LogReader.shouldEmitReplay(
                        record,
                        watermark: &overlapWatermark,
                        baselineTimestamp: &overlapBaselineTimestamp,
                        baselineCounts: &overlapBaselineCounts,
                        replayCounts: &overlapReplayCounts,
                        coversOlderTimestamps: historyCoversOlderRecords
                    )
                }
            } else if recentBaselineCount > 0 {
                let nextReplayCount = min(
                    overlapRecentReplayCounts[record, default: 0] + 1,
                    recentBaselineCount + 1
                )
                overlapRecentReplayCounts[record] = nextReplayCount
                if nextReplayCount <= recentBaselineCount {
                    shouldDeliver = false
                } else {
                    shouldDeliver = LogReader.shouldEmitReplay(
                        record,
                        watermark: &overlapWatermark,
                        baselineTimestamp: &overlapBaselineTimestamp,
                        baselineCounts: &overlapBaselineCounts,
                        replayCounts: &overlapReplayCounts,
                        coversOlderTimestamps: historyCoversOlderRecords
                    )
                }
            } else {
                shouldDeliver = LogReader.shouldEmitReplay(
                    record,
                    watermark: &overlapWatermark,
                    baselineTimestamp: &overlapBaselineTimestamp,
                    baselineCounts: &overlapBaselineCounts,
                    replayCounts: &overlapReplayCounts,
                    coversOlderTimestamps: historyCoversOlderRecords
                )
            }
            if shouldDeliver {
                watermark.observe(record)
                emittedRecords += 1
                recentRecords.append(record)
            }
        case .usingMirrors:
            if didEmitMirrorNotice {
                shouldDeliver = false
            } else {
                didEmitMirrorNotice = true
                shouldDeliver = true
            }
        }
        condition.unlock()
        if shouldDeliver {
            onEvent(event)
        }
        deliveryLock.unlock()
    }

    func receiveLive(_ event: LogReadEvent) {
        let eventByteCount = Self.bufferedByteCount(for: event)
        while true {
            condition.lock()
            while !cancelled,
                !historyIsComplete || catchupIsActive,
                bufferedLiveEvents.count >= Self.maximumBufferedLiveEvents
                    || bufferedLiveEventBytes + eventByteCount
                        > Self.maximumBufferedLiveBytes
            {
                condition.wait()
            }
            guard !cancelled else {
                condition.unlock()
                return
            }
            if !historyIsComplete || catchupIsActive {
                if case .entry(let record) = event {
                    bufferedWatermark.observe(record)
                    let occurrenceCount = bufferedLiveOccurrenceCounts[record, default: 0]
                    bufferedLiveOccurrenceCounts[record] =
                        occurrenceCount == .max ? .max : occurrenceCount + 1
                }
                bufferedLiveEvents.append(event)
                bufferedLiveEventBytes += eventByteCount
                condition.unlock()
                return
            }
            condition.unlock()

            deliveryLock.lock()
            condition.lock()
            guard !cancelled else {
                condition.unlock()
                deliveryLock.unlock()
                return
            }
            guard historyIsComplete, !catchupIsActive else {
                condition.unlock()
                deliveryLock.unlock()
                continue
            }
            let shouldDeliver = acceptLiveEventLocked(event)
            condition.unlock()
            if shouldDeliver {
                onEvent(event)
            }
            deliveryLock.unlock()
            return
        }
    }

    private static func bufferedByteCount(for event: LogReadEvent) -> Int {
        switch event {
        case .entry(let record):
            return record.estimatedUTF8ByteCount + bufferedEventOverheadBytes
        case .usingMirrors:
            return bufferedEventOverheadBytes
        }
    }

    func finishHistory(
        hasCompleteHistory: Bool = false,
        coverageWatermark: LogRecordWatermark = LogRecordWatermark(),
        coverageStartTimestamp: Date? = nil
    ) {
        finishBuffering(
            marksHistoryComplete: true,
            hasCompleteHistory: hasCompleteHistory,
            coverageWatermark: coverageWatermark,
            coverageStartTimestamp: coverageStartTimestamp
        )
    }

    func finishCatchup(
        hasCompleteHistory: Bool,
        coverageWatermark: LogRecordWatermark,
        coverageStartTimestamp: Date?
    ) {
        finishBuffering(
            marksHistoryComplete: false,
            hasCompleteHistory: hasCompleteHistory,
            coverageWatermark: coverageWatermark,
            coverageStartTimestamp: coverageStartTimestamp
        )
    }

    private func finishBuffering(
        marksHistoryComplete: Bool,
        hasCompleteHistory: Bool,
        coverageWatermark: LogRecordWatermark,
        coverageStartTimestamp: Date?
    ) {
        deliveryLock.lock()
        condition.lock()
        guard !cancelled,
            marksHistoryComplete ? !historyIsComplete : historyIsComplete
        else {
            condition.unlock()
            deliveryLock.unlock()
            return
        }
        if marksHistoryComplete {
            historyIsComplete = true
            historyCoversOlderRecords = hasCompleteHistory
            historyCoverageStartTimestamp = coverageStartTimestamp
        }
        if hasCompleteHistory, historyCoversOlderRecords {
            updateHistoryCoverageLocked(with: coverageWatermark)
        }
        catchupIsActive = false
        for (record, queryOccurrences) in bufferedReplaySourceRecords.occurrenceCounts(
            since: coverageStartTimestamp
        ) {
            let bufferedOccurrences = bufferedLiveOccurrenceCounts[record, default: 0]
            guard bufferedOccurrences > 0 else { continue }
            let currentBaseline = bufferedReplayBaselineCounts[record, default: 0]
            bufferedReplayBaselineCounts[record] = max(
                currentBaseline,
                min(queryOccurrences, bufferedOccurrences)
            )
        }
        bufferedReplaySourceRecords = RecentLogRecordWindow(
            maximumByteCount: Self.maximumBufferedLiveBytes
        )
        bufferedReplayCounts.removeAll(keepingCapacity: true)
        isDeliveringBufferedReplay = true
        liveRecordsAtHistoryTimestamp.removeAll(keepingCapacity: true)
        var eventsToDeliver: [LogReadEvent] = []
        for event in bufferedLiveEvents {
            if acceptBufferedLiveEventLocked(event) {
                eventsToDeliver.append(event)
            }
        }
        isDeliveringBufferedReplay = false
        bufferedReplayBaselineCounts.removeAll(keepingCapacity: true)
        bufferedLiveEvents.removeAll(keepingCapacity: false)
        bufferedLiveOccurrenceCounts.removeAll(keepingCapacity: true)
        bufferedLiveEventBytes = 0
        condition.broadcast()
        condition.unlock()
        for event in eventsToDeliver {
            condition.lock()
            let shouldDeliver = !cancelled
            condition.unlock()
            guard shouldDeliver else { break }
            onEvent(event)
        }
        deliveryLock.unlock()
    }

    private func updateHistoryCoverageLocked(with coverage: LogRecordWatermark) {
        guard let coverageTimestamp = coverage.latestTimestamp else { return }
        if let historyTimestamp = historyWatermark.latestTimestamp,
            coverageTimestamp < historyTimestamp
        {
            return
        }
        historyWatermark = coverage
    }

    func cancelBuffering() {
        condition.lock()
        cancelled = true
        bufferedLiveEvents.removeAll(keepingCapacity: false)
        bufferedLiveOccurrenceCounts.removeAll(keepingCapacity: true)
        bufferedLiveEventBytes = 0
        condition.broadcast()
        condition.unlock()
    }

    func cancelAndWait() {
        cancelBuffering()
        deliveryLock.lock()
        deliveryLock.unlock()
    }

    func waitForDelivery() {
        deliveryLock.lock()
        deliveryLock.unlock()
    }

    private func acceptHistoryEventLocked(_ event: LogReadEvent) -> Bool {
        switch event {
        case .entry(let record):
            historyWatermark.observe(record)
            watermark.observe(record)
            emittedRecords += 1
            recentRecords.append(record)
            bufferedReplaySourceRecords.append(record)
            recordBufferedReplayOccurrenceLocked(record)
            return true
        case .usingMirrors:
            guard !didEmitMirrorNotice else { return false }
            didEmitMirrorNotice = true
            return true
        }
    }

    private func acceptBufferedLiveEventLocked(_ event: LogReadEvent) -> Bool {
        switch event {
        case .entry(let record):
            var wasComparedWithCurrentQuery = false
            if isDeliveringBufferedReplay {
                bufferedReplayCounts[record, default: 0] += 1
                let baselineCount = bufferedReplayBaselineCounts[record, default: 0]
                if bufferedReplayCounts[record, default: 0] <= baselineCount {
                    return false
                }
                wasComparedWithCurrentQuery = true
            }
            if !wasComparedWithCurrentQuery,
                let timestamp = LogReader.parseTimestamp(record.timestamp),
                let historyTimestamp = historyWatermark.latestTimestamp
            {
                let timestampIsCoveredByHistoryStart =
                    historyCoverageStartTimestamp.map { timestamp >= $0 } ?? true
                if timestamp < historyTimestamp,
                    historyCoversOlderRecords,
                    timestampIsCoveredByHistoryStart
                {
                    return false
                }
                if timestamp == historyTimestamp {
                    let baselineCount =
                        historyWatermark.recordsAtLatestTimestamp[record, default: 0]
                    if baselineCount > 0 {
                        let observedLiveCount = liveRecordsAtHistoryTimestamp[record, default: 0]
                        if observedLiveCount < baselineCount {
                            liveRecordsAtHistoryTimestamp[record] = observedLiveCount + 1
                            return false
                        }
                    }
                }
            }
            watermark.observe(record)
            emittedRecords += 1
            recentRecords.append(record)
            return true
        case .usingMirrors:
            guard !didEmitMirrorNotice else { return false }
            didEmitMirrorNotice = true
            return true
        }
    }

    private func acceptLiveEventLocked(_ event: LogReadEvent) -> Bool {
        acceptBufferedLiveEventLocked(event)
    }

    private func recordBufferedReplayOccurrenceLocked(_ record: LogRecord) {
        let bufferedOccurrences = bufferedLiveOccurrenceCounts[record, default: 0]
        let baselineOccurrences = bufferedReplayBaselineCounts[record, default: 0]
        guard baselineOccurrences < bufferedOccurrences else { return }
        bufferedReplayBaselineCounts[record] = baselineOccurrences + 1
    }
}

// UNCHECKED-SENDABLE: The lock protects the signal state and checked continuation.
private final class LogCommandStartSignal: @unchecked Sendable {
    private enum State: Equatable {
        case pending
        case ready
        case finished
    }

    private let lock = NSLock()
    private var state = State.pending
    private var continuation: CheckedContinuation<Bool, Never>?

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            switch state {
            case .pending:
                self.continuation = continuation
                lock.unlock()
            case .ready:
                lock.unlock()
                continuation.resume(returning: true)
            case .finished:
                lock.unlock()
                continuation.resume(returning: false)
            }
        }
    }

    func markReady() {
        finish(with: .ready)
    }

    func markFinished() {
        finish(with: .finished)
    }

    private func finish(with newState: State) {
        lock.lock()
        guard case .pending = state else {
            lock.unlock()
            return
        }
        state = newState
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: newState == .ready)
    }
}

// UNCHECKED-SENDABLE: The lock protects the pending bytes, entry count, and watermark.
private final class LogRecordAccumulator: @unchecked Sendable {
    private static let maximumRecordBytes = 1_048_576

    private let lock = NSLock()
    private let options: LogReadOptions
    private let onEvent: @Sendable (LogReadEvent) -> Void
    private var pending = Data()
    private var discardingOversizedLine = false
    private var emitted = 0
    private var latestRecordWatermark = LogRecordWatermark()

    init(options: LogReadOptions, onEvent: @escaping @Sendable (LogReadEvent) -> Void) {
        self.options = options
        self.onEvent = onEvent
    }

    var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return emitted
    }

    var watermark: LogRecordWatermark {
        lock.lock()
        defer { lock.unlock() }
        return latestRecordWatermark
    }

    func append(_ bytes: Data) {
        lock.lock()
        var lines: [Data] = []
        var cursor = bytes.startIndex
        while cursor < bytes.endIndex {
            if discardingOversizedLine {
                guard let newline = bytes[cursor...].firstIndex(of: 0x0A) else {
                    lock.unlock()
                    return
                }
                discardingOversizedLine = false
                cursor = bytes.index(after: newline)
                continue
            }

            if let newline = bytes[cursor...].firstIndex(of: 0x0A) {
                let lineBytes = bytes[cursor..<newline]
                if pending.count + lineBytes.count <= Self.maximumRecordBytes {
                    pending.append(contentsOf: lineBytes)
                    lines.append(pending)
                }
                pending.removeAll(keepingCapacity: true)
                cursor = bytes.index(after: newline)
            } else {
                let remainingBytes = bytes[cursor..<bytes.endIndex]
                if pending.count + remainingBytes.count <= Self.maximumRecordBytes {
                    pending.append(contentsOf: remainingBytes)
                } else {
                    pending.removeAll(keepingCapacity: true)
                    discardingOversizedLine = true
                }
                break
            }
        }
        lock.unlock()
        lines.forEach(emitJSONLine)
    }

    func finishPendingLine() {
        lock.lock()
        let line = discardingOversizedLine ? Data() : pending
        pending.removeAll(keepingCapacity: true)
        discardingOversizedLine = false
        lock.unlock()
        if !line.isEmpty {
            emitJSONLine(line)
        }
    }

    func emit(_ record: LogRecord) {
        guard record.estimatedUTF8ByteCount <= Self.maximumRecordBytes else { return }
        guard LogReader.matches(record, options: options) else { return }
        lock.lock()
        emitted += 1
        latestRecordWatermark.observe(record)
        lock.unlock()
        onEvent(.entry(record))
    }

    private func emitJSONLine(_ data: Data) {
        guard let record = Self.decode(data), LogReader.matches(record, options: options) else {
            return
        }
        emit(record)
    }

    private static func decode(_ data: Data) -> LogRecord? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let fields = object as? [String: Any],
            let timestamp = fields["timestamp"] as? String,
            let subsystem = fields["subsystem"] as? String,
            let rawCategory = fields["category"] as? String,
            let eventMessage = fields["eventMessage"] as? String
        else {
            return nil
        }
        let hasWarningCategory = rawCategory.hasSuffix(OSLogCategory.warningSuffix)
        let category =
            hasWarningCategory
            ? String(rawCategory.dropLast(OSLogCategory.warningSuffix.count))
            : rawCategory
        let rawLevel = (fields["messageType"] as? String) ?? (fields["logType"] as? String)
        let rawPublicMessage = eventMessage.components(separatedBy: "\u{1F}").first ?? ""
        let publicMessage = rawPublicMessage
        let level: String
        if hasWarningCategory {
            level = LogLevel.warning.rawValue
        } else {
            switch rawLevel?.lowercased() {
            case "debug": level = LogLevel.debug.rawValue
            case "info": level = LogLevel.info.rawValue
            case "warning": level = LogLevel.warning.rawValue
            case "error": level = LogLevel.error.rawValue
            case "fault": level = LogLevel.fault.rawValue
            case "default": level = LogLevel.notice.rawValue
            default: level = "unknown"
            }
        }
        return LogRecord(
            timestamp: timestamp,
            level: level,
            subsystem: subsystem,
            category: category,
            message: publicMessage
        )
    }
}

// UNCHECKED-SENDABLE: The serial queue protects all process, pipe, timeout, and continuation state.
private final class LogProcessExecution: @unchecked Sendable {
    private static let readinessMarker = "Filtering the log data using"
    private static let maximumCapturedErrorBytes = 64 * 1_024
    private let queue = DispatchQueue(label: "io.apkrun.diagnostics.log-reader")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let executableURL: URL
    private let arguments: [String]
    private let initialOutputTimeout: Duration?
    private let captureOutput: Bool
    private let signalsReadiness: Bool
    private let onStarted: @Sendable () -> Void
    private let onReady: @Sendable () -> Void
    private let onOutput: @Sendable (Data) -> Void

    private var continuation: CheckedContinuation<LogCommandResult, any Error>?
    private var timeout: DispatchSourceTimer?
    private var outputData = Data()
    private var errorData = Data()
    private var readinessTail = Data()
    private var exitCode: Int32 = -1
    private var timedOut = false
    private var didTerminate = false
    private var stdoutClosed = false
    private var stderrClosed = false
    private var didStartProcess = false
    private var didReceiveInitialOutput = false
    private var didSignalReady = false
    private var cancelled = false

    init(
        executableURL: URL,
        arguments: [String],
        initialOutputTimeout: Duration?,
        captureOutput: Bool,
        signalsReadiness: Bool,
        onStarted: @escaping @Sendable () -> Void,
        onReady: @escaping @Sendable () -> Void,
        onOutput: @escaping @Sendable (Data) -> Void
    ) {
        queue.setSpecific(key: queueKey, value: true)
        self.executableURL = executableURL
        self.arguments = arguments
        self.initialOutputTimeout = initialOutputTimeout
        self.captureOutput = captureOutput
        self.signalsReadiness = signalsReadiness
        self.onStarted = onStarted
        self.onReady = onReady
        self.onOutput = onOutput
    }

    func run() async throws -> LogCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                guard !self.cancelled else {
                    self.continuation = nil
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.process.executableURL = self.executableURL
                self.process.arguments = self.arguments
                self.process.standardOutput = self.stdout
                self.process.standardError = self.stderr
                self.installReader(self.stdout.fileHandleForReading, isError: false)
                self.installReader(self.stderr.fileHandleForReading, isError: true)
                self.process.terminationHandler = { [self] process in
                    self.queue.async {
                        self.didTerminate = true
                        self.exitCode = process.terminationStatus
                        self.finishIfReady()
                    }
                }

                do {
                    try self.process.run()
                    self.didStartProcess = true
                    self.onStarted()
                    self.installInitialOutputTimeout()
                } catch {
                    self.stdout.fileHandleForReading.readabilityHandler = nil
                    self.stderr.fileHandleForReading.readabilityHandler = nil
                    self.process.terminationHandler = nil
                    continuation.resume(throwing: error)
                    self.continuation = nil
                }
            }
        }
    }

    func cancel() {
        queue.async {
            self.cancelled = true
            if self.process.isRunning {
                self.process.terminate()
            } else if !self.didStartProcess, self.continuation != nil {
                self.continuation?.resume(throwing: CancellationError())
                self.continuation = nil
            }
            self.finishIfReady()
        }
    }

    private func installReader(_ handle: FileHandle, isError: Bool) {
        handle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            var didReachEOF = false
            let consumeAvailableData = {
                let bytes = handle.availableData
                if bytes.isEmpty {
                    didReachEOF = true
                    if isError {
                        self.stderrClosed = true
                    } else {
                        self.stdoutClosed = true
                    }
                } else if isError {
                    if !self.cancelled {
                        if self.captureOutput {
                            self.appendCapturedError(bytes)
                        }
                        self.observeStreamReadiness(in: bytes)
                    }
                } else {
                    guard !self.cancelled else { return }
                    self.didReceiveInitialOutput = true
                    if self.signalsReadiness {
                        self.signalReady()
                    }
                    self.timeout?.cancel()
                    self.timeout = nil
                    if self.captureOutput {
                        self.outputData.append(bytes)
                    }
                    self.onOutput(bytes)
                }
            }
            if DispatchQueue.getSpecific(key: self.queueKey) == true {
                consumeAvailableData()
            } else {
                self.queue.sync(execute: consumeAvailableData)
            }
            if didReachEOF {
                handle.readabilityHandler = nil
                let finishIfReady = { self.finishIfReady() }
                if DispatchQueue.getSpecific(key: self.queueKey) == true {
                    finishIfReady()
                } else {
                    self.queue.sync(execute: finishIfReady)
                }
            }
        }
    }

    private func installInitialOutputTimeout() {
        guard let initialOutputTimeout else { return }
        let components = initialOutputTimeout.components
        let seconds =
            Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timeout = timer
        timer.schedule(deadline: .now() + .milliseconds(max(1, Int(seconds * 1_000))))
        timer.setEventHandler {
            guard !self.didTerminate,
                !self.didReceiveInitialOutput,
                !self.didSignalReady
            else {
                return
            }
            self.timedOut = true
            if self.process.isRunning {
                self.process.terminate()
            }
        }
        timer.resume()
    }

    private func appendCapturedError(_ bytes: Data) {
        errorData.append(bytes)
        guard errorData.count > Self.maximumCapturedErrorBytes else { return }
        errorData.removeFirst(errorData.count - Self.maximumCapturedErrorBytes)
    }

    private func observeStreamReadiness(in bytes: Data) {
        guard signalsReadiness, !didSignalReady else { return }
        var sample = readinessTail
        sample.append(bytes)
        if String(decoding: sample, as: UTF8.self).contains(Self.readinessMarker) {
            signalReady()
            return
        }
        let retainedBytes = min(sample.count, Self.readinessMarker.utf8.count - 1)
        readinessTail = Data(sample.suffix(retainedBytes))
    }

    private func signalReady() {
        guard signalsReadiness, !didSignalReady else { return }
        didSignalReady = true
        readinessTail.removeAll(keepingCapacity: false)
        timeout?.cancel()
        timeout = nil
        onReady()
    }

    private func finishIfReady() {
        guard didTerminate, stdoutClosed, stderrClosed, let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        process.terminationHandler = nil
        if cancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        continuation.resume(
            returning: LogCommandResult(
                exitCode: exitCode,
                standardOutput: outputData,
                standardError: errorData,
                timedOut: timedOut
            )
        )
    }
}
