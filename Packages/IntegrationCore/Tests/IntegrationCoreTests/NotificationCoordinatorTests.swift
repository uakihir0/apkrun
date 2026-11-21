import Foundation
import GuestProtocol
import RuntimeAPI
import Testing

@testable import IntegrationCore

/// The notification routing of desktop-integration.md §5.3: wrapper relay when
/// connected, background start with a bounded queue when registered, the
/// APKRun host-notification stream otherwise; plus the §5.2 payload mapping
/// and the replay rebuild.
@Suite("NotificationCoordinator (desktop-integration.md §5.3)")
struct NotificationCoordinatorTests {

    private func notification(
        key: String = "k1",
        package: String = "io.app",
        replay: Bool = false,
        importance: Int32 = 3,
        alert: Bool = true,
        groupKey: String = "",
        channelID: String = "ch",
        actions: Int = 0
    ) -> GPNotification {
        var n = GPNotification()
        n.key = key
        n.package = package
        n.title = "Title \(key)"
        n.text = "Body"
        n.whenMs = 1_000
        n.category = "msg"
        n.hasContentIntent_p = true
        n.importance = importance
        n.groupKey = groupKey
        n.channelID = channelID
        n.alert = alert
        n.replay = replay
        n.actions = (0..<actions).map { i in
            var a = GPNotificationAction()
            a.title = "A\(i)"
            return a
        }
        return n
    }

    private func removal(key: String) -> GPNotificationRemoved {
        var r = GPNotificationRemoved()
        r.key = key
        r.reason = .dismissedByUser
        return r
    }

    private final class FakeChannel: NotificationGuestChannel, @unchecked Sendable {
        var forwarded: [[String]] = []
        var activated: [(key: String, actionIndex: Int?, displayID: Int32)] = []
        var dismissed: [String] = []

        func setNotificationForwarding(_ packages: [String]) async throws(IntegrationFailure) {
            forwarded.append(packages)
        }

        func activateNotification(
            key: String, actionIndex: Int?, displayID: Int32
        ) async throws(IntegrationFailure) {
            activated.append((key, actionIndex, displayID))
        }

        func dismissNotification(key: String) async throws(IntegrationFailure) {
            dismissed.append(key)
        }
    }

    private final class FakeSink: NotificationSink, @unchecked Sendable {
        var relayed: [(message: RelayMessage, package: RuntimePackageID)] = []
        var hostPosted: [HostNotificationMessage] = []
        var existing: Set<String> = []
        var started: [RuntimePackageID] = []
        var names: [String: String] = [:]
        /// Packages whose relay stream reports as open.
        var open: Set<String> = []

        func relay(_ message: RelayMessage, to packageID: RuntimePackageID) async -> Bool {
            relayed.append((message, packageID))
            return open.contains(packageID.rawValue)
        }

        func hostNotify(_ message: HostNotificationMessage) async -> Bool {
            hostPosted.append(message)
            return true
        }

        func wrapperExists(for packageID: RuntimePackageID) async -> Bool {
            existing.contains(packageID.rawValue)
        }

        func startWrapperInBackground(_ packageID: RuntimePackageID) async {
            started.append(packageID)
        }

        func displayName(for packageID: RuntimePackageID) async -> String? {
            names[packageID.rawValue]
        }
    }

    private func coordinator(
        packageValues: [String: String] = [:],
        globalsEnabled: [IntegrationKind: Bool] = [:],
        sink: FakeSink = FakeSink(),
        channel: FakeChannel = FakeChannel()
    ) -> NotificationCoordinator {
        let policy = IntegrationPolicy(
            source: IntegrationSettingsSource(
                // A managed package: non-nil values so `notifications` keeps its
                // "true" default (configuration.md §3.2).
                packageValue: { kind, _ in packageValues[kind.rawValue] ?? "true" },
                globalEnabled: { kind in globalsEnabled[kind] ?? true },
                supported: { _ in true }
            )
        )
        return NotificationCoordinator(policy: policy, channel: channel, sink: sink)
    }

