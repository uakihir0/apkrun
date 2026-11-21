import Foundation

/// The notification wire types of runtime-api.md §11.3 and
/// desktop-integration.md §5.
///
/// Two streams exist. `notificationRelay` serves a wrapper its own package's
/// Android notifications as `RelayMessage` values; the wrapper answers with
/// `RelayResponse`. `hostNotifications` serves APKRun.app the notifications
/// that must appear under APKRun's own identity (a package without a usable
/// wrapper, or APKRun's own updates) as `HostNotificationMessage` values; the
/// app answers with `HostNotificationResponse`.

/// The state of the poster's macOS notification authorization
/// (runtime-api.md §11.1 `MacPermissionState`).
public enum MacPermissionState: String, Codable, Equatable, Sendable {
    /// The user was never asked.
    case notDetermined
    /// The user or an administrator denied authorization.
    case denied
    /// Authorization is restricted by the system.
    case restricted
    /// Full authorization.
    case authorized
    /// Provisional (quiet) authorization.
    case provisional
    /// Ephemeral authorization for the current session.
    case ephemeral
    /// The state could not be determined.
    case unknown
}

/// How a notification interrupts the user (desktop-integration.md §5.2).
public enum NotificationInterruption: String, Codable, Equatable, Sendable {
    /// Quiet delivery (Android `LOW`/`MIN` importance).
    case passive
    /// Banner delivery.
    case active
}

/// One action button on a notification (runtime-api.md §11.3, at most 3).
public struct NotificationAction: Codable, Equatable, Sendable {
    /// The action's title.
    public var title: String
    /// Destructive styling hint.
    public var destructive: Bool

    /// Creates a notification action.
    public init(title: String, destructive: Bool = false) {
        self.title = title
        self.destructive = destructive
    }
}

/// One Android notification offered to a wrapper (runtime-api.md §11.3).
public struct NotificationPayload: Codable, Equatable, Sendable {
    /// `<package>|<first 16 hex of SHA-256(key)>`; replaces any post with the
    /// same identifier.
    public var identifier: String
    /// The macOS thread identifier (Android group or channel mapping).
    public var threadID: String
    /// The notification title.
    public var title: String
    /// The notification body.
    public var body: String
    /// Whether the banner plays a sound.
    public var sound: Bool
    /// Banner delivery style.
    public var interruption: NotificationInterruption
    /// Action buttons, at most 3.
    public var actions: [NotificationAction]
    /// The Dock badge count this notification represents, if any.
    public var badge: Int?
    /// True when this payload rebuilds an already posted notification after a
    /// reconnect; the poster applies it without a banner or sound.
    public var replay: Bool

    /// Creates a notification payload.
    public init(
        identifier: String,
        threadID: String,
        title: String,
        body: String,
        sound: Bool = true,
        interruption: NotificationInterruption = .active,
        actions: [NotificationAction] = [],
        badge: Int? = nil,
        replay: Bool = false
    ) {
        self.identifier = identifier
        self.threadID = threadID
        self.title = title
        self.body = body
        self.sound = sound
        self.interruption = interruption
        self.actions = actions
        self.badge = badge
        self.replay = replay
    }
}

/// A message on the `notificationRelay` stream (runtime-api.md §11.3).
public enum RelayMessage: Codable, Equatable, Sendable {
    /// Post or replace a notification.
    case post(NotificationPayload)
    /// Remove notifications by identifier.
    case remove([String])
    /// Set the Dock badge count; nil clears it.
    case setBadge(Int?)
    /// A message this build does not know.
    case unknown
}

/// A wrapper's answer on its notification relay (runtime-api.md §11.3).
public enum RelayResponse: Codable, Equatable, Sendable {
    /// The user clicked the notification or an action (nil = the notification
    /// itself).
    case activated(identifier: String, actionIndex: Int?)
    /// The user or macOS dismissed the notification.
    case dismissed(identifier: String)
    /// The wrapper's macOS notification authorization changed.
    case authorizationChanged(MacPermissionState)
    /// A response this build does not know.
    case unknown
}

/// `notificationRelay` (runtime-api.md §11.1): one relay per connection; a
/// second request returns the existing handle.
public struct NotificationRelayRequest: Codable, Equatable, Sendable {
    /// True when the wrapper was started only to relay notifications.
    public var background: Bool

    /// Creates a notification-relay request.
    public init(background: Bool) {
        self.background = background
    }
}

/// `notificationRelayResponse` (runtime-api.md §11.1): one-way; no reply is
/// expected beyond the wire acknowledgement.
public struct RelayResponseRequest: Codable, Equatable, Sendable {
    /// The stream the response belongs to.
    public var streamID: StreamID
    /// The response.
    public var response: RelayResponse

    /// Creates a relay-response request.
    public init(streamID: StreamID, response: RelayResponse) {
        self.streamID = streamID
        self.response = response
    }
}

