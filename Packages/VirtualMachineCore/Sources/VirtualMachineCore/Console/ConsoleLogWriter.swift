import DiagnosticsCore
import Foundation

package struct ConsoleLogClockReading: Sendable {
    package let wallTime: Date
    package let monotonicUptime: Duration

    package init(wallTime: Date, monotonicUptime: Duration) {
        self.wallTime = wallTime
        self.monotonicUptime = monotonicUptime
    }
}

package protocol ConsoleLogClock: Sendable {
    func read() -> ConsoleLogClockReading
}

package struct SystemConsoleLogClock: ConsoleLogClock {
    private let continuousClock = ContinuousClock()
    private let origin = ContinuousClock().now

    package init() {}

    package func read() -> ConsoleLogClockReading {
        ConsoleLogClockReading(
            wallTime: Date(),
            monotonicUptime: origin.duration(to: continuousClock.now)
        )
    }
}

/// Persists unmodified guest console bytes with timestamps and bounded rotation.
package actor ConsoleLogWriter {
    package static let maximumLogBytes: UInt64 = 20 * 1_024 * 1_024
    package static let maximumBootLogs = 5
    package static let maximumRecordBytes = 64 * 1_024
    package static let flushInterval: Duration = .milliseconds(250)

    private let directoryURL: URL
    private let fileSystem: any ConsoleLogFileSystem
    private let clock: any ConsoleLogClock
    private let logger: APKLogger
    private let onWriteFailure: @Sendable () -> Void
    private let rotationLimit: UInt64
    private let retainedBootLogs: Int
    private let timerInterval: Duration

    private var mainHandle: (any ConsoleLogFileHandle)?
    private var bootHandle: (any ConsoleLogFileHandle)?
    private var bootLogURL: URL?
    private var mainLogSize: UInt64 = 0
    private var bytesSinceSynchronization: UInt64 = 0
    private var pendingRecord = Data()
    private var monotonicStart: Duration?
    private var streamDroppedByteCount: UInt64 = 0
    private var lastStreamDroppedByteCount: UInt64 = 0
    private var writerDroppedByteCount: UInt64 = 0
    private var hasReportedFailure = false
    private var hasStarted = false
    private var hasFinished = false
    private var writesDisabled = false
    private var timerTask: Task<Void, Never>?

    package var droppedByteCount: UInt64 {
        streamDroppedByteCount &+ writerDroppedByteCount
    }

    package var didFail: Bool {
        hasReportedFailure || droppedByteCount > 0
    }

    package init(
        directoryURL: URL,
        logger: APKLogger,
        fileSystem: any ConsoleLogFileSystem = SystemConsoleLogFileSystem(),
        clock: any ConsoleLogClock = SystemConsoleLogClock(),
        rotationLimit: UInt64 = ConsoleLogWriter.maximumLogBytes,
        retainedBootLogs: Int = ConsoleLogWriter.maximumBootLogs,
        timerInterval: Duration = ConsoleLogWriter.flushInterval,
        onWriteFailure: @escaping @Sendable () -> Void = {}
    ) {
        precondition(rotationLimit > 0)
        precondition(retainedBootLogs > 0)
        precondition(timerInterval > .zero)
        self.directoryURL = directoryURL
        self.logger = logger
        self.fileSystem = fileSystem
        self.clock = clock
        self.rotationLimit = rotationLimit
        self.retainedBootLogs = retainedBootLogs
        self.timerInterval = timerInterval
        self.onWriteFailure = onWriteFailure
    }

    package func start() {
        guard !hasStarted, !hasFinished else { return }
        hasStarted = true
        monotonicStart = clock.read().monotonicUptime
        do {
            try fileSystem.createDirectory(at: directoryURL, permissions: 0o700)
            try openMainLog()
            try openBootLog()
            try removeOldBootLogs()
        } catch {
            reportFailure(error, droppedBytes: 0)
        }
        startFlushTimer()
    }

    package func append(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        guard hasStarted, !hasFinished, !writesDisabled else {
            writerDroppedByteCount &+= UInt64(bytes.count)
            return
        }
        pendingRecord.append(bytes)
        writeReadyRecords()
    }

    /// Records output lost by the bounded stream feeding this writer.
    package func recordStreamDroppedBytes(_ total: UInt64) {
        guard total > lastStreamDroppedByteCount else { return }
        streamDroppedByteCount &+= total - lastStreamDroppedByteCount
        lastStreamDroppedByteCount = total
    }

    /// Flushes partial records and synchronizes both log files.
    package func flush() {
        guard hasStarted, !hasFinished else { return }
        if !pendingRecord.isEmpty {
            let partial = pendingRecord
            pendingRecord.removeAll(keepingCapacity: true)
            writeRecord(partial, addRecordSeparator: true)
        }
        synchronizeOpenFiles()
    }

    /// Flushes and closes both files after the guest-output stream reaches EOF.
    package func finish() {
        guard !hasFinished else { return }
        if !hasStarted {
            hasFinished = true
            return
        }
        flush()
        hasFinished = true
        timerTask?.cancel()
        timerTask = nil
        close(&mainHandle)
        close(&bootHandle)
    }

    private func startFlushTimer() {
        let interval = timerInterval
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                await self.flushTimerFired()
            }
        }
    }

    private func flushTimerFired() {
        guard !pendingRecord.isEmpty || bytesSinceSynchronization > 0 else { return }
        flush()
    }

    private func writeReadyRecords() {
        while !pendingRecord.isEmpty {
            let newline = pendingRecord.firstIndex(of: 0x0A)
            let lineLength = newline.map { pendingRecord.distance(from: pendingRecord.startIndex, to: $0) + 1 }
            if let lineLength, lineLength <= Self.maximumRecordBytes {
                let record = Data(pendingRecord.prefix(lineLength))
                pendingRecord.removeFirst(lineLength)
                writeRecord(record, addRecordSeparator: false)
                continue
            }

            if pendingRecord.count >= Self.maximumRecordBytes {
                let record = Data(pendingRecord.prefix(Self.maximumRecordBytes))
                pendingRecord.removeFirst(Self.maximumRecordBytes)
                writeRecord(record, addRecordSeparator: true)
                continue
            }
            return
        }
    }

    private func writeRecord(_ guestBytes: Data, addRecordSeparator: Bool) {
        guard !writesDisabled else {
            writerDroppedByteCount &+= UInt64(guestBytes.count)
            return
        }
        var output = Data(makePrefix())
        output.append(guestBytes)
        if addRecordSeparator {
            output.append(0x0A)
        }

        do {
            try ensureOpenFiles()
            try rotateMainLogIfNeeded(for: UInt64(output.count))
            guard let mainHandle, let bootHandle else {
                throw POSIXError(.EBADF)
            }
            try mainHandle.write(output)
            mainLogSize &+= UInt64(output.count)
            try bootHandle.write(output)
            bytesSinceSynchronization &+= UInt64(guestBytes.count)
            if bytesSinceSynchronization >= UInt64(Self.maximumRecordBytes) {
                synchronizeOpenFiles()
            }
        } catch {
            writesDisabled = true
            reportFailure(error, droppedBytes: UInt64(guestBytes.count))
            synchronizeOpenFiles()
        }
    }

    private func makePrefix() -> [UInt8] {
        let reading = clock.read()
        let wallClock = DateFormatter()
        wallClock.locale = Locale(identifier: "en_US_POSIX")
        wallClock.calendar = Calendar(identifier: .iso8601)
        wallClock.timeZone = TimeZone(secondsFromGMT: 0)
        wallClock.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"

        let monotonicStart = monotonicStart ?? reading.monotonicUptime
        let elapsed = max(.zero, reading.monotonicUptime - monotonicStart)
        let components = elapsed.components
        let milliseconds = components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
        let wholeSeconds = milliseconds / 1_000
        let fractionalMilliseconds = milliseconds % 1_000
        let prefix = String(
            format: "%@ +%lld.%03lld ",
            wallClock.string(from: reading.wallTime),
            wholeSeconds,
            fractionalMilliseconds
        )
        return Array(prefix.utf8)
    }

    private func openMainLog() throws {
        guard mainHandle == nil else { return }
        let currentSize = try fileSystem.fileSize(at: directoryURL.appendingPathComponent("console.log"))
        mainLogSize = currentSize ?? 0
        mainHandle = try fileSystem.openForAppend(
            at: directoryURL.appendingPathComponent("console.log"),
            permissions: 0o600
        )
    }

    private func openBootLog() throws {
        guard bootHandle == nil else { return }
        if bootLogURL == nil {
            let timestamp = Self.bootTimestamp(clock.read().wallTime)
            var candidate = directoryURL.appendingPathComponent("boot-\(timestamp).log")
            var suffix = 0
            while try fileSystem.fileSize(at: candidate) != nil {
                suffix += 1
                candidate = directoryURL.appendingPathComponent(
                    "boot-\(timestamp)-\(String(format: "%03d", suffix)).log"
                )
            }
            bootLogURL = candidate
        }
        guard let bootLogURL else {
            throw POSIXError(.EIO)
        }
        bootHandle = try fileSystem.openForAppend(at: bootLogURL, permissions: 0o600)
    }

    private func ensureOpenFiles() throws {
        try fileSystem.createDirectory(at: directoryURL, permissions: 0o700)
        try openMainLog()
        try openBootLog()
    }

    private func rotateMainLogIfNeeded(for nextRecordSize: UInt64) throws {
        guard mainLogSize > 0, mainLogSize + nextRecordSize > rotationLimit else { return }
        guard synchronizeOpenFiles() else {
            throw POSIXError(.EIO)
        }
        close(&mainHandle)

        for index in stride(from: 3, through: 1, by: -1) {
            let source = directoryURL.appendingPathComponent("console.\(index).log")
            let destination = directoryURL.appendingPathComponent("console.\(index + 1).log")
            if try fileSystem.fileSize(at: source) != nil {
                try fileSystem.moveItem(from: source, to: destination)
            }
        }

        let current = directoryURL.appendingPathComponent("console.log")
        if try fileSystem.fileSize(at: current) != nil {
            try fileSystem.moveItem(
                from: current,
                to: directoryURL.appendingPathComponent("console.1.log")
            )
        }
        mainLogSize = 0
        try openMainLog()
    }

    private func removeOldBootLogs() throws {
        let bootLogs = try fileSystem.contentsOfDirectory(at: directoryURL)
            .filter {
                let name = $0.lastPathComponent
                return name.hasPrefix("boot-") && name.hasSuffix(".log")
            }
            .sorted { Self.bootLogSortKey($0.lastPathComponent) < Self.bootLogSortKey($1.lastPathComponent) }
        for oldLog in bootLogs.prefix(max(0, bootLogs.count - retainedBootLogs)) {
            try fileSystem.removeItem(at: oldLog)
        }
    }

    @discardableResult
    private func synchronizeOpenFiles() -> Bool {
        var synchronizedAllFiles = true
        for handle in [mainHandle, bootHandle].compactMap({ $0 }) {
            do {
                try handle.synchronize()
            } catch {
                reportFailure(error, droppedBytes: 0)
                synchronizedAllFiles = false
            }
        }
        if synchronizedAllFiles {
            bytesSinceSynchronization = 0
        }
        return synchronizedAllFiles
    }

    private func close(_ handle: inout (any ConsoleLogFileHandle)?) {
        guard let openHandle = handle else { return }
        handle = nil
        do {
            try openHandle.close()
        } catch {
            reportFailure(error, droppedBytes: 0)
        }
    }

    private func reportFailure(_ error: any Error, droppedBytes: UInt64) {
        writerDroppedByteCount &+= droppedBytes
        guard !hasReportedFailure else { return }
        hasReportedFailure = true
        onWriteFailure()
        logger.error(
            "Failed to persist the VM console log: \(String(describing: error), .private)",
            errorCode: VMFailure.consoleLogWriteFailed.qualifiedCode
        )
    }

    private static func bootTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func bootLogSortKey(_ name: String) -> String {
        guard name.hasSuffix(".log") else { return name }
        let stem = String(name.dropLast(4))
        if let dash = stem.lastIndex(of: "-"),
            stem[stem.index(after: dash)...].count == 3,
            stem[stem.index(after: dash)...].allSatisfy(\.isNumber)
        {
            return stem + ".log"
        }
        return stem + "-000.log"
    }
}
