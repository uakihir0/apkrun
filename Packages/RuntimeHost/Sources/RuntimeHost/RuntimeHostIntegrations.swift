import Foundation
import GuestProtocol
import IntegrationCore
import RuntimeAPI
import RuntimeCore

/// The cached inputs of `IntegrationSettingsSource`, whose closures are
/// synchronous while `PackageStore` reads are not (desktop-integration.md §2.3).
/// `RuntimeHost` refreshes the cache before every evaluation.
final class IntegrationSettingsCache: @unchecked Sendable {
    private let lock = NSLock()
    private var packageValues: [String: [String: String]] = [:]
    private var globalsEnabled: [String: Bool] = [:]
    private var capabilities: Set<String> = []
    private var capabilitiesKnown = false

    /// Replaces the cached values of one package.
    func setPackage(_ packageID: String, values: [String: String]) {
        lock.withLock { packageValues[packageID] = values }
    }

    /// Replaces the global `integrations.enabled.*` switches.
    func setGlobals(_ enabled: [String: Bool]) {
        lock.withLock { globalsEnabled = enabled }
    }

    /// Replaces the capabilities the running image reports; nil means unknown.
    func setCapabilities(_ capabilities: Set<String>?) {
        lock.withLock {
            self.capabilities = capabilities ?? []
            capabilitiesKnown = capabilities != nil
        }
    }

    /// The package's stored `integrations.<kind>` value, or nil for the default.
    func packageValue(_ packageID: String, _ kind: String) -> String? {
        lock.withLock { packageValues[packageID]?[kind] }
    }

    /// The global `integrations.enabled.<kind>` switch; absent means on.
    func globalEnabled(_ kind: String) -> Bool {
        lock.withLock { globalsEnabled[kind] ?? true }
    }

    /// Whether the image reports a capability; unknown counts as supported so
    /// a stopped image does not shadow the session/focus checks.
    func supports(_ capability: String) -> Bool {
        lock.withLock { !capabilitiesKnown || capabilities.contains(capability) }
    }

    /// Whether the capability set has been read at least once this run.
    var capabilitiesAreKnown: Bool {
        lock.withLock { capabilitiesKnown }
    }
}

/// The channel that sends host clips to the Guest Agent (desktop-integration.md §3.3).
private struct GuestClipboardChannel: IntegrationChannel {
    /// `RuntimeHost`'s async send; throws any error, mapped here.
    let send: @Sendable (GPClipData) async throws -> Void

    /// Forwards the clip; non-integration errors become ``IntegrationFailure/guestUnavailable``.
    func setClipboard(_ clip: GPClipData) async throws(IntegrationFailure) {
        do {
            try await send(clip)
        } catch let failure as IntegrationFailure {
            throw failure
        } catch {
            throw .guestUnavailable
        }
    }
}

extension RuntimeHost {
    /// The shared §2.3 policy and §4 coordinator, built on first use.
    func integrationCoordinator() -> ClipboardCoordinator {
        if let clipboardCoordinator { return clipboardCoordinator }
        let settings = integrationSettings
        let policy = IntegrationPolicy(
            source: IntegrationSettingsSource(
                packageValue: { kind, packageID in
                    settings.packageValue(packageID.rawValue, kind.rawValue)
                },
                globalEnabled: { kind in
                    settings.globalEnabled(kind.rawValue)
                },
                supported: { capability in
                    settings.supports(capability)
                }
            )
        )
        let channel = GuestClipboardChannel { [weak self] clip in
            guard let self,
                let supervisor = await self.runtimeSupervisorForIntegrations(),
                let agent = await supervisor.developmentGuestAgent
            else {
                throw IntegrationFailure.guestUnavailable
            }
            do {
                _ = try await agent.supervisor.send(GuestSetClipboard(clip: clip))
            } catch let failure as GuestProtocolFailure {
                if case .capabilityMissing(let capability) = failure {
                    throw IntegrationFailure.notSupportedOnImage(capability: capability)
                }
                throw IntegrationFailure.guestUnavailable
            } catch {
                throw IntegrationFailure.guestUnavailable
            }
        }
        let coordinator = ClipboardCoordinator(policy: policy, channel: channel) {
            [weak self] sessionID, packageID, item in
            await self?.publishGuestClip(sessionID: sessionID, packageID: packageID, item: item)
        }
        clipboardCoordinator = coordinator
        return coordinator
    }

