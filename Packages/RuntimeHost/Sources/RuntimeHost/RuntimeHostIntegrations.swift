import AVFoundation
import DiagnosticsCore
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
    private var recordings: Set<String> = []

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

    /// The enabled set the last Android boot carried (desktop-integration.md
    /// §9); the boot writes it through `microphoneProvider`.
    var microphoneBootedSet: Set<String> {
        get { lock.withLock { bootedMicrophoneSet } }
        set { lock.withLock { bootedMicrophoneSet = newValue } }
    }
    private var bootedMicrophoneSet: Set<String> = []

    /// The packages the guest reports as recording (§9.3).
    var activeRecordings: Set<String> {
        lock.withLock { recordings }
    }

    /// Replaces the recording set after a `recording_changed` event.
    func setRecordings(_ packages: Set<String>) {
        lock.withLock { recordings = packages }
    }
}

/// The channel that sends notification ops to the Guest Agent
/// (desktop-integration.md §5.1, guest-protocol.md §7.5).
private struct GuestNotificationsChannel: NotificationGuestChannel {
    /// Resolves the live agent supervisor; nil while no agent is connected.
    let supervisor: @Sendable () async -> GuestAgentSupervisor?

    func setNotificationForwarding(_ packages: [String]) async throws(IntegrationFailure) {
        try await send { try await $0.send(GuestSetNotificationForwarding(packages: packages)) }
    }

    func activateNotification(
        key: String, actionIndex: Int?, displayID: Int32
    ) async throws(IntegrationFailure) {
        try await send {
            try await $0.send(
                GuestActivateNotification(
                    key: key, actionIndex: actionIndex.map(Int32.init), displayID: displayID))
        }
    }

    func dismissNotification(key: String) async throws(IntegrationFailure) {
        try await send { try await $0.send(GuestDismissNotification(key: key)) }
    }

    private func send(
        _ body: @Sendable (GuestAgentSupervisor) async throws -> GPEmpty
    ) async throws(IntegrationFailure) {
        guard let agent = await supervisor() else {
            throw .guestUnavailable
        }
        do {
            _ = try await body(agent)
        } catch let failure as GuestProtocolFailure {
            if case .capabilityMissing(let capability) = failure {
                throw .notSupportedOnImage(capability: capability)
            }
            throw .guestUnavailable
        } catch {
            throw .guestUnavailable
        }
    }
}

/// The §5.3 host deliveries over `RuntimeStreamCenter`, the wrapper registry,
/// and `WorkspaceOpener`.
private struct HostNotificationSink: NotificationSink {
    /// The daemon; the sink outlives nothing it touches.
    weak var host: RuntimeHost?

    func relay(_ message: RelayMessage, to packageID: RuntimePackageID) async -> Bool {
        host?.streamCenter.sendRelay(message, to: packageID) ?? false
    }

    func hostNotify(_ message: HostNotificationMessage) async -> Bool {
        host?.streamCenter.sendHostNotification(message) ?? false
    }

    func wrapperExists(for packageID: RuntimePackageID) async -> Bool {
        guard let host,
            let entry = await host.wrapperRegistryInstance().entry(packageID: packageID)
        else {
            return false
        }
        return entry.state != .pending
    }

    func startWrapperInBackground(_ packageID: RuntimePackageID) async {
        guard let host,
            let entry = await host.wrapperRegistryInstance().entry(packageID: packageID),
            entry.state != .pending
        else {
            return
        }
        let candidates = WorkspaceOpener.applicationURLs(bundleIdentifier: entry.bundleId)
        guard let appURL = candidates.first else {
            return
        }
        await WorkspaceOpener.openApplication(
            at: appURL,
            arguments: ["--apkrun-background", "notifications"],
            activates: false,
            hides: true,
            addsToRecentItems: false
        )
    }

    func displayName(for packageID: RuntimePackageID) async -> String? {
        guard let host else { return nil }
        if let entry = await host.wrapperRegistryInstance().entry(packageID: packageID),
            !entry.displayName.isEmpty
        {
            return entry.displayName
        }
        return
            (try? await host.packageServiceForIntegrations()?.packageInfo(
                RuntimePackageRequest(packageID: packageID)))??.summary.displayName
    }
}

