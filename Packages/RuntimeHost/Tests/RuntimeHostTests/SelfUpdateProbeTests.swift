import CryptoKit
import Foundation
import Testing
import UpdateCore

@testable import RuntimeHost

/// A scripted `UpdateHTTPClient` standing in for the appcast server
/// (runtime-maintenance.md §14 T0). `routes` maps a path suffix to a reply;
/// the stub honours `If-None-Match`/`If-Modified-Since` like a real server.
final class StubUpdateHTTPClient: UpdateHTTPClient, @unchecked Sendable {
    struct Route {
        var body: Data
        var status = 200
        var etag: String?
        var lastModified: String?
    }

    var routes: [String: Route]
    private(set) var requests: [(url: String, headers: [String: String])] = []

    init(routes: [String: Route]) {
        self.routes = routes
    }

    func get(_ url: URL, headers: [String: String], byteLimit: Int64?) async throws(UpdateFailure)
        -> HTTPResponse
    {
        requests.append((url: url.absoluteString, headers: headers))
        guard let key = routes.keys.first(where: { url.absoluteString.hasSuffix($0) }),
            let route = routes[key]
        else {
            throw .providerHTTPStatus(404)
        }
        if let etag = route.etag, headers["If-None-Match"] == etag {
            return HTTPResponse(status: 304, body: Data())
        }
        return HTTPResponse(
            status: route.status, body: route.body,
            etag: route.etag, lastModified: route.lastModified)
    }

    func download(
        _ url: URL, headers: [String: String], into file: URL, byteLimit: Int64?
    ) async throws(UpdateFailure) -> DownloadResponse {
        throw .providerUnreachable(reason: "not implemented")
    }
}

private func appcast(
    items: [(
        version: String, build: Int, channel: String?, minimum: String?,
        critical: Bool, pubDate: String
    )]
) -> Data {
    var itemsXML = ""
    for item in items {
        var fields = """
            <title>APKRun \(item.version)</title>
            <pubDate>\(item.pubDate)</pubDate>
            <sparkle:version>\(item.build)</sparkle:version>
            <sparkle:shortVersionString>\(item.version)</sparkle:shortVersionString>
            """
        if let minimum = item.minimum {
            fields += "<sparkle:minimumSystemVersion>\(minimum)</sparkle:minimumSystemVersion>"
        }
        if let channel = item.channel {
            fields += "<sparkle:channel>\(channel)</sparkle:channel>"
        }
        if item.critical {
            fields += "<sparkle:criticalUpdate sparkle:version=\"\(item.build)\"/>"
        }
        itemsXML += """
            <item>\(fields)
            <enclosure url="https://updates.example/APKRun-\(item.version).zip"
                length="1000" type="application/octet-stream"
                sparkle:edSignature="c2ln"/></item>
            """
    }
    return Data(
        """
        <?xml version="1.0"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
        <channel><title>APKRun updates</title>\(itemsXML)</channel></rss>
        """.utf8)
}

private let oldPubDate = "Wed, 01 Jan 2020 00:00:00 +0000"
private let nowPubDate = "Wed, 01 Jan 2020 00:00:00 +0000"

/// Mutable capture for the probe's `persist`/`notify` closures.
final class ProbeRecorder: @unchecked Sendable {
    var state = SelfUpdateProbeState()
    var notified = 0
}

private func makeProbe(
    http: StubUpdateHTTPClient,
    ownBuild: Int = 1000,
    channels: Set<String> = [],
    signed: Bool = false,
    key: String? = nil,
    state: SelfUpdateProbeState = SelfUpdateProbeState(),
    recorder: ProbeRecorder = ProbeRecorder(),
    appConnected: Bool = false
) -> SelfUpdateProbe {
    SelfUpdateProbe(
        feedURL: URL(string: "https://updates.example/appcast.xml")!,
        http: http,
        ownVersion: "1.0.0",
        ownBuild: ownBuild,
        allowedChannels: channels,
        requiresSignedFeed: signed,
        publicEDKey: key,
        state: state,
        persist: { recorder.state = $0 },
        notify: { _, _ in recorder.notified += 1 },
        appConnected: { appConnected }
    )
}

@Suite(.serialized)
struct SelfUpdateProbeTests {
    @Test func picksNewerBuildAndRecordsETag() async {
        let feed = appcast(items: [
            (
                version: "1.1.0", build: 1100, channel: nil, minimum: nil,
                critical: false, pubDate: oldPubDate
            )
        ])
        let stub = StubUpdateHTTPClient(routes: [
            "appcast.xml": .init(body: feed, etag: "v1")
        ])
        let recorder = ProbeRecorder()
        let probe = makeProbe(http: stub, recorder: recorder)
        let status = await probe.check(userInitiated: true)
        #expect(status.latest?.build == 1100)
        #expect(status.lastError == nil)
        #expect(recorder.state.etag == "v1")
        #expect(recorder.notified == 1)
        // The second check sends If-None-Match and gets 304.
        stub.routes["appcast.xml"] = .init(body: feed, etag: "v1")
        _ = await probe.check(userInitiated: true)
        #expect(stub.requests.last?.headers["If-None-Match"] == "v1")
    }

