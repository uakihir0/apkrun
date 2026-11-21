import Foundation
import GuestProtocol
import RuntimeAPI

/// The guest operations LinkForwarder needs (desktop-integration.md §7.2).
public protocol LinkChannel: Sendable {
    /// Whether the session advertises `url.v1` (guest-protocol.md §5.3).
    func supportsLinks() async -> Bool
    /// Answers one `OpenUrlOnHost` event.
    func resolveUrl(requestID: UInt64, action: GPUrlAction) async throws(IntegrationFailure)
    /// Pushes the global switch and the excluded package list (§3.2).
    func setUrlRedirect(enabled: Bool, excludedPackages: [String]) async throws(IntegrationFailure)
}

/// Opens a URL on the Mac (desktop-integration.md §7.2). The NSWorkspace
/// adapter lives in RuntimeHost; IntegrationCore does not use AppKit.
public protocol LinkOpener: Sendable {
    /// Opens the URL in the default browser or mail app.
    func open(_ url: URL) async
}

/// What the forwarder needs to know about a package's window
/// (desktop-integration.md §7.2): a session exists, and the window is key or
/// had user input in the last 5 s.
public struct LinkWindowState: Sendable, Equatable {
    /// The key-window session of the package, when it has one.
    public var sessionID: UUID?
    /// The package's window is key, or got input within 5 s.
    public var usable: Bool

    /// Creates a window state.
    public init(sessionID: UUID?, usable: Bool) {
        self.sessionID = sessionID
        self.usable = usable
    }
}