/// A localized string on the wire (runtime-api.md §17). `fallback` is the
/// already-substituted text; `key` and `parameters` let a peer re-localize.
public struct WireLocalizedText: Codable, Equatable, Sendable {
    /// The catalog or table key, when the text came from one.
    public var key: String?
    /// Substitution parameters for `key`.
    public var parameters: [String: String]
    /// The rendered text; always present.
    public var fallback: String

    /// Creates a localized text.
    public init(key: String? = nil, parameters: [String: String] = [:], fallback: String) {
        self.key = key
        self.parameters = parameters
        self.fallback = fallback
    }

    /// A plain literal with no localization key.
    public init(_ literal: String) {
        self.init(fallback: literal)
    }
}

/// What a host notification is about (runtime-api.md §11.3).
public enum HostNotificationKind: String, Codable, Equatable, Sendable {
    /// An Android app's notification for a package with no usable wrapper.
    case androidApp
    case updateAvailable
    case updated
    case updateWaiting
    case updateRolledBack
    case updateRefused
    case providerProblem
    case runtimeStopped
    case approvalNeeded
    case selfUpdateAvailable
    case imageUpdateReady
    case imageUpdated
    case imageUpdateFailed
    case imageIncompatible
    /// A kind this build does not know.
    case unknown
}

/// One action on a host notification (runtime-api.md §11.3).
public enum HostNotificationAction: Codable, Equatable, Sendable {
    case updateNow
    case open
    case restart
    case update
    case later
    case reportProblem
    case openAPKRun
    /// An action delivered to the Android app; the index matches the payload's
    /// `actions` and the title is the button text.
    case android(index: Int, title: String)
    /// An action this build does not know.
    case unknown
}

/// One notification offered to APKRun.app (runtime-api.md §11.3).
public struct HostNotificationPayload: Codable, Equatable, Sendable {
    /// The notification identifier.
    public var identifier: String
    /// What the notification is about.
    public var kind: HostNotificationKind
    /// The Android package it belongs to, when any.
    public var packageID: String?
    /// The notification title.
    public var title: String
    /// The notification body.
    public var body: WireLocalizedText
    /// The notification subtitle.
    public var subtitle: String?
    /// The macOS thread identifier.
    public var threadID: String?
    /// Whether the banner plays a sound.
    public var sound: Bool
    /// Banner delivery style.
    public var interruption: NotificationInterruption
    /// Action buttons.
    public var actions: [HostNotificationAction]
    /// The `apkrun://` URL to open on activation, when any.
    public var targetURL: String?
    /// True when this payload rebuilds an already posted notification.
    public var replay: Bool

    /// Creates a host notification payload.
    public init(
        identifier: String,
        kind: HostNotificationKind,
        packageID: String? = nil,
        title: String,
        body: WireLocalizedText,
        subtitle: String? = nil,
        threadID: String? = nil,
        sound: Bool = true,
        interruption: NotificationInterruption = .active,
        actions: [HostNotificationAction] = [],
        targetURL: String? = nil,
        replay: Bool = false
    ) {
        self.identifier = identifier
        self.kind = kind
        self.packageID = packageID
        self.title = title
        self.body = body
        self.subtitle = subtitle
        self.threadID = threadID
        self.sound = sound
        self.interruption = interruption
        self.actions = actions
        self.targetURL = targetURL
        self.replay = replay
    }
}

/// A message on the `hostNotifications` stream (runtime-api.md §11.3).
public enum HostNotificationMessage: Codable, Equatable, Sendable {
    /// Post or replace a notification.
    case post(HostNotificationPayload)
    /// Remove notifications by identifier.
    case remove([String])
    /// A message this build does not know.
    case unknown
}

/// APKRun.app's answer on the host-notification stream (runtime-api.md §11.3).
public enum HostNotificationResponse: Codable, Equatable, Sendable {
    /// The user clicked the notification or an action (nil = the notification
    /// itself).
    case activated(identifier: String, action: HostNotificationAction?)
    /// The user or macOS dismissed the notification.
    case dismissed(identifier: String)
    /// A response this build does not know.
    case unknown
}

/// `hostNotifications` (runtime-api.md §11.1). Only one stream is served; a
/// new request replaces the old one, which ends with `replaced`.
public struct HostNotificationsRequest: Codable, Equatable, Sendable {
    /// True when the app was started only to deliver notifications.
    public var background: Bool

    /// Creates a host-notifications request.
    public init(background: Bool) {
        self.background = background
    }
}

/// `hostNotificationResponse` (runtime-api.md §11.1): one-way.
public struct HostNotificationResponseRequest: Codable, Equatable, Sendable {
    /// The stream the response belongs to.
    public var streamID: StreamID
    /// The response.
    public var response: HostNotificationResponse

    /// Creates a host-notification-response request.
    public init(streamID: StreamID, response: HostNotificationResponse) {
        self.streamID = streamID
        self.response = response
    }
}