    /// Refreshes the synchronous policy inputs from settings.json and
    /// PackageStore before an evaluation (desktop-integration.md §2.3).
    private func refreshIntegrationSettings(for packageID: RuntimePackageID) async {
        let globals = GlobalSettings.load(from: integrationSettingsFile)
        integrationSettings.setGlobals(globals.integrationsEnabled)
        if let service = packageServiceForIntegrations() {
            let settings = try? await service.packageIntegrationSettings(for: packageID.rawValue)
            integrationSettings.setPackage(packageID.rawValue, values: settings?.integrations ?? [:])
        }
        await refreshIntegrationCapabilities()
    }

    /// Caches the running image's capabilities; nil while no agent answers.
    private func refreshIntegrationCapabilities() async {
        guard let supervisor = runtimeSupervisorForIntegrations(),
            let agent = await supervisor.developmentGuestAgent,
            let capabilities = await agent.supervisor.session?.enabledCapabilities
        else {
            integrationSettings.setCapabilities(nil)
            return
        }
        integrationSettings.setCapabilities(Set(capabilities))
    }

    /// Publishes the accepted guest clip on the `integrations` topic (§4.3).
    private func publishGuestClip(sessionID: UUID, packageID: RuntimePackageID, item: ClipItem) {
        eventHub.publishIntegrationChange(
            .clipboardFromGuest(sessionID: sessionID, packageID: packageID, item: item))
    }

    /// Starts the guest→coordinator clip relay once the supervisor is ready.
    func startClipboardRelay() {
        guard clipboardRelayTask == nil, let supervisor = runtimeSupervisorForIntegrations() else {
            return
        }
        clipboardRelayTask = Task.detached { [weak self] in
            guard let agent = await supervisor.developmentGuestAgent else { return }
            for await clip in agent.clipboardEvents {
                guard !Task.isCancelled else { return }
                await self?.clipboardFromGuest(clip)
            }
        }
    }

    /// Ends the relay; clips received while Android stops are dropped (§4.3).
    func stopClipboardRelay() {
        clipboardRelayTask?.cancel()
        clipboardRelayTask = nil
    }

    /// One `clipboard_changed` guest event for the coordinator.
    func clipboardFromGuest(_ clip: GPClipData) async {
        // The §2.3 policy reads the cache, so refresh it first: the key
        // package, plus the source package of a foreign clip (§4.3).
        if let key = await integrationCoordinator().currentKeySession {
            await refreshIntegrationSettings(for: key.packageID)
            if !clip.sourcePackage.isEmpty, clip.sourcePackage != key.packageID.rawValue,
                let foreign = RuntimePackageID(rawValue: clip.sourcePackage)
            {
                await refreshIntegrationSettings(for: foreign)
            }
        }
        await integrationCoordinator().guestChanged(clip)
    }

    /// `pushClipboard`: a window sends a Mac clip to Android (§4.2).
    public func pushClipboard(sessionID: UUID, item: ClipItem) async throws(RuntimeWireError) -> ClipAck {
        guard let packageID = await sessionPackageID(sessionID) else {
            throw Self.integrationWireError(.disabled(.clipboard, .noSession))
        }
        await refreshIntegrationSettings(for: packageID)
        let failure: IntegrationFailure
        do {
            return try await integrationCoordinator().push(
                sessionID: sessionID, packageID: packageID, item: item)
        } catch let error as IntegrationFailure {
            failure = error
        } catch {
            failure = .guestUnavailable
        }
        throw Self.integrationWireError(failure)
    }

    /// `clipboardWritten`: a window reports the pasteboard write it made (§4.2).
    public func clipboardWritten(sessionID: UUID, written: ClipboardWritten) async throws(RuntimeWireError) {
        await integrationCoordinator().noteWritten(sessionID: sessionID, written: written)
    }

    /// `focusChanged`: a window reports whether it is the key window (§4.1).
    public func focusChanged(sessionID: UUID, isKey: Bool) async throws(RuntimeWireError) {
        guard let packageID = await sessionPackageID(sessionID) else {
            // A window for a dead session reports focus; the change is dropped
            // like every clip that arrives without a session (§4.3).
            return
        }
        await integrationCoordinator().noteFocusChanged(
            sessionID: sessionID, packageID: packageID, isKey: isKey)
    }

