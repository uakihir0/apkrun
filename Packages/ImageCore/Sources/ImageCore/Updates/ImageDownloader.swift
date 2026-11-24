import CryptoKit
import Foundation

/// Downloads an image `.aar` over HTTPS (runtime-maintenance.md §4.4): resume
/// with `Range`/`If-Range`, hashing as bytes arrive, and the size/hash checks
/// that promote `.aar.partial` to `.aar`.
public actor ImageDownloader {
    /// The running download's state, for progress display.
    public struct Progress: Sendable {
        /// Bytes stored so far.
        public var received: Int64
        /// The archive's expected size.
        public var total: Int64
    }

    /// Free space under a path, in bytes (`nil` = unknown).
    private let freeSpace: @Sendable (URL) -> Int64?
    private let session: URLSession
    private var task: Task<URL, any Error>?

    /// Creates a downloader. `session` is normally a session whose
    /// configuration matches §4.4's network rules; tests hand in a stub via a
    /// custom protocol class.
    public init(
        session: URLSession = ImageDownloader.defaultSession(),
        freeSpace: @escaping @Sendable (URL) -> Int64? = ImageDownloader.diskFreeSpace
    ) {
        self.session = session
        self.freeSpace = freeSpace
    }

    /// Cancels the running download; the partial file stays for a later resume.
    public func cancel() {
        task?.cancel()
    }

    /// The path a candidate's archive lands in (`<version>.aar`).
    public static func archiveURL(in cacheDirectory: URL, for version: ImageVersion) -> URL {
        cacheDirectory.appendingPathComponent("\(version.description).aar")
    }

    /// True while a partial file for `version` exists.
    public static func partialURL(in cacheDirectory: URL, for version: ImageVersion) -> URL {
        cacheDirectory.appendingPathComponent("\(version.description).aar.partial")
    }

    /// Downloads `candidate`'s archive into `cacheDirectory` and returns the
    /// finished `.aar` URL. `expandedSize` drives the §4.4 space check;
    /// `expensiveAllowed` is the user-initiated network exception.
    public func download(
        _ candidate: ImageCandidate,
        into cacheDirectory: URL,
        expensiveAllowed: Bool = false,
        progress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) async throws(ImageFailure) -> URL {
        guard let location = candidate.archiveLocation,
            let url = URL(string: location), url.scheme == "https"
        else {
            throw .imageDownloadFailed(detail: "archive location is not an https URL")
        }
        let expected = candidate.archiveSize ?? 0
        let expanded = candidate.expandedSize ?? 0
        // §4.4: archive + installed tree + a 10 GiB margin.
        let needed = expected + expanded + 10 * 1_073_741_824
        if let available = freeSpace(cacheDirectory), available < needed {
            throw .insufficientSpace(required: needed, available: available)
        }

        let work = Task { () throws -> URL in
            try await self.performDownload(
                url: url,
                expected: expected,
                expectedSHA256: candidate.archiveSHA256,
                into: cacheDirectory,
                version: candidate.version,
                expensiveAllowed: expensiveAllowed,
                progress: progress
            )
        }
        task = work
        defer { task = nil }
        do {
            return try await work.value
        } catch let failure as ImageFailure {
            throw failure
        } catch is CancellationError {
            throw .imageDownloadFailed(detail: "cancelled")
        } catch {
            throw .imageDownloadFailed(detail: error.localizedDescription)
        }
    }

    private struct ActiveDownload {
        var handle: FileHandle
        var hasher = SHA256()
        var received: Int64 = 0
    }

    private func performDownload(
        url: URL,
        expected: Int64,
        expectedSHA256: String?,
        into cacheDirectory: URL,
        version: ImageVersion,
        expensiveAllowed: Bool,
        progress: @Sendable (Progress) -> Void
    ) async throws -> URL {
        let partial = Self.partialURL(in: cacheDirectory, for: version)
        let final = Self.archiveURL(in: cacheDirectory, for: version)
        let etagFile = partial.appendingPathExtension("etag")
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        var resumeFrom: Int64 = 0
        var active = try openPartial(partial)

        // Resume needs the partial's hash state, so re-hash it (§4.4).
        if active.received > 0 {
            var hasher = SHA256()
            try FileHandle(forReadingFrom: partial).readChunks { chunk in
                hasher.update(data: chunk)
            }
            resumeFrom = active.received
            active.hasher = hasher
        }

        var request = URLRequest(url: url)
        request.networkServiceType = .background
        request.allowsExpensiveNetworkAccess = expensiveAllowed
        request.allowsConstrainedNetworkAccess = expensiveAllowed
        if resumeFrom > 0 {
            request.setValue("bytes=\(resumeFrom)-", forHTTPHeaderField: "Range")
            if let etag = try? String(contentsOf: etagFile, encoding: .utf8) {
                request.setValue(
                    etag.trimmingCharacters(in: .whitespacesAndNewlines),
                    forHTTPHeaderField: "If-Range")
            }
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ImageFailure.imageDownloadFailed(detail: "not an HTTP response")
        }
        switch http.statusCode {
        case 200:
            // The server ignored Range (or refused If-Range): restart from zero.
            if resumeFrom > 0 {
                try active.handle.truncate(atOffset: 0)
                try active.handle.seek(toOffset: 0)
                active = ActiveDownload(handle: active.handle)
            }
        case 206:
            break
        default:
            throw ImageFailure.imageDownloadFailed(detail: "archive status \(http.statusCode)")
        }

        if let etag = http.value(forHTTPHeaderField: "ETag") {
            try? Data(etag.utf8).write(to: etagFile)
        }

        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= (1 << 16) {
                try writeChunk(&buffer, into: &active)
                if expected > 0, resumeFrom + active.received > expected {
                    throw ImageFailure.imageArchiveSizeMismatch(
                        expected: expected, received: resumeFrom + active.received
                    )
                }
                progress(Progress(received: resumeFrom + active.received, total: expected))
            }
        }
        try writeChunk(&buffer, into: &active)

        let received = resumeFrom + active.received
        if expected > 0, received != expected {
            throw ImageFailure.imageArchiveSizeMismatch(expected: expected, received: received)
        }
        let digest = Data(active.hasher.finalize())
        if let expectedSHA256 {
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            guard hex == expectedSHA256.lowercased() else {
                throw ImageFailure.imageArchiveHashMismatch
            }
        }
        try active.handle.close()
        try FileManager.default.moveItem(at: partial, to: final)
        try? FileManager.default.removeItem(at: etagFile)
        return final
    }

    private func openPartial(_ partial: URL) throws -> ActiveDownload {
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        let handle = try FileHandle(forUpdating: partial)
        let size = try handle.seekToEnd()
        return ActiveDownload(handle: handle, received: Int64(size))
    }

    private func writeChunk(_ buffer: inout Data, into active: inout ActiveDownload) throws {
        guard !buffer.isEmpty else { return }
        try active.handle.write(contentsOf: buffer)
        active.hasher.update(data: buffer)
        active.received += Int64(buffer.count)
        buffer.removeAll(keepingCapacity: true)
    }

    /// The default download session (§4.4 network rules).
    public static func defaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        return URLSession(configuration: configuration)
    }

    /// Free space of the volume containing `url`, in bytes.
    public static func diskFreeSpace(_ url: URL) -> Int64? {
        guard
            let values = try? url.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ),
            let capacity = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return Int64(capacity)
    }
}

extension FileHandle {
    /// Reads the file in 1 MiB chunks from the start, passing each to `body`.
    fileprivate func readChunks(_ body: (Data) throws -> Void) throws {
        try seek(toOffset: 0)
        while true {
            let chunk = try read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { return }
            try body(chunk)
        }
    }
}
