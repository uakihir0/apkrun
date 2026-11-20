import Foundation
import RuntimeAPI

/// Approves wrappers that are not in the registry (wrapper.md §7.3).
///
/// A launcher whose `requestEndpoint` was refused asks the daemon through the
/// broker's `requestApproval`. The service runs the static checks, enforces the
/// limits (one pending request per bundle ID, five prompts a minute, an
/// unexpired denial refuses at once), hands a prompt to the UI announcer, and
/// waits for `decide` or the ten-minute timeout.
public actor WrapperApprovalService {
    /// Tunables; tests shrink them.
    public struct Configuration: Sendable {
        /// How long a prompt waits for an answer (spec: 10 minutes).
        public var promptTimeout: Duration
        /// How long a denial blocks a new request (spec: 24 hours).
        public var denialDuration: Duration
        /// Requests allowed within `rateLimitWindow` (spec: 5 per minute).
        public var rateLimitCount: Int
        /// The rate-limit window.
        public var rateLimitWindow: Duration

        /// Creates the approval configuration.
        public init(
            promptTimeout: Duration = .seconds(600),
            denialDuration: Duration = .seconds(24 * 60 * 60),
            rateLimitCount: Int = 5,
            rateLimitWindow: Duration = .seconds(60)
        ) {
            self.promptTimeout = promptTimeout
            self.denialDuration = denialDuration
            self.rateLimitCount = rateLimitCount
            self.rateLimitWindow = rateLimitWindow
        }
    }

    /// What the service announces while an approval runs.
    public enum Announcement: Sendable {
        /// A new prompt is waiting; the UI should show it.
        case requested(ApprovalPrompt)
        /// A prompt was answered or expired.
        case resolved(ApprovalID)
        /// An allowed prompt registered a wrapper; publish `wrappers.created`.
        case created(WrapperSummary)
    }

    private struct PendingApproval {
        var prompt: ApprovalPrompt
        /// The cdhash and plist captured when the bundle passed the static
        /// checks, so the decision registers exactly the code the user saw.
        var cdhash: String
        var plist: [String: Any]
        var waiters: [CheckedContinuation<ApprovalReply, Never>]
        var timeoutTask: Task<Void, Never>
    }

    private let registry: WrapperRegistry
    private let announce: @Sendable (Announcement) -> Void
    private let packageInstalled: @Sendable (RuntimePackageID) async -> Bool
    private let iconProvider: @Sendable (URL) -> Data?
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async -> Void
    private var configuration: Configuration
    private var pendingByBundleID: [String: PendingApproval] = [:]
    private var recentRequests: [Date] = []

    /// Creates the approval service.
    /// - Parameters:
    ///   - registry: the wrapper registry; only apkrund writes it.
    ///   - announce: publishes prompts, resolutions, and created summaries.
    ///   - packageInstalled: whether the store has an installed record.
    ///   - iconProvider: a PNG icon of at most 256 px for the bundle, if any.
    ///   - configuration: timeouts and limits.
    ///   - now/sleep: clocks injected for tests.
    public init(
        registry: WrapperRegistry,
        announce: @escaping @Sendable (Announcement) -> Void,
        packageInstalled: @escaping @Sendable (RuntimePackageID) async -> Bool = { _ in false },
        iconProvider: @escaping @Sendable (URL) -> Data? = { _ in nil },
        configuration: Configuration = Configuration(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        self.registry = registry
        self.announce = announce
        self.packageInstalled = packageInstalled
        self.iconProvider = iconProvider
        self.configuration = configuration
        self.now = now
        self.sleep = sleep
    }

    /// Steps 1–5 of wrapper.md §7.3. Returns the reply the launcher maps to its
    /// screen: `approved` (repeat `requestEndpoint`), `denied`, or `timedOut`.
    public func request(
        bundleURL: URL,
        bundleID: String,
        packageID: RuntimePackageID
    ) async throws(WrapperFailure) -> ApprovalReply {
        // Step 3b: a second request for the same bundle ID joins the pending one.
        if var pending = pendingByBundleID[bundleID] {
            return await withCheckedContinuation { continuation in
                pending.waiters.append(continuation)
                pendingByBundleID[bundleID] = pending
            }
        }

        // Step 1: static checks of the bundle.
        let document = try staticCheck(bundleURL: bundleURL, bundleID: bundleID, packageID: packageID)

        // Step 2: cdhash.
        guard let cdhash = WrapperCodeSign.cdhash(of: bundleURL) else {
            throw .bundleInvalid(bundleURL, reason: .signatureInvalid)
        }

        // Step 3a: an unexpired denial for the same cdhash answers denied at once.
        if let denied = await registry.deniedEntries().first(where: {
            $0.bundleId == bundleID && $0.cdhash == cdhash && $0.until > now()
        }) {
            return .denied(until: denied.until)
        }

        // Step 3c: five requests a minute in total.
        let cutoff = now().addingTimeInterval(-configuration.rateLimitWindow.timeInterval)
        recentRequests.removeAll { $0 < cutoff }
        guard recentRequests.count < configuration.rateLimitCount else {
            throw .approvalBusy
        }
        recentRequests.append(now())

        // Step 4: build the prompt and ask.
        let plist = InfoPlistWriter.infoDictionary(of: bundleURL) ?? [:]
        let displayName =
            (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        let requestedAt = now()
        let expiresAt = requestedAt.addingTimeInterval(
            configuration.promptTimeout.timeInterval)
        let replacesURL = await registry.entry(bundleID: bundleID).flatMap {
            $0.state == .active ? URL(fileURLWithPath: $0.path) : nil
        }
        let prompt = ApprovalPrompt(
            approvalID: ApprovalID(rawValue: UUID().uuidString),
            kind: .wrapper,
            bundleURL: bundleURL,
            bundleID: bundleID,
            packageID: packageID,
            displayName: displayName,
            signer: signer(of: bundleURL),
            packageInstalled: await packageInstalled(packageID),
            bundledVersion: nil,
            replacesURL: replacesURL,
            integrations: Self.integrations(of: document),
            icon: iconProvider(bundleURL),
            requestedAt: requestedAt,
            expiresAt: expiresAt
        )

        // A request for the same bundle ID may have opened a pending entry
        // while the awaits above ran; join it instead of replacing its waiters.
        if var pending = pendingByBundleID[bundleID] {
            return await withCheckedContinuation { continuation in
                pending.waiters.append(continuation)
                pendingByBundleID[bundleID] = pending
            }
        }

        let approvalID = prompt.approvalID
        let timeout = configuration.promptTimeout
        let timeoutTask = Task { [weak self] in
            await self?.sleep(timeout)
            await self?.expire(approvalID: approvalID)
        }
        pendingByBundleID[bundleID] = PendingApproval(
            prompt: prompt,
            cdhash: cdhash,
            plist: plist,
            waiters: [],
            timeoutTask: timeoutTask
        )
        announce(.requested(prompt))

        return await withCheckedContinuation { continuation in
            if var pending = pendingByBundleID[bundleID] {
                pending.waiters.append(continuation)
                pendingByBundleID[bundleID] = pending
            } else {
                continuation.resume(returning: .timedOut)
            }
        }
    }

    /// Answers a pending prompt (wrapper.md §7.3 step 5). The first decision
    /// wins; an unknown, answered, or expired prompt throws `approvalNotFound`.
    @discardableResult
    public func decide(
        approvalID: ApprovalID,
        allow: Bool
    ) async throws(WrapperFailure) -> ApprovalReply {
        guard
            let key = pendingByBundleID.first(where: {
                $0.value.prompt.approvalID == approvalID
            })?.key, let pending = pendingByBundleID.removeValue(forKey: key)
        else {
            throw .approvalNotFound
        }
        pending.timeoutTask.cancel()
        announce(.resolved(approvalID))

        let reply: ApprovalReply
        do {
            if allow {
                let summary = try await register(pending: pending)
                announce(.created(summary))
                reply = .approved
            } else {
                let until = now().addingTimeInterval(configuration.denialDuration.timeInterval)
                do {
                    try await registry.deny(
                        bundleID: pending.prompt.bundleID,
                        cdhash: pending.cdhash,
                        until: until
                    )
                } catch {
                    throw WrapperFailure.registryUnavailable
                }
                reply = .denied(until: until)
            }
        } catch {
            // The launcher still needs a terminal reply (§7.3 step 5).
            for waiter in pending.waiters { waiter.resume(returning: .timedOut) }
            guard let failure = error as? WrapperFailure else {
                throw .registryUnavailable
            }
            throw failure
        }
        for waiter in pending.waiters { waiter.resume(returning: reply) }
        return reply
    }

    /// Ends every pending prompt during daemon shutdown. Each waiter gets
    /// `timedOut` so the broker's reply is not held past the drain.
    public func cancelAll() {
        let pending = pendingByBundleID
        pendingByBundleID.removeAll()
        for entry in pending.values {
            entry.timeoutTask.cancel()
            announce(.resolved(entry.prompt.approvalID))
            for waiter in entry.waiters { waiter.resume(returning: .timedOut) }
        }
    }

    /// The prompts that are still waiting (runtime-api.md `pendingApprovals`).
    public func pendingPrompts() -> [ApprovalPrompt] {
        pendingByBundleID.values.map(\.prompt).sorted { $0.requestedAt < $1.requestedAt }
    }

    /// Steps 1–3 and 5 without a prompt (`apkrun wrapper approve`, §7.3).
    public func approve(bundleURL: URL) async throws(WrapperFailure) -> WrapperSummary {
        guard let plist = InfoPlistWriter.infoDictionary(of: bundleURL),
            let packageID = plist["APKRunPackageID"] as? String,
            let bundleID = plist["CFBundleIdentifier"] as? String
        else {
            throw .bundleInvalid(bundleURL, reason: .wrapperJSONInvalid)
        }
        guard let runtimePackageID = RuntimePackageID(rawValue: packageID) else {
            throw .bundleInvalid(bundleURL, reason: .packageMismatch)
        }
        _ = try staticCheck(
            bundleURL: bundleURL,
            bundleID: bundleID,
            packageID: runtimePackageID
        )
        guard let cdhash = WrapperCodeSign.cdhash(of: bundleURL) else {
            throw .bundleInvalid(bundleURL, reason: .signatureInvalid)
        }
        let displayName =
            (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        return try await register(
            bundleURL: bundleURL,
            bundleID: bundleID,
            packageID: packageID,
            cdhash: cdhash,
            displayName: displayName,
            plist: plist
        )
    }

    /// The denied wrappers of Settings → Privacy (runtime-api.md `deniedWrappers`).
    public func deniedWrappers() async -> [DeniedWrapper] {
        await registry.deniedEntries().map { entry in
            DeniedWrapper(
                bundleID: entry.bundleId,
                packageID: nil,
                cdhash: entry.cdhash,
                until: entry.until
            )
        }
    }

    /// Removes every denial of a bundle ID (runtime-api.md `clearWrapperDenial`).
    public func clearDenial(bundleID: String) async throws(WrapperFailure) {
        do {
            try await registry.clearDenial(bundleID: bundleID)
        } catch {
            throw .registryUnavailable
        }
    }

    // MARK: - Internals

    /// The static checks of §7.3 step 1.
    private func staticCheck(
        bundleURL: URL,
        bundleID: String,
        packageID: RuntimePackageID
    ) throws(WrapperFailure) -> WrapperDocument {
        guard let plist = InfoPlistWriter.infoDictionary(of: bundleURL),
            let declaredPackageID = plist["APKRunPackageID"] as? String,
            let declaredBundleID = plist["CFBundleIdentifier"] as? String
        else {
            throw .bundleInvalid(bundleURL, reason: .wrapperJSONInvalid)
        }
        guard declaredBundleID == bundleID else {
            throw .bundleInvalid(bundleURL, reason: .identifierMismatch)
        }
        guard WrapperCodeSign.signatureIsValid(bundleURL: bundleURL, identifier: bundleID) else {
            throw .bundleInvalid(bundleURL, reason: .signatureInvalid)
        }
        guard bundleID == BundleIDMapper.map(packageID.rawValue),
            declaredPackageID == packageID.rawValue
        else {
            throw .bundleInvalid(bundleURL, reason: .bundleIDMismatch)
        }
        let document: WrapperDocument
        do {
            document = try WrapperDocumentCodec.load(from: bundleURL)
        } catch {
            throw .bundleInvalid(bundleURL, reason: .wrapperJSONInvalid)
        }
        guard document.application.packageId == packageID.rawValue else {
            throw .bundleInvalid(bundleURL, reason: .packageMismatch)
        }
        return document
    }

    /// The signer summary of §7.3 step 2.
    private func signer(of bundleURL: URL) -> RuntimeAPI.WrapperSigner {
        guard WrapperCodeSign.signatureIdentifier(of: bundleURL) != nil else {
            return .unknown
        }
        return .adHoc
    }

    /// Registers an approved bundle as a `user` entry (§7.3 step 5). Uses the
    /// cdhash and plist captured at request time: the user approved that exact
    /// code, not whatever now sits at the path.
    private func register(pending: PendingApproval) async throws(WrapperFailure) -> WrapperSummary {
        try await register(
            bundleURL: pending.prompt.bundleURL,
            bundleID: pending.prompt.bundleID,
            packageID: pending.prompt.packageID.rawValue,
            cdhash: pending.cdhash,
            displayName: pending.prompt.displayName,
            plist: pending.plist
        )
    }

    private func register(
        bundleURL: URL,
        bundleID: String,
        packageID: String,
        cdhash: String,
        displayName: String,
        plist: [String: Any]
    ) async throws(WrapperFailure) -> WrapperSummary {
        var entry = WrapperRegistryEntry(
            bundleId: bundleID,
            packageId: packageID,
            kind: .local,
            state: .pending,
            path: bundleURL.path,
            cdhash: cdhash,
            launcherVersion: (plist["APKRunLauncherVersion"] as? String) ?? "0",
            launcherAPI: (plist["APKRunLauncherAPI"] as? String) ?? "1.0",
            fileName: bundleURL.lastPathComponent,
            displayName: displayName,
            createdAt: now()
        )
        entry.approval = .user
        let bookmark = (try? bundleURL.bookmarkData()) ?? Data()
        do {
            try await registry.markPending(entry)
            try await registry.activate(bundleID: bundleID, path: bundleURL, bookmark: bookmark)
        } catch {
            throw .registryUnavailable
        }
        guard let summaryPackageID = RuntimePackageID(rawValue: packageID) else {
            throw .bundleInvalid(bundleURL, reason: .packageMismatch)
        }
        return WrapperSummary(
            packageID: summaryPackageID,
            bundleID: bundleID,
            displayName: displayName,
            kind: .local,
            bundleURL: bundleURL,
            status: WrapperStatus(state: .valid, refreshReasons: []),
            approval: .user,
            launcherVersion: entry.launcherVersion,
            createdAt: entry.createdAt
        )
    }

    /// Fires when a prompt's ten minutes are up.
    private func expire(approvalID: ApprovalID) {
        guard
            let key = pendingByBundleID.first(where: {
                $0.value.prompt.approvalID == approvalID
            })?.key, let pending = pendingByBundleID.removeValue(forKey: key)
        else { return }
        announce(.resolved(approvalID))
        for waiter in pending.waiters { waiter.resume(returning: .timedOut) }
    }

    /// The integration values the wrapper asks for (configuration.md §3.3).
    private static func integrations(
        of document: WrapperDocument
    ) -> [IntegrationKind: WireIntegrationDecision] {
        guard let integration = document.integration else { return [:] }
        var result: [IntegrationKind: WireIntegrationDecision] = [:]
        if let clipboard = integration.clipboard {
            result[.clipboard] = clipboard ? .on : .off
        }
        if let notifications = integration.notifications {
            result[.notifications] = notifications ? .on : .off
        }
        if let links = integration.links {
            switch links {
            case .android: result[.links] = .android
            case .ask: result[.links] = .ask
            case .mac: result[.links] = .mac
            }
        }
        if let files = integration.files {
            result[.files] = files ? .on : .off
        }
        if let sharedFolders = integration.sharedFolders {
            switch sharedFolders {
            case .off: result[.sharedFolders] = .off
            case .readOnly: result[.sharedFolders] = .readOnly
            case .readWrite: result[.sharedFolders] = .readWrite
            }
        }
        if let microphone = integration.microphone {
            result[.microphone] = microphone ? .on : .off
        }
        return result
    }
}

extension Duration {
    /// Seconds as a `TimeInterval` for `Date` arithmetic.
    fileprivate var timeInterval: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
