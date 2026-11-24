import Foundation
import Testing

@testable import ImageCore

/// T0 for the feed parser and the C1–C7 picker (runtime-maintenance.md §4.1–§4.3).
struct ImageFeedTests {

    private static func feedJSON(
        sequence: Int = 7,
        channel: String = "stable",
        expiresInSeconds: Double = 3_600,
        entries: [String] = [ImageFeedTests.entryJSON(version: "2026.11.1")]
    ) -> Data {
        let expires = ISO8601DateFormatter().string(
            from: Date(timeIntervalSinceNow: expiresInSeconds))
        let generated = ISO8601DateFormatter().string(from: Date())
        let json = """
            {"schemaVersion":1,"channel":"\(channel)","sequence":\(sequence),
             "generatedAt":"\(generated)","expiresAt":"\(expires)",
             "images":[\(entries.joined(separator: ","))]}
            """
        return Data(json.utf8)
    }

    static func entryJSON(
        version: String = "2026.11.1",
        kind: String = "apkrun",
        minRuntime: String = "1.0",
        protoMin: Int = 1, protoMax: Int = 1,
        schema: Int = 1, upgradableFrom: [Int] = [1],
        minSource: String = "0.0",
        critical: Bool = false,
        rollout: Int = 100
    ) -> String {
        let upgradable = upgradableFrom.map(String.init).joined(separator: ",")
        return """
            {"imageVersion":"\(version)","kind":"\(kind)",
             "publishedAt":"2026-11-01T00:00:00Z",
             "archive":{"url":"https://x.test/images/\(version).aar",
                        "size":1048576,
                        "sha256":"\(String(repeating: "ab", count: 32))"},
             "expandedSize":2097152,
             "requirements":{"minimumRuntimeVersion":"\(minRuntime)",
                             "guestProtocol":{"min":\(protoMin),"max":\(protoMax)}},
             "userdata":{"schemaVersion":\(schema),"upgradableFrom":[\(upgradable)]},
             "minimumSourceVersion":"\(minSource)",
             "critical":\(critical),"rolloutPercent":\(rollout)}
            """
    }

    static func context(
        current: String = "2026.10.1",
        kind: String = "apkrun",
        schema: Int = 1,
        host: String = "1.1",
        hostProtocol: ClosedRange<Int> = 1...1,
        rejected: Set<ImageVersion> = [],
        instanceID: UUID = UUID(),
        userInitiated: Bool = false
    ) -> ImageCandidateSelection.Context {
        .init(
            current: ImageVersion(current)!,
            currentKind: kind,
            userdataSchema: schema,
            hostVersion: host,
            hostProtocol: hostProtocol,
            rejected: rejected,
            instanceID: instanceID,
            userInitiated: userInitiated
        )
    }

    // MARK: parser

    @Test func parsesAMinimalFeed() throws {
        let feed = try ImageFeed.parse(Self.feedJSON())
        #expect(feed.channel == "stable")
        #expect(feed.sequence == 7)
        #expect(feed.images.count == 1)
        #expect(feed.images[0].imageVersion == "2026.11.1")
        #expect(feed.images[0].critical == false)
    }

