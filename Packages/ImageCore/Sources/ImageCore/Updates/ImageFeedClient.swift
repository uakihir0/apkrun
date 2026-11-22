import Foundation

/// Fetches and validates `feed.json` (runtime-image-manifest.md §9): HTTPS only,
/// size caps, conditional GET, signature before parse, replay protection, and
/// expiry. Verified bytes and the ETag persist in a cache file so a replayed or
/// mutated feed never replaces an accepted one.
public actor ImageFeedClient {
    /// One feed check's outcome.
    public enum Outcome: Sendable {
        /// The server answered 304: the accepted feed still stands.
        case notModified
        /// A new feed passed every check and became the accepted one.
        case feed(ImageFeed)
    }

    /// Persisted acceptance state: the validator state across restarts.
    private struct Cache: Codable {
        /// The last `ETag` the server sent for `feed.json`.
        var etag: String?
        /// The highest accepted `sequence` (rule 5).
        var sequence: Int
        /// The bytes that produced `sequence`, for rule 5's equality check.
        var feed: Data
    }

    /// `feed.json` is at most 1 MiB (§9.4).
    private static let feedLimit = 1_048_576
    /// `feed.json.sig` is a few hundred bytes; 4 KiB is generous (§9.4).
    private static let signatureLimit = 4_096

    private let feedURL: URL
    private let signatureURL: URL
    private let channel: String
    private let trust: ImageTrustStore
    private let cacheFile: URL
    private let session: URLSession
    private let now: () -> Date

    /// Creates a client. `baseURL` is `https://<host>/apkrun/images/<channel>/`;
    /// `cacheFile` is where the accepted feed and its ETag persist.
    public init(
        baseURL: URL,
        channel: String,
        trust: ImageTrustStore,
        cacheFile: URL,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        feedURL = baseURL.appendingPathComponent("feed.json")
        signatureURL = baseURL.appendingPathComponent("feed.json.sig")
        self.channel = channel
        self.trust = trust
        self.cacheFile = cacheFile
        self.session = session
        self.now = now
    }

    /// Checks the feed once. Throws `ImageFailure` for every rejection
    /// (§9.4); the previous accepted feed is never touched by a bad answer.
    public func fetch() async throws(ImageFailure) -> Outcome {
        guard feedURL.scheme == "https" else {
            throw .imageFeedInvalid(detail: "feed URL is not https")
        }
        let cached = loadCache()
        var request = URLRequest(url: feedURL)
        if let etag = cached?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let (body, response) = try await get(request, limit: Self.feedLimit, what: "feed")
        if response.statusCode == 304 {
            // A cached feed still has to validate: an expired one is not a
            // usable answer, and a still-valid one is re-evaluated so
            // candidate selection sees context changes (§9.4).
            guard let cached else { return .notModified }
            let cachedFeed = try ImageFeed.parse(cached.feed)
            guard cachedFeed.expiresAt > now() else {
                throw .imageFeedExpired
            }
            return .feed(cachedFeed)
        }
        guard response.statusCode == 200 else {
            throw .imageDownloadFailed(detail: "feed status \(response.statusCode)")
        }

        let (signature, signatureResponse) = try await get(
            URLRequest(url: signatureURL), limit: Self.signatureLimit, what: "signature"
        )
        guard signatureResponse.statusCode == 200 else {
            throw .imageDownloadFailed(detail: "signature status \(signatureResponse.statusCode)")
        }

        // Verify before parse (§9.1): an unsigned or wrongly signed feed is
        // `imageFeedSignatureInvalid` whatever its contents look like.
        do {
            _ = try ImageSignature.verify(message: body, signatureFile: signature, trust: trust)
        } catch {
            throw .imageFeedSignatureInvalid
        }
        let feed = try ImageFeed.parse(body)
        guard feed.channel == channel else {
            throw .imageFeedInvalid(detail: "channel \(feed.channel) served for \(channel)")
        }
        guard feed.expiresAt > now() else {
            throw .imageFeedExpired
        }
        if let cached {
            if feed.sequence < cached.sequence {
                throw .imageFeedReplayed(sequence: feed.sequence, highest: cached.sequence)
            }
            if feed.sequence == cached.sequence, body != cached.feed {
                throw .imageFeedInvalid(detail: "sequence \(feed.sequence) reused with new bytes")
            }
        }

        var next = cached ?? Cache(etag: nil, sequence: 0, feed: Data())
        next.etag = response.value(forHTTPHeaderField: "ETag")
        next.sequence = feed.sequence
        next.feed = body
        saveCache(next)
        return .feed(feed)
    }

    private func get(
        _ request: URLRequest, limit: Int, what: String
    ) async throws(ImageFailure) -> (Data, HTTPURLResponse) {
        let result: (URLSession.AsyncBytes, URLResponse)
        do {
            result = try await session.bytes(for: request)
        } catch {
            throw .imageDownloadFailed(detail: "\(what): \(error.localizedDescription)")
        }
        guard let http = result.1 as? HTTPURLResponse else {
            throw .imageDownloadFailed(detail: "\(what): not an HTTP response")
        }
        if http.expectedContentLength > Int64(limit) {
            throw .imageFeedInvalid(detail: "\(what) larger than \(limit) bytes")
        }
        // The limit applies while the body streams in: a source that sends
        // more than `limit` bytes is cut off before it fills memory.
        var body = Data()
        body.reserveCapacity(min(limit, 1 << 16))
        do {
            for try await byte in result.0 {
                body.append(byte)
                if body.count > limit {
                    throw ImageFailure.imageFeedInvalid(
                        detail: "\(what) larger than \(limit) bytes")
                }
            }
        } catch let failure as ImageFailure {
            throw failure
        } catch {
            throw .imageDownloadFailed(detail: "\(what): \(error.localizedDescription)")
        }
        return (body, http)
    }

    private func loadCache() -> Cache? {
        guard let data = try? Data(contentsOf: cacheFile) else { return nil }
        return try? JSONDecoder().decode(Cache.self, from: data)
    }

    private func saveCache(_ cache: Cache) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(
            at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: cacheFile, options: .atomic)
    }
}
