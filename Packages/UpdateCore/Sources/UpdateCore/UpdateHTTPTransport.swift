import APKStoreCore
import CryptoKit
import Foundation

/// `GET` through `URLSession` (update-system.md §3.4, §4.1).
///
/// The session follows the shared rules: `waitsForConnectivity`, a 30 s
/// request timeout, at most 4 connections per host, the system proxy, and
/// redirects only to `https` URLs (debug builds also accept loopback HTTP),
/// at most 5.
public struct URLSessionUpdateHTTPClient: UpdateHTTPClient {
    /// The session carrying the §3.4 configuration.
    private let session: URLSession

    /// Creates a client with the §3.4 session configuration.
    public init() {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(
            configuration: configuration,
            delegate: RedirectPolicy(),
            delegateQueue: nil)
    }

    /// Redirect destinations the shared session accepts: `https`, or loopback
    /// `http` in debug builds (direct-provider-manifest.md §5.1).
    static func allowsRedirect(to url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" { return true }
        #if DEBUG
            if scheme == "http",
                let host = url.host?.lowercased(),
                host == "127.0.0.1" || host == "localhost"
            {
                return true
            }
        #endif
        return false
    }

    /// Performs a GET request, streaming the body so at most `byteLimit` + 1
    /// bytes are buffered — a larger body is truncated and the caller's size
    /// check rejects it without the daemon buffering the whole response.
    public func get(_ url: URL, headers: [String: String], byteLimit: Int64?) async throws(UpdateFailure)
        -> HTTPResponse
    {
        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw UpdateFailure.providerUnreachable(reason: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UpdateFailure.providerUnreachable(reason: "not an HTTP response")
        }
        var body = Data()
        let cap = byteLimit.map { Int($0) + 1 }
        do {
            for try await byte in bytes {
                if let cap, body.count >= cap { break }
                body.append(byte)
            }
        } catch {
            throw UpdateFailure.providerUnreachable(reason: error.localizedDescription)
        }
        return HTTPResponse(
            status: http.statusCode,
            body: body,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            finalURL: http.url,
            retryAfter: Self.retryAfter(of: http))
    }

    /// Streams a GET request into `file`, hashing while bytes arrive.
    public func download(
        _ url: URL,
        headers: [String: String],
        into file: URL,
        byteLimit: Int64?
    ) async throws(UpdateFailure) -> DownloadResponse {
        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw UpdateFailure.providerUnreachable(reason: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UpdateFailure.providerUnreachable(reason: "not an HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            return DownloadResponse(
                status: http.statusCode,
                bytesWritten: 0,
                finalURL: http.url,
                retryAfter: Self.retryAfter(of: http))
        }
        let handle: FileHandle
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file.path, contents: nil)
            handle = try FileHandle(forWritingTo: file)
        } catch {
            throw UpdateFailure.downloadFailed(reason: error.localizedDescription)
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        var written: Int64 = 0
        var limitHit = false
        do {
            var buffer = Data()
            buffer.reserveCapacity(65_536)
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 65_536 {
                    try flush(
                        &buffer, into: handle, hasher: &hasher, written: &written,
                        limit: byteLimit, limitHit: &limitHit)
                    if limitHit { break }
                }
            }
            if !limitHit {
                try flush(
                    &buffer, into: handle, hasher: &hasher, written: &written,
                    limit: byteLimit, limitHit: &limitHit)
            }
        } catch let error as UpdateFailure {
            throw error
        } catch {
            throw UpdateFailure.downloadFailed(reason: error.localizedDescription)
        }
        return DownloadResponse(
            status: http.statusCode,
            bytesWritten: written,
            sha256: SHA256Digest(
                hex: hasher.finalize().map { String(format: "%02x", $0) }.joined()),
            limitHit: limitHit,
            finalURL: http.url,
            retryAfter: Self.retryAfter(of: http))
    }

    /// Writes `buffer` up to the byte limit and clears it.
    private func flush(
        _ buffer: inout Data,
        into handle: FileHandle,
        hasher: inout SHA256,
        written: inout Int64,
        limit: Int64?,
        limitHit: inout Bool
    ) throws(UpdateFailure) {
        var chunk = buffer
        if let limit, written + Int64(chunk.count) > limit {
            chunk = chunk.prefix(Int(limit - written))
            limitHit = true
        }
        buffer.removeAll(keepingCapacity: true)
        guard !chunk.isEmpty else { return }
        do {
            try handle.write(contentsOf: chunk)
        } catch {
            throw UpdateFailure.downloadFailed(reason: error.localizedDescription)
        }
        hasher.update(data: chunk)
        written += Int64(chunk.count)
    }

    /// The `Retry-After` header in seconds (delta-seconds or HTTP-date).
    static func retryAfter(of response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(raw) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: raw).map { max(0, $0.timeIntervalSinceNow) }
    }

    /// Refuses redirects to non-allowed URLs and caps hops at 5
    /// (direct-provider-manifest.md §5.1).
    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        /// Redirect hops per task identifier.
        private var hops: [Int: Int] = [:]
        private let lock = NSLock()

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            lock.lock()
            let hop = (hops[task.taskIdentifier] ?? 0) + 1
            hops[task.taskIdentifier] = hop
            lock.unlock()
            guard hop <= 5,
                let url = request.url,
                URLSessionUpdateHTTPClient.allowsRedirect(to: url)
            else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: (any Error)?
        ) {
            lock.lock()
            hops[task.taskIdentifier] = nil
            lock.unlock()
        }
    }
}
