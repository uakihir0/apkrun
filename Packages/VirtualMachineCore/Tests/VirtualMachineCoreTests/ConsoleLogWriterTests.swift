import DiagnosticsCore
import DiagnosticsCoreTestSupport
import Foundation
import Testing
import VirtualMachineCoreTestSupport

@testable import VirtualMachineCore

@Test(.timeLimit(.minutes(1)))
func consoleLogWriterPrefixesRecordsAndPreservesUnmodifiedGuestBytes() async throws {
    let fixture = makeConsoleLogWriter()
    await fixture.writer.start()
    fixture.clock.advance(by: .seconds(12) + .milliseconds(345))
    await fixture.writer.append(Data([0x68, 0xFF, 0x0A, 0x74, 0x61, 0x69, 0x6C]))

    fixture.clock.advance(by: .milliseconds(250))
    await fixture.writer.flush()

    let output = try #require(fixture.fileSystem.contents(at: fixture.paths.consoleLogFile))
    let firstPrefix =
        Array(formattedWallTime(fixture.clock.read().wallTime.addingTimeInterval(-0.25)).utf8)
        + Array(" +12.345 ".utf8)
    let secondPrefix =
        Array(formattedWallTime(fixture.clock.read().wallTime).utf8)
        + Array(" +12.595 ".utf8)
    #expect(output.starts(with: firstPrefix))
    #expect(output.range(of: Data([0x68, 0xFF, 0x0A])) != nil)
    #expect(output.suffix(secondPrefix.count + 5).starts(with: secondPrefix))
    #expect(output.suffix(5) == Data([0x74, 0x61, 0x69, 0x6C, 0x0A]))

    let bootPath = try #require(fixture.fileSystem.contents(at: fixture.bootLogURL))
    #expect(bootPath == output)
}

@Test(.timeLimit(.minutes(1)))
func consoleLogWriterRotatesFiveGenerationsAndKeepsEachFilePrivate() async throws {
    let fixture = makeConsoleLogWriter(rotationLimit: 100)
    await fixture.writer.start()

    for index in 0..<30 {
        await fixture.writer.append(Data("line-\(index)\n".utf8))
    }
    await fixture.writer.finish()

    #expect(fixture.fileSystem.contents(at: fixture.paths.consoleLogFile) != nil)
    for index in 1...4 {
        #expect(fixture.fileSystem.contents(at: fixture.paths.consoleLogRotationFile(index: index)) != nil)
    }
    #expect(fixture.fileSystem.contents(at: fixture.paths.consoleLogRotationFile(index: 5)) == nil)
    #expect(fixture.fileSystem.permissions(at: fixture.paths.vmLogsDirectory) == 0o700)
    #expect(fixture.fileSystem.permissions(at: fixture.paths.consoleLogFile) == 0o600)
    for index in 1...4 {
        #expect(
            fixture.fileSystem.permissions(at: fixture.paths.consoleLogRotationFile(index: index))
                == 0o600
        )
    }
}

@Test(.timeLimit(.minutes(1)))
func consoleLogWriterKeepsOnlyTheNewestFiveBootCopies() async throws {
    let fixture = makeConsoleLogWriter(retainedBootLogs: 5)
    for day in 1...6 {
        let name = String(format: "boot-202601%02dT000000Z.log", day)
        fixture.fileSystem.setContents(
            Data("old\n".utf8),
            at: fixture.paths.vmLogsDirectory.appendingPathComponent(name)
        )
    }
    await fixture.writer.start()
    await fixture.writer.append(Data("current\n".utf8))
    await fixture.writer.finish()

    let bootFiles = try fixture.fileSystem.contentsOfDirectory(at: fixture.paths.vmLogsDirectory)
        .filter { $0.lastPathComponent.hasPrefix("boot-") }
    #expect(bootFiles.count == 5)
    #expect(
        !bootFiles.contains {
            $0.lastPathComponent == "boot-20260101T000000Z.log"
                || $0.lastPathComponent == "boot-20260102T000000Z.log"
        }
    )
    #expect(bootFiles.contains(fixture.bootLogURL))
}

