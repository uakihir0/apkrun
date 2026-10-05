import DiagnosticsCore
import DiagnosticsCoreTestSupport
import Foundation
import Testing

@Test func logReaderParsesUnifiedLogAndBuildsSafeArguments() async throws {
    let timestampFormatter = DateFormatter()
    timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
    timestampFormatter.timeZone = .current
    timestampFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
    let timestamp = timestampFormatter.string(from: .now)
    let output =
        #"{"timestamp":"\#(timestamp)","messageType":"Info","eventMessage":"started\u001fprivate detail","subsystem":"io.apkrun.cli","category":"command"}"#
    let runner = FakeLogCommandRunner(results: [
        LogCommandResult(exitCode: 0, standardOutput: Data(output.utf8))
    ])
    let paths = APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory)
    let reader = LogReader(paths: paths, runner: runner)
    let recorder = LogReadEventRecorder()

    let report = try await reader.read(
        LogReadOptions(since: "5m", subsystem: "io.apkrun.cli", level: .info),
        onEvent: recorder.append
    )

    #expect(report.emittedEntries == 1)
    #expect(!report.usedMirrors)
    #expect(
        recorder.entries == [
            LogRecord(
                timestamp: timestamp,
                level: "info",
                subsystem: "io.apkrun.cli",
                category: "command",
                message: "started"
            )
        ])
    let arguments = await runner.recordedArguments()
    #expect(arguments.count == 1)
    #expect(arguments[0].contains("--last"))
    #expect(arguments[0].contains("5m"))
    #expect(arguments[0].contains("--info"))
    #expect(
        arguments[0].contains(
            #"subsystem BEGINSWITH "io.apkrun" AND subsystem BEGINSWITH "io.apkrun.cli""#))
    #expect(arguments[0].contains("--style"))
    #expect(arguments[0].contains("ndjson"))
}

@Test func logReaderParsesFractionalISO8601Timestamps() async throws {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let timestamp = formatter.string(from: .now)
    let output = """
        {"timestamp":"\(timestamp)","messageType":"Default","eventMessage":"fractional","subsystem":"io.apkrun.cli","category":"command"}
        """
    let reader = LogReader(
        paths: APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory),
        runner: FakeLogCommandRunner(results: [
            LogCommandResult(exitCode: 0, standardOutput: Data(output.utf8))
        ])
    )
    let recorder = LogReadEventRecorder()

    let report = try await reader.read(LogReadOptions(since: "1h"), onEvent: recorder.append)

    #expect(report.emittedEntries == 1)
    #expect(recorder.entries.map(\.message) == ["fractional"])
}

@Test func logReaderDropsOversizedNDJSONLinesAndContinues() async throws {
    let timestamp = ISO8601DateFormatter().string(from: .now)
    let validRecord = """
        {"timestamp":"\(timestamp)","messageType":"Default","eventMessage":"after-oversized","subsystem":"io.apkrun.cli","category":"command"}
        """
    var recordTerminatorAndNextRecord = Data([0x0A])
    recordTerminatorAndNextRecord.append(contentsOf: validRecord.utf8)
    let reader = LogReader(
        paths: APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory),
        runner: ChunkedOutputLogCommandRunner(chunks: [
            Data(repeating: 0x61, count: 600_000),
            Data(repeating: 0x62, count: 500_000),
            recordTerminatorAndNextRecord,
        ])
    )
    let recorder = LogReadEventRecorder()

    let report = try await reader.read(onEvent: recorder.append)

    #expect(report.emittedEntries == 1)
    #expect(recorder.entries.map(\.message) == ["after-oversized"])
}

@Test func logReaderDropsAnOversizedUnterminatedLineAtEndOfStream() async throws {
    let reader = LogReader(
        paths: APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory),
        runner: ChunkedOutputLogCommandRunner(chunks: [
            Data(repeating: 0x61, count: 600_000),
            Data(repeating: 0x62, count: 500_000),
        ])
    )
    let recorder = LogReadEventRecorder()

    let report = try await reader.read(onEvent: recorder.append)

    #expect(report.hasReadableSource)
    #expect(report.emittedEntries == 0)
    #expect(recorder.entries.isEmpty)
}

@Test func logReaderUsesOneFixedSinceWindowForSnapshotRecords() async throws {
    let reader = LogReader(
        paths: APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory),
        runner: SlowSnapshotLogCommandRunner()
    )
    let recorder = LogReadEventRecorder()

    let report = try await reader.read(LogReadOptions(since: "1s"), onEvent: recorder.append)

    #expect(report.emittedEntries == 2)
    #expect(recorder.entries.map(\.message) == ["first", "delayed"])
}

@Test func logReaderFallsBackToPublicRotatingMirrorsOnTimeout() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("APKRun-LogReader-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = APKRunPaths(homeDirectory: directory)
    try FileManager.default.createDirectory(at: paths.logsRoot, withIntermediateDirectories: true)
    let timestamp = ISO8601DateFormatter().string(from: .now.addingTimeInterval(-60))
    let mirror = """
        \(timestamp) notice io.apkrun.cli/command version 0.1\u{1F}private version
        """
    try mirror.write(to: paths.daemonLogFile, atomically: true, encoding: .utf8)

    let runner = FakeLogCommandRunner(results: [
        LogCommandResult(exitCode: -1, timedOut: true)
    ])
    let reader = LogReader(paths: paths, runner: runner)
    let recorder = LogReadEventRecorder()
    let report = try await reader.read(
        LogReadOptions(since: "1d"),
        onEvent: recorder.append
    )

    #expect(report.usedMirrors)
    #expect(report.emittedEntries == 1)
    #expect(recorder.usedMirrors)
    #expect(recorder.entries.first?.message == "version 0.1")
}

@Test func logReaderKeepsOlderMirrorEntriesAfterPartialUnifiedOutput() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("APKRun-LogReader-Partial-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = APKRunPaths(homeDirectory: directory)
    try FileManager.default.createDirectory(at: paths.logsRoot, withIntermediateDirectories: true)

    let formatter = ISO8601DateFormatter()
    let olderTimestamp = formatter.string(from: .now.addingTimeInterval(-10))
    let newerTimestamp = formatter.string(from: .now)
    try "\(olderTimestamp) notice io.apkrun.cli/command mirror-older\n"
        .write(to: paths.daemonLogFile, atomically: true, encoding: .utf8)
    let partialRecord = """
        {"timestamp":"\(newerTimestamp)","messageType":"Default","eventMessage":"partial-unified","subsystem":"io.apkrun.cli","category":"command"}
        """
    let reader = LogReader(
        paths: paths,
        runner: FakeLogCommandRunner(results: [
            LogCommandResult(exitCode: 1, standardOutput: Data(partialRecord.utf8))
        ])
    )
    let recorder = LogReadEventRecorder()

    let report = try await reader.read(LogReadOptions(since: "1h"), onEvent: recorder.append)

    #expect(report.usedMirrors)
    #expect(recorder.entries.map(\.message) == ["partial-unified", "mirror-older"])
}

@Test func logReaderFallsBackWhenLogProcessCannotBeStarted() async throws {
    let reader = LogReader(
        paths: APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory),
        runner: ThrowingLogCommandRunner()
    )
    let recorder = LogReadEventRecorder()

    let report = try await reader.read(LogReadOptions(since: "5m"), onEvent: recorder.append)

    #expect(!report.usedMirrors)
    #expect(report.emittedEntries == 0)
    #expect(!recorder.usedMirrors)
}

