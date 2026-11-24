import AppKit
import CryptoKit
import Foundation
import RuntimeAPI
import RuntimeClient
import UserNotifications

/// The deterministic Android package ID → Mac bundle ID mapping
/// (wrapper.md §4.1), mirrored here because the launcher links only system
/// frameworks and RuntimeClient.
enum LauncherBundleIDMapper {
    static let prefix = "io.apkrun.android."

    static func map(_ packageID: String) -> String {
        var mapped = packageID.replacingOccurrences(of: "_", with: "-")
        if packageID.contains(where: { $0.isUppercase }) {
            let digest = SHA256.hash(data: Data(packageID.utf8))
            let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
            mapped += "-h" + suffix
        }
        return prefix + mapped
    }
}

/// Posts Android notifications through `UNUserNotificationCenter` on the
/// wrapper's own `notificationRelay` stream (desktop-integration.md §5.2,
/// wrapper.md §5.8). Used by `--apkrun-background notifications`.
@MainActor
final class NotificationPoster: NSObject, UNUserNotificationCenterDelegate {
    /// `UNNotificationCategory` identifiers are per process, so categories
    /// are keyed by the action titles and kept in an LRU of 32 (§5.2). A
    /// category referenced by a delivered notification is never evicted.
    private static let categoryLimit = 32
    /// wrapper.md §5.8: quit 30 s after the last delivered notification.
    private static let idleQuitInterval: Duration = .seconds(30)

    private let client: RuntimeControlClient
    private let center = UNUserNotificationCenter.current()

    private var streamID: StreamID?
    /// Action-titles hash → category identifier, oldest first.
    private var categoryLRU: [String] = []
    private var categories: [String: UNNotificationCategory] = [:]
    private var delivered: Set<String> = []
    private var identifierCategory: [String: String] = [:]
    private var idleQuitTask: Task<Void, Never>?
    /// `--apkrun-background notifications` claims a background slot and quits
    /// on stream end; the foreground launcher takes a regular slot and keeps
    /// running when the stream dies with its connection.
    private let background: Bool

    init(client: RuntimeControlClient, background: Bool = true) {
        self.client = client
        self.background = background
    }

    /// Connects, asks for authorization when `notDetermined`, and consumes
    /// the relay until the stream ends (desktop-integration.md §5.3).
    func run() async {
        center.delegate = self
        await reportAuthorization()
        let stream: (handle: StreamHandle, events: AsyncStream<StreamEnvelope>)
        do {
            stream = try await client.notificationRelayStream(background: background)
        } catch {
            // No daemon or a rejected endpoint: nothing can arrive. A
            // background-only launch exits; the foreground launcher just
            // goes without notification relay.
            if background { NSApp.terminate(nil) }
            return
        }
        streamID = stream.handle.streamID
        let events = stream.events
        for await envelope in events {
            switch envelope.event {
            case .relay(let message):
                handle(message)
            case .ended:
                if background { NSApp.terminate(nil) }
                return
            default:
                break
            }
        }
        if background { NSApp.terminate(nil) }
    }

    // MARK: - Relay messages

    private func handle(_ message: RelayMessage) {
        switch message {
        case .post(let payload):
            post(payload)
        case .remove(let identifiers):
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
            for identifier in identifiers {
                delivered.remove(identifier)
            }
            scheduleIdleQuitIfEmpty()
        case .setBadge(let count):
            NSApp.dockTile.badgeLabel = count.map(String.init)
        case .unknown:
            break
        }
    }

    private func post(_ payload: NotificationPayload) {
        idleQuitTask?.cancel()
        idleQuitTask = nil
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.threadIdentifier = payload.threadID
        if let badge = payload.badge {
            content.badge = NSNumber(value: badge)
        }
        // A replay rebuilds an already posted notification after a
        // reconnect: no banner and no sound (desktop-integration.md §5.3).
        content.sound = payload.sound && !payload.replay ? .default : nil
        if payload.replay || payload.interruption == .passive {
            content.interruptionLevel = .passive
        } else {
            content.interruptionLevel = .active
        }
        let split = splitIdentifier(payload.identifier)
        content.userInfo = ["package": split.package, "keyDigest": split.digest]
        if !payload.actions.isEmpty {
            let category = categoryIdentifier(for: payload.actions)
            content.categoryIdentifier = category
            identifierCategory[payload.identifier] = category
        }
        let request = UNNotificationRequest(
            identifier: payload.identifier, content: content, trigger: nil)
        delivered.insert(payload.identifier)
        center.add(request)
    }

