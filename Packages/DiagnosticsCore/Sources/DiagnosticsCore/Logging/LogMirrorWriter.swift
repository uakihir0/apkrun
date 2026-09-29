import Foundation

/// Asynchronously mirrors public apkrund log entries to a rotating file set.
///
/// Each writer owns a serial queue. Disk work, including formatting, is kept off
/// the logging call path; the bounded pending-byte budget drops new entries
/// rather than allowing a slow disk to stall callers or grow memory without
/// limit.
public final class LogMirrorWriter: LogSink, @unchecked Sendable {
    private let fileURL: URL
    private let maximumFileBytes: Int
    private let maximumFileCount: Int
    private let maximumBufferedBytes: Int
    private let queue: DispatchQueue
    private let timer: DispatchSourceTimer
    private let stateLock = NSLock()
    private var pendingBytes = 0
    private var droppedEntries: UInt64 = 0

    deinit {
        timer.cancel()
    }

    /// Creates an asynchronous mirror with the production rotation defaults.
    ///
    /// - Parameters:
    ///   - fileURL: The active log file URL, normally `apkrund.log`.
    ///   - maximumFileBytes: Maximum size of each active or rotated file.
    ///   - maximumFileCount: Number of files to retain, including the active file.
    ///   - maximumBufferedBytes: Maximum estimated bytes queued for disk.
    ///   - flushInterval: Periodic durability interval.
    public init(
        fileURL: URL,
        maximumFileBytes: Int = 10 * 1_024 * 1_024,
        maximumFileCount: Int = 3,
        maximumBufferedBytes: Int = 1 * 1_024 * 1_024,
        flushInterval: TimeInterval = 1
    ) {
        precondition(maximumFileBytes > 0)
        precondition(maximumFileCount > 0)
        precondition(maximumBufferedBytes > 0)
        precondition(flushInterval > 0)

        self.fileURL = fileURL
        self.maximumFileBytes = maximumFileBytes
        self.maximumFileCount = maximumFileCount
        self.maximumBufferedBytes = maximumBufferedBytes

        let serialQueue = DispatchQueue(label: "io.apkrun.diagnostics.log-mirror")
        queue = serialQueue
        let flushTimer = DispatchSource.makeTimerSource(queue: serialQueue)
        timer = flushTimer
        flushTimer.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        flushTimer.setEventHandler { [weak self] in
            self?.synchronizeActiveFile()
        }
        flushTimer.resume()
    }

    /// Returns whether the mirror accepts the requested severity.
    ///
    /// Debug entries are intentionally not written to the persistent mirror.
    public func isEnabled(for level: LogLevel) -> Bool {
        level >= .info
    }

    /// Queues a public entry without waiting for file I/O.
    public func write(_ entry: LogEntry) {
        guard isEnabled(for: entry.level) else { return }

        let record = PublicLogRecord(entry: entry)
        let estimatedBytes = Self.estimatedLineSize(for: record)
        guard reserve(estimatedBytes) else {
            recordDrop()
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            defer { release(estimatedBytes) }

            do {
                try append(record)
                if record.level >= .error {
                    synchronizeActiveFile()
                }
            } catch {
                recordDrop()
            }
        }
    }

    /// Number of entries dropped because the buffer was full or writing failed.
    public var droppedEntryCount: UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return droppedEntries
    }

    /// Waits for earlier queued writes and synchronizes the active file.
    public func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                self?.synchronizeActiveFile()
                continuation.resume()
            }
        }
    }

    private func reserve(_ byteCount: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard byteCount <= maximumBufferedBytes,
            pendingBytes <= maximumBufferedBytes - byteCount
        else {
            return false
        }
        pendingBytes += byteCount
        return true
    }

    private func release(_ byteCount: Int) {
        stateLock.lock()
        pendingBytes -= byteCount
        stateLock.unlock()
    }

    private func recordDrop() {
        stateLock.lock()
        droppedEntries += 1
        stateLock.unlock()
    }

    private func append(_ record: PublicLogRecord) throws {
        let line = Self.lineData(for: record)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } else {
            guard
                FileManager.default.createFile(
                    atPath: fileURL.path,
                    contents: Data(),
                    attributes: [.posixPermissions: 0o600]
                )
            else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        let activeSize = try Self.fileSize(at: fileURL)
        if activeSize > 0, activeSize + line.count > maximumFileBytes {
            try rotateFiles()
            guard
                FileManager.default.createFile(
                    atPath: fileURL.path,
                    contents: Data(),
                    attributes: [.posixPermissions: 0o600]
                )
            else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private func rotateFiles() throws {
        let fileManager = FileManager.default
        if maximumFileCount > 1 {
            if maximumFileCount > 2 {
                for index in stride(from: maximumFileCount - 1, through: 2, by: -1) {
                    let source = rotatedFileURL(index: index - 1)
                    let destination = rotatedFileURL(index: index)
                    if fileManager.fileExists(atPath: destination.path) {
                        try fileManager.removeItem(at: destination)
                    }
                    if fileManager.fileExists(atPath: source.path) {
                        try fileManager.moveItem(at: source, to: destination)
                    }
                }
            }
            let newestRotation = rotatedFileURL(index: 1)
            if fileManager.fileExists(atPath: newestRotation.path) {
                try fileManager.removeItem(at: newestRotation)
            }
            try fileManager.moveItem(at: fileURL, to: newestRotation)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: newestRotation.path
            )
        } else {
            try fileManager.removeItem(at: fileURL)
        }
    }

    private func rotatedFileURL(index: Int) -> URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponentWithoutExtension).\(index).log")
    }

    private func synchronizeActiveFile() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
            let handle = try? FileHandle(forWritingTo: fileURL)
        else {
            return
        }
        defer { try? handle.close() }
        try? handle.synchronize()
    }

    private static func fileSize(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    private static func estimatedLineSize(for record: PublicLogRecord) -> Int {
        let message = record.message
        let newlineExpansion = message.unicodeScalars.reduce(into: 0) { extraBytes, scalar in
            if scalar == "\r" || scalar == "\n" {
                extraBytes += 1
            }
        }
        return message.utf8.count + newlineExpansion + record.subsystem.rawValue.utf8.count
            + record.category.utf8.count + 96
    }

    private static func lineData(for record: PublicLogRecord) -> Data {
        let timestamp = ISO8601DateFormatter().string(from: record.timestamp)
        let message = record.message
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        let line = "\(timestamp) \(record.level.rawValue) \(record.subsystem.rawValue)/\(record.category) \(message)\n"
        return Data(line.utf8)
    }
}

private struct PublicLogRecord: Sendable {
    let timestamp: Date
    let level: LogLevel
    let subsystem: LogSubsystem
    let category: String
    let message: String

    init(entry: LogEntry) {
        timestamp = entry.timestamp
        level = entry.level
        subsystem = entry.subsystem
        category = entry.category
        message = entry.formattedPublicMessage
    }
}

extension URL {
    fileprivate var lastPathComponentWithoutExtension: String {
        deletingPathExtension().lastPathComponent
    }
}