/// The channel that sends host clips to the Guest Agent (desktop-integration.md §3.3).
private struct GuestClipboardChannel: IntegrationChannel {
    /// `RuntimeHost`'s async send; throws any error, mapped here.
    let send: @Sendable (GPClipData) async throws -> Void
    /// Whether the image advertises `clipboard.image.v1`.
    let imagesSupported: @Sendable () async -> Bool
    /// Uploads PNG bytes on the bulk stream; answers the transfer ID.
    let upload: @Sendable (Data) async throws -> UInt64
    /// The payload of an announced inbound transfer.
    let inbound: @Sendable (UInt64) async -> Data?

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

    /// `clipboard.image.v1` on the running image (guest-protocol.md §5.3).
    func supportsImages() async -> Bool {
        await imagesSupported()
    }

    /// Sends the image on the bulk stream; a send failure is `guestUnavailable`.
    func uploadClipboardImage(_ png: Data) async throws(IntegrationFailure) -> UInt64 {
        do {
            return try await upload(png)
        } catch {
            throw .guestUnavailable
        }
    }

    /// The resolved bytes of a guest-announced transfer.
    func inboundTransfer(_ transferID: UInt64) async -> Data? {
        await inbound(transferID)
    }
}

/// The channel that sends link ops to the Guest Agent
/// (desktop-integration.md §7.2, guest-protocol.md §7.5).
private struct GuestLinkChannel: LinkChannel {
    /// Resolves the live agent supervisor; nil while no agent is connected.
    let supervisor: @Sendable () async -> GuestAgentSupervisor?
    /// Whether the image advertises `url.v1`.
    let imageSupportsLinks: @Sendable () async -> Bool

    func supportsLinks() async -> Bool {
        await imageSupportsLinks()
    }

    func resolveUrl(requestID: UInt64, action: GPUrlAction) async throws(IntegrationFailure) {
        try await send {
            try await $0.send(GuestResolveUrl(requestID: requestID, action: action))
        }
    }

    func setUrlRedirect(enabled: Bool, excludedPackages: [String]) async throws(IntegrationFailure) {
        try await send {
            try await $0.send(
                GuestSetUrlRedirect(enabled: enabled, excludedPackages: excludedPackages))
        }
    }

    private func send(
        _ body: @Sendable (GuestAgentSupervisor) async throws -> GPEmpty
    ) async throws(IntegrationFailure) {
        guard let agent = await supervisor() else {
            throw .guestUnavailable
        }
        do {
            _ = try await body(agent)
        } catch let failure as GuestProtocolFailure {
            if case .capabilityMissing(let capability) = failure {
                throw .notSupportedOnImage(capability: capability)
            }
            throw .guestUnavailable
        } catch {
            throw .guestUnavailable
        }
    }
}

/// The `LinkOpener` over `NSWorkspace` (desktop-integration.md §7.2).
private struct HostLinkOpener: LinkOpener {
    func open(_ url: URL) async {
        WorkspaceOpener.open(url)
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
        let channel = GuestClipboardChannel(
            send: { [weak self] clip in
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
            },
            imagesSupported: { [weak self] in
                self?.integrationSettings.supports("clipboard.image.v1") ?? false
            },
            upload: { [weak self] png in
                guard let channel = try await self?.clipboardBulkChannel() else {
                    throw IntegrationFailure.guestUnavailable
                }
                return try await channel.send(
                    payload: png, kind: .clipboardImage, mimeType: "image/png")
            },
            inbound: { [weak self] transferID in
                guard let channel = try? await self?.clipboardBulkChannel() else {
                    return nil
                }
                // The transfer lands in the transfer cache first, is read
                // once, and is deleted (desktop-integration.md §4.4).
                guard let transfer = await channel.transfer(transferID) else {
                    return nil
                }
                return self?.readTransferOnce(transfer)
            })
        let coordinator = ClipboardCoordinator(policy: policy, channel: channel) {
            [weak self] sessionID, packageID, item in
            await self?.publishGuestClip(sessionID: sessionID, packageID: packageID, item: item)
        }
        clipboardCoordinator = coordinator
        return coordinator
    }

