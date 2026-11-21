import CryptoKit
import Foundation
import RuntimeAPI
import UpdateCore

/// The `selfUpdate` object persisted inside the root `state.json`
/// (runtime-maintenance.md §9, schema 1). Losing it costs at most one extra
/// check and one repeated notification.
public struct SelfUpdateProbeState: Codable, Equatable, Sendable {
    /// When the last check finished (any result).
    public var lastCheckedAt: Date?
    /// The appcast's `ETag` for conditional GETs.
    public var etag: String?
    /// The appcast's `Last-Modified` for conditional GETs.
    public var lastModified: String?
    /// Build numbers the user was already notified about.
    public var notifiedBuilds: [Int]
    /// When the last critical-update notification went out.
    public var criticalNotifiedAt: Date?

    /// Creates an empty probe state.
    public init() {
        lastCheckedAt = nil
        etag = nil
        lastModified = nil
        notifiedBuilds = []
        criticalNotifiedAt = nil
    }
}

/// One `<item>` of a Sparkle appcast (runtime-maintenance.md §3.3).
public struct AppcastItem: Equatable, Sendable {
    /// `sparkle:shortVersionString` (marketing version), or `sparkle:version`.
    public var version: String = ""
    /// `sparkle:version` (the build number).
    public var build: Int = 0
    /// `sparkle:channel`, when declared.
    public var channel: String?
    /// `sparkle:minimumSystemVersion`, when declared.
    public var minimumSystemVersion: String?
    /// `sparkle:releaseNotesLink`, when declared.
    public var releaseNotesURL: String?
    /// `pubDate`, when parseable.
    public var publishedAt: Date?
    /// `sparkle:phasedRolloutInterval` in seconds; 0 means not phased.
    public var phasedRolloutInterval: Int = 0
    /// Whether the item carries `sparkle:criticalUpdate`.
    public var isCritical: Bool = false

    /// The `AvailableRelease` this item selects into (runtime-api.md §12.2).
    public var release: AvailableRelease {
        AvailableRelease(
            version: version,
            build: build,
            channel: channel,
            minimumSystemVersion: minimumSystemVersion,
            releaseNotesURL: releaseNotesURL,
            publishedAt: publishedAt)
    }
}

/// Parses a Sparkle appcast with `XMLParser` (runtime-maintenance.md §3.4).
/// Values may appear as item elements or as attributes of `<enclosure>`;
/// both spellings are accepted.
public final class AppcastParser: NSObject, XMLParserDelegate {
    /// Namespace prefix Sparkle uses.
    private static let sparkle = "sparkle:"
    private var items: [AppcastItem] = []
    private var current: AppcastItem?
    private var text = ""
    private var insideItem = false
    private var failed = false

    /// The parsed items, in document order.
    public var parsedItems: [AppcastItem] { items }

    /// Parses `data`; malformed XML returns an empty list so callers report
    /// `selfUpdateFeedInvalid` rather than crash on a hostile feed.
    public static func parse(_ data: Data) -> [AppcastItem] {
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        return delegate.parsedItems
    }