    @Test func betaItemIgnoredWithoutChannel() async {
        let feed = appcast(items: [
            (
                version: "1.1.0", build: 1100, channel: "beta", minimum: nil,
                critical: false, pubDate: oldPubDate
            )
        ])
        let stub = StubUpdateHTTPClient(routes: ["appcast.xml": .init(body: feed)])
        let probe = makeProbe(http: stub)
        let status = await probe.check(userInitiated: true)
        #expect(status.latest == nil)
    }

    @Test func betaItemAcceptedOnBetaChannel() async {
        let feed = appcast(items: [
            (
                version: "1.1.0", build: 1100, channel: "beta", minimum: nil,
                critical: false, pubDate: oldPubDate
            )
        ])
        let stub = StubUpdateHTTPClient(routes: ["appcast.xml": .init(body: feed)])
        let probe = makeProbe(http: stub, channels: ["beta"])
        let status = await probe.check(userInitiated: true)
        #expect(status.latest?.build == 1100)
    }

    @Test func minimumSystemVersionFilters() async {
        let feed = appcast(items: [
            (
                version: "1.1.0", build: 1100, channel: nil, minimum: "99.0",
                critical: false, pubDate: oldPubDate
            )
        ])
        let stub = StubUpdateHTTPClient(routes: ["appcast.xml": .init(body: feed)])
        let probe = makeProbe(http: stub)
        let status = await probe.check(userInitiated: true)
        #expect(status.latest == nil)
    }

    @Test func phasedRolloutSkippedUnlessUserInitiated() async {
        let recent = Date().addingTimeInterval(-3600)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let pubDate = formatter.string(from: recent)
        let feed = Data(
            """
            <?xml version="1.0"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
            <channel><item>
            <title>APKRun 1.1.0</title><pubDate>\(pubDate)</pubDate>
            <sparkle:version>1100</sparkle:version>
            <sparkle:shortVersionString>1.1.0</sparkle:shortVersionString>
            <sparkle:phasedRolloutInterval>86400</sparkle:phasedRolloutInterval>
            <enclosure url="https://updates.example/a.zip" length="1" sparkle:edSignature="x"/>
            </item></channel></rss>
            """.utf8)
        let stub = StubUpdateHTTPClient(routes: ["appcast.xml": .init(body: feed)])
        var probe = makeProbe(http: stub)
        var status = await probe.check(userInitiated: false)
        #expect(status.latest == nil)
        probe = makeProbe(http: stub)
        status = await probe.check(userInitiated: true)
        #expect(status.latest?.build == 1100)
    }

    @Test func malformedFeedReportsInvalid() async {
        let stub = StubUpdateHTTPClient(routes: [
            "appcast.xml": .init(body: Data("<rss><channel>".utf8))
        ])
        let probe = makeProbe(http: stub)
        let status = await probe.check(userInitiated: true)
        #expect(status.lastError?.code == "maintenance.selfUpdateFeedInvalid")
    }

    @Test func unreachableFeedReportsUnreachable() async {
        let stub = StubUpdateHTTPClient(routes: [
            "appcast.xml": .init(body: Data(), status: 500)
        ])
        let probe = makeProbe(http: stub)
        let status = await probe.check(userInitiated: true)
        #expect(status.lastError?.code == "maintenance.selfUpdateFeedUnreachable")
    }

    @Test func signedFeedRequiresValidSignature() async {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let feed = appcast(items: [
            (
                version: "1.1.0", build: 1100, channel: nil, minimum: nil,
                critical: false, pubDate: oldPubDate
            )
        ])
        let goodSignature = try! key.signature(for: feed).base64EncodedString()
        // Bad signature → invalid.
        var stub = StubUpdateHTTPClient(routes: [
            "appcast.xml": .init(body: feed),
            "appcast.xml.sig": .init(body: Data("aGVsbG8=".utf8)),
        ])
        var probe = makeProbe(http: stub, signed: true, key: publicKey)
        var status = await probe.check(userInitiated: true)
        #expect(status.lastError?.code == "maintenance.selfUpdateFeedInvalid")
        // Good signature → item accepted.
        stub = StubUpdateHTTPClient(routes: [
            "appcast.xml": .init(body: feed),
            "appcast.xml.sig": .init(body: Data(goodSignature.utf8)),
        ])
        probe = makeProbe(http: stub, signed: true, key: publicKey)
        status = await probe.check(userInitiated: true)
        #expect(status.latest?.build == 1100)
    }

    @Test func notifiesOncePerBuildAndNotWhenAppConnected() async {
        let feed = appcast(items: [
            (
                version: "1.1.0", build: 1100, channel: nil, minimum: nil,
                critical: false, pubDate: oldPubDate
            )
        ])
        let stub = StubUpdateHTTPClient(routes: ["appcast.xml": .init(body: feed)])
        let recorder = ProbeRecorder()
        // App connected → no notification.
        var probe = makeProbe(http: stub, recorder: recorder, appConnected: true)
        _ = await probe.check(userInitiated: true)
        #expect(recorder.notified == 0)
        // Same build again → still only the one notification.
        probe = makeProbe(http: stub, recorder: recorder)
        _ = await probe.check(userInitiated: true)
        #expect(recorder.notified == 1)
        // Restore the notified builds: no repeat.
        var restored = SelfUpdateProbeState()
        restored.notifiedBuilds = [1100]
        probe = makeProbe(http: stub, state: restored, recorder: recorder)
        _ = await probe.check(userInitiated: true)
        #expect(recorder.notified == 1)
    }
}