    // MARK: - Categories (LRU 32)

    private func categoryIdentifier(for actions: [NotificationAction]) -> String {
        let titles = actions.map(\.title).joined(separator: "|")
        let digest = SHA256.hash(data: Data(titles.utf8))
        let key = "apkrun-actions-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        if let existing = categories[key] {
            categoryLRU.removeAll { $0 == key }
            categoryLRU.append(key)
            _ = existing
            return key
        }
        let unActions = actions.enumerated().map { index, action in
            UNNotificationAction(
                identifier: "a\(index)", title: action.title,
                options: action.destructive ? .destructive : [])
        }
        let category = UNNotificationCategory(
            identifier: key, actions: unActions, intentIdentifiers: [],
            options: .customDismissAction)
        categories[key] = category
        categoryLRU.append(key)
        evictCategoriesIfNeeded()
        center.setNotificationCategories(Set(categories.values))
        return key
    }

    /// Evicts the oldest categories down to the limit, skipping any a
    /// delivered notification still references (desktop-integration.md §5.2).
    private func evictCategoriesIfNeeded() {
        let inUse = Set(identifierCategory.values)
        var index = 0
        while categories.count > Self.categoryLimit, index < categoryLRU.count {
            let candidate = categoryLRU[index]
            if inUse.contains(candidate) {
                index += 1
                continue
            }
            categories.removeValue(forKey: candidate)
            categoryLRU.remove(at: index)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        await MainActor.run {
            delivered.remove(identifier)
            if action == UNNotificationDismissActionIdentifier {
                send(.dismissed(identifier: identifier))
                scheduleIdleQuitIfEmpty()
                return
            }
            // wrapper.md §5.8: a click switches to .regular and continues at
            // §5.2 step 3; the session window itself is #45's.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            let index: Int?
            if action == UNNotificationDefaultActionIdentifier {
                index = nil
            } else if action.hasPrefix("a"), let value = Int(action.dropFirst()) {
                index = value
            } else {
                index = nil
            }
            send(.activated(identifier: identifier, actionIndex: index))
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // §5.2: while the app's window is key, LOW shows [.list] and
        // DEFAULT/HIGH shows [.banner, .list, .sound]. `.passive` is the LOW
        // bucket; the wrapper has no key window in background mode.
        if notification.request.content.interruptionLevel == .passive {
            return [.list]
        }
        return [.banner, .list, .sound]
    }

    // MARK: - Helpers

    /// `<package>|<16 hex>` split on the last `|` (§5.2).
    private func splitIdentifier(_ identifier: String) -> (package: String, digest: String) {
        guard let separator = identifier.lastIndex(of: "|") else {
            return (identifier, "")
        }
        return (String(identifier[..<separator]), String(identifier[identifier.index(after: separator)...]))
    }

    private func send(_ response: RelayResponse) {
        guard let streamID else { return }
        Task {
            try? await client.sendNotificationRelayResponse(response, on: streamID)
        }
    }

    private func reportAuthorization() async {
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            settings = await center.notificationSettings()
        }
        send(.authorizationChanged(permissionState(settings.authorizationStatus)))
    }

    private func permissionState(_ status: UNAuthorizationStatus) -> MacPermissionState {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        @unknown default: return .unknown
        }
    }

    /// wrapper.md §5.8: quit 30 s after the last delivered notification.
    private func scheduleIdleQuitIfEmpty() {
        guard background, delivered.isEmpty, idleQuitTask == nil else { return }
        idleQuitTask = Task {
            try? await Task.sleep(for: Self.idleQuitInterval)
            guard !Task.isCancelled, delivered.isEmpty else { return }
            NSApp.terminate(nil)
        }
    }
}