    /// Refreshes the synchronous policy inputs from settings.json and
    /// PackageStore before an evaluation (desktop-integration.md §2.3).
    func refreshIntegrationSettings(for packageID: RuntimePackageID) async {
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
            // A guest→host image rides the bulk connection; open it before
            // the guest can announce a transfer — it otherwise opens lazily
            // on the first host upload (desktop-integration.md §4.4).
            await self?.refreshIntegrationCapabilities()
            if let self, await self.integrationSettings.supports("clipboard.image.v1") {
                _ = try? await self.clipboardBulkChannel().open()
            }
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
        let details = try await packageInfo(RuntimePackageRequest(packageID: packageID))
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
                    capability: capability,
                    macPermission: await macPermissionText(
                        for: kind, packageID: packageID,
                        displayName: details.summary.displayName)
                )
            )
        }
        return IntegrationStatus(
            packageID: packageID,
            items: items,
            microphoneNeedsRestart: await microphoneNeedsRestart())
    }

    /// The host-ui §7.4 permission line of a kind: the notifications case is
    /// "Notifications for ‹App› are turned off in System Settings." when the
    /// wrapper reported `.denied`; the microphone case reports apkrund's own
    /// TCC answer, since the daemon owns the audio input device (§9.5).
    private func macPermissionText(
        for kind: IntegrationKind,
        packageID: RuntimePackageID,
        displayName: String
    ) async -> String? {
        switch kind {
        case .notifications:
            guard await notificationCoordinator().macPermission(for: packageID) == .denied
            else {
                return nil
            }
            return "Notifications for \(displayName) are turned off in System Settings."
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .denied, .restricted:
                return
                    "APKRun needs microphone access in System Settings → Privacy & Security → Microphone."
            case .authorized, .notDetermined:
                return nil
            @unknown default:
                return nil
            }
        default:
            return nil
        }
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
        case .notifications:
            return NotificationCoordinator.requiredCapability
        case .links:
            return LinkForwarder.requiredCapability
        case .files, .sharedFolders, .microphone:
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

    // MARK: - Notifications (desktop-integration.md §5)

    /// The §5.3 coordinator, built on first use. Also installs the stream
    /// callbacks so relay responses reach it.
    func notificationCoordinator() -> NotificationCoordinator {
        if let notificationCoordinatorLazy { return notificationCoordinatorLazy }
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
        let channel = GuestNotificationsChannel { [weak self] in
            await self?.runtimeSupervisorForIntegrations()?.developmentGuestAgent?.supervisor
        }
        let sink = HostNotificationSink(host: self)
        let coordinator = NotificationCoordinator(
            policy: policy, channel: channel, sink: sink,
            logSink: hostLogSink)
        registerIntegrationHealthChecks()
        let center = streamCenter
        center.onRelayStreamOpened = { packageID, _ in
            Task { await coordinator.relayOpened(packageID: packageID) }
        }
        center.onRelayResponse = { [weak self] streamID, response in
            guard let self else { return }
            switch response {
            case .activated(let identifier, let actionIndex):
                Task {
                    // A relay stream without a package record is not a
                    // wrapper answer; dropping it is the safe default.
                    guard let package = center.relayPackageID(for: streamID) else { return }
                    await coordinator.activated(
                        identifier: identifier, actionIndex: actionIndex,
                        displayID: await self.displayIDForActivation(of: identifier),
                        fromPackage: package)
                }
            case .dismissed(let identifier):
                Task {
                    guard let package = center.relayPackageID(for: streamID) else { return }
                    await coordinator.dismissed(
                        identifier: identifier, fromPackage: package)
                }
            case .authorizationChanged(let state):
                if let packageID = center.relayPackageID(for: streamID) {
                    Task { await coordinator.noteAuthorization(state, packageID: packageID) }
                }
            case .unknown:
                break
            }
        }
        center.onHostNotificationResponse = { [weak self] _, response in
            guard let self else { return }
            switch response {
            case .activated(let identifier, let action):
                let index: Int?
                if case .android(let i, _) = action { index = i } else { index = nil }
                Task {
                    // The host stream belongs to APKRun.app itself: trusted,
                    // not package-scoped (nil = unrestricted caller).
                    await coordinator.activated(
                        identifier: identifier, actionIndex: index,
                        displayID: await self.displayIDForActivation(of: identifier),
                        fromPackage: nil)
                }
            case .dismissed(let identifier):
                Task { await coordinator.dismissed(identifier: identifier, fromPackage: nil) }
            case .unknown:
                break
            }
        }
        notificationCoordinatorLazy = coordinator
        return coordinator
    }

    /// The session display of the package a wire identifier belongs to (§5.4);
    /// 0 when the package has no session (the primary display).
    private func displayIDForActivation(of identifier: String) async -> Int32 {
        guard let packageRaw = identifier.split(separator: "|").first.map(String.init) else {
            return 0
        }
        let snapshots = await sessionServiceForIntegrations()?.sessionSnapshots() ?? []
        return snapshots.first { $0.packageID == packageRaw }?.displayID ?? 0
    }

    /// Starts the guest→coordinator notification relay once the agent is
    /// ready, and pushes the forwarding allowlist (§3.2, §5.1).
    func startNotificationRelay() {
        guard notificationRelayTask == nil, let supervisor = runtimeSupervisorForIntegrations() else {
            return
        }
        notificationRelayTask = Task.detached { [weak self] in
            guard let self else { return }
            var agent = await supervisor.developmentGuestAgent
            while !Task.isCancelled, let current = agent {
                await self.pushNotificationForwarding()
                for await event in current.notificationEvents {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case .posted(let notification):
                        await self.notificationFromGuest(notification)
                    case .removed(let removal):
                        await self.removedFromGuest(removal)
                    }
                }
                // The stream ended: an agent restart detaches it while
                // Android keeps running. Wait for a different agent, then
                // resubscribe — the allowlist went away with the old one.
                agent = nil
                while !Task.isCancelled, agent == nil {
                    try? await Task.sleep(for: .seconds(1))
                    let next = await supervisor.developmentGuestAgent
                    if let next, next !== current {
                        agent = next
                    }
                }
            }
            await self.clearNotificationRelayTask()
        }
    }

    /// Clears the finished relay task so `startNotificationRelay` re-arms.
    private func clearNotificationRelayTask() {
        notificationRelayTask = nil
    }

    /// Ends the notification relay.
    func stopNotificationRelay() {
        notificationRelayTask?.cancel()
        notificationRelayTask = nil
    }

    /// Pushes `SetNotificationForwarding` for every managed package (§5.1).
    func pushNotificationForwarding() async {
        guard let service = packageServiceForIntegrations() else { return }
        guard let result = try? await service.listPackages(RuntimeListPackagesRequest()) else {
            return
        }
        var candidates: [RuntimePackageID] = []
        for summary in result.packages {
            await refreshIntegrationSettings(for: summary.packageID)
            candidates.append(summary.packageID)
        }
        try? await notificationCoordinator().pushForwardingList(candidates)
    }

    /// One `notification_posted` event for the coordinator (§5.3).
    func notificationFromGuest(_ notification: GPNotification) async {
        if let packageID = RuntimePackageID(rawValue: notification.package) {
            await refreshIntegrationSettings(for: packageID)
        }
        await notificationCoordinator().posted(notification)
    }

    /// One `notification_removed` event for the coordinator (§5.3).
    func removedFromGuest(_ removal: GPNotificationRemoved) async {
        await notificationCoordinator().removed(removal)
    }

    // MARK: - Links (desktop-integration.md §7.2)

    /// The §7.2 forwarder, built on first use.
    func linkForwarder() -> LinkForwarder {
        if let linkForwarderLazy { return linkForwarderLazy }
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
        let sink = hostLogSink
        let channel = GuestLinkChannel(
            supervisor: { [weak self] in
                await self?.runtimeSupervisorForIntegrations()?.developmentGuestAgent?.supervisor
            },
            imageSupportsLinks: { [weak self] in
                self?.integrationSettings.supports(LinkForwarder.requiredCapability) ?? false
            })
        let forwarder = LinkForwarder(
            policy: policy,
            channel: channel,
            opener: HostLinkOpener(),
            linksValue: { packageID in
                settings.packageValue(packageID.rawValue, IntegrationKind.links.rawValue)
            },
            windowState: { [weak self] packageID in
                // A link lands only on the key window of the package
                // (§7.2); input-within-5 s is not tracked separately.
                // TODO(#82): feed last-input timestamps from InputCore.
                guard let self else {
                    return LinkWindowState(sessionID: nil, usable: false)
                }
                let key = await self.integrationCoordinator().currentKeySession
                let isKey = key?.packageID == packageID
                return LinkWindowState(sessionID: isKey ? key?.sessionID : nil, usable: isKey)
            },
            presentPrompt: { [weak self] sessionID, packageID, prompt in
                self?.eventHub.publishIntegrationChange(
                    .linkPrompt(sessionID: sessionID, packageID: packageID, prompt: prompt))
            },
            setLinksValue: { [weak self] packageID, value in
                guard let self, let service = await self.packageServiceForIntegrations() else {
                    return
                }
                _ = try? await service.updatePackageSettings(
                    RuntimeUpdatePackageSettingsRequest(
                        packageID: packageID,
                        patch: RuntimePackageSettingsPatch(
                            set: ["integrations.links": value])))
                if let stored = try? await service.packageIntegrationSettings(
                    for: packageID.rawValue)
                {
                    self.integrationSettings.setPackage(
                        packageID.rawValue, values: stored.integrations)
                }
                await self.pushUrlRedirect()
            },
            excludedPackages: { [weak self] in
                guard let self, let service = await self.packageServiceForIntegrations() else {
                    return []
                }
                guard let result = try? await service.listPackages(RuntimeListPackagesRequest())
                else {
                    return []
                }
                var excluded: [String] = []
                for summary in result.packages {
                    let stored = try? await service.packageIntegrationSettings(
                        for: summary.packageID.rawValue)
                    let value = stored?.value("integrations.links")
                    if value == "android" || value == "off" {
                        excluded.append(summary.packageID.rawValue)
                    }
                }
                return excluded
            },
            logDrop: { packageID, rejection, url in
                Self.logLinkDrop(
                    sink: sink, packageID: packageID, rejection: rejection, url: url)
            })
        linkForwarderLazy = forwarder
        return forwarder
    }

    /// `resolveLinkPrompt`: the key window's answer to a link prompt
    /// (runtime-api.md §11.2).
    public func resolveLinkPrompt(
        sessionID: UUID,
        promptID: UUID,
        choice: LinkChoice,
        remember: Bool,
        callerPackageID: RuntimePackageID? = nil
    ) async throws(RuntimeWireError) {
        do {
            try await linkForwarder().resolvePrompt(
                sessionID: sessionID, promptID: promptID, choice: choice, remember: remember,
                callerPackageID: callerPackageID)
        } catch let failure as IntegrationFailure {
            throw Self.integrationWireError(failure)
        } catch {
            throw Self.integrationWireError(.guestUnavailable)
        }
    }

    /// Starts the guest→forwarder `open_url_on_host` relay once the agent is
    /// ready, and pushes SetUrlRedirect on each (re)connection (§3.2).
    func startLinkRelay() {
        guard linkRelayTask == nil, let supervisor = runtimeSupervisorForIntegrations() else {
            return
        }
        linkRelayTask = Task.detached { [weak self] in
            guard let self else { return }
            var agent = await supervisor.developmentGuestAgent
            while !Task.isCancelled, let current = agent {
                await self.refreshIntegrationCapabilities()
                await self.pushUrlRedirect()
                for await event in current.urlEvents {
                    guard !Task.isCancelled else { return }
                    if let packageID = RuntimePackageID(rawValue: event.sourcePackage) {
                        await self.refreshIntegrationSettings(for: packageID)
                    }
                    _ = await self.linkForwarder().openUrlOnHost(event)
                }
                // A stream that ended means an agent restart: wait for the
                // next agent, then resubscribe and re-push (the forwarder
                // stays; its pending prompts keep their 60 s expiry).
                agent = nil
                while !Task.isCancelled, agent == nil {
                    try? await Task.sleep(for: .seconds(1))
                    let next = await supervisor.developmentGuestAgent
                    if let next, next !== current {
                        agent = next
                    }
                }
            }
            await self.clearLinkRelayTask()
        }
    }

    /// Clears the finished relay task so `startLinkRelay` re-arms.
    private func clearLinkRelayTask() {
        linkRelayTask = nil
    }

    /// Ends the link relay.
    func stopLinkRelay() {
        linkRelayTask?.cancel()
        linkRelayTask = nil
    }

    /// Starts the microphone relay of desktop-integration.md §8.2: pushes the
    /// `SetMicrophoneAccess` allowlist on each (re)connection and republishes
    /// the guest's `recording_changed` events on the `integrations` topic.
    func startMicrophoneRelay() {
        guard microphoneRelayTask == nil,
            let supervisor = runtimeSupervisorForIntegrations()
        else {
            return
        }
        microphoneRelayTask = Task.detached { [weak self] in
            guard let self else { return }
            var agent = await supervisor.developmentGuestAgent
            while !Task.isCancelled, let current = agent {
                await self.pushMicrophoneAccess()
                for await event in current.recordingEvents {
                    guard !Task.isCancelled else { return }
                    let set = Set(event.packages)
                    self.integrationSettings.setRecordings(set)
                    self.eventHub.publishIntegrationChange(
                        .recordingChanged(
                            packageIDs: set.compactMap { RuntimePackageID(rawValue: $0) }))
                }
                // A stream that ended means an agent restart: wait for the
                // next agent, then resubscribe and re-push the allowlist.
                agent = nil
                while !Task.isCancelled, agent == nil {
                    try? await Task.sleep(for: .seconds(1))
                    let next = await supervisor.developmentGuestAgent
                    if let next, next !== current {
                        agent = next
                    }
                }
            }
            await self.clearMicrophoneRelayTask()
        }
    }

    /// Clears the finished relay task so `startMicrophoneRelay` re-arms.
    private func clearMicrophoneRelayTask() {
        microphoneRelayTask = nil
    }

    /// Ends the microphone relay.
    func stopMicrophoneRelay() {
        microphoneRelayTask?.cancel()
        microphoneRelayTask = nil
    }

    /// Pushes the current microphone allowlist (desktop-integration.md §8.2):
    /// the global switch gates the kind, then every package whose stored
    /// `integrations.microphone` is "true". Packages absent from the list keep
    /// recording silence; packages installed later are denied by the gate.
    func pushMicrophoneAccess() async {
        guard let supervisor = runtimeSupervisorForIntegrations(),
            let agent = await supervisor.developmentGuestAgent,
            let service = packageServiceForIntegrations()
        else {
            return
        }
        guard let result = try? await service.listPackages(RuntimeListPackagesRequest())
        else {
            return
        }
        let global = integrationSettings.globalEnabled(IntegrationKind.microphone.rawValue)
        var packageValues: [String: String?] = [:]
        for summary in result.packages {
            let stored = try? await service.packageIntegrationSettings(
                for: summary.packageID.rawValue)
            packageValues[summary.packageID.rawValue] =
                stored?.value("integrations.microphone")
        }
        let set = AudioPolicy.enabledPackages(
            packageValues: packageValues, globalEnabled: global)
        do {
            _ = try await agent.supervisor.send(
                GuestSetMicrophoneAccess(packages: set.sorted()))
        } catch {
            let logger = APKLogger(
                category: RuntimeLogCategory.host, sink: hostLogSink)
            logger.notice(
                "SetMicrophoneAccess failed; the gate keeps its previous list")
        }
    }

    /// The packages the guest reports as recording (desktop-integration.md
    /// §9.3): package IDs only, never contents or levels (NFR-SEC-05).
    public func activeRecordings() -> Set<String> {
        integrationSettings.activeRecordings
    }

    /// Whether a microphone change is waiting on an Android restart: the
    /// `recording_changed`… booted input stream differs from what the current
    /// allowlist needs (§9.4).
    func microphoneNeedsRestart() async -> Bool {
        guard let service = packageServiceForIntegrations(),
            let result = try? await service.listPackages(RuntimeListPackagesRequest())
        else {
            return false
        }
        let global = integrationSettings.globalEnabled(IntegrationKind.microphone.rawValue)
        var packageValues: [String: String?] = [:]
        for summary in result.packages {
            let stored = try? await service.packageIntegrationSettings(
                for: summary.packageID.rawValue)
            packageValues[summary.packageID.rawValue] =
                stored?.value("integrations.microphone")
        }
        let current = AudioPolicy.enabledPackages(
            packageValues: packageValues, globalEnabled: global)
        return !current.isEmpty != !integrationSettings.microphoneBootedSet.isEmpty
    }

    /// Pushes the current SetUrlRedirect state: the global links switch and
    /// the packages that keep their intents (§3.2).
    func pushUrlRedirect() async {
        await linkForwarder().pushUrlRedirect(
            enabled: integrationSettings.globalEnabled(IntegrationKind.links.rawValue))
    }

    /// The §7.2 drop log: scheme and registrable domain, never the full URL.
    private static func logLinkDrop(
        sink: (any LogSink)?,
        packageID: RuntimePackageID, rejection: LinkRejection, url: URL?
    ) {
        let logger = APKLogger(category: RuntimeLogCategory.host, sink: sink)
        let host = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.host }
        let domain = host.map { LinkForwarder.registrableDomain(of: $0) } ?? "-"
        let scheme =
            url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.scheme } ?? "-"
        logger.debug(
            "Dropped a link from \(packageID.rawValue, .public): \(rejection.rawValue, .public) \(scheme, .public) \(domain, .public)"
        )
    }

    /// Maps an `IntegrationFailure` to its catalog wire error (§13.1).
    static func integrationWireError(_ failure: IntegrationFailure) -> RuntimeWireError {
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
        case .promptTimedOut:
            return RuntimeWireError(
                domain: "integration",
                code: "integration.promptTimedOut",
                message: "The link prompt is no longer open.",
                remediation: nil
            )
        case .linkRejected(let reason):
            return RuntimeWireError(
                domain: "integration",
                code: "integration.linkRejected",
                message: "The link was dropped (\(reason.rawValue)).",
                remediation: nil
            )
        case .tooManyFiles(let count, let limit):
            return RuntimeWireError(
                domain: "integration",
                code: "integration.tooManyFiles",
                message: "Too many files at once (\(count)).",
                remediation: "Drop at most \(limit) files at a time."
            )
        case .fileTooLarge(let name, let bytes):
            return RuntimeWireError(
                domain: "integration",
                code: "integration.fileTooLarge",
                message: "\(name) is too large to drop into Android (\(bytes) bytes).",
                remediation: "Drop files of up to 2 GB each and 4 GB in total."
            )
        case .transferFailed(let detail):
            return RuntimeWireError(
                domain: "integration",
                code: "integration.transferFailed",
                message: "The file transfer didn't finish (\(detail)).",
                remediation: "Try again."
            )
        case .folderUnavailable(let problem):
            return RuntimeWireError(
                domain: "integration",
                code: "integration.folderUnavailable",
                message: "A shared folder can't be used (\(problem.rawValue)).",
                remediation: nil
            )
        case .pathRejected(let problem):
            return RuntimeWireError(
                domain: "integration",
                code: "integration.pathRejected",
                message: "The file request was refused (\(problem.rawValue)).",
                remediation: nil
            )
        case .folderRefused(let reason):
            return RuntimeWireError(
                domain: "integration",
                code: "integration.folderRefused",
                message: "The folder can't be shared (\(reason.rawValue)).",
                remediation: nil
            )
        case .readOnly:
            return RuntimeWireError(
                domain: "integration",
                code: "integration.readOnly",
                message: "The app can only read files in the shared folders.",
                remediation:
                    "To allow changes, set Shared folders to Read and write in the app's settings, and give the folder Read and write access in Settings → Files."
            )
        }
    }
}

