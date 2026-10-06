import Foundation
import VirtualMachineCore

/// An in-memory console log file system for deterministic writer tests.
public final class FakeConsoleLogFileSystem: ConsoleLogFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var modes: [String: UInt16] = [:]
    private var directories: [String: UInt16] = [:]
    private var synchronizations = 0
    private var writes = 0
    private var shouldFailOpens = false
    private var shouldFailWrites = false
    private var pathsWithFailedWrites: Set<String> = []
    private var shouldFailSynchronizations = false
    private var pathsWithFailedSynchronizations: Set<String> = []

    public init() {}

    /// The file contents, when the file exists.
    public func contents(at url: URL) -> Data? {
        lock.withLock { files[url.path] }
    }

    /// The mode used when the file or directory was created.
    public func permissions(at url: URL) -> UInt16? {
        lock.withLock { modes[url.path] ?? directories[url.path] }
    }

    /// The number of successful or attempted synchronization calls.
    public var synchronizeCallCount: Int {
        lock.withLock { synchronizations }
    }

    /// The number of attempted file writes.
    public var writeCallCount: Int {
        lock.withLock { writes }
    }

    /// Installs a file before the writer starts.
    public func setContents(_ contents: Data, at url: URL, permissions: UInt16 = 0o600) {
        lock.withLock {
            files[url.path] = contents
            modes[url.path] = permissions
        }
    }

    /// Makes later append operations fail.
    public func failWrites() {
        lock.withLock { shouldFailWrites = true }
    }

    /// Makes writes to one file fail while other files remain writable.
    public func failWrites(at url: URL) {
        lock.withLock { _ = pathsWithFailedWrites.insert(url.path) }
    }

    /// Makes later file-open operations fail.
    public func failOpens() {
        lock.withLock { shouldFailOpens = true }
    }

    /// Makes later synchronization operations fail.
    public func failSynchronizations() {
        lock.withLock { shouldFailSynchronizations = true }
    }

    /// Makes synchronization of one file fail while other files remain synchronized.
    public func failSynchronizations(at url: URL) {
        lock.withLock { _ = pathsWithFailedSynchronizations.insert(url.path) }
    }

    /// Allows synchronization of one file to succeed again.
    public func allowSynchronizations(at url: URL) {
        lock.withLock { _ = pathsWithFailedSynchronizations.remove(url.path) }
    }

    package func createDirectory(at url: URL, permissions: UInt16) throws {
        lock.withLock {
            directories[url.path] = permissions
        }
    }

    package func openForAppend(
        at url: URL,
        permissions: UInt16
    ) throws -> any ConsoleLogFileHandle {
        try lock.withLock {
            guard !shouldFailOpens else {
                throw FakeConsoleLogFileSystemError.openFailed
            }
            if files[url.path] == nil {
                files[url.path] = Data()
            }
            modes[url.path] = permissions
        }
        return FakeConsoleLogFileHandle(fileSystem: self, path: url.path)
    }

    package func fileSize(at url: URL) throws -> UInt64? {
        lock.withLock {
            files[url.path].map { UInt64($0.count) }
        }
    }

    package func moveItem(from source: URL, to destination: URL) throws {
        try lock.withLock {
            guard let contents = files.removeValue(forKey: source.path) else {
                throw FakeConsoleLogFileSystemError.missingFile
            }
            files[destination.path] = contents
            modes[destination.path] = modes.removeValue(forKey: source.path)
        }
    }

    package func removeItem(at url: URL) throws {
        lock.withLock {
            files.removeValue(forKey: url.path)
            modes.removeValue(forKey: url.path)
        }
    }

    package func contentsOfDirectory(at url: URL) throws -> [URL] {
        lock.withLock {
            files.keys
                .filter { URL(fileURLWithPath: $0).deletingLastPathComponent() == url }
                .map { URL(fileURLWithPath: $0) }
        }
    }

    fileprivate func append(_ data: Data, to path: String) throws {
        try lock.withLock {
            writes += 1
            guard !shouldFailWrites, !pathsWithFailedWrites.contains(path) else {
                throw FakeConsoleLogFileSystemError.writeFailed
            }
            files[path, default: Data()].append(data)
        }
    }

    fileprivate func synchronize(path: String) throws {
        try lock.withLock {
            synchronizations += 1
            guard
                !shouldFailSynchronizations,
                !pathsWithFailedSynchronizations.contains(path)
            else {
                throw FakeConsoleLogFileSystemError.synchronizeFailed
            }
        }
    }
}

private final class FakeConsoleLogFileHandle: ConsoleLogFileHandle, @unchecked Sendable {
    private let fileSystem: FakeConsoleLogFileSystem
    private let path: String
    private let lock = NSLock()
    private var isClosed = false

    init(fileSystem: FakeConsoleLogFileSystem, path: String) {
        self.fileSystem = fileSystem
        self.path = path
    }

    func write(_ data: Data) throws {
        try lock.withLock {
            guard !isClosed else { throw FakeConsoleLogFileSystemError.closed }
            try fileSystem.append(data, to: path)
        }
    }

    func synchronize() throws {
        try lock.withLock {
            guard !isClosed else { throw FakeConsoleLogFileSystemError.closed }
            try fileSystem.synchronize(path: path)
        }
    }

    func close() throws {
        lock.withLock { isClosed = true }
    }
}

private enum FakeConsoleLogFileSystemError: Error {
    case missingFile
    case openFailed
    case writeFailed
    case synchronizeFailed
    case closed
}

/// A manually advanced wall and monotonic clock for console writer tests.
public final class ManualConsoleLogClock: ConsoleLogClock, @unchecked Sendable {
    private let lock = NSLock()
    private var wallTime: Date
    private var monotonicUptime: Duration

    public init(
        wallTime: Date = Date(timeIntervalSince1970: 1_790_000_000),
        monotonicUptime: Duration = .zero
    ) {
        self.wallTime = wallTime
        self.monotonicUptime = monotonicUptime
    }

    package func read() -> ConsoleLogClockReading {
        lock.withLock {
            ConsoleLogClockReading(wallTime: wallTime, monotonicUptime: monotonicUptime)
        }
    }

    /// Advances wall and monotonic time together.
    public func advance(by duration: Duration) {
        lock.withLock {
            let components = duration.components
            let interval =
                Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
            wallTime.addTimeInterval(interval)
            monotonicUptime += duration
        }
    }
}