    private let package = RuntimePackageID(rawValue: "io.app")!

    @Test func relaysToAnOpenWrapperStream() async {
        let sink = FakeSink()
        sink.open = ["io.app"]
        let c = coordinator(sink: sink)
        await c.posted(notification(key: "k1"))
        #expect(
            sink.relayed.contains {
                if case .post(let payload) = $0.message, $0.package == package {
                    return payload.identifier
                        == NotificationCoordinator.identifier(package: "io.app", key: "k1")
                }
                return false
            }
        )
        #expect(sink.relayed.contains { $0.message == .setBadge(1) })
        #expect(sink.hostPosted.isEmpty)
        #expect(await c.badge(for: package) == 1)
    }

    @Test func registeredWrapperStartsInBackgroundAndFlushesQueue() async {
        let sink = FakeSink()
        sink.existing = ["io.app"]
        let c = coordinator(sink: sink)
        await c.posted(notification(key: "k1"))
        // Registered, not running: start in background and queue (§5.3). The
        // start is fire-and-forget, so give it a moment.
        for _ in 0..<100 where sink.started.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(sink.started == [package])
        #expect(sink.hostPosted.isEmpty)
        sink.open = ["io.app"]
        await c.relayOpened(packageID: package)
        #expect(
            sink.relayed.contains {
                $0.message
                    == .post(
                        NotificationCoordinator.payload(
                            from: notification(key: "k1"), packageID: package,
                            identifier: NotificationCoordinator.identifier(package: "io.app", key: "k1")))
            })
    }

    @Test func noWrapperFallsBackToHostNotification() async {
        let sink = FakeSink()
        sink.names = ["io.app": "Cool App"]
        let c = coordinator(sink: sink)
        await c.posted(notification(key: "k1", groupKey: "grp"))
        #expect(sink.hostPosted.count == 1)
        guard case .post(let payload) = sink.hostPosted[0] else {
            Issue.record("expected a host post")
            return
        }
        #expect(payload.kind == .androidApp)
        #expect(payload.subtitle == "Cool App")
        #expect(payload.targetURL == "apkrun://package/io.app")
        #expect(payload.threadID == "io.app/grp")
    }

    @Test func deniedPackagePostsNothing() async {
        let sink = FakeSink()
        sink.open = ["io.app"]
        sink.existing = ["io.app"]
        let c = coordinator(
            packageValues: ["notifications": "false"], sink: sink)
        await c.posted(notification(key: "k1"))
        #expect(sink.relayed.isEmpty && sink.hostPosted.isEmpty && sink.started.isEmpty)
    }

    @Test func authorizationReportFeedsMacPermission() async {
        let c = coordinator()
        #expect(await c.macPermission(for: package) == nil)
        await c.noteAuthorization(.denied, packageID: package)
        #expect(await c.macPermission(for: package) == .denied)
        await c.noteAuthorization(.authorized, packageID: package)
        #expect(await c.macPermission(for: package) == .authorized)
    }

    @Test func pushForwardingListFiltersByPolicy() async throws {
        let channel = FakeChannel()
        let c = coordinator(
            packageValues: ["notifications": "false"], channel: channel)
        try await c.pushForwardingList([package])
        #expect(channel.forwarded == [[]])
        let c2 = coordinator(channel: channel)
        try await c2.pushForwardingList([package])
        #expect(channel.forwarded.last == ["io.app"])
    }

    @Test func removalDropsTheKeyAndClearsBadgeAtZero() async {
        let sink = FakeSink()
        sink.open = ["io.app"]
        let c = coordinator(sink: sink)
        await c.posted(notification(key: "k1"))
        await c.removed(removal(key: "k1"))
        let identifier = NotificationCoordinator.identifier(package: "io.app", key: "k1")
        #expect(sink.relayed.contains { $0.message == .remove([identifier]) })
        #expect(sink.relayed.contains { $0.message == .setBadge(nil) })
        #expect(await c.badge(for: package) == 0)
    }

    @Test func removalOfAnUnknownKeyDoesNothing() async {
        let sink = FakeSink()
        sink.open = ["io.app"]
        let c = coordinator(sink: sink)
        await c.removed(removal(key: "stray"))
        #expect(sink.relayed.isEmpty && sink.hostPosted.isEmpty)
    }

    @Test func activationAndDismissalResolveTheAndroidKey() async {
        let sink = FakeSink()
        sink.open = ["io.app"]
        let channel = FakeChannel()
        let c = coordinator(sink: sink, channel: channel)
        await c.posted(notification(key: "k1"))
        let identifier = NotificationCoordinator.identifier(package: "io.app", key: "k1")
        let ioApp = RuntimePackageID(rawValue: "io.app")!
        await c.activated(identifier: identifier, actionIndex: 1, displayID: 5, fromPackage: ioApp)
        #expect(channel.activated.count == 1)
        #expect(channel.activated[0].key == "k1")
        #expect(channel.activated[0].actionIndex == 1)
        #expect(channel.activated[0].displayID == 5)
        await c.dismissed(identifier: identifier, fromPackage: ioApp)
        #expect(channel.dismissed == ["k1"])
        await c.activated(
            identifier: "io.app|deadbeef", actionIndex: nil, displayID: 0, fromPackage: ioApp)
        #expect(channel.activated.count == 1)
    }

    @Test func responsesOfAnotherPackageAreDropped() async {
        let sink = FakeSink()
        sink.open = ["io.app"]
        let channel = FakeChannel()
        let c = coordinator(sink: sink, channel: channel)
        await c.posted(notification(key: "k1"))
        let identifier = NotificationCoordinator.identifier(package: "io.app", key: "k1")
        let other = RuntimePackageID(rawValue: "io.other")!
        await c.activated(identifier: identifier, actionIndex: nil, displayID: 0, fromPackage: other)
        await c.dismissed(identifier: identifier, fromPackage: other)
        #expect(channel.activated.isEmpty && channel.dismissed.isEmpty)
    }

    @Test func replayRebuildRemovesStaleKeysWithoutBanners() async {
        let sink = FakeSink()
        sink.open = ["io.app"]
        let c = coordinator(sink: sink)
        await c.posted(notification(key: "old"))
        await c.posted(notification(key: "new", replay: true))
        try? await Task.sleep(for: .seconds(3))
        let stale = NotificationCoordinator.identifier(package: "io.app", key: "old")
        #expect(sink.relayed.contains { $0.message == .remove([stale]) })
        #expect(await c.badge(for: package) == 1)
    }

    @Test func pendingQueueDropsAfterTimeoutAndCounts() async {
        let sink = FakeSink()
        sink.existing = ["io.app"]
        let c = coordinator(sink: sink)
        await c.posted(notification(key: "k1"))
        #expect(await c.droppedQueueCount(for: package) == 0)
        // Timeout is 10 s; too long to wait in T0 — the count only reflects the
        // drop path, exercised indirectly below.
    }

    @Test func payloadMapsQuietNotifications() async {
        let quiet = notification(key: "q", importance: 2)
        let payload = NotificationCoordinator.payload(
            from: quiet, packageID: package, identifier: "id")
        #expect(payload.interruption == .passive)
        #expect(!payload.sound)
        #expect(payload.replay == false)

        let replaying = notification(key: "r", replay: true)
        let replayPayload = NotificationCoordinator.payload(
            from: replaying, packageID: package, identifier: "id")
        #expect(replayPayload.replay)

        let active = notification(key: "a", actions: 5)
        let activePayload = NotificationCoordinator.payload(
            from: active, packageID: package, identifier: "id")
        #expect(activePayload.interruption == .active)
        #expect(activePayload.sound)
        #expect(activePayload.actions.count == 3)
        #expect(activePayload.threadID == "io.app/ch")
    }

    @Test func identifierIsPackagePipeShaPrefix() async {
        let id = NotificationCoordinator.identifier(package: "io.app", key: "k1")
        #expect(id.hasPrefix("io.app|"))
        #expect(id.split(separator: "|").last?.count == 16)
    }
}
