import AppKit
import Foundation
import IntegrationCore

final class LocaleTimeNotificationRelay: @unchecked Sendable {
    struct Binding {
        let center: NotificationCenter
        let name: Notification.Name
        let trigger: LocaleTimeSyncTrigger
    }

    static func workspaceWakeBinding(notificationCenter: NotificationCenter) -> Binding {
        Binding(
            center: notificationCenter,
            name: NSWorkspace.didWakeNotification,
            trigger: .wake
        )
    }

    private let bindings: [Binding]
    private let onTrigger: @Sendable (LocaleTimeSyncTrigger) async -> Void
    private var observerTokens: [(NotificationCenter, NSObjectProtocol)] = []

    init(
        bindings: [Binding],
        onTrigger: @escaping @Sendable (LocaleTimeSyncTrigger) async -> Void
    ) {
        self.bindings = bindings
        self.onTrigger = onTrigger
    }

    func start() {
        guard observerTokens.isEmpty else { return }
        observerTokens = bindings.map { binding in
            let onTrigger = self.onTrigger
            let token = binding.center.addObserver(
                forName: binding.name,
                object: nil,
                queue: nil
            ) { _ in
                Task { await onTrigger(binding.trigger) }
            }
            return (binding.center, token)
        }
    }

    func stop() {
        for (center, token) in observerTokens {
            center.removeObserver(token)
        }
        observerTokens.removeAll()
    }
}
