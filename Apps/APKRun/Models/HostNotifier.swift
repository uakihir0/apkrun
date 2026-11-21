import AppKit
import CryptoKit
import RuntimeAPI
import RuntimeClient
import UserNotifications

/// Posts host-initiated notifications (updates, approvals, runtime state)
/// through `UNUserNotificationCenter` and answers on the `hostNotifications`
/// stream (runtime-api.md §11.3, host-ui.md). Activation opens the payload's
/// `apkrun://` target through the app's router.
@MainActor
final class HostNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// Category identifiers are per process; host notifications are few, so
    /// categories keyed by the action-titles digest need no eviction.
    private static let reconnectDelay: Duration = .seconds(2)

    private let client: RuntimeControlClient?
    private let openRoute: (AppRoute) -> Void
    private let center = UNUserNotificationCenter.current()

    private var streamID: StreamID?
    private var payloads: [String: HostNotificationPayload] = [:]
    private var categories: [String: UNNotificationCategory] = [:]
    private var task: Task<Void, Never>?

    init(clientKind: RuntimeClientKind = .app, openRoute: @escaping (AppRoute) -> Void) {
        self.client = try? RuntimeControlClient(clientKind: clientKind)
        self.openRoute = openRoute
    }

    /// Asks for authorization and consumes the stream, reconnecting while
    /// running (the single stream is replaced or dies with its connection).
    func start() {
        guard task == nil else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        task = Task { [weak self] in await self?.consume() }
    }

    private func consume() async {
        while !Task.isCancelled {
            if let client {
                do {
                    let stream = try await client.hostNotificationsStream(background: false)
                    streamID = stream.handle.streamID
                    for await envelope in stream.events {
                        if case .hostNotification(let message) = envelope.event {
                            handle(message)
                        }
                    }
                } catch {
                    // No daemon or a rejected endpoint: retry below.
                }
                streamID = nil
            }
            try? await Task.sleep(for: Self.reconnectDelay)
        }
    }

    // MARK: - Stream messages

    private func handle(_ message: HostNotificationMessage) {
        switch message {
        case .post(let payload):
            post(payload)
        case .remove(let identifiers):
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
            for identifier in identifiers {
                payloads.removeValue(forKey: identifier)
            }
        case .unknown:
            break
        }
    }

    private func post(_ payload: HostNotificationPayload) {
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body.fallback
        if let subtitle = payload.subtitle {
            content.subtitle = subtitle
        }
        if let threadID = payload.threadID {
            content.threadIdentifier = threadID
        }
        content.sound = payload.sound && !payload.replay ? .default : nil
        content.interruptionLevel =
            payload.replay || payload.interruption == .passive ? .passive : .active
        if !payload.actions.isEmpty {
            content.categoryIdentifier = categoryIdentifier(for: payload.actions)
        }
        let request = UNNotificationRequest(
            identifier: payload.identifier, content: content, trigger: nil)
        payloads[payload.identifier] = payload
        center.add(request)
    }

    private func categoryIdentifier(for actions: [HostNotificationAction]) -> String {
        let titles = actions.enumerated().map { Self.title(of: $0.element, index: $0.offset) }
        let digest = SHA256.hash(data: Data(titles.joined(separator: "|").utf8))
        let key = "apkrun-host-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        if categories[key] == nil {
            let unActions = actions.enumerated().map { index, action in
                UNNotificationAction(
                    identifier: "a\(index)",
                    title: Self.title(of: action, index: index),
                    options: [])
            }
            categories[key] = UNNotificationCategory(
                identifier: key, actions: unActions, intentIdentifiers: [])
        }
        return key
    }

    /// The button title of a host action (runtime-api.md §11.3).
    private static func title(of action: HostNotificationAction, index: Int) -> String {
        switch action {
        case .updateNow: return "Update Now"
        case .open: return "Open"
        case .restart: return "Restart"
        case .update: return "Update"
        case .later: return "Later"
        case .reportProblem: return "Report a Problem"
        case .openAPKRun: return "Open APKRun"
        case .android(_, let title): return title
        case .unknown: return "Action \(index + 1)"
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let identifier = response.notification.request.identifier
        let actionIdentifier = response.actionIdentifier
        await MainActor.run {
            guard let streamID = self.streamID, let client = self.client else { return }
            if actionIdentifier == UNNotificationDismissActionIdentifier {
                let stream = streamID
                Task {
                    try? await client.sendHostNotificationResponse(
                        .dismissed(identifier: identifier), on: stream)
                }
                self.payloads.removeValue(forKey: identifier)
                return
            }
            var action: HostNotificationAction? = nil
            if actionIdentifier.hasPrefix("a"), let index = Int(actionIdentifier.dropFirst()),
                let actions = self.payloads[identifier]?.actions,
                actions.indices.contains(index)
            {
                action = actions[index]
            }
            let stream = streamID
            Task {
                try? await client.sendHostNotificationResponse(
                    .activated(identifier: identifier, action: action), on: stream)
            }
            // `targetURL` opens on activation: the banner itself, and Open
            // actions (runtime-api.md §11.3).
            switch action {
            case nil, .open, .openAPKRun:
                if let target = self.payloads[identifier]?.targetURL,
                    let url = URL(string: target), let route = AppRouter.route(url)
                {
                    NSApp.activate(ignoringOtherApps: true)
                    self.openRoute(route)
                }
            default:
                break
            }
        }
    }
}
