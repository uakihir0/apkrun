import CryptoKit
import Foundation

/// Picks the image update candidate out of a verified feed
/// (runtime-maintenance.md §4.2, C1–C7). Pure: every input arrives in `Context`,
/// so the rules are testable without a runtime.
public enum ImageCandidateSelection {
    /// The host facts the rules need.
    public struct Context: Sendable {
        /// The currently installed image (`current`).
        public var current: ImageVersion
        /// The current image's manifest `kind` (`apkrun` or `stock`).
        public var currentKind: String
        /// The instance's userdata schema version.
        public var userdataSchema: Int
        /// This APKRun's marketing version.
        public var hostVersion: String
        /// The guest protocol majors this host speaks.
        public var hostProtocol: ClosedRange<Int>
        /// Versions rejected per §4.8.
        public var rejected: Set<ImageVersion>
        /// The instance ID; only the rollout bucket uses it (C6).
        public var instanceID: UUID
        /// A user-initiated check ignores C5 and C6.
        public var userInitiated: Bool

        /// Creates the context.
        public init(
            current: ImageVersion,
            currentKind: String,
            userdataSchema: Int,
            hostVersion: String,
            hostProtocol: ClosedRange<Int>,
            rejected: Set<ImageVersion>,
            instanceID: UUID,
            userInitiated: Bool = false
        ) {
            self.current = current
            self.currentKind = currentKind
            self.userdataSchema = userdataSchema
            self.hostVersion = hostVersion
            self.hostProtocol = hostProtocol
            self.rejected = rejected
            self.instanceID = instanceID
            self.userInitiated = userInitiated
        }
    }

    /// The pick's outcome.
    public struct Pick: Sendable, Equatable {
        /// The newest entry passing every rule, as an `ImageCandidate`.
        public var candidate: ImageCandidate?
        /// The newest version whose only failure was C2 (`requiresNewerAPKRun`
        /// in §4.2): Settings shows "…after you update APKRun".
        public var requiresNewerAPKRun: ImageVersion?
    }

    /// Runs C1–C7 over the feed, newest first; the first entry passing all of
    /// them is the candidate.
    public static func pick(feed: ImageFeed, context: Context) -> Pick {
        pick(feed: feed, context: context, channel: feed.channel)
    }

    /// Same as ``pick(feed:context:)``; the channel labels the candidate.
    public static func pick(feed: ImageFeed, context: Context, channel: String) -> Pick {
        var newerAPKRunNeeded: ImageVersion?
        let entries = feed.images.compactMap { entry -> (ImageFeed.Entry, ImageVersion)? in
            guard let version = ImageVersion(entry.imageVersion) else { return nil }
            return (entry, version)
        }
        .sorted { $0.1 > $1.1 }
        for (entry, version) in entries where eligible(entry, version: version, context: context) {
            return Pick(
                candidate: candidate(entry, version: version, channel: channel),
                requiresNewerAPKRun: nil
            )
        }
        for (entry, version) in entries {
            if passesExceptRuntime(entry, version: version, context: context) {
                newerAPKRunNeeded = newerAPKRunNeeded ?? version
            }
        }
        return Pick(candidate: nil, requiresNewerAPKRun: newerAPKRunNeeded)
    }

    private static func eligible(
        _ entry: ImageFeed.Entry, version: ImageVersion, context: Context
    ) -> Bool {
        passesExceptRuntime(entry, version: version, context: context)
            && compareVersions(context.hostVersion, entry.requirements.minimumRuntimeVersion) >= 0
    }

    private static func passesExceptRuntime(
        _ entry: ImageFeed.Entry, version: ImageVersion, context: Context
    ) -> Bool {
        // C7: feed updates only ever come to an `apkrun` instance.
        guard entry.kind == "apkrun", context.currentKind == "apkrun" else { return false }
        // C1: never a downgrade.
        guard version > context.current else { return false }
        // C3: guest protocol ranges must intersect.
        let range = entry.requirements.guestProtocol
        guard range.min <= context.hostProtocol.upperBound,
            context.hostProtocol.lowerBound <= range.max
        else { return false }
        // C4: userdata schema upgradable, and current is not below the floor.
        guard entry.userdata.upgradableFrom.contains(context.userdataSchema),
            compareVersions(context.current.shortForm, entry.minimumSourceVersion) >= 0
        else { return false }
        // C5: rejected versions are skipped (a user check retries them).
        if !context.userInitiated, context.rejected.contains(version) { return false }
        // C6: rollout bucket; skipped for user checks and critical entries.
        if !context.userInitiated, !entry.critical,
            rolloutBucket(instanceID: context.instanceID, version: version) >= entry.rolloutPercent
        {
            return false
        }
        return true
    }

    /// C6: first two bytes of SHA-256(instance ID ‖ imageVersion), modulo 100.
    public static func rolloutBucket(instanceID: UUID, version: ImageVersion) -> Int {
        var bytes = Data()
        withUnsafeBytes(of: instanceID.uuid) { bytes.append(contentsOf: $0) }
        bytes.append(Data(version.description.utf8))
        let digest = SHA256.hash(data: bytes)
        let first = Array(digest.prefix(2))
        return (Int(first[0]) << 8 | Int(first[1])) % 100
    }

    private static func candidate(
        _ entry: ImageFeed.Entry, version: ImageVersion, channel: String
    ) -> ImageCandidate {
        ImageCandidate(
            version: version,
            channel: channel,
            archiveSHA256: entry.archive.sha256,
            archiveSize: entry.archive.size,
            expandedSize: entry.expandedSize,
            archiveLocation: entry.archive.url,
            isCritical: entry.critical
        )
    }
}