@Test func logReaderRetriesQuietFollowAfterUsingMirrors() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("APKRun-LogReader-Follow-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = APKRunPaths(homeDirectory: directory)
    try FileManager.default.createDirectory(at: paths.logsRoot, withIntermediateDirectories: true)
    let timestamp = ISO8601DateFormatter().string(from: .now)
    let mirror = "\(timestamp) notice io.apkrun.cli/command startup"
    try mirror.write(to: paths.daemonLogFile, atomically: true, encoding: .utf8)
    let eventTimestamp = ISO8601DateFormatter().string(from: .now.addingTimeInterval(2))
    let event = """
        {"timestamp":"\(eventTimestamp)","messageType":"Default","eventMessage":"new event","subsystem":"io.apkrun.runtime","category":"host"}
        """
    let runner = FakeLogCommandRunner(results: [
        LogCommandResult(exitCode: 1),
        LogCommandResult(exitCode: 0),
        LogCommandResult(exitCode: 0),
        LogCommandResult(exitCode: 0, standardOutput: Data(event.utf8)),
    ])
    let reader = LogReader(paths: paths, runner: runner)
    let recorder = LogReadEventRecorder()

    var wasCancelled = false
    do {
        _ = try await reader.read(LogReadOptions(follow: true), onEvent: recorder.append)
    } catch is CancellationError {
        wasCancelled = true
    } catch {
        Issue.record("unexpected log-reader failure: \(error)")
    }

    #expect(wasCancelled)
    #expect(recorder.usedMirrors)
    #expect(recorder.entries.contains { $0.message == "new event" })
    let timeouts = await runner.recordedTimeouts()
    #expect(timeouts == Array(repeating: .seconds(30), count: 5))
    let arguments = await runner.recordedArguments()
    #expect(arguments.map(\.first) == ["stream", "show", "stream", "show", "stream"])
}

@Test func logReaderUsesAQuietStreamWhenHistoryAlreadyVerifiedUnifiedAccess() async throws {
    let timestamp = ISO8601DateFormatter().string(from: .now)
    let history = """
        {"timestamp":"\(timestamp)","messageType":"Default","eventMessage":"history","subsystem":"io.apkrun.cli","category":"command"}
        """
    let live = """
        {"timestamp":"\(timestamp)","messageType":"Default","eventMessage":"live","subsystem":"io.apkrun.cli","category":"command"}
        """
    let runner = FakeLogCommandRunner(results: [
        LogCommandResult(
            exitCode: 0,
            standardOutput: Data("\(history)\n\(history)\n\(live)".utf8)
        ),
        LogCommandResult(exitCode: 0, standardOutput: Data(history.utf8)),
        LogCommandResult(exitCode: 0, standardOutput: Data(history.utf8)),
    ])
    let reader = LogReader(
        paths: APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory),
        runner: runner
    )
    let recorder = LogReadEventRecorder()

    var wasCancelled = false
    do {
        _ = try await reader.read(
            LogReadOptions(follow: true, since: "1h"),
            onEvent: recorder.append
        )
    } catch is CancellationError {
        wasCancelled = true
    }

    #expect(wasCancelled)
    #expect(!recorder.usedMirrors)
    #expect(recorder.entries.map(\.message) == ["history", "history", "live"])
    let arguments = await runner.recordedArguments()
    #expect(arguments.map(\.first) == ["stream", "show", "stream", "show"])
    let timeouts = await runner.recordedTimeouts()
    #expect(timeouts == Array(repeating: .seconds(30), count: 4))
}

@Test func logReaderDeduplicatesDelayedLiveRecordsAfterHistoryHandoff() async {
    let timestamp = ISO8601DateFormatter().string(from: .now)
    let shared = """
        {"timestamp":"\(timestamp)","messageType":"Default","eventMessage":"shared","subsystem":"io.apkrun.cli","category":"command"}
        """
    let runner = FakeLogCommandRunner(results: [
        LogCommandResult(exitCode: 0),
        LogCommandResult(exitCode: 0, standardOutput: Data(shared.utf8)),
        LogCommandResult(exitCode: 0, standardOutput: Data(shared.utf8)),
        LogCommandResult(exitCode: 0, standardOutput: Data("\(shared)\n\(shared)".utf8)),
    ])
    let reader = LogReader(
        paths: APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory),
        runner: runner
    )
    let recorder = LogReadEventRecorder()
    var wasCancelled = false
    do {
        _ = try await reader.read(LogReadOptions(follow: true), onEvent: recorder.append)
    } catch is CancellationError {
        wasCancelled = true
    } catch {
        Issue.record("unexpected log-reader failure: \(error)")
    }

    #expect(wasCancelled)
    #expect(recorder.entries.map(\.message) == ["shared", "shared"])
}

@Test func logReaderKeepsDelayedLiveRecordsOutsideTheInitialSinceWindow() async {
    let oldTimestamp = ISO8601DateFormatter().string(from: .now.addingTimeInterval(-10))
    let delayedLive = """
        {"timestamp":"\(oldTimestamp)","messageType":"Default","eventMessage":"delayed-live","subsystem":"io.apkrun.cli","category":"command"}
        """
    let runner = FakeLogCommandRunner(results: [
        LogCommandResult(exitCode: 0, standardOutput: Data(delayedLive.utf8)),
        LogCommandResult(exitCode: 0),
    ])
    let reader = LogReader(
        paths: APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory),
        runner: runner
    )
    let recorder = LogReadEventRecorder()
    var wasCancelled = false
    do {
        _ = try await reader.read(
            LogReadOptions(follow: true, since: "1s"),
            onEvent: recorder.append
        )
    } catch is CancellationError {
        wasCancelled = true
    } catch {
        Issue.record("unexpected log-reader failure: \(error)")
    }

    #expect(wasCancelled)
    #expect(recorder.entries.map(\.message) == ["delayed-live"])
}

@Test func logReaderKeepsLiveRecordsOlderThanTheInitialHistoryWindow() async {
    let oldTimestamp = ISO8601DateFormatter().string(from: .now.addingTimeInterval(-10))
    let historyTimestamp = ISO8601DateFormatter().string(from: .now)
    let liveRecord = """
        {"timestamp":"\(oldTimestamp)","messageType":"Default","eventMessage":"outside-history-window","subsystem":"io.apkrun.cli","category":"command"}
        """
    let historyRecord = """
        {"timestamp":"\(historyTimestamp)","messageType":"Default","eventMessage":"inside-history-window","subsystem":"io.apkrun.cli","category":"command"}
        """
    let runner = FakeLogCommandRunner(results: [
        LogCommandResult(exitCode: 0, standardOutput: Data(liveRecord.utf8)),
        LogCommandResult(exitCode: 0, standardOutput: Data(historyRecord.utf8)),
    ])
    let reader = LogReader(
        paths: APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory),
        runner: runner
    )
    let recorder = LogReadEventRecorder()
    var wasCancelled = false
    do {
        _ = try await reader.read(
            LogReadOptions(follow: true, since: "1s"),
            onEvent: recorder.append
        )
    } catch is CancellationError {
        wasCancelled = true
    } catch {
        Issue.record("unexpected log-reader failure: \(error)")
    }

    #expect(wasCancelled)
    #expect(
        recorder.entries.map(\.message)
            == ["inside-history-window", "outside-history-window"]
    )
}