/// `integrations.notificationListener` (diagnostics.md §7.3): the Guest
/// Agent's notification listener access, read from the latest snapshot the
/// supervisor holds. The guest re-grants access itself on loss
/// (guest-components.md §5), so a failure is a warning, not a fix.
struct NotificationListenerCheck: HealthCheck {
    /// Resolves the live agent supervisor; nil while no agent is connected.
    let supervisor: @Sendable () async -> GuestAgentSupervisor?

    var id: HealthCheckID { "integrations.notificationListener" }
    var group: HealthGroup { .integrations }
    var requirement: HealthRequirement { .runningRuntime }
    var cost: HealthCost { .quick }
    var title: LocalizedText {
        LocalizedText(
            key: "health.integrations.notificationListener",
            fallback: "Notification listener")
    }

    func run(_ context: HealthContext) async -> DiagnosticsCore.HealthResult {
        let now = context.clock.now
        guard let supervisor = await supervisor() else {
            return DiagnosticsCore.HealthResult(
                id: id, group: group, state: .skipped, title: title,
                detail: "The Guest Agent is not connected.",
                error: nil, measuredAt: now)
        }
        if await supervisor.snapshot.notificationListenerEnabled {
            return DiagnosticsCore.HealthResult(
                id: id, group: group, state: .pass, title: title,
                detail: "The notification listener has access.",
                error: nil, measuredAt: now)
        }
        return DiagnosticsCore.HealthResult(
            id: id, group: group, state: .warning, title: title,
            detail: "The notification listener lost its access.",
            error: ErrorInfo(
                code: "integration.notificationAccessMissing",
                message: LocalizedText(
                    key: "integration.notificationAccessMissing",
                    fallback: "Android lost access to its notifications."),
                remediation: LocalizedText(
                    key: "integration.notificationAccessMissing.remediation",
                    fallback: "The Guest Agent restores the access automatically; restart Android if the warning stays."
                ),
                action: .none),
            measuredAt: now)
    }
}