    @Test func rejectsBadSchemaVersion() {
        let json = Data(
            #"""
            {"schemaVersion":2,"channel":"stable","sequence":1,
             "generatedAt":"2026-11-01T00:00:00Z","expiresAt":"2026-11-02T00:00:00Z",
             "images":[]}
            """#.utf8)
        #expect(throws: ImageFailure.self) { try ImageFeed.parse(json) }
    }

    @Test func rejectsTooManyEntries() {
        let entries = (0..<300).map { _ in Self.entryJSON(version: "2026.11.1") }
        #expect(throws: ImageFailure.self) {
            try ImageFeed.parse(Self.feedJSON(entries: entries))
        }
    }

    @Test func rejectsMissingArchiveHash() {
        let entry = #"""
            {"imageVersion":"2026.11.1","kind":"apkrun",
             "publishedAt":"2026-11-01T00:00:00Z",
             "archive":{"url":"https://x.test/a.aar","size":1},
             "expandedSize":2,
             "requirements":{"minimumRuntimeVersion":"1.0",
                             "guestProtocol":{"min":1,"max":1}},
             "userdata":{"schemaVersion":1,"upgradableFrom":[1]},
             "minimumSourceVersion":"0.0"}
            """#
        #expect(throws: ImageFailure.self) {
            try ImageFeed.parse(Self.feedJSON(entries: [entry]))
        }
    }

    // MARK: C1–C7

    @Test func picksANewerEntry() throws {
        let feed = try ImageFeed.parse(Self.feedJSON())
        let pick = ImageCandidateSelection.pick(feed: feed, context: Self.context())
        #expect(pick.candidate?.version.description == "2026.11.1")
        #expect(pick.requiresNewerAPKRun == nil)
    }

    @Test func c1SkipsSameOrOlder() throws {
        let feed = try ImageFeed.parse(
            Self.feedJSON(entries: [
                Self.entryJSON(version: "2026.10.1")
            ]))
        let pick = ImageCandidateSelection.pick(feed: feed, context: Self.context())
        #expect(pick.candidate == nil)
    }

    @Test func c2ReportsRequiresNewerAPKRun() throws {
        let feed = try ImageFeed.parse(
            Self.feedJSON(entries: [
                Self.entryJSON(minRuntime: "9.9")
            ]))
        let pick = ImageCandidateSelection.pick(feed: feed, context: Self.context())
        #expect(pick.candidate == nil)
        #expect(pick.requiresNewerAPKRun?.description == "2026.11.1")
    }

    @Test func c3SkipsProtocolMismatch() throws {
        let feed = try ImageFeed.parse(
            Self.feedJSON(entries: [
                Self.entryJSON(protoMin: 2, protoMax: 3)
            ]))
        let pick = ImageCandidateSelection.pick(feed: feed, context: Self.context())
        #expect(pick.candidate == nil)
    }

    @Test func c4SkipsUnupgradableSchema() throws {
        let feed = try ImageFeed.parse(
            Self.feedJSON(entries: [
                Self.entryJSON(schema: 2, upgradableFrom: [3])
            ]))
        let pick = ImageCandidateSelection.pick(
            feed: feed, context: Self.context(schema: 2))
        #expect(pick.candidate == nil)
    }

    @Test func c4SkipsBelowMinimumSource() throws {
        let feed = try ImageFeed.parse(
            Self.feedJSON(entries: [
                Self.entryJSON(minSource: "2026.10.9")
            ]))
        let pick = ImageCandidateSelection.pick(
            feed: feed, context: Self.context(current: "2026.10.1"))
        #expect(pick.candidate == nil)
    }

    @Test func c5SkipsRejectedUnlessUserChecks() throws {
        let rejected: Set<ImageVersion> = [ImageVersion("2026.11.1")!]
        let feed = try ImageFeed.parse(Self.feedJSON())
        let auto = ImageCandidateSelection.pick(
            feed: feed, context: Self.context(rejected: rejected))
        #expect(auto.candidate == nil)
        let manual = ImageCandidateSelection.pick(
            feed: feed,
            context: Self.context(rejected: rejected, userInitiated: true))
        #expect(manual.candidate != nil)
    }

    @Test func c6RolloutZeroSkipsButCriticalPasses() throws {
        let normal = try ImageFeed.parse(
            Self.feedJSON(entries: [
                Self.entryJSON(rollout: 0)
            ]))
        let auto = ImageCandidateSelection.pick(
            feed: normal, context: Self.context())
        #expect(auto.candidate == nil)
        let critical = try ImageFeed.parse(
            Self.feedJSON(entries: [
                Self.entryJSON(critical: true, rollout: 0)
            ]))
        let picked = ImageCandidateSelection.pick(
            feed: critical, context: Self.context())
        #expect(picked.candidate != nil)
    }

    @Test func c7RequiresAnAPKRunCurrentImage() throws {
        let feed = try ImageFeed.parse(Self.feedJSON())
        let pick = ImageCandidateSelection.pick(
            feed: feed, context: Self.context(kind: "stock"))
        #expect(pick.candidate == nil)
        let foreign = try ImageFeed.parse(
            Self.feedJSON(entries: [
                Self.entryJSON(kind: "stock")
            ]))
        #expect(
            ImageCandidateSelection.pick(feed: foreign, context: Self.context())
                .candidate == nil)
    }

    @Test func bucketIsDeterministicAndUniformEnough() {
        let version = ImageVersion("2026.11.1")!
        var hits = 0
        let total = 10_000
        for _ in 0..<total {
            if ImageCandidateSelection.rolloutBucket(
                instanceID: UUID(), version: version) < 50
            {
                hits += 1
            }
        }
        #expect(abs(hits - total / 2) < total / 25)
        let id = UUID()
        #expect(
            ImageCandidateSelection.rolloutBucket(instanceID: id, version: version)
                == ImageCandidateSelection.rolloutBucket(instanceID: id, version: version))
    }
}