@Test func logReaderQueriesTheGapAfterAStreamReconnects() async {
    let runner = ReconnectingLogCommandRunner()
    let reader = LogReader(
        paths: APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory),
        runner: runner
    )
    let recorder = LogReadEventRecorder()
    var wasCancelled = false
    do {
        _ = try await reader.read(LogReadOptions(follow: true), onEvent: recorder.append)
    } catch is CancellationError {
        wasCancelled = true
    } catch {
        Issue.record("unexpected log-reader failure: \(error)")
    }

    #expect(wasCancelled)
    #expect(recorder.entries.map(\.message) == ["before-reconnect", "during-reconnect"])
    let arguments = await runner.recordedArguments()
    #expect(arguments.map(\.first) == ["stream", "show", "stream", "show", "stream"])
    #expect(arguments[3].contains("--start"))
    #expect(!arguments[3].contains("--last"))
}

@Test func logReaderKeepsOlderReconnectCatchupEntriesAfterPartialHistory() async {
    let runner = PartialHistoryReconnectLogCommandRunner()
    let reader = LogReader(
        paths: APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory),
        runner: runner
    )
    let recorder = LogReadEventRecorder()
    var wasCancelled = false
    do {
        _ = try await reader.read(LogReadOptions(follow: true), onEvent: recorder.append)
    } catch is CancellationError {
        wasCancelled = true
    } catch {
        Issue.record("unexpected log-reader failure: \(error)")
    }

    #expect(wasCancelled)
    #expect(recorder.entries.map(\.message) == ["partial-history", "older-catchup"])
}

@Test func logReaderDeduplicatesOlderCatchupRecordsAfterPartialHistory() async {
    let runner = PartialHistoryReplayLogCommandRunner()
    let reader = LogReader(
        paths: APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory),
        runner: runner
    )
    let recorder = LogReadEventRecorder()
    var wasCancelled = false
    do {
        _ = try await reader.read(LogReadOptions(follow: true), onEvent: recorder.append)
    } catch is CancellationError {
        wasCancelled = true
    } catch {
        Issue.record("unexpected log-reader failure: \(error)")
    }

    #expect(wasCancelled)
    #expect(
        recorder.entries.map(\.message)
            == ["partial-history", "already-a", "already-b", "gap-record"]
    )
}

@Test func logReaderKeepsTheReconnectCheckpointWhenCatchupFails() async {
    let runner = CatchupFailureLogCommandRunner()
    let reader = LogReader(
        paths: APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory),
        runner: runner
    )
    let recorder = LogReadEventRecorder()
    var wasCancelled = false
    do {
        _ = try await reader.read(LogReadOptions(follow: true), onEvent: recorder.append)
    } catch is CancellationError {
        wasCancelled = true
    } catch {
        Issue.record("unexpected log-reader failure: \(error)")
    }

    #expect(wasCancelled)
    #expect(recorder.entries.map(\.message) == ["uncovered-gap"])
    let catchupStarts = await runner.recordedCatchupStarts()
    #expect(catchupStarts.count == 2)
    #expect(catchupStarts[0] == catchupStarts[1])
}

@Test func logReaderDoesNotAdvanceReconnectCheckpointPastStreamCoverage() async {
    let runner = CatchupSnapshotBoundaryLogCommandRunner()
    let reader = LogReader(
        paths: APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory),
        runner: runner
    )
    let recorder = LogReadEventRecorder()
    var wasCancelled = false
    do {
        _ = try await reader.read(LogReadOptions(follow: true), onEvent: recorder.append)
    } catch is CancellationError {
        wasCancelled = true
    } catch {
        Issue.record("unexpected log-reader failure: \(error)")
    }

    #expect(wasCancelled)
    #expect(recorder.entries.map(\.message).contains("after-catchup-snapshot"))
}

@Test func logReaderKeepsNewIdenticalLiveOccurrenceOutsideCatchupSnapshot() async {
    let runner = SameRecordCatchupLogCommandRunner()
    let reader = LogReader(
        paths: APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory),
        runner: runner
    )
    let recorder = LogReadEventRecorder()
    var wasCancelled = false
    do {
        _ = try await reader.read(LogReadOptions(follow: true), onEvent: recorder.append)
    } catch is CancellationError {
        wasCancelled = true
    } catch {
        Issue.record("unexpected log-reader failure: \(error)")
    }

    #expect(wasCancelled)
    #expect(recorder.entries.map(\.message) == ["same-record", "same-record"])
}

@Test func logReaderDeduplicatesLargeReconnectReplayAtTheTimestampBoundary() async {
    let timestamp = ISO8601DateFormatter().string(from: .now)
    for recordsAreIdentical in [false, true] {
        let runner = LargeBoundaryReplayLogCommandRunner(
            recordCount: 4_100,
            timestamp: timestamp,
            recordsAreIdentical: recordsAreIdentical
        )
        let reader = LogReader(
            paths: APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory),
            runner: runner
        )
        let recorder = LogReadEventRecorder()
        var wasCancelled = false
        do {
            _ = try await reader.read(LogReadOptions(follow: true), onEvent: recorder.append)
        } catch is CancellationError {
            wasCancelled = true
        } catch {
            Issue.record("unexpected log-reader failure: \(error)")
        }

        #expect(wasCancelled)
        #expect(recorder.entries.count == 4_100)
    }
}

@Test func logReaderAcceptsUnseenRowsAtTheExistingTimestampBoundary() async {
    let runner = UnseenBoundaryReplayLogCommandRunner(
        recordCount: 5_000,
        timestamp: ISO8601DateFormatter().string(from: .now)
    )
    let reader = LogReader(
        paths: APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory),
        runner: runner
    )
    let recorder = LogReadEventRecorder()
    var wasCancelled = false
    do {
        _ = try await reader.read(LogReadOptions(follow: true), onEvent: recorder.append)
    } catch is CancellationError {
        wasCancelled = true
    } catch {
        Issue.record("unexpected log-reader failure: \(error)")
    }

    #expect(wasCancelled)
    #expect(recorder.entries.count == 5_001)
}

@Test func logReaderDeduplicatesBufferedLargeOccurrencesWithinTheHandoffByteLimit() async {
    let message = String(repeating: "x", count: 900_000)
    let runner = LargeBufferedReplayLogCommandRunner(
        message: message,
        timestamp: ISO8601DateFormatter().string(from: .now)
    )
    let reader = LogReader(
        paths: APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory),
        runner: runner
    )
    let recorder = LogReadEventRecorder()
    var wasCancelled = false
    do {
        _ = try await reader.read(LogReadOptions(follow: true), onEvent: recorder.append)
    } catch is CancellationError {
        wasCancelled = true
    } catch {
        Issue.record("unexpected log-reader failure: \(error)")
    }

    #expect(wasCancelled)
    #expect(recorder.entries.count == 4)
    #expect(recorder.entries.allSatisfy { $0.message == message })
}

