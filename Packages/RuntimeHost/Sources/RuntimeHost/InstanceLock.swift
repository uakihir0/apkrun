import Darwin
import DiagnosticsCore
import Foundation

// UNCHECKED-SENDABLE: the descriptor is immutable while open and its lifetime is protected by lock.
/// Holds the process-wide lock for one APKRun data root.
public final class InstanceLock: @unchecked Sendable {
    private let lock = NSLock()
    private var fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    /// Acquires `Runtime/instance.lock` without waiting for another owner.
    ///
    /// - Parameters:
    ///   - paths: The resolved per-user APKRun paths.
    ///   - owner: The process identity written into the lock file.
    ///   - processID: The owning process ID, defaulting to the current process.
    ///   - executablePath: The binary path recorded for diagnostics.
    public static func acquire(
        paths: APKRunPaths,
        owner: InstanceLockOwner,
        processID: Int32 = getpid(),
        executablePath: String = CommandLine.arguments.first ?? ""
    ) throws(RuntimeFailure) -> InstanceLock {
        do {
            try FileManager.default.createDirectory(
                at: paths.runtimeDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw lockFailure(for: error)
        }

        let descriptor = open(
            paths.instanceLockFile.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw systemFailure(errno)
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            let currentOwner = readOwner(from: descriptor)
            Darwin.close(descriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                throw .instanceLocked(owner: currentOwner)
            }
            throw systemFailure(lockError)
        }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            let metadataError = errno
            Darwin.close(descriptor)
            throw systemFailure(metadataError)
        }
        guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            Darwin.close(descriptor)
            throw systemFailure(EINVAL)
        }
        guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            let permissionError = errno
            Darwin.close(descriptor)
            throw systemFailure(permissionError)
        }

        let record = InstanceLockRecord(
            owner: owner.lockFileValue,
            pid: processID,
            binaryPath: executablePath
        )
        do {
            try write(record, to: descriptor)
        } catch let failure {
            Darwin.close(descriptor)
            throw failure
        }

        return InstanceLock(fileDescriptor: descriptor)
    }

    /// Releases the lock. Repeated calls are safe.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard fileDescriptor >= 0 else { return }
        _ = Darwin.close(fileDescriptor)
        fileDescriptor = -1
    }

    deinit {
        close()
    }

    private static func write(
        _ record: InstanceLockRecord,
        to descriptor: Int32
    ) throws(RuntimeFailure) {
        let data: Data
        do {
            data = try JSONEncoder().encode(record)
        } catch {
            throw lockFailure(for: error)
        }

        guard ftruncate(descriptor, 0) == 0 else {
            throw systemFailure(errno)
        }
        do {
            try data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else {
                    throw systemFailure(EIO)
                }
                var offset = 0
                while offset < buffer.count {
                    let written = pwrite(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        buffer.count - offset,
                        off_t(offset)
                    )
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw systemFailure(errno)
                    }
                    guard written > 0 else {
                        throw systemFailure(EIO)
                    }
                    offset += written
                }
            }
        } catch let failure as RuntimeFailure {
            throw failure
        } catch {
            throw lockFailure(for: error)
        }
    }

    private static func readOwner(from descriptor: Int32) -> InstanceLockOwner {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { return .unknown }
        let length = Int(min(max(metadata.st_size, 0), 4 * 1_024))
        guard length > 0 else { return .unknown }

        var bytes = [UInt8](repeating: 0, count: length)
        let count = bytes.withUnsafeMutableBytes { buffer in
            pread(descriptor, buffer.baseAddress, buffer.count, 0)
        }
        guard count > 0 else { return .unknown }
        let data = Data(bytes.prefix(count))
        guard
            let record = try? JSONDecoder().decode(InstanceLockRecord.self, from: data)
        else {
            return .unknown
        }
        return InstanceLockOwner(lockFileValue: record.owner)
    }

    private static func lockFailure(for error: any Error) -> RuntimeFailure {
        let error = error as NSError
        return .instanceLockFailed(
            underlying: UnderlyingError(domain: error.domain, code: error.code)
        )
    }

    private static func systemFailure(_ code: Int32) -> RuntimeFailure {
        .instanceLockFailed(
            underlying: UnderlyingError(domain: NSPOSIXErrorDomain, code: Int(code))
        )
    }
}

private struct InstanceLockRecord: Codable {
    let owner: String
    let pid: Int32
    let binaryPath: String
}
