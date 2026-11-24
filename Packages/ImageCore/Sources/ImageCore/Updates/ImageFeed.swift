import Foundation

/// A parsed `feed.json` (runtime-image-manifest.md §9.1–§9.3). Unknown fields
/// are ignored; a `schemaVersion` other than 1 makes the feed unusable.
public struct ImageFeed: Sendable, Equatable {
    /// One `images` entry that passed the field rules.
    public struct Entry: Sendable, Equatable {
        /// The full image version text.
        public var imageVersion: String
        /// `apkrun`; entries with other kinds are skipped before validation.
        public var kind: String
        /// When the entry was published.
        public var publishedAt: Date
        /// The `.aar` location and digest.
        public var archive: Archive
        /// Bytes after extraction; used by the space check.
        public var expandedSize: Int64
        /// `minimumRuntimeVersion` and `guestProtocol`, as in the manifest.
        public var requirements: Requirements
        /// `schemaVersion`/`upgradableFrom`, as in the manifest.
        public var userdata: Userdata
        /// `upgradeFrom.minimumImageVersion` in short form.
        public var minimumSourceVersion: String
        /// Day-precise Android security patch level, when published.
        public var securityPatchLevel: String?
        /// The image's time zone database version, when published.
        public var tzdataVersion: String?
        /// Skips the rollout and shortens reminders (§4.11).
        public var critical: Bool
        /// The rollout percentage (C6).
        public var rolloutPercent: Int
        /// "What's new" link.
        public var releaseNotesURL: String?

        /// The `.aar` pointer.
        public struct Archive: Sendable, Equatable {
            /// Absolute https URL, at most 2048 characters, no user info.
            public var url: String
            /// Archive bytes; the downloader stops above it.
            public var size: Int64
            /// Lowercase hex SHA-256 of the archive.
            public var sha256: String
        }

        /// The manifest `requirements` fields that rule 6 compares.
        public struct Requirements: Sendable, Equatable {
            /// The minimum APKRun marketing version.
            public var minimumRuntimeVersion: String
            /// The guest protocol range.
            public var guestProtocol: GuestProtocolRange
        }

        /// `min`/`max` of `requirements.guestProtocol`.
        public struct GuestProtocolRange: Sendable, Equatable {
            /// Lowest supported guest protocol major.
            public var min: Int
            /// Highest supported guest protocol major.
            public var max: Int
        }

        /// The manifest `userdata` fields that rule 6 compares.
        public struct Userdata: Sendable, Equatable {
            /// The userdata schema the image writes.
            public var schemaVersion: Int
            /// Schemas the image can upgrade from.
            public var upgradableFrom: [Int]
        }
    }

    /// `stable` or `beta`; must equal the requested channel.
    public var channel: String
    /// Monotonic sequence per channel (rule 4).
    public var sequence: Int
    /// When the feed was signed.
    public var generatedAt: Date
    /// After this the feed is not used.
    public var expiresAt: Date
    /// Validated entries, `kind != apkrun` already dropped.
    public var images: [Entry]