@Test func logReaderKeepsBufferedMatchesWhenTheHistoryWindowEvictsThem() async {
    let runner = EvictedBufferedReplayLogCommandRunner(
        recordCount: 4_096,
        timestamp: ISO8601DateFormatter().string(from: .now)
    )
    let reader = LogReader(
        paths: APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory),
        runner: runner
    )
    let recorder = LogReadEventRecorder()
    var wasCancelled = false
    do {
        _ = try await reader.read(LogReadOptions(follow: true), onEvent: recorder.append)
    } catch is CancellationError {
        wasCancelled = true
    } catch {
        Issue.record("unexpected log-reader failure: \(error)")
    }

    #expect(wasCancelled)
    #expect(recorder.entries.count == 4_097)
    #expect(recorder.entries.filter { $0.message == "buffered-match" }.count == 1)
}

@Test func logReaderAcceptsOnlyBoundedDurationSyntax() {
    #expect(LogReader.isValidDuration("5m"))
    #expect(LogReader.isValidDuration("1h"))
    #expect(LogReader.isValidDuration("30d"))
    #expect(!LogReader.isValidDuration("0s"))
    #expect(!LogReader.isValidDuration("31d"))
    #expect(!LogReader.isValidDuration("999999999d"))
    #expect(!LogReader.isValidDuration("5m --predicate true"))
    #expect(!LogReader.isValidDuration("-1m"))
}

@Test func logReaderValidatesDurationForDirectAPIConsumers() async {
    let reader = LogReader(
        paths: APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory),
        runner: FakeLogCommandRunner(results: [])
    )
    var rejectedDuration = false
    do {
        _ = try await reader.read(LogReadOptions(since: "31d")) { _ in }
    } catch LogReaderError.invalidDuration {
        rejectedDuration = true
    } catch {
        rejectedDuration = false
    }
    #expect(rejectedDuration)
}

@Test func logReaderStopsFollowWhenNoSourceCanBeOpened() async throws {
    let runner = FailingStartRecordingLogCommandRunner()
    let reader = LogReader(
        paths: APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory),
        runner: runner
    )

    let report = try await reader.read(LogReadOptions(follow: true)) { _ in }

    #expect(!report.hasReadableSource)
    #expect(report.commandAttempts == 4)
    let arguments = await runner.recordedArguments()
    #expect(arguments.map(\.first) == ["stream", "stream", "stream", "show"])
}

@Test func logReaderUsesHistoryWhenStreamCannotStart() async throws {
    let timestamp = ISO8601DateFormatter().string(from: .now)
    let history = """
        {"timestamp":"\(timestamp)","messageType":"Default","eventMessage":"history-only","subsystem":"io.apkrun.cli","category":"command"}
        """
    let runner = StreamStartupFailureHistoryRunner(output: Data(history.utf8))
    let reader = LogReader(
        paths: APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory),
        runner: runner
    )
    let recorder = LogReadEventRecorder()

    let report = try await reader.read(LogReadOptions(follow: true), onEvent: recorder.append)

    #expect(report.hasReadableSource)
    #expect(!report.usedMirrors)
    #expect(report.emittedEntries == 1)
    #expect(recorder.entries.map(\.message) == ["history-only"])
    let arguments = await runner.recordedArguments()
    #expect(arguments.map(\.first) == ["stream", "stream", "stream", "show"])
}

@Test func logReaderRunsOneShotCatchupAfterReconnectStartupFailures() async {
    let runner = ReconnectStartupFailureLogCommandRunner()
    let reader = LogReader(
        paths: APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory),
        runner: runner
    )
    let recorder = LogReadEventRecorder()
    var wasCancelled = false
    do {
        _ = try await reader.read(LogReadOptions(follow: true), onEvent: recorder.append)
    } catch is CancellationError {
        wasCancelled = true
    } catch {
        Issue.record("unexpected log-reader failure: \(error)")
    }

    #expect(!wasCancelled)
    #expect(recorder.entries.map(\.message) == ["initial-history", "recovered-gap"])
    let arguments = await runner.recordedArguments()
    #expect(
        arguments.map(\.first) == ["stream", "show", "stream", "stream", "stream", "show"]
    )
    #expect(arguments[5].contains("--start"))
}

@Test func logReaderReturnsReadableMirrorsWhenStreamCannotStart() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "APKRun-LogReader-Follow-Mirror-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = APKRunPaths(homeDirectory: directory)
    try FileManager.default.createDirectory(at: paths.logsRoot, withIntermediateDirectories: true)
    let timestamp = ISO8601DateFormatter().string(from: .now)
    try "\(timestamp) notice io.apkrun.runtime/host started"
        .write(to: paths.daemonLogFile, atomically: true, encoding: .utf8)

    let runner = FailingStartRecordingLogCommandRunner()
    let reader = LogReader(paths: paths, runner: runner)
    let recorder = LogReadEventRecorder()
    let report = try await reader.read(LogReadOptions(follow: true), onEvent: recorder.append)

    #expect(report.hasReadableSource)
    #expect(report.usedMirrors)
    #expect(report.emittedEntries == 1)
    #expect(recorder.entries.map(\.message) == ["started"])
    let arguments = await runner.recordedArguments()
    #expect(arguments.map(\.first) == ["stream", "stream", "stream", "show"])
}

@Test func logReaderBoundsLiveHandoffWhileLargeHistoryIsRead() async {
    let timestamp = ISO8601DateFormatter().string(from: .now)
    let runner = HighVolumeFollowLogCommandRunner(recordCount: 5_000, timestamp: timestamp)
    let reader = LogReader(
        paths: APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory),
        runner: runner
    )
    let recorder = LogReadEventRecorder()
    var wasCancelled = false
    do {
        _ = try await reader.read(LogReadOptions(follow: true), onEvent: recorder.append)
    } catch is CancellationError {
        wasCancelled = true
    } catch {
        Issue.record("unexpected log-reader failure: \(error)")
    }

    #expect(wasCancelled)
    #expect(recorder.entries.count == 5_001)
    #expect(recorder.entries.first?.message == "history")
    #expect(recorder.entries.last?.message == "live-4999")
}

@Test func logReaderBoundsLiveHandoffByBytesWhileHistoryIsRead() async {
    let runner = ByteBoundedFollowLogCommandRunner(
        recordCount: 10,
        messageByteCount: 900_000
    )
    let reader = LogReader(
        paths: APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory),
        runner: runner
    )
    let recorder = LogReadEventRecorder()
    do {
        _ = try await reader.read(LogReadOptions(follow: true), onEvent: recorder.append)
    } catch is CancellationError {
    } catch {
        Issue.record("unexpected log-reader failure: \(error)")
    }

    #expect((runner.liveRecordCountBeforeHistoryCompletes() ?? -1) == 5)
    #expect(recorder.entries.count == 11)
    #expect(recorder.entries.first?.message == "history")
    #expect(recorder.entries.last?.message.hasPrefix("live-9-") == true)
    #expect(recorder.entries.last?.message.utf8.count == 900_007)
}

@Test func logReaderKeepsPartialOutputWhenUnifiedLogExitsWithFailure() async throws {
    let timestamp = ISO8601DateFormatter().string(from: .now)
    let output = """
        {"timestamp":"\(timestamp)","messageType":"Error","eventMessage":"partial","subsystem":"io.apkrun.cli","category":"command"}
        """
    let reader = LogReader(
        paths: APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory),
        runner: FakeLogCommandRunner(results: [
            LogCommandResult(exitCode: 1, standardOutput: Data(output.utf8))
        ])
    )
    let recorder = LogReadEventRecorder()

    let report = try await reader.read(onEvent: recorder.append)

    #expect(report.hasReadableSource)
    #expect(report.emittedEntries == 1)
    #expect(recorder.entries.first?.message == "partial")
}

