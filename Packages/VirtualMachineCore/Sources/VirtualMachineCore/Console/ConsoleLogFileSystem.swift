import Darwin
import Foundation

package protocol ConsoleLogFileHandle: Sendable {
    func write(_ data: Data) throws
    func synchronize() throws
    func close() throws
}

package protocol ConsoleLogFileSystem: Sendable {
    func createDirectory(at url: URL, permissions: UInt16) throws
    func openForAppend(at url: URL, permissions: UInt16) throws -> any ConsoleLogFileHandle
    func fileSize(at url: URL) throws -> UInt64?
    func moveItem(from source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
    func contentsOfDirectory(at url: URL) throws -> [URL]
}

package struct SystemConsoleLogFileSystem: ConsoleLogFileSystem {
    package init() {}

    package func createDirectory(at url: URL, permissions: UInt16) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: permissions)]
        )
        guard chmod(url.path, mode_t(permissions)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    package func openForAppend(
        at url: URL,
        permissions: UInt16
    ) throws -> any ConsoleLogFileHandle {
        let descriptor = url.path.withCString {
            Darwin.open(
                $0,
                O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
                mode_t(permissions)
            )
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard fchmod(descriptor, mode_t(permissions)) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            _ = Darwin.close(descriptor)
            throw error
        }
        return SystemConsoleLogFileHandle(descriptor: descriptor)
    }

    package func fileSize(at url: URL) throws -> UInt64? {
        var information = stat()
        let result = url.path.withCString { lstat($0, &information) }
        guard result == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (information.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw POSIXError(.EINVAL)
        }
        return UInt64(information.st_size)
    }

    package func moveItem(from source: URL, to destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    package func removeItem(at url: URL) throws {
        let result = url.path.withCString { unlink($0) }
        guard result == 0 || errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    package func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    }
}

// UNCHECKED-SENDABLE: the lock serializes writes, fsync, and close on the file descriptor.
private final class SystemConsoleLogFileHandle: ConsoleLogFileHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func write(_ data: Data) throws {
        try lock.withLock {
            guard descriptor >= 0 else {
                throw POSIXError(.EBADF)
            }
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var written = 0
                while written < rawBuffer.count {
                    let result = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: written),
                        rawBuffer.count - written
                    )
                    if result < 0 {
                        if errno == EINTR {
                            continue
                        }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    written += result
                }
            }
        }
    }

    func synchronize() throws {
        try lock.withLock {
            guard descriptor >= 0 else {
                throw POSIXError(.EBADF)
            }
            guard fsync(descriptor) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    func close() throws {
        try lock.withLock {
            guard descriptor >= 0 else { return }
            let descriptorToClose = descriptor
            descriptor = -1
            guard Darwin.close(descriptorToClose) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    deinit {
        try? close()
    }
}