extension RuntimeHost {
    /// Registers the integrations health checks once (diagnostics.md §7.3).
    func registerIntegrationHealthChecks() {
        guard !integrationHealthChecksRegistered,
            let checks = healthCheckRegistry
        else { return }
        integrationHealthChecksRegistered = true
        Task {
            try? await checks.register(
                NotificationListenerCheck(supervisor: { [weak self] in
                    await self?.runtimeSupervisorForIntegrations()?
                        .developmentGuestAgent?.supervisor
                }))
        }
    }
}

extension RuntimeHost {
    /// The bulk channel of the current agent session, opened on first use
    /// (guest-protocol.md §10). A new session token rebuilds it.
    func clipboardBulkChannel() async throws -> GuestBulkChannel {
        guard let supervisor = runtimeSupervisorForIntegrations(),
            let agent = await supervisor.developmentGuestAgent,
            let token = await agent.supervisor.session?.sessionToken
        else {
            throw GuestProtocolFailure.disconnected
        }
        if let channel = integrationBulkChannel, channel.token == token {
            return channel.channel
        }
        if let channel = integrationBulkChannel {
            await channel.channel.close()
        }
        let channel = GuestBulkChannel(agent: agent, token: token)
        integrationBulkChannel = (token, channel)
        return channel
    }

    /// Writes a finished transfer into `~/Library/Caches/io.apkrun.APKRun/
    /// transfers/`, reads it back, and deletes the file
    /// (desktop-integration.md §4.4). A failure anywhere answers the bytes.
    nonisolated func readTransferOnce(_ transfer: GuestInboundTransfer) -> Data? {
        guard let bytes = transfer.bytes, !bytes.isEmpty else { return nil }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory =
            caches
            .appendingPathComponent("io.apkrun.APKRun", isDirectory: true)
            .appendingPathComponent("transfers", isDirectory: true)
        let file = directory.appendingPathComponent("\(transfer.transferID)")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try bytes.write(to: file, options: .atomic)
            let read = try Data(contentsOf: file)
            try? FileManager.default.removeItem(at: file)
            return read
        } catch {
            try? FileManager.default.removeItem(at: file)
            return bytes
        }
    }
}