@Test func logRecordEscapesTerminalControlAndFormattingCharacters() throws {
    let record = LogRecord(
        timestamp: "2026-09-29T00:00:00Z",
        level: "notice",
        subsystem: "io.apkrun.cli\u{001B}]0;spoof",
        category: "command\u{0007}",
        message: "line\n\u{001B}[31mred\u{001B}[0m\u{202E}"
    )

    #expect(
        record.humanLine
            == #"2026-09-29T00:00:00Z notice io.apkrun.cli\u{1B}]0;spoof/command\u{7} line\n\u{1B}[31mred\u{1B}[0m\u{202E}"#
    )
    #expect(record.jsonLine.contains(#"\u202E"#))
    #expect(!record.jsonLine.unicodeScalars.contains(where: { $0.value == 0x202E }))
    let decodedJSON = try JSONDecoder().decode(LogRecord.self, from: Data(record.jsonLine.utf8))
    #expect(decodedJSON == record)
}

private final class LogReadEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEntries: [LogRecord] = []
    private var storedUsedMirrors = false

    var entries: [LogRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storedEntries
    }

    var usedMirrors: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedUsedMirrors
    }

    func append(_ event: LogReadEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .entry(let record):
            storedEntries.append(record)
        case .usingMirrors:
            storedUsedMirrors = true
        }
    }
}

private struct ThrowingLogCommandRunner: LogCommandRunning {
    func run(
        arguments: [String],
        initialOutputTimeout: Duration?,
        captureOutput: Bool,
        onStarted: @escaping @Sendable () -> Void,
        onReady: @escaping @Sendable () -> Void,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> LogCommandResult {
        throw TestLogCommandFailure.cannotStart
    }
}

private struct ChunkedOutputLogCommandRunner: LogCommandRunning {
    let chunks: [Data]