    /// `integrationStatus`: per-kind setting, decision, and support (§11).
    public func integrationStatus(packageID: RuntimePackageID) async throws(RuntimeWireError)
        -> IntegrationStatus
    {
        _ = try await packageInfo(RuntimePackageRequest(packageID: packageID))
        await refreshIntegrationSettings(for: packageID)
        let coordinator = integrationCoordinator()
        let key = await coordinator.currentKeySession
        let hasSession =
            (await sessionServiceForIntegrations()?.hasLiveSession(packageID: packageID.rawValue))
            ?? false
        let isKey = key?.packageID == packageID
        var items: [IntegrationItemStatus] = []
        for kind in IntegrationKind.allCases {
            let capability = Self.capability(for: kind)
            let context = IntegrationContext(
                hasSession: hasSession,
                windowIsKey: isKey,
                requiredCapability: capability
            )
            let decision = await integrationCoordinator().policyDecision(
                kind, package: packageID, context: context)
            let (value, source) = integrationValue(for: kind, packageID: packageID)
            items.append(
                IntegrationItemStatus(
                    kind: kind,
                    value: value,
                    source: source,
                    decision: Self.wireDecision(decision),
                    support: supportState(kind: kind, capability: capability),
                    capability: capability
                )
            )
        }
        return IntegrationStatus(packageID: packageID, items: items)
    }

    /// The stored or default `integrations.<kind>` value and its source.
    private func integrationValue(
        for kind: IntegrationKind, packageID: RuntimePackageID
    ) -> (IntegrationValue, IntegrationSettingSource) {
        if let stored = integrationSettings.packageValue(packageID.rawValue, kind.rawValue) {
            return (IntegrationValue(policyString: stored) ?? .null, .user)
        }
        return (IntegrationValue(policyString: IntegrationDefaults.value(for: kind)) ?? .null, .default)
    }

    /// The capability a kind requires, when any (guest-protocol.md §5.3).
    private static func capability(for kind: IntegrationKind) -> String? {
        switch kind {
        case .clipboard:
            return ClipboardCoordinator.requiredCapability
        case .notifications, .links, .files, .sharedFolders, .microphone:
            return nil
        }
    }

    /// The image support of a kind's capability.
    private func supportState(kind: IntegrationKind, capability: String?) -> IntegrationSupport {
        guard let capability else { return .unknown }
        // `supports` treats an unread capability set as supported so a stopped
        // image does not block the policy; the status answer reports unknown.
        guard integrationSettings.capabilitiesAreKnown else { return .unknown }
        return integrationSettings.supports(capability) ? .supported : .unsupported
    }

    /// The wire form of an `IntegrationDecision`.
    private static func wireDecision(_ decision: IntegrationDecision) -> IntegrationStatusDecision {
        switch decision {
        case .allow: return .allow
        case .ask: return .ask
        case .deny(let reason): return .deny(reason)
        }
    }

    /// The package that owns an app session, for session-channel routing.
    private func sessionPackageID(_ sessionID: UUID) async -> RuntimePackageID? {
        guard let raw = await sessionServiceForIntegrations()?.packageID(forSession: sessionID) else {
            return nil
        }
        return RuntimePackageID(rawValue: raw)
    }

    /// Maps an `IntegrationFailure` to its catalog wire error (§13.1).
    private static func integrationWireError(_ failure: IntegrationFailure) -> RuntimeWireError {
        switch failure {
        case .disabled(let kind, let reason):
            let messages: (String, String?)
            switch reason {
            case .globallyOff:
                messages = (
                    "\(kind.rawValue) is turned off for all apps.",
                    "Turn it on in Settings → Privacy."
                )
            case .notFocused:
                messages = (
                    "The app can use \(kind.rawValue) only while you use its window.",
                    "Click the app's window, then try again."
                )
            case .noSession:
                messages = ("The app isn't open.", "Open the app, then try again.")
            case .notSupported:
                messages = (
                    "This version of Android doesn't support \(kind.rawValue).",
                    "Update Android."
                )
            case .rateLimited:
                messages = ("The app is doing this too often.", "Wait a moment, then try again.")
            case .packageOff, .unknown:
                messages = (
                    "\(kind.rawValue) is turned off for the app.",
                    "Turn it on in the app's settings in APKRun."
                )
            }
            return RuntimeWireError(
                domain: "integration",
                code: "integration.disabled",
                message: messages.0,
                remediation: messages.1
            )
        case .notSupportedOnImage(let capability):
            return RuntimeWireError(
                domain: "integration",
                code: "integration.notSupportedOnImage",
                message: "This version of Android doesn't support this (\(capability)).",
                remediation: "Update Android."
            )
        case .guestUnavailable:
            return RuntimeWireError(
                domain: "integration",
                code: "integration.guestUnavailable",
                message: "The Guest Agent in Android isn't connected.",
                remediation: "APKRun reconnects automatically. Try again in a moment."
            )
        case .clipboardTooLarge(let bytes, let limit):
            return RuntimeWireError(
                domain: "integration",
                code: "integration.clipboardTooLarge",
                message: "The copied item is too large for Android (\(bytes); the limit is \(limit)).",
                remediation: "Copy a smaller item."
            )
        }
    }
}
