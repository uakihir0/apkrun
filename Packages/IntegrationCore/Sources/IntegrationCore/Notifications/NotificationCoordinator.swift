import CryptoKit
import Foundation
import GuestProtocol
import RuntimeAPI

/// The guest operations notifications need (desktop-integration.md §5.1,
/// guest-protocol.md §7.5).
public protocol NotificationGuestChannel: Sendable {
    /// Replaces the forwarding allowlist; the agent re-sends every active
    /// forwarded notification with `replay = true` afterwards.
    func setNotificationForwarding(_ packages: [String]) async throws(IntegrationFailure)
    /// Sends the content or action intent (§5.4).
    func activateNotification(key: String, actionIndex: Int?, displayID: Int32) async throws(IntegrationFailure)
    /// Dismisses the notification on Android (§5.4).
    func dismissNotification(key: String) async throws(IntegrationFailure)
}

/// The host-side deliveries the coordinator routes to (§5.3). The RuntimeHost
/// implements this over `RuntimeStreamCenter` and `WorkspaceOpener`.
public protocol NotificationSink: Sendable {
    /// Delivers a relay message on the package's `notificationRelay` stream;
    /// false when the wrapper has no open stream.
    func relay(_ message: RelayMessage, to packageID: RuntimePackageID) async -> Bool
    /// Delivers a message on the `hostNotifications` stream; false when none.
    func hostNotify(_ message: HostNotificationMessage) async -> Bool
    /// A registered, non-pending wrapper exists for the package.
    func wrapperExists(for packageID: RuntimePackageID) async -> Bool
    /// Starts the wrapper in background mode (wrapper.md §5.8); fire-and-forget.
    func startWrapperInBackground(_ packageID: RuntimePackageID) async
    /// The package's display name, for the subtitle of host-posted notifications.
    func displayName(for packageID: RuntimePackageID) async -> String?
}