    /// Tracks the current `<item>`'s text and element stack.
    public func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        text = ""
        switch elementName {
        case "item":
            insideItem = true
            current = AppcastItem()
        case "enclosure" where insideItem:
            // sparkle:* attributes ride on the enclosure in generate_appcast
            // output; element spellings fill anything still missing.
            var item = current ?? AppcastItem()
            if item.build == 0, let build = Self.int(attributeDict[Self.sparkle + "version"]) {
                item.build = build
            }
            if item.version.isEmpty, let version = attributeDict[Self.sparkle + "shortVersionString"] {
                item.version = version
            }
            if item.releaseNotesURL == nil, let notes = attributeDict[Self.sparkle + "releaseNotesLink"] {
                item.releaseNotesURL = notes
            }
            if item.minimumSystemVersion == nil {
                item.minimumSystemVersion = attributeDict[Self.sparkle + "minimumSystemVersion"]
            }
            if item.channel == nil {
                item.channel = attributeDict[Self.sparkle + "channel"]
            }
            current = item
        case Self.sparkle + "criticalUpdate" where insideItem:
            var item = current ?? AppcastItem()
            item.isCritical = true
            current = item
        default:
            break
        }
    }

    /// Accumulates element text while inside an `<item>`.
    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideItem { text += string }
    }

    /// CDATA sections carry the release-notes HTML; same accumulation.
    public func parser(_ parser: XMLParser, foundCDATA cdataBlock: Data) {
        if insideItem, let string = String(data: cdataBlock, encoding: .utf8) {
            text += string
        }
    }

    /// Reads the finished element's fields into the pending item.
    public func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard insideItem, var item = current else {
            if elementName == "item" { insideItem = false }
            return
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "item":
            items.append(item)
            current = nil
            insideItem = false
        case "title":
            if item.version.isEmpty { item.version = Self.version(from: value) }
        case "pubDate":
            item.publishedAt = Self.pubDate(value)
        case Self.sparkle + "version":
            if let build = Self.int(value) { item.build = build }
        case Self.sparkle + "shortVersionString":
            if !value.isEmpty { item.version = value }
        case Self.sparkle + "minimumSystemVersion":
            if !value.isEmpty { item.minimumSystemVersion = value }
        case Self.sparkle + "releaseNotesLink":
            if !value.isEmpty { item.releaseNotesURL = value }
        case Self.sparkle + "channel":
            if !value.isEmpty { item.channel = value }
        case Self.sparkle + "phasedRolloutInterval":
            item.phasedRolloutInterval = Self.int(value) ?? 0
        default:
            break
        }
        if elementName != "item" { current = item }
    }

    /// Any parse error rejects the feed (§3.4).
    public func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
        failed = true
    }

    /// "APKRun 1.2.0" → "1.2.0"; keeps the raw title when it starts with a digit.
    private static func version(from title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.split(separator: " ").last else { return trimmed }
        let candidate = String(last)
        return candidate.first?.isNumber == true ? candidate : trimmed
    }

    private static func int(_ value: String?) -> Int? {
        value.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func pubDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.date(from: value)
    }
}

/// The probe's outcome for one feed item.
enum SelfUpdateProbeFailure: Error, Equatable {
    /// The appcast could not be fetched (network, non-2xx, oversize).
    case unreachable(detail: String)
    /// The appcast did not parse, or its signature did not verify.
    case invalid(detail: String)
}