@Test(.timeLimit(.minutes(1)))
func consoleLogWriterSynchronizesAtSixtyFourKiBAndOnTimerFlush() async throws {
    let fixture = makeConsoleLogWriter()
    await fixture.writer.start()
    let largePartialLine = Data(repeating: 0x61, count: ConsoleLogWriter.maximumRecordBytes)
    await fixture.writer.append(largePartialLine)
    #expect(fixture.fileSystem.synchronizeCallCount >= 2)
    #expect(fixture.fileSystem.contents(at: fixture.paths.consoleLogFile)?.contains(0x61) == true)

    let countBeforeTimerFlush = fixture.fileSystem.contents(at: fixture.paths.consoleLogFile)?.count ?? 0
    await fixture.writer.append(Data("partial".utf8))
    fixture.clock.advance(by: .milliseconds(250))
    try await Task.sleep(for: .milliseconds(350))

    let contentsAfterTimerFlush = try #require(
        fixture.fileSystem.contents(at: fixture.paths.consoleLogFile)
    )
    #expect(contentsAfterTimerFlush.count > countBeforeTimerFlush)
    #expect(contentsAfterTimerFlush.suffix(8) == Data("partial\n".utf8))
    #expect(fixture.fileSystem.synchronizeCallCount >= 4)
    await fixture.writer.finish()
}

@Test(.timeLimit(.minutes(1)))
func consoleLogWriterReportsWriteAndSynchronizationFailures() async throws {
    let writeFixture = makeConsoleLogWriter()
    writeFixture.fileSystem.failWrites()
    await writeFixture.writer.start()
    await writeFixture.writer.append(Data("lost\n".utf8))
    #expect(await writeFixture.writer.didFail)
    #expect(await writeFixture.writer.droppedByteCount == 5)
    #expect(writeFixture.failureCount.value == 1)
    #expect(
        writeFixture.logSink.entries.contains {
            $0.errorCode == VMFailure.consoleLogWriteFailed.qualifiedCode
        }
    )
    await writeFixture.writer.finish()

    let syncFixture = makeConsoleLogWriter()
    await syncFixture.writer.start()
    await syncFixture.writer.append(Data("durable\n".utf8))
    syncFixture.fileSystem.failSynchronizations()
    await syncFixture.writer.flush()
    #expect(await syncFixture.writer.didFail)
    #expect(syncFixture.failureCount.value == 1)
    await syncFixture.writer.finish()
}

private struct ConsoleLogWriterFixture {
    let paths: APKRunPaths
    let writer: ConsoleLogWriter
    let fileSystem: FakeConsoleLogFileSystem
    let clock: ManualConsoleLogClock
    let logSink: RecordingLogSink
    let failureCount: ConsoleLogFailureCounter

    var bootLogURL: URL {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return paths.vmLogsDirectory.appendingPathComponent("boot-\(formatter.string(from: date)).log")
    }
}

private func makeConsoleLogWriter(
    rotationLimit: UInt64 = ConsoleLogWriter.maximumLogBytes,
    retainedBootLogs: Int = ConsoleLogWriter.maximumBootLogs
) -> ConsoleLogWriterFixture {
    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": "/tmp/apkrun-console-log-writer-tests/\(UUID().uuidString)"]
    )
    let fileSystem = FakeConsoleLogFileSystem()
    let clock = ManualConsoleLogClock()
    let logSink = RecordingLogSink()
    let failureCount = ConsoleLogFailureCounter()
    let writer = ConsoleLogWriter(
        directoryURL: paths.vmLogsDirectory,
        logger: APKLogger(category: VMLogCategory.console, sink: logSink),
        fileSystem: fileSystem,
        clock: clock,
        rotationLimit: rotationLimit,
        retainedBootLogs: retainedBootLogs,
        onWriteFailure: { failureCount.increment() }
    )
    return ConsoleLogWriterFixture(
        paths: paths,
        writer: writer,
        fileSystem: fileSystem,
        clock: clock,
        logSink: logSink,
        failureCount: failureCount
    )
}

private func formattedWallTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .iso8601)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    return formatter.string(from: date)
}

private final class ConsoleLogFailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