/// Forwards Android `OpenUrlOnHost` events per desktop-integration.md §7.2:
/// validate, focus, rate limit, then the `integrations.links` value —
/// `mac` opens on the Mac, `android` goes back to the guest, and `ask` shows
/// the key window's link prompt.
public actor LinkForwarder {
    /// The capability the link path needs (guest-protocol.md §5.3).
    public static let requiredCapability = "url.v1"
    /// The URL length limit (§7.2).
    public static let urlByteLimit = 8 * 1024
    /// At most this many links per `rateWindow` per package (§7.2).
    public static let rateLimit = 3
    /// The rate-limit window (§7.2).
    public static let rateWindow: Duration = .seconds(10)
    /// A prompt with no answer resolves as Cancel after this (§7.2).
    public static let promptLifetime: Duration = .seconds(60)

    /// A prompt the window has not answered yet.
    public struct PendingPrompt: Sendable {
        /// The published prompt.
        public var prompt: LinkPrompt
        /// The session the prompt went to.
        public var sessionID: UUID
        /// The package that opened the link.
        public var packageID: RuntimePackageID
        /// The `OpenUrlOnHost.request_id` being answered.
        public var requestID: UInt64
        /// The validated URL.
        public var url: URL
        /// The instant the prompt cancels itself.
        public var expiresAt: ContinuousClock.Instant
    }

    /// The outcome of one `openUrlOnHost` event, for diagnostics and tests.
    public enum Outcome: Sendable, Equatable {
        /// The Mac opened the URL.
        case openedOnHost
        /// Android opens the kept intent.
        case openInGuest
        /// The link was dropped.
        case dropped(LinkRejection)
        /// A prompt went to the key window.
        case prompted(LinkPrompt)
        /// The policy refused the link.
        case denied(IntegrationDenial)
    }

    private let policy: IntegrationPolicy
    private let channel: any LinkChannel
    private let opener: any LinkOpener
    /// The raw `integrations.links` value of a package (nil = default `ask`).
    private let linksValue: @Sendable (RuntimePackageID) async -> String?
    /// The window state of a package.
    private let windowState: @Sendable (RuntimePackageID) async -> LinkWindowState
    /// Publishes the prompt to the key window (IntegrationChange.linkPrompt).
    private let presentPrompt: @Sendable (UUID, RuntimePackageID, LinkPrompt) async -> Void
    /// Writes `integrations.links` and pushes the SetUrlRedirect update.
    private let setLinksValue: @Sendable (RuntimePackageID, String) async -> Void
    /// The packages to exclude in the next SetUrlRedirect push.
    private let excludedPackages: @Sendable () async -> [String]
    /// Logs a dropped or denied link (scheme and registrable domain only).
    private let logDrop: @Sendable (RuntimePackageID, LinkRejection, URL?) async -> Void

    private var pending: [UUID: PendingPrompt] = [:]
    private var recent: [RuntimePackageID: [ContinuousClock.Instant]] = [:]

    /// Creates a forwarder.
    public init(
        policy: IntegrationPolicy,
        channel: any LinkChannel,
        opener: any LinkOpener,
        linksValue: @escaping @Sendable (RuntimePackageID) async -> String?,
        windowState: @escaping @Sendable (RuntimePackageID) async -> LinkWindowState,
        presentPrompt: @escaping @Sendable (UUID, RuntimePackageID, LinkPrompt) async -> Void,
        setLinksValue: @escaping @Sendable (RuntimePackageID, String) async -> Void,
        excludedPackages: @escaping @Sendable () async -> [String] = { [] },
        logDrop: @escaping @Sendable (RuntimePackageID, LinkRejection, URL?) async -> Void = {
            _, _, _ in
        }
    ) {
        self.policy = policy
        self.channel = channel
        self.opener = opener
        self.linksValue = linksValue
        self.windowState = windowState
        self.presentPrompt = presentPrompt
        self.setLinksValue = setLinksValue
        self.excludedPackages = excludedPackages
        self.logDrop = logDrop
    }

    /// Handles one `OpenUrlOnHost` guest event (§7.2).
    @discardableResult
    public func openUrlOnHost(_ event: GPOpenUrlOnHost) async -> Outcome {
        guard let package = RuntimePackageID(rawValue: event.sourcePackage) else {
            try? await channel.resolveUrl(requestID: event.requestID, action: .drop)
            return .dropped(.scheme)
        }
        guard let url = Self.validatedURL(event.url) else {
            let rejection: LinkRejection =
                event.url.utf8.count > Self.urlByteLimit ? .tooLong : .scheme
            await logDrop(package, rejection, URLComponents(string: event.url)?.url)
            try? await channel.resolveUrl(requestID: event.requestID, action: .drop)
            return .dropped(rejection)
        }

        let state = await windowState(package)
        let decision = await policy.evaluate(
            .links,
            package: package,
            context: IntegrationContext(
                hasSession: state.sessionID != nil,
                windowIsKey: state.usable,
                requiredCapability: Self.requiredCapability
            )
        )
        switch decision {
        case .deny(let reason):
            try? await channel.resolveUrl(requestID: event.requestID, action: .drop)
            return .denied(reason)
        case .allow, .ask:
            break
        }

        let now = ContinuousClock.now
        var stamps = (recent[package] ?? []).filter { now - $0 < Self.rateWindow }
        guard stamps.count < Self.rateLimit else {
            recent[package] = stamps
            await logDrop(package, .rateLimited, url)
            try? await channel.resolveUrl(requestID: event.requestID, action: .drop)
            return .dropped(.rateLimited)
        }
        stamps.append(now)
        recent[package] = stamps

        let value =
            await linksValue(package) ?? IntegrationDefaults.value(for: .links)
        switch value {
        case "mac":
            await opener.open(url)
            try? await channel.resolveUrl(requestID: event.requestID, action: .openedOnHost)
            return .openedOnHost
        case "android":
            try? await channel.resolveUrl(requestID: event.requestID, action: .openInGuest)
            return .openInGuest
        case "off":
            try? await channel.resolveUrl(requestID: event.requestID, action: .drop)
            return .denied(.packageOff)
        default:
            break
        }

        // `ask`, or an unknown value treated as ask. The `url.v1`
        // capability gates the whole path; the policy's `ask` short-circuit
        // skips it, so the forwarder checks it here.
        guard await channel.supportsLinks() else {
            try? await channel.resolveUrl(requestID: event.requestID, action: .drop)
            return .denied(.notSupported)
        }
        guard let sessionID = state.sessionID else {
            await logDrop(package, .notFocused, url)
            try? await channel.resolveUrl(requestID: event.requestID, action: .drop)
            return .dropped(.notFocused)
        }
        let prompt = Self.makePrompt(
            for: url,
            keepInAndroidAvailable: await channel.supportsLinks(),
            now: Date()
        )
        pending[prompt.promptID] = PendingPrompt(
            prompt: prompt,
            sessionID: sessionID,
            packageID: package,
            requestID: event.requestID,
            url: url,
            expiresAt: now.advanced(by: Self.promptLifetime)
        )
        Task { await self.expirePrompt(prompt.promptID, after: Self.promptLifetime) }
        await presentPrompt(sessionID, package, prompt)
        return .prompted(prompt)
    }

    /// The window's answer to a prompt (runtime-api.md §11.2). An expired or
    /// unknown prompt throws ``IntegrationFailure/promptTimedOut``.
    public func resolvePrompt(
        sessionID: UUID,
        promptID: UUID,
        choice: LinkChoice,
        remember: Bool
    ) async throws(IntegrationFailure) {
        guard let entry = pending.removeValue(forKey: promptID),
            entry.sessionID == sessionID
        else {
            throw .promptTimedOut
        }
        if remember, choice != .cancel {
            await setLinksValue(entry.packageID, choice == .openOnMac ? "mac" : "android")
        }
        switch choice {
        case .openOnMac:
            await opener.open(entry.url)
            try? await channel.resolveUrl(requestID: entry.requestID, action: .openedOnHost)
        case .keepInAndroid:
            try? await channel.resolveUrl(requestID: entry.requestID, action: .openInGuest)
        case .cancel:
            try? await channel.resolveUrl(requestID: entry.requestID, action: .drop)
        }
    }

    /// Pushes the current SetUrlRedirect state to the guest (§3.2).
    public func pushUrlRedirect(enabled: Bool) async {
        try? await channel.setUrlRedirect(
            enabled: enabled, excludedPackages: await excludedPackages())
    }

    /// The pending prompt of an id, for tests.
    public func pendingPrompt(_ promptID: UUID) -> PendingPrompt? {
        pending[promptID]
    }

    /// Cancels a still-open prompt at its expiry.
    private func expirePrompt(_ promptID: UUID, after lifetime: Duration) async {
        try? await Task.sleep(for: lifetime)
        guard let entry = pending.removeValue(forKey: promptID) else { return }
        try? await channel.resolveUrl(requestID: entry.requestID, action: .drop)
        await logDrop(entry.packageID, .notFocused, entry.url)
    }

    /// Validates a link (§7.2): parses, at most 8 KiB, scheme
    /// http/https/mailto, and a host for http(s).
    public static func validatedURL(_ string: String) -> URL? {
        guard string.utf8.count <= urlByteLimit else { return nil }
        guard let components = URLComponents(string: string),
            let scheme = components.scheme?.lowercased()
        else {
            return nil
        }
        switch scheme {
        case "http", "https":
            guard let host = components.host, !host.isEmpty else { return nil }
        case "mailto":
            break
        default:
            return nil
        }
        return components.url
    }

    /// Builds the prompt for a validated URL (runtime-api.md §11.2).
    public static func makePrompt(
        for url: URL,
        keepInAndroidAvailable: Bool,
        now: Date
    ) -> LinkPrompt {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let scheme = components?.scheme?.lowercased() ?? ""
        let host =
            components?.host
            ?? (scheme == "mailto" ? String(url.absoluteString.dropFirst("mailto:".count)) : "")
        let path = components?.percentEncodedPath.lowercased() ?? ""
        let signIn =
            path.contains("oauth") || path.contains("authorize") || path.contains("login")
        return LinkPrompt(
            promptID: UUID(),
            host: host,
            registrableDomain: registrableDomain(of: host),
            scheme: scheme,
            signInHint: signIn,
            keepInAndroidAvailable: keepInAndroidAvailable,
            expiresAt: now.addingTimeInterval(promptLifetime.timeInterval)
        )
    }

    /// The registrable domain of a Unicode host (§7.2: the bold part). A
    /// small public-suffix approximation: the last two labels, or three when
    /// the second level is a common SLD of a two-letter TLD.
    public static func registrableDomain(of host: String) -> String {
        let labels = host.split(separator: ".", omittingEmptySubsequences: true)
        guard labels.count >= 2 else { return host }
        let slds: Set<String> = [
            "ac", "co", "com", "edu", "go", "gov", "ne", "net", "or", "org",
        ]
        let tld = String(labels[labels.count - 1])
        let sld = String(labels[labels.count - 2])
        if tld.count == 2, slds.contains(sld.lowercased()), labels.count >= 3 {
            return labels.suffix(3).joined(separator: ".")
        }
        return labels.suffix(2).joined(separator: ".")
    }
}

extension Duration {
    /// The whole seconds of the duration, for `Date` arithmetic.
    fileprivate var timeInterval: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