/// The background appcast probe of runtime-maintenance.md §3.4.
///
/// Informational only: it never downloads or installs an update. It keeps the
/// newest acceptable item in `SelfUpdateStatus` and notifies once per version
/// while APKRun.app is not connected (Sparkle owns its own alert then).
public actor SelfUpdateProbe {
    /// The conditional-GET and response limits of §3.4.
    public static let bodyByteLimit: Int64 = 2 * 1024 * 1024

    /// A critical update is notified again after this interval (§3.4).
    public static let criticalRenotifyInterval: TimeInterval = 3 * 24 * 60 * 60

    /// Items under phased rollout stay invisible for this many intervals
    /// after `pubDate` (§3.4: `pubDate + 7 × phasedRolloutInterval`).
    static let phasedIntervals = 7

    private let feedURL: URL?
    private let http: any UpdateHTTPClient
    private let ownVersion: String
    private let ownBuild: Int
    private let allowedChannels: Set<String>
    private let requiresSignedFeed: Bool
    private let publicEDKey: String?
    private let userAgent: String
    private let now: @Sendable () -> Date
    private let persist: @Sendable (SelfUpdateProbeState) -> Void
    private let notify: @Sendable (AvailableRelease, Bool) -> Void
    private let appConnected: @Sendable () async -> Bool
    private var state: SelfUpdateProbeState
    private var latest: AvailableRelease?
    private var critical = false
    private var lastError: WireError?

    /// Creates a probe. `feedURL` is `nil` without `SUFeedURL` — checks then
    /// report `unreachable` instead of crashing debug builds.
    public init(
        feedURL: URL?,
        http: any UpdateHTTPClient,
        ownVersion: String,
        ownBuild: Int,
        allowedChannels: Set<String> = [],
        requiresSignedFeed: Bool = false,
        publicEDKey: String? = nil,
        userAgent: String? = nil,
        state: SelfUpdateProbeState = SelfUpdateProbeState(),
        now: @escaping @Sendable () -> Date = { Date() },
        persist: @escaping @Sendable (SelfUpdateProbeState) -> Void = { _ in },
        notify: @escaping @Sendable (AvailableRelease, Bool) -> Void = { _, _ in },
        appConnected: @escaping @Sendable () async -> Bool = { false },
        load: (@Sendable () async -> SelfUpdateProbeState)? = nil
    ) {
        self.feedURL = feedURL
        self.http = http
        self.ownVersion = ownVersion
        self.ownBuild = ownBuild
        self.allowedChannels = allowedChannels
        self.requiresSignedFeed = requiresSignedFeed
        self.publicEDKey = publicEDKey
        self.userAgent = userAgent ?? "APKRun/\(ownVersion)"
        self.state = state
        self.now = now
        self.persist = persist
        self.notify = notify
        self.appConnected = appConnected
        self.load = load
    }

    private let load: (@Sendable () async -> SelfUpdateProbeState)?
    private var didLoad = false

    /// The last known snapshot (`selfUpdateStatus`).
    public func status() -> SelfUpdateStatus {
        SelfUpdateStatus(
            currentVersion: ownVersion,
            currentBuild: ownBuild,
            latest: latest,
            critical: critical,
            lastCheckedAt: state.lastCheckedAt,
            lastError: lastError)
    }

    /// Runs one probe check (§3.4). `userInitiated` ignores phased rollout.
    @discardableResult
    public func check(userInitiated: Bool) async -> SelfUpdateStatus {
        if !didLoad {
            didLoad = true
            if let restored = await load?() {
                state = restored
            }
        }
        guard let feedURL else {
            return finish(error: .unreachable(detail: "no SUFeedURL configured"))
        }
        var headers = ["User-Agent": userAgent]
        if let etag = state.etag { headers["If-None-Match"] = etag }
        if let lastModified = state.lastModified { headers["If-Modified-Since"] = lastModified }
        let response: HTTPResponse
        do throws(UpdateFailure) {
            response = try await http.get(feedURL, headers: headers, byteLimit: Self.bodyByteLimit)
        } catch {
            return finish(error: .unreachable(detail: String(describing: error)))
        }
        if response.status == 304 {
            state.lastCheckedAt = now()
            persist(state)
            return status()
        }
        guard (200...299).contains(response.status) else {
            return finish(error: .unreachable(detail: "HTTP \(response.status)"))
        }
        guard response.body.count <= Self.bodyByteLimit else {
            return finish(error: .invalid(detail: "appcast exceeds the 2 MiB limit"))
        }
        if requiresSignedFeed {
            guard await verifySignature(of: response.body, feedURL: feedURL) else {
                return finish(error: .invalid(detail: "appcast signature invalid"))
            }
        }
        let items = AppcastParser.parse(response.body)
        guard !items.isEmpty else {
            return finish(error: .invalid(detail: "no usable appcast items"))
        }
        let chosen = SelfUpdateProbe.select(
            items,
            ownBuild: ownBuild,
            allowedChannels: allowedChannels,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersion,
            userInitiated: userInitiated,
            now: now())
        latest = chosen?.release
        critical = chosen?.isCritical ?? false
        state.lastCheckedAt = now()
        if let etag = response.etag { state.etag = etag }
        if let lastModified = response.lastModified { state.lastModified = lastModified }
        lastError = nil
        persist(state)
        await maybeNotify(chosen)
        return status()
    }

    /// Fetches `<feed>.sig` and verifies the EdDSA signature (§3.4).
    private func verifySignature(of body: Data, feedURL: URL) async -> Bool {
        guard let publicEDKey,
            let keyData = Data(base64Encoded: publicEDKey),
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else {
            return false
        }
        let signatureURL = feedURL.appendingPathExtension("sig")
        let signature: HTTPResponse
        do throws(UpdateFailure) {
            signature = try await http.get(signatureURL, headers: [:], byteLimit: 1024)
        } catch {
            return false
        }
        let signatureString = String(decoding: signature.body, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (200...299).contains(signature.status),
            let signatureData = Data(base64Encoded: signatureString)
        else {
            return false
        }
        return key.isValidSignature(signatureData, for: body)
    }

    /// Picks the highest acceptable item (§3.4): allowed channel, a
    /// `minimumSystemVersion` the host meets, a build newer than the running
    /// one, and not inside the phased window (unless critical or the check is
    /// user-initiated).
    static func select(
        _ items: [AppcastItem],
        ownBuild: Int,
        allowedChannels: Set<String>,
        macOSVersion: OperatingSystemVersion,
        userInitiated: Bool,
        now: Date
    ) -> AppcastItem? {
        items
            .filter { item in
                guard item.build > ownBuild else { return false }
                if let channel = item.channel, !channel.isEmpty, channel != "stable" {
                    guard allowedChannels.contains(channel) else { return false }
                }
                if let minimum = item.minimumSystemVersion,
                    Self.compare(macOSVersion, to: minimum) == .orderedAscending
                {
                    return false
                }
                if !userInitiated, !item.isCritical, item.phasedRolloutInterval > 0,
                    let publishedAt = item.publishedAt,
                    now
                        < publishedAt.addingTimeInterval(
                            TimeInterval(item.phasedRolloutInterval * phasedIntervals))
                {
                    return false
                }
                return true
            }
            .max { $0.build < $1.build }
    }

    /// Compares an `OperatingSystemVersion` with a dotted version string.
    static func compare(
        _ version: OperatingSystemVersion,
        to string: String
    ) -> ComparisonResult {
        let parts = string.split(separator: ".").compactMap { Int($0) }
        let left = [version.majorVersion, version.minorVersion, version.patchVersion]
        for index in 0..<max(left.count, parts.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < parts.count ? parts[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// §3.4: one notification per version while APKRun.app is away; a
    /// critical update re-notifies after three days.
    private func maybeNotify(_ chosen: AppcastItem?) async {
        guard let chosen, await !appConnected() else { return }
        let first = !state.notifiedBuilds.contains(chosen.build)
        let criticalRepeat =
            chosen.isCritical
            && (state.criticalNotifiedAt.map {
                now().timeIntervalSince($0) >= Self.criticalRenotifyInterval
            } ?? false)
        guard first || criticalRepeat else { return }
        if first { state.notifiedBuilds.append(chosen.build) }
        if chosen.isCritical { state.criticalNotifiedAt = now() }
        persist(state)
        notify(chosen.release, chosen.isCritical)
    }

    private func finish(error: SelfUpdateProbeFailure) -> SelfUpdateStatus {
        let wire: WireError
        switch error {
        case .unreachable(let detail):
            wire = WireError(
                domain: "maintenance", code: "maintenance.selfUpdateFeedUnreachable",
                parameters: ["detail": .text(detail)])
        case .invalid(let detail):
            wire = WireError(
                domain: "maintenance", code: "maintenance.selfUpdateFeedInvalid",
                parameters: ["detail": .text(detail)])
        }
        lastError = wire
        state.lastCheckedAt = now()
        persist(state)
        return status()
    }
}