    /// Parses and validates `data` per §9.3–§9.4. Throws `ImageFailure`.
    public static func parse(_ data: Data) throws(ImageFailure) -> ImageFeed {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any]
        else {
            throw .imageFeedInvalid(detail: "not a JSON object")
        }
        guard let schema = root["schemaVersion"] as? Int else {
            throw .imageFeedInvalid(detail: "schemaVersion missing")
        }
        guard schema == 1 else {
            throw .imageFeedInvalid(detail: "schemaVersion \(schema)")
        }
        guard let channel = root["channel"] as? String,
            ["stable", "beta"].contains(channel)
        else {
            throw .imageFeedInvalid(detail: "channel")
        }
        guard let sequence = root["sequence"] as? Int, sequence >= 1 else {
            throw .imageFeedInvalid(detail: "sequence")
        }
        guard let generatedAt = parseDate(root["generatedAt"]),
            let expiresAt = parseDate(root["expiresAt"]),
            expiresAt > generatedAt
        else {
            throw .imageFeedInvalid(detail: "timestamps")
        }
        guard let rawImages = root["images"] as? [[String: Any]], rawImages.count <= 256 else {
            throw .imageFeedInvalid(detail: "images")
        }
        var images: [Entry] = []
        var triples = Set<String>()
        for raw in rawImages where (raw["kind"] as? String) == "apkrun" {
            let entry = try parseEntry(raw)
            let triple = entry.imageVersion.split(separator: "-").first.map(String.init) ?? ""
            guard triples.insert(triple).inserted else {
                throw .imageFeedInvalid(detail: "duplicate \(triple)")
            }
            images.append(entry)
        }
        return ImageFeed(
            channel: channel, sequence: sequence,
            generatedAt: generatedAt, expiresAt: expiresAt, images: images
        )
    }

    private static func parseEntry(_ raw: [String: Any]) throws(ImageFailure) -> Entry {
        guard let version = raw["imageVersion"] as? String,
            ImageVersion(version) != nil
        else { throw .imageFeedInvalid(detail: "imageVersion") }
        guard let publishedAt = parseDate(raw["publishedAt"]) else {
            throw .imageFeedInvalid(detail: "publishedAt")
        }
        guard let archive = raw["archive"] as? [String: Any],
            let url = archive["url"] as? String, url.count <= 2048,
            let parsed = URLComponents(string: url),
            parsed.scheme == "https", parsed.user == nil, parsed.password == nil,
            let size = archive["size"] as? Int, size >= 1,
            let sha = archive["sha256"] as? String, isSHA256(sha)
        else { throw .imageFeedInvalid(detail: "archive") }
        guard let expanded = raw["expandedSize"] as? Int,
            expanded >= size, expanded <= 1_099_511_627_776
        else { throw .imageFeedInvalid(detail: "expandedSize") }
        guard let requirements = raw["requirements"] as? [String: Any],
            let minimumRuntimeVersion = requirements["minimumRuntimeVersion"] as? String,
            let proto = requirements["guestProtocol"] as? [String: Any],
            let protoMin = proto["min"] as? Int, let protoMax = proto["max"] as? Int,
            protoMin >= 1, protoMax >= protoMin,
            requirements["agents"] == nil
        else { throw .imageFeedInvalid(detail: "requirements") }
        guard let userdata = raw["userdata"] as? [String: Any],
            let schema = userdata["schemaVersion"] as? Int,
            let upgradableFrom = userdata["upgradableFrom"] as? [Int]
        else { throw .imageFeedInvalid(detail: "userdata") }
        guard let upgradeFrom = raw["upgradeFrom"] as? [String: Any],
            let minimumSource = upgradeFrom["minimumImageVersion"] as? String
        else { throw .imageFeedInvalid(detail: "upgradeFrom") }
        guard let critical = raw["critical"] as? Bool,
            let rollout = raw["rolloutPercent"] as? Int, (0...100).contains(rollout)
        else { throw .imageFeedInvalid(detail: "flags") }
        if let patch = raw["securityPatchLevel"] as? String,
            patch.matches(of: /^\d{4}-\d{2}-\d{2}$/).isEmpty
        {
            throw .imageFeedInvalid(detail: "securityPatchLevel")
        }
        if let tz = raw["tzdataVersion"] as? String,
            tz.matches(of: /^\d{4}[a-z]$/).isEmpty
        {
            throw .imageFeedInvalid(detail: "tzdataVersion")
        }
        if let notes = raw["releaseNotesURL"] as? String,
            URLComponents(string: notes)?.scheme != "https"
        {
            throw .imageFeedInvalid(detail: "releaseNotesURL")
        }
        return Entry(
            imageVersion: version, kind: "apkrun", publishedAt: publishedAt,
            archive: .init(url: url, size: Int64(size), sha256: sha),
            expandedSize: Int64(expanded),
            requirements: .init(
                minimumRuntimeVersion: minimumRuntimeVersion,
                guestProtocol: .init(min: protoMin, max: protoMax)
            ),
            userdata: .init(schemaVersion: schema, upgradableFrom: upgradableFrom),
            minimumSourceVersion: minimumSource,
            securityPatchLevel: raw["securityPatchLevel"] as? String,
            tzdataVersion: raw["tzdataVersion"] as? String,
            critical: critical, rolloutPercent: rollout,
            releaseNotesURL: raw["releaseNotesURL"] as? String
        )
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let text = value as? String, text.hasSuffix("Z") else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func isSHA256(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
