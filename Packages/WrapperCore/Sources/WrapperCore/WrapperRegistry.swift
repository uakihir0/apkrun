import Darwin
import Dispatch
import Foundation

/// Reads and atomically writes the wrapper authorization registry.
///
/// The registry actor serializes access, while file operations run on its private serial queue so
/// they do not block an actor executor. apkrund is the only production writer.
public actor WrapperRegistry {
    /// A registry read or write failure.
    public typealias Failure = WrapperRegistryFile.Failure

    private static let maximumFileBytes = 4 * 1024 * 1024

    private let fileURL: URL
    private let ioQueue: DispatchQueue

    /// Creates a registry owner for the supplied registry file.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        ioQueue = DispatchQueue(label: "io.apkrun.wrapper.registry")
    }

    /// Reads the registry, returning an empty registry when it has not been created yet.
    ///
    /// An unreadable or malformed file throws, so callers cannot authorize a wrapper from partial
    /// or corrupt data.
    public func read() async throws(Failure) -> WrapperRegistryFile {
        let fileURL = self.fileURL
        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<Result<WrapperRegistryFile, Failure>, Never>) in
            ioQueue.async {
                do {
                    continuation.resume(returning: .success(try Self.readFile(at: fileURL)))
                } catch let failure as Failure {
                    continuation.resume(returning: .failure(failure))
                } catch {
                    continuation.resume(returning: .failure(Self.ioFailure(error)))
                }
            }
        }
        return try result.get()
    }

    /// Writes a canonical registry with expired denial entries removed.
    public func write(_ registry: WrapperRegistryFile, now: Date = Date()) async throws(Failure) {
        let fileURL = self.fileURL
        let ioQueue = self.ioQueue
        let currentFile = try WrapperRegistryFile(
            wrappers: registry.wrappers,
            denied: registry.denied.filter { $0.until > now }
        )
        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<Result<Void, Failure>, Never>) in
            ioQueue.async {
                do {
                    try Self.writeFile(currentFile, to: fileURL)
                    continuation.resume(returning: .success(()))
                } catch let failure as Failure {
                    continuation.resume(returning: .failure(failure))
                } catch {
                    continuation.resume(returning: .failure(Self.ioFailure(error)))
                }
            }
        }
        try result.get()
    }

    private static func readFile(at fileURL: URL) throws(Failure) -> WrapperRegistryFile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return try WrapperRegistryFile()
        }

        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer {
                // Closing a read-only handle during cleanup does not change authorization state.
                try? handle.close()
            }
            var contents = Data()
            while contents.count <= maximumFileBytes {
                let remainingLimit = maximumFileBytes + 1 - contents.count
                guard let chunk = try handle.read(upToCount: min(64 * 1024, remainingLimit)), !chunk.isEmpty else {
                    break
                }
                contents.append(chunk)
            }
            guard contents.count <= maximumFileBytes else {
                throw Failure.fileTooLarge
            }
            data = contents
        } catch let failure as Failure {
            throw failure
        } catch {
            throw ioFailure(error)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = parseISO8601Date(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Registry dates must be ISO 8601 UTC timestamps."
                )
            }
            return date
        }
        do {
            return try decoder.decode(WrapperRegistryFile.self, from: data)
        } catch let failure as Failure {
            if case .invalidDocument = failure {
                try preserveCorruptFile(at: fileURL)
            }
            throw failure
        } catch {
            try preserveCorruptFile(at: fileURL)
            throw .invalidDocument
        }
    }

    private static func preserveCorruptFile(at fileURL: URL) throws(Failure) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let backupURL = fileURL.deletingLastPathComponent().appendingPathComponent(
            "\(fileURL.lastPathComponent).corrupt-\(timestamp)-\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
        let result = fileURL.withUnsafeFileSystemRepresentation { sourcePath in
            backupURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else {
                    return EINVAL
                }
                return Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw posixFailure()
        }

        let directoryURL = fileURL.deletingLastPathComponent()
        let directoryDescriptor = directoryURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard directoryDescriptor >= 0 else {
            throw posixFailure()
        }
        let syncResult = Darwin.fsync(directoryDescriptor)
        let syncError = errno
        _ = Darwin.close(directoryDescriptor)
        guard syncResult == 0 else {
            throw posixFailure(code: syncError)
        }
    }

    private static func writeFile(_ registry: WrapperRegistryFile, to fileURL: URL) throws(Failure) {
        try registry.validateForWriting()
        let data = try encode(registry)
        guard data.count <= maximumFileBytes else {
            throw .fileTooLarge
        }

        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw ioFailure(error)
        }

        let temporaryURL = directoryURL.appendingPathComponent(
            ".registry-\(UUID().uuidString.lowercased()).tmp",
            isDirectory: false
        )
        let descriptor = temporaryURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR))
        }
        guard descriptor >= 0 else {
            throw posixFailure()
        }

        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw ioFailure(error)
        }

        let renameResult = temporaryURL.withUnsafeFileSystemRepresentation { temporaryPath in
            fileURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let temporaryPath, let destinationPath else {
                    return EINVAL
                }
                return Darwin.rename(temporaryPath, destinationPath)
            }
        }
        guard renameResult == 0 else {
            let failure = posixFailure()
            try? FileManager.default.removeItem(at: temporaryURL)
            throw failure
        }

        let directoryDescriptor = directoryURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard directoryDescriptor >= 0 else {
            throw posixFailure()
        }
        let syncResult = Darwin.fsync(directoryDescriptor)
        let syncError = errno
        _ = Darwin.close(directoryDescriptor)
        guard syncResult == 0 else {
            throw posixFailure(code: syncError)
        }
    }

    private static func encode(_ registry: WrapperRegistryFile) throws(Failure) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatISO8601Date(date))
        }
        do {
            var data = try encoder.encode(registry)
            data.append(0x0A)
            return data
        } catch {
            throw .invalidDocument
        }
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        guard hasUTCDateShape(value) else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        let baseDate: String
        let fractionalDigits: Substring?
        if let decimalIndex = value.firstIndex(of: ".") {
            baseDate = String(value[..<decimalIndex]) + "Z"
            fractionalDigits = value[value.index(after: decimalIndex)..<value.index(before: value.endIndex)]
        } else {
            baseDate = value
            fractionalDigits = nil
        }
        guard let date = formatter.date(from: baseDate) else {
            return nil
        }
        guard let fractionalDigits else {
            return date
        }
        guard let fraction = Double("0." + fractionalDigits) else {
            return nil
        }
        return date.addingTimeInterval(fraction)
    }

    private static func hasUTCDateShape(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 20 || (22...30).contains(bytes.count) else {
            return false
        }
        guard
            bytes[4] == 45,
            bytes[7] == 45,
            bytes[10] == 84,
            bytes[13] == 58,
            bytes[16] == 58,
            bytes[bytes.count - 1] == 90,
            bytes[0..<4].allSatisfy(isASCIIDigit),
            bytes[5..<7].allSatisfy(isASCIIDigit),
            bytes[8..<10].allSatisfy(isASCIIDigit),
            bytes[11..<13].allSatisfy(isASCIIDigit),
            bytes[14..<16].allSatisfy(isASCIIDigit),
            bytes[17..<19].allSatisfy(isASCIIDigit)
        else {
            return false
        }
        guard bytes.count > 20 else {
            return true
        }
        return bytes[19] == 46 && bytes[20..<(bytes.count - 1)].allSatisfy(isASCIIDigit)
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }

    private static func formatISO8601Date(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func ioFailure(_ error: any Error) -> Failure {
        let nsError = error as NSError
        return .ioFailure(domain: nsError.domain, code: nsError.code)
    }

    private static func posixFailure(code: Int32 = errno) -> Failure {
        .ioFailure(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