    func run(
        arguments: [String],
        initialOutputTimeout: Duration?,
        captureOutput: Bool,
        onStarted: @escaping @Sendable () -> Void,
        onReady: @escaping @Sendable () -> Void,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> LogCommandResult {
        onStarted()
        for chunk in chunks {
            onOutput(chunk)
        }
        return LogCommandResult(exitCode: 0)
    }
}

private struct SlowSnapshotLogCommandRunner: LogCommandRunning {
    func run(
        arguments: [String],
        initialOutputTimeout: Duration?,
        captureOutput: Bool,
        onStarted: @escaping @Sendable () -> Void,
        onReady: @escaping @Sendable () -> Void,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> LogCommandResult {
        onStarted()
        let reference = Date()
        let first = Self.record("first", timestamp: reference.addingTimeInterval(-0.5))
        let delayed = Self.record("delayed", timestamp: reference.addingTimeInterval(-0.8))
        onOutput(Data("\(first)\n".utf8))
        try await Task.sleep(for: .milliseconds(1_200))
        onOutput(Data("\(delayed)\n".utf8))
        return LogCommandResult(exitCode: 0)
    }

    private static func record(_ message: String, timestamp: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: timestamp)
        return """
            {"timestamp":"\(timestamp)","messageType":"Default","eventMessage":"\(message)","subsystem":"io.apkrun.cli","category":"command"}
            """
    }
}

private actor FailingStartRecordingLogCommandRunner: LogCommandRunning {
    private var arguments: [[String]] = []

    func run(
        arguments: [String],
        initialOutputTimeout: Duration?,
        captureOutput: Bool,
        onStarted: @escaping @Sendable () -> Void,
        onReady: @escaping @Sendable () -> Void,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> LogCommandResult {
        self.arguments.append(arguments)
        throw TestLogCommandFailure.cannotStart
    }

    func recordedArguments() -> [[String]] {
        arguments
    }
}

private actor StreamStartupFailureHistoryRunner: LogCommandRunning {
    private let output: Data
    private var arguments: [[String]] = []

    init(output: Data) {
        self.output = output
    }

    func run(
        arguments: [String],
        initialOutputTimeout: Duration?,
        captureOutput: Bool,
        onStarted: @escaping @Sendable () -> Void,
        onReady: @escaping @Sendable () -> Void,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> LogCommandResult {
        self.arguments.append(arguments)
        guard arguments.first == "show" else {
            throw TestLogCommandFailure.cannotStart
        }
        onStarted()
        onOutput(output)
        return LogCommandResult(exitCode: 0)
    }

    func recordedArguments() -> [[String]] {
        arguments
    }
}

private actor ReconnectingLogCommandRunner: LogCommandRunning {
    private var streamCount = 0
    private var historyCount = 0
    private var arguments: [[String]] = []

    func run(
        arguments: [String],
        initialOutputTimeout: Duration?,
        captureOutput: Bool,
        onStarted: @escaping @Sendable () -> Void,
        onReady: @escaping @Sendable () -> Void,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> LogCommandResult {
        self.arguments.append(arguments)
        onStarted()
        if arguments.first == "stream" {
            streamCount += 1
            guard streamCount <= 2 else { throw CancellationError() }
            onReady()
            return LogCommandResult(exitCode: 0)
        }

        historyCount += 1
        if historyCount == 1 {
            let timestamp = ISO8601DateFormatter().string(from: .now.addingTimeInterval(-10))
            onOutput(Self.record("before-reconnect", timestamp: timestamp))
        } else {
            let timestamp = ISO8601DateFormatter().string(from: .now)
            onOutput(Self.record("during-reconnect", timestamp: timestamp))
        }
        return LogCommandResult(exitCode: 0)
    }

    func recordedArguments() -> [[String]] {
        arguments
    }

    private static func record(_ message: String, timestamp: String) -> Data {
        Data(
            """
            {"timestamp":"\(timestamp)","messageType":"Default","eventMessage":"\(message)","subsystem":"io.apkrun.cli","category":"command"}
            """.utf8
        )
    }
}

private actor PartialHistoryReconnectLogCommandRunner: LogCommandRunning {
    private var streamCount = 0
    private var historyCount = 0
    private var firstHistorySecond: TimeInterval?

    func run(
        arguments: [String],
        initialOutputTimeout: Duration?,
        captureOutput: Bool,
        onStarted: @escaping @Sendable () -> Void,
        onReady: @escaping @Sendable () -> Void,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> LogCommandResult {
        onStarted()
        if arguments.first == "stream" {
            streamCount += 1
            guard streamCount <= 2 else { throw CancellationError() }
            onReady()
            return LogCommandResult(exitCode: 0)
        }

        historyCount += 1
        let referenceSecond: TimeInterval
        let recordDate: Date
        if historyCount == 1 {
            referenceSecond = floor(Date().timeIntervalSince1970)
            firstHistorySecond = referenceSecond
            recordDate = Date(timeIntervalSince1970: referenceSecond - 0.1)
        } else {
            referenceSecond = firstHistorySecond ?? floor(Date().timeIntervalSince1970)
            recordDate = Date(timeIntervalSince1970: referenceSecond - 0.8)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let message = historyCount == 1 ? "partial-history" : "older-catchup"
        onOutput(
            Self.record(
                message,
                timestamp: formatter.string(from: recordDate)
            )
        )
        return LogCommandResult(exitCode: historyCount == 1 ? 1 : 0)
    }

    private static func record(_ message: String, timestamp: String) -> Data {
        Data(
            """
            {"timestamp":"\(timestamp)","messageType":"Default","eventMessage":"\(message)","subsystem":"io.apkrun.cli","category":"command"}
            """.utf8
        )
    }
}

private actor PartialHistoryReplayLogCommandRunner: LogCommandRunning {
    private var streamCount = 0
    private var historyCount = 0
    private var checkpointSecond: TimeInterval?

    func run(
        arguments: [String],
        initialOutputTimeout: Duration?,
        captureOutput: Bool,
        onStarted: @escaping @Sendable () -> Void,
        onReady: @escaping @Sendable () -> Void,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> LogCommandResult {
        onStarted()
        if arguments.first == "stream" {
            streamCount += 1
            guard streamCount <= 2 else { throw CancellationError() }
            onReady()
            if streamCount == 1 {
                let second = floor(Date().timeIntervalSince1970)
                checkpointSecond = second
                let output = [
                    Self.record("already-a", timestamp: second - 0.8),
                    Self.record("already-b", timestamp: second - 0.6),
                ]
                .joined(separator: "\n")
                onOutput(Data(output.utf8))
            }
            return LogCommandResult(exitCode: 0)
        }

        historyCount += 1
        let second = checkpointSecond ?? floor(Date().timeIntervalSince1970)
        if historyCount == 1 {
            onOutput(Data(Self.record("partial-history", timestamp: second - 0.1).utf8))
            return LogCommandResult(exitCode: 1)
        }
        let output = [
            Self.record("already-a", timestamp: second - 0.8),
            Self.record("already-b", timestamp: second - 0.6),
            Self.record("gap-record", timestamp: Date().timeIntervalSince1970),
        ]
        .joined(separator: "\n")
        onOutput(Data(output.utf8))
        return LogCommandResult(exitCode: 0)
    }

    private static func record(_ message: String, timestamp: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date(timeIntervalSince1970: timestamp))
        return """
            {"timestamp":"\(timestamp)","messageType":"Default","eventMessage":"\(message)","subsystem":"io.apkrun.cli","category":"command"}
            """
    }
}

private actor CatchupFailureLogCommandRunner: LogCommandRunning {
    private var streamCount = 0
    private var historyCount = 0
    private var initialSecond: TimeInterval?
    private var argumentsHistory: [[String]] = []

    func run(
        arguments: [String],
        initialOutputTimeout: Duration?,
        captureOutput: Bool,
        onStarted: @escaping @Sendable () -> Void,
        onReady: @escaping @Sendable () -> Void,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> LogCommandResult {
        argumentsHistory.append(arguments)
        onStarted()
        if arguments.first == "stream" {
            streamCount += 1
            if streamCount == 3 {
                onReady()
                throw CancellationError()
            }
            onReady()
            return LogCommandResult(exitCode: 0)
        }

        historyCount += 1
        if historyCount == 1 {
            initialSecond = floor(Date().timeIntervalSince1970)
            return LogCommandResult(exitCode: 0)
        }
        if historyCount == 2 {
            return LogCommandResult(exitCode: 1)
        }
        let second = initialSecond ?? floor(Date().timeIntervalSince1970)
        let timestamp = ISO8601DateFormatter().string(
            from: Date(timeIntervalSince1970: second - 0.5)
        )
        let record = """
            {"timestamp":"\(timestamp)","messageType":"Default","eventMessage":"uncovered-gap","subsystem":"io.apkrun.cli","category":"command"}
            """
        onOutput(Data(record.utf8))
        return LogCommandResult(exitCode: 0)
    }

    func recordedCatchupStarts() -> [String] {
        let historyArguments = argumentsHistory.filter { $0.first == "show" }.dropFirst()
        return historyArguments.compactMap { arguments in
            guard arguments.first == "show",
                let startIndex = arguments.firstIndex(of: "--start"),
                arguments.indices.contains(startIndex + 1)
            else {
                return nil
            }
            return arguments[startIndex + 1]
        }
    }
}

private actor CatchupSnapshotBoundaryLogCommandRunner: LogCommandRunning {
    private let catchupStarted = LogReaderTestGate()
    private let replacementStreamEnded = LogReaderTestGate()
    private let finalCatchupStarted = LogReaderTestGate()
    private var streamCount = 0
    private var historyCount = 0
    private var lateRecordTimestamp: Date?

    func run(
        arguments: [String],
        initialOutputTimeout: Duration?,
        captureOutput: Bool,
        onStarted: @escaping @Sendable () -> Void,
        onReady: @escaping @Sendable () -> Void,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> LogCommandResult {
        onStarted()
        if arguments.first == "stream" {
            streamCount += 1
            switch streamCount {
            case 1:
                onReady()
                return LogCommandResult(exitCode: 0)
            case 2:
                onReady()
                await catchupStarted.wait()
                await replacementStreamEnded.open()
                return LogCommandResult(exitCode: 0)
            case 3:
                onReady()
                await finalCatchupStarted.wait()
                throw CancellationError()
            default:
                throw CancellationError()
            }
        }

        historyCount += 1
        switch historyCount {
        case 1:
            let record = Self.record(
                "initial-history",
                timestamp: ISO8601DateFormatter().string(from: .now)
            )
            onOutput(Data(record.utf8))
        case 2:
            lateRecordTimestamp = Date().addingTimeInterval(1.5)
            await catchupStarted.open()
            await replacementStreamEnded.wait()
            try await Task.sleep(for: .milliseconds(3_500))
        case 3:
            if let lateRecordTimestamp,
                let startIndex = arguments.firstIndex(of: "--start"),
                arguments.indices.contains(startIndex + 1),
                arguments[startIndex + 1] <= Self.logQueryTimestamp(lateRecordTimestamp)
            {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let record = Self.record(
                    "after-catchup-snapshot",
                    timestamp: formatter.string(from: lateRecordTimestamp)
                )
                onOutput(Data(record.utf8))
            }
            await finalCatchupStarted.open()
        default:
            break
        }
        return LogCommandResult(exitCode: 0)
    }

    private static func record(_ message: String, timestamp: String) -> String {
        """
        {"timestamp":"\(timestamp)","messageType":"Default","eventMessage":"\(message)","subsystem":"io.apkrun.cli","category":"command"}
        """
    }

    private static func logQueryTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
        return formatter.string(from: date)
    }
}

@Test func logReaderKeepsTheOldestCheckpointAfterPartialInitialHistory() async {
    let runner = PartialInitialHistoryGapLogCommandRunner()
    let reader = LogReader(
        paths: APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory),
        runner: runner
    )
    let recorder = LogReadEventRecorder()
    var wasCancelled = false
    do {
        _ = try await reader.read(LogReadOptions(follow: true), onEvent: recorder.append)
    } catch is CancellationError {
        wasCancelled = true
    } catch {
        Issue.record("unexpected log-reader failure: \(error)")
    }

    #expect(wasCancelled)
    #expect(recorder.entries.map(\.message).contains("missed-before-readiness"))
}

private actor PartialInitialHistoryGapLogCommandRunner: LogCommandRunning {
    private var streamCount = 0
    private var historyCount = 0
    private var missedRecordTimestamp: Date?

    func run(
        arguments: [String],
        initialOutputTimeout: Duration?,
        captureOutput: Bool,
        onStarted: @escaping @Sendable () -> Void,
        onReady: @escaping @Sendable () -> Void,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> LogCommandResult {
        onStarted()
        if arguments.first == "stream" {
            streamCount += 1
            switch streamCount {
            case 1:
                missedRecordTimestamp = Date()
                try await Task.sleep(for: .milliseconds(1_500))
                return LogCommandResult(exitCode: 1)
            case 2, 3:
                onReady()
                return LogCommandResult(exitCode: 0)
            default:
                onReady()
                throw CancellationError()
            }
        }

        historyCount += 1
        guard historyCount > 1,
            let missedRecordTimestamp,
            let startIndex = arguments.firstIndex(of: "--start"),
            arguments.indices.contains(startIndex + 1),
            arguments[startIndex + 1] <= Self.logQueryTimestamp(missedRecordTimestamp)
        else {
            return LogCommandResult(exitCode: historyCount == 1 ? 1 : 0)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        onOutput(
            Self.record(
                "missed-before-readiness",
                timestamp: formatter.string(from: missedRecordTimestamp)
            )
        )
        return LogCommandResult(exitCode: 0)
    }

    private static func record(_ message: String, timestamp: String) -> Data {
        Data(
            """
            {"timestamp":"\(timestamp)","messageType":"Default","eventMessage":"\(message)","subsystem":"io.apkrun.cli","category":"command"}
            """.utf8
        )
    }

    private static func logQueryTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
        return formatter.string(from: date)
    }
}

private actor SameRecordCatchupLogCommandRunner: LogCommandRunning {
    private let catchupStarted = LogReaderTestGate()
    private let replacementStreamEnded = LogReaderTestGate()
    private let finalCatchupStarted = LogReaderTestGate()
    private let timestamp = ISO8601DateFormatter().string(from: .now)
    private var streamCount = 0
    private var historyCount = 0

    func run(
        arguments: [String],
        initialOutputTimeout: Duration?,
        captureOutput: Bool,
        onStarted: @escaping @Sendable () -> Void,
        onReady: @escaping @Sendable () -> Void,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> LogCommandResult {
        onStarted()
        if arguments.first == "stream" {
            streamCount += 1
            switch streamCount {
            case 1:
                onReady()
                return LogCommandResult(exitCode: 0)
            case 2:
                onReady()
                await catchupStarted.wait()
                var record = Self.record("same-record", timestamp: timestamp)
                record.append(0x0A)
                onOutput(record)
                await replacementStreamEnded.open()
                return LogCommandResult(exitCode: 0)
            case 3:
                onReady()
                await finalCatchupStarted.wait()
                throw CancellationError()
            default:
                throw CancellationError()
            }
        }

        historyCount += 1
        switch historyCount {
        case 1:
            onOutput(Self.record("same-record", timestamp: timestamp))
        case 2:
            await catchupStarted.open()
            await replacementStreamEnded.wait()
        case 3:
            await finalCatchupStarted.open()
        default:
            break
        }
        return LogCommandResult(exitCode: 0)
    }

    private static func record(_ message: String, timestamp: String) -> Data {
        Data(
            """
            {"timestamp":"\(timestamp)","messageType":"Default","eventMessage":"\(message)","subsystem":"io.apkrun.runtime","category":"host"}
            """.utf8
        )
    }
}

private actor LargeBoundaryReplayLogCommandRunner: LogCommandRunning {
    private let output: Data
    private var streamCount = 0

    init(recordCount: Int, timestamp: String, recordsAreIdentical: Bool) {
        let records = (0..<recordCount).map { index in
            let message = recordsAreIdentical ? "same-record" : "record-\(index)"
            return """
                {"timestamp":"\(timestamp)","messageType":"Default","eventMessage":"\(message)","subsystem":"io.apkrun.runtime","category":"host"}
                """
        }
        output = Data(records.joined(separator: "\n").utf8)
    }

    func run(
        arguments: [String],
        initialOutputTimeout: Duration?,
        captureOutput: Bool,
        onStarted: @escaping @Sendable () -> Void,
        onReady: @escaping @Sendable () -> Void,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> LogCommandResult {
        onStarted()
        if arguments.first == "stream" {
            streamCount += 1
            guard streamCount <= 2 else { throw CancellationError() }
            onReady()
            return LogCommandResult(exitCode: 0)
        }
        onOutput(output)
        return LogCommandResult(exitCode: 0)
    }
}

private actor UnseenBoundaryReplayLogCommandRunner: LogCommandRunning {
    private let initialOutput: Data
    private let catchupOutput: Data
    private var streamCount = 0
    private var historyCount = 0

    init(recordCount: Int, timestamp: String) {
        initialOutput = Self.record("initial-boundary", timestamp: timestamp)
        let records = (0..<recordCount).map { index in
            String(decoding: Self.record("unseen-\(index)", timestamp: timestamp), as: UTF8.self)
        }
        catchupOutput = Data(records.joined(separator: "\n").utf8)
    }

    func run(
        arguments: [String],
        initialOutputTimeout: Duration?,
        captureOutput: Bool,
        onStarted: @escaping @Sendable () -> Void,
        onReady: @escaping @Sendable () -> Void,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> LogCommandResult {
        onStarted()
        if arguments.first == "stream" {
            streamCount += 1
            guard streamCount <= 2 else {
                onReady()
                throw CancellationError()
            }
            onReady()
            return LogCommandResult(exitCode: 0)
        }

        historyCount += 1
        onOutput(historyCount == 1 ? initialOutput : catchupOutput)
        return LogCommandResult(exitCode: 0)
    }

    private static func record(_ message: String, timestamp: String) -> Data {
        Data(
            """
            {"timestamp":"\(timestamp)","messageType":"Default","eventMessage":"\(message)","subsystem":"io.apkrun.runtime","category":"host"}
            """.utf8
        )
    }
}

private actor LargeBufferedReplayLogCommandRunner: LogCommandRunning {
    private let repeatedOutput: Data
    private var streamCount = 0
    private var historyCount = 0

    init(message: String, timestamp: String) {
        let record = """
            {"timestamp":"\(timestamp)","messageType":"Default","eventMessage":"\(message)","subsystem":"io.apkrun.runtime","category":"host"}
            """
        repeatedOutput = Data(Array(repeating: record, count: 4).joined(separator: "\n").utf8)
    }

    func run(
        arguments: [String],
        initialOutputTimeout: Duration?,
        captureOutput: Bool,
        onStarted: @escaping @Sendable () -> Void,
        onReady: @escaping @Sendable () -> Void,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> LogCommandResult {
        onStarted()
        if arguments.first == "stream" {
            streamCount += 1
            if streamCount == 3 {
                onReady()
                throw CancellationError()
            }
            onReady()
            if streamCount == 2 {
                onOutput(repeatedOutput)
            }
            return LogCommandResult(exitCode: 0)
        }

        historyCount += 1
        if historyCount == 2 {
            onOutput(repeatedOutput)
        }
        return LogCommandResult(exitCode: 0)
    }
}

private actor EvictedBufferedReplayLogCommandRunner: LogCommandRunning {
    private let liveRecordReady = LogReaderTestGate()
    private let catchupQueryFinished = LogReaderTestGate()
    private let timestamp: String
    private let catchupOutput: Data
    private var streamCount = 0
    private var historyCount = 0

    init(recordCount: Int, timestamp: String) {
        self.timestamp = timestamp
        let rows =
            ["buffered-match"]
            + (0..<recordCount).map { "history-\($0)" }
        let output = rows.map { Self.record($0, timestamp: timestamp) }
            .joined(separator: "\n")
        catchupOutput = Data(output.utf8)
    }

    func run(
        arguments: [String],
        initialOutputTimeout: Duration?,
        captureOutput: Bool,
        onStarted: @escaping @Sendable () -> Void,
        onReady: @escaping @Sendable () -> Void,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> LogCommandResult {
        onStarted()
        if arguments.first == "stream" {
            streamCount += 1
            switch streamCount {
            case 1:
                onReady()
                return LogCommandResult(exitCode: 0)
            case 2:
                onReady()
                var liveRecord = Data(Self.record("buffered-match", timestamp: timestamp).utf8)
                liveRecord.append(0x0A)
                onOutput(liveRecord)
                await liveRecordReady.open()
                await catchupQueryFinished.wait()
                return LogCommandResult(exitCode: 0)
            default:
                onReady()
                throw CancellationError()
            }
        }

        historyCount += 1
        if historyCount == 2 {
            await liveRecordReady.wait()
            onOutput(catchupOutput)
            await catchupQueryFinished.open()
        }
        return LogCommandResult(exitCode: 0)
    }

    private static func record(_ message: String, timestamp: String) -> String {
        """
        {"timestamp":"\(timestamp)","messageType":"Default","eventMessage":"\(message)","subsystem":"io.apkrun.runtime","category":"host"}
        """
    }
}

private actor LogReaderTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let continuations = waiters
        waiters.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private actor ReconnectStartupFailureLogCommandRunner: LogCommandRunning {
    private var streamCount = 0
    private var historyCount = 0
    private var argumentsHistory: [[String]] = []

    func run(
        arguments: [String],
        initialOutputTimeout: Duration?,
        captureOutput: Bool,
        onStarted: @escaping @Sendable () -> Void,
        onReady: @escaping @Sendable () -> Void,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> LogCommandResult {
        argumentsHistory.append(arguments)
        onStarted()
        if arguments.first == "stream" {
            streamCount += 1
            if streamCount == 1 {
                onReady()
                return LogCommandResult(exitCode: 0)
            }
            return LogCommandResult(exitCode: 1)
        }

        historyCount += 1
        let timestamp = ISO8601DateFormatter().string(from: .now)
        let message = historyCount == 1 ? "initial-history" : "recovered-gap"
        let record = """
            {"timestamp":"\(timestamp)","messageType":"Default","eventMessage":"\(message)","subsystem":"io.apkrun.cli","category":"command"}
            """
        onOutput(Data(record.utf8))
        return LogCommandResult(exitCode: 0)
    }

    func recordedArguments() -> [[String]] {
        argumentsHistory
    }
}

private final class ByteBoundedFollowLogCommandRunner: LogCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let recordCount: Int
    private let messageByteCount: Int
    private let timestamp = ISO8601DateFormatter().string(from: .now)
    private var streamAttempts = 0
    private var historyAttempts = 0
    private var liveRecordsStarted = 0
    private var observedLiveRecordsBeforeHistoryCompletes: Int?

    init(recordCount: Int, messageByteCount: Int) {
        self.recordCount = recordCount
        self.messageByteCount = messageByteCount
    }

    func run(
        arguments: [String],
        initialOutputTimeout: Duration?,
        captureOutput: Bool,
        onStarted: @escaping @Sendable () -> Void,
        onReady: @escaping @Sendable () -> Void,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> LogCommandResult {
        onStarted()
        if arguments.first == "show" {
            let historyAttempt = lock.withLock {
                historyAttempts += 1
                return historyAttempts
            }
            if historyAttempt == 1 {
                var previousCount = -1
                var stableCount = 0
                while stableCount < 10 {
                    try await Task.sleep(for: .milliseconds(20))
                    let currentCount = lock.withLock { liveRecordsStarted }
                    if currentCount < 5 {
                        stableCount = 0
                    } else if currentCount == previousCount {
                        stableCount += 1
                    } else {
                        stableCount = 0
                    }
                    previousCount = currentCount
                }
                lock.withLock {
                    observedLiveRecordsBeforeHistoryCompletes = liveRecordsStarted
                }
                onOutput(Self.record("history", timestamp: timestamp))
            }
            return LogCommandResult(exitCode: 0)
        }

        let streamAttempt = lock.withLock {
            streamAttempts += 1
            return streamAttempts
        }
        guard streamAttempt == 1 else { throw CancellationError() }
        onReady()
        for index in 0..<recordCount {
            lock.withLock {
                liveRecordsStarted += 1
            }
            let message = "live-\(index)-" + String(repeating: "x", count: messageByteCount)
            onOutput(Self.record(message, timestamp: timestamp, terminated: true))
        }
        return LogCommandResult(exitCode: 0)
    }

    func liveRecordCountBeforeHistoryCompletes() -> Int? {
        lock.withLock {
            observedLiveRecordsBeforeHistoryCompletes
        }
    }

    private static func record(
        _ message: String,
        timestamp: String,
        terminated: Bool = false
    ) -> Data {
        var data = Data(
            """
            {"timestamp":"\(timestamp)","messageType":"Default","eventMessage":"\(message)","subsystem":"io.apkrun.runtime","category":"host"}
            """.utf8
        )
        if terminated {
            data.append(0x0A)
        }
        return data
    }
}

private final class HighVolumeFollowLogCommandRunner: LogCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let historyOutput: Data
    private let liveOutput: Data
    private var streamAttempts = 0

    init(recordCount: Int, timestamp: String) {
        let history = """
            {"timestamp":"\(timestamp)","messageType":"Default","eventMessage":"history","subsystem":"io.apkrun.cli","category":"command"}
            """
        historyOutput = Data(history.utf8)
        let liveLines = (0..<recordCount).map { index in
            """
            {"timestamp":"\(timestamp)","messageType":"Default","eventMessage":"live-\(index)","subsystem":"io.apkrun.runtime","category":"host"}
            """
        }
        liveOutput = Data(liveLines.joined(separator: "\n").utf8)
    }

    func run(
        arguments: [String],
        initialOutputTimeout: Duration?,
        captureOutput: Bool,
        onStarted: @escaping @Sendable () -> Void,
        onReady: @escaping @Sendable () -> Void,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> LogCommandResult {
        if arguments.first == "show" {
            onStarted()
            onOutput(historyOutput)
            return LogCommandResult(exitCode: 0)
        }

        let attempt = nextStreamAttempt()
        guard attempt == 1 else { throw CancellationError() }
        onStarted()
        onReady()
        onOutput(liveOutput)
        return LogCommandResult(exitCode: 0)
    }

    private func nextStreamAttempt() -> Int {
        lock.lock()
        defer { lock.unlock() }
        streamAttempts += 1
        return streamAttempts
    }
}

private enum TestLogCommandFailure: Error {
    case cannotStart
}