/// Routes Android notifications to the wrapper relay or APKRun
/// (desktop-integration.md §5.3).
///
/// The coordinator owns the per-package key map: Android keys are translated
/// to the §5.2 wire identifier `"<package>|<first 16 hex of SHA-256(key)>"`
/// so the Android key itself never leaves apkrund. The Dock badge is the
/// number of active forwarded notifications of the package.
public actor NotificationCoordinator {
    /// The capability #55 requires (guest-protocol.md §5.3).
    public static let requiredCapability = "notifications.v1"
    /// The pending-queue cap while a wrapper starts (§5.3).
    public static let queueLimit = 50
    /// The pending-queue lifetime while a wrapper starts (§5.3).
    public static let queueTimeout: Duration = .seconds(10)
    /// The action limit of §5.2.
    public static let actionLimit = 3
    /// Quiet time after which a `replay` rebuild counts as finished.
    public static let replayQuietTime: Duration = .seconds(2)

    /// A queued relay message and its wall-clock deadline.
    private struct PendingPost {
        let message: RelayMessage
    }

    private let policy: IntegrationPolicy
    private let channel: any NotificationGuestChannel
    private let sink: any NotificationSink

    /// Active Android keys per package: key → wire identifier.
    private var forwarded: [RuntimePackageID: [String: String]] = [:]
    /// Wire identifier → (package, Android key) for responses.
    private var byIdentifier: [String: (package: RuntimePackageID, key: String)] = [:]
    /// Keys seen in a running replay rebuild, per package.
    private var replaySeen: [RuntimePackageID: Set<String>] = [:]
    /// Timer that finishes a replay rebuild after a quiet window.
    private var replayTimers: [RuntimePackageID: Task<Void, Never>] = [:]
    /// Posts queued while the wrapper starts in background mode.
    private var pending: [RuntimePackageID: [PendingPost]] = [:]
    /// Timeout tasks dropping a still-unflushed pending queue (§5.3).
    private var pendingTimers: [RuntimePackageID: Task<Void, Never>] = [:]
    /// Queues dropped on the 10 s timeout, per package (counted per §5.3).
    private var droppedQueues: [RuntimePackageID: Int] = [:]

    /// Creates a coordinator over the policy, guest channel, and host sink.
    public init(
        policy: IntegrationPolicy,
        channel: any NotificationGuestChannel,
        sink: any NotificationSink
    ) {
        self.policy = policy
        self.channel = channel
        self.sink = sink
    }

    // MARK: - Forwarding list (§3.2)

    /// Pushes `SetNotificationForwarding` with the packages whose
    /// `integrations.notifications` decision is allow (§2.1, §5.1).
    ///
    /// The caller passes every package candidate (installed, wrapper-registered);
    /// the coordinator filters them by the §2.3 policy so a
    /// `notifications = false` package never leaves the guest.
    public func pushForwardingList(_ candidates: [RuntimePackageID]) async throws(IntegrationFailure) {
        var allowed: [String] = []
        for packageID in candidates {
            let context = IntegrationContext(
                hasSession: false, windowIsKey: false,
                requiredCapability: Self.requiredCapability)
            if case .allow = await policy.evaluate(.notifications, package: packageID, context: context) {
                allowed.append(packageID.rawValue)
            }
        }
        try await channel.setNotificationForwarding(allowed.sorted())
    }

    // MARK: - Guest events (§5.3)

    /// Handles one `notification_posted` event.
    public func posted(_ notification: GPNotification) async {
        guard let packageID = RuntimePackageID(rawValue: notification.package) else {
            return
        }
        let context = IntegrationContext(
            hasSession: false, windowIsKey: false,
            requiredCapability: Self.requiredCapability)
        guard case .allow = await policy.evaluate(
            .notifications, package: packageID, context: context)
        else {
            return
        }
        if !notification.replay {
            await finishReplayRebuildIfRunning(for: packageID)
        }
        let identifier = Self.identifier(package: packageID.rawValue, key: notification.key)
        forwarded[packageID, default: [:]][notification.key] = identifier
        byIdentifier[identifier] = (packageID, notification.key)
        if notification.replay {
            replaySeen[packageID, default: []].insert(notification.key)
            scheduleReplayFinish(for: packageID)
        }
        let payload = Self.payload(from: notification, packageID: packageID, identifier: identifier)
        let count = forwarded[packageID]?.count ?? 0
        await deliver(packageID: packageID, notification: notification, payload: payload, badge: count)
    }

    /// Handles one `notification_removed` event.
    public func removed(_ removal: GPNotificationRemoved) async {
        for packageID in forwarded.keys {
            guard let identifier = forwarded[packageID]?[removal.key] else {
                continue
            }
            await finishReplayRebuildIfRunning(for: packageID)
            forwarded[packageID]?[removal.key] = nil
            byIdentifier[identifier] = nil
            let badge = forwarded[packageID]?.count ?? 0
            if await sink.relay(.remove([identifier]), to: packageID) {
                await sendBadge(packageID: packageID, badge: badge)
            } else {
                _ = await sink.hostNotify(.remove([identifier]))
            }
            return
        }
    }

    // MARK: - Relay lifecycle

    /// A wrapper's `notificationRelay` stream opened; flush its pending queue
    /// (§5.3).
    public func relayOpened(packageID: RuntimePackageID) async {
        pendingTimers[packageID]?.cancel()
        pendingTimers[packageID] = nil
        let queued = pending[packageID] ?? []
        pending[packageID] = nil
        for entry in queued {
            if await !sink.relay(entry.message, to: packageID) {
                pending[packageID, default: []].append(entry)
            }
        }
        if (pending[packageID] ?? []).isEmpty {
            pending[packageID] = nil
        }
    }

    /// The stream the coordinator pushes to was replaced or closed; nothing to
    /// requeue — new posts start a fresh background start.
    public func relayClosed(packageID: RuntimePackageID) async {
        // State is kept: a rebuilt stream replays from `forwarded` via
        // SetNotificationForwarding.
    }

    // MARK: - Responses (§5.4)

    /// `activated(identifier, actionIndex?)` from a wrapper or the app:
    /// resolve the Android key and send `ActivateNotification` with the
    /// session's display (§5.4).
    public func activated(identifier: String, actionIndex: Int?, displayID: Int32) async {
        guard let record = byIdentifier[identifier] else {
            return
        }
        try? await channel.activateNotification(
            key: record.key, actionIndex: actionIndex, displayID: displayID)
    }

    /// `dismissed(identifier)`: send `DismissNotification` (§5.4).
    public func dismissed(identifier: String) async {
        guard let record = byIdentifier[identifier] else {
            return
        }
        try? await channel.dismissNotification(key: record.key)
    }

    /// `authorizationChanged(denied)` from a wrapper. The host reports it in
    /// `integrationStatus`; the coordinator only has to stop pushing posts.
    public func noteAuthorizationDenied(packageID: RuntimePackageID) {
        // Kept for symmetry; denial state lives in settings/health reporting.
    }

    // MARK: - Status

    /// The active forwarded count = the Dock badge for the package (§5.3).
    public func badge(for packageID: RuntimePackageID) -> Int {
        forwarded[packageID]?.count ?? 0
    }

    /// Queues dropped by the 10 s timeout, for `apkrun integrations status`.
    public func droppedQueueCount(for packageID: RuntimePackageID) -> Int {
        droppedQueues[packageID] ?? 0
    }

    /// The wire identifier of an Android key (§5.2): "<package>|<16 hex>".
    public static func identifier(package: String, key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(package)|\(hex)"
    }

    /// The §5.2 payload mapping.
    static func payload(
        from notification: GPNotification,
        packageID: RuntimePackageID,
        identifier: String
    ) -> NotificationPayload {
        // importance: LOW (2) or an alert=false update → passive, silent.
        let importanceLowOrQuiet = notification.importance <= 2 || !notification.alert
        let thread = notification.groupKey.isEmpty ? notification.channelID : notification.groupKey
        return NotificationPayload(
            identifier: identifier,
            threadID: "\(packageID.rawValue)/\(thread)",
            title: notification.title,
            body: notification.text,
            sound: !importanceLowOrQuiet,
            interruption: importanceLowOrQuiet ? .passive : .active,
            actions: notification.actions.prefix(actionLimit).map {
                NotificationAction(title: $0.title, destructive: false)
            },
            badge: nil,
            replay: notification.replay
        )
    }

    // MARK: - Delivery

    private func deliver(
        packageID: RuntimePackageID,
        notification: GPNotification,
        payload: NotificationPayload,
        badge: Int
    ) async {
        if await sink.relay(.post(payload), to: packageID) {
            await sendBadge(packageID: packageID, badge: badge)
            return
        }
        if await sink.wrapperExists(for: packageID) {
            queueForBackgroundStart(packageID: packageID, message: .post(payload))
            return
        }
        let hostPayload = await hostPayload(from: notification, packageID: packageID, badge: badge)
        _ = await sink.hostNotify(.post(hostPayload))
    }

    private func queueForBackgroundStart(packageID: RuntimePackageID, message: RelayMessage) {
        var queue = pending[packageID] ?? []
        if queue.count < Self.queueLimit {
            queue.append(PendingPost(message: message))
        }
        pending[packageID] = queue
        guard pendingTimers[packageID] == nil else { return }
        Task { await sink.startWrapperInBackground(packageID) }
        pendingTimers[packageID] = Task {
            try? await Task.sleep(for: Self.queueTimeout)
            guard !Task.isCancelled else { return }
            await self.pendingTimedOut(packageID: packageID)
        }
    }

    private func pendingTimedOut(packageID: RuntimePackageID) {
        pendingTimers[packageID] = nil
        if let queue = pending[packageID], !queue.isEmpty {
            droppedQueues[packageID, default: 0] += 1
            pending[packageID] = nil
        }
    }

    private func sendBadge(packageID: RuntimePackageID, badge: Int) async {
        _ = await sink.relay(.setBadge(badge == 0 ? nil : badge), to: packageID)
    }

    private func hostPayload(
        from notification: GPNotification,
        packageID: RuntimePackageID,
        badge: Int
    ) async -> HostNotificationPayload {
        let importanceLowOrQuiet = notification.importance <= 2 || !notification.alert
        let thread = notification.groupKey.isEmpty ? notification.channelID : notification.groupKey
        let subtitle = await sink.displayName(for: packageID)
        return HostNotificationPayload(
            identifier: Self.identifier(package: packageID.rawValue, key: notification.key),
            kind: .androidApp,
            packageID: packageID.rawValue,
            title: notification.title,
            body: WireLocalizedText(notification.text),
            subtitle: subtitle,
            threadID: "\(packageID.rawValue)/\(thread)",
            sound: !importanceLowOrQuiet,
            interruption: importanceLowOrQuiet ? .passive : .active,
            actions: notification.actions.enumerated().prefix(Self.actionLimit).map {
                .android(index: $0.offset, title: $0.element.title)
            },
            targetURL: "apkrun://package/\(packageID.rawValue)",
            replay: notification.replay
        )
    }

    // MARK: - Replay rebuild (§5.3 reconnect)

    private func scheduleReplayFinish(for packageID: RuntimePackageID) {
        replayTimers[packageID]?.cancel()
        replayTimers[packageID] = Task {
            try? await Task.sleep(for: Self.replayQuietTime)
            guard !Task.isCancelled else { return }
            await self.finishReplayRebuildIfRunning(for: packageID)
        }
    }

    /// Ends a replay rebuild: Android keys that were not re-sent are gone, so
    /// their Mac notifications are removed and badges rebuilt (§5.3).
    private func finishReplayRebuildIfRunning(for packageID: RuntimePackageID) async {
        replayTimers[packageID]?.cancel()
        replayTimers[packageID] = nil
        guard let seen = replaySeen[packageID] else { return }
        replaySeen[packageID] = nil
        let stale = (forwarded[packageID] ?? [:]).filter { !seen.contains($0.key) }
        guard !stale.isEmpty else { return }
        var identifiers: [String] = []
        for (key, identifier) in stale {
            forwarded[packageID]?[key] = nil
            byIdentifier[identifier] = nil
            identifiers.append(identifier)
        }
        if await sink.relay(.remove(identifiers), to: packageID) {
            await sendBadge(packageID: packageID, badge: forwarded[packageID]?.count ?? 0)
        } else {
            _ = await sink.hostNotify(.remove(identifiers))
        }
    }
}
