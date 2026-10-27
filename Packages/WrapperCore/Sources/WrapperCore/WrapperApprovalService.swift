import Foundation
import RuntimeAPI
import Security

/// One validated wrapper approval request ready to be shown by the control client.
public struct WrapperApprovalChallenge: Equatable, Sendable {
    /// The identifier used to submit a decision.
    public let approvalID: ApprovalID

    /// The validated facts that the approval UI should show.
    public let prompt: RuntimeWrapperApprovalPrompt

    fileprivate init(prompt: RuntimeWrapperApprovalPrompt) {
        approvalID = prompt.approvalID
        self.prompt = prompt
    }
}

/// Static identity facts used to bind a one-use approval endpoint to the wrapper binary.
///
/// This value contains no approval token and grants no package access. The broker may use it to
/// create an endpoint whose code-signing requirement matches the inspected bundle; the endpoint
/// must still revalidate the bundle before it consumes quota or creates a prompt.
public struct WrapperApprovalEndpointIdentity: Equatable, Sendable {
    /// The canonical path to the app bundle.
    public let bundlePath: String
    /// The bundle identifier validated against the signature and bundle metadata.
    public let bundleID: String
    /// The Android package identifier validated against `wrapper.json`.
    public let packageID: RuntimePackageID
    /// The validated executable cdhash.
    public let cdhash: String

    fileprivate init(
        bundlePath: String,
        bundleID: String,
        packageID: RuntimePackageID,
        cdhash: String
    ) {
        self.bundlePath = bundlePath
        self.bundleID = bundleID
        self.packageID = packageID
        self.cdhash = cdhash
    }
}

/// Installed package facts used in the wrapper approval prompt.
public struct WrapperApprovalPackageStatus: Equatable, Sendable {
    /// Whether the Android package is installed.
    public let isInstalled: Bool
    /// Its installed version, when package metadata is available.
    public let installedVersion: String?

    /// Creates the package facts shown in the approval prompt.
    public init(isInstalled: Bool, installedVersion: String? = nil) {
        self.isInstalled = isInstalled
        self.installedVersion = installedVersion
    }
}

/// Validates unknown wrapper bundles and records explicit user approval or denial.
///
/// The service owns ephemeral admission and pending-request state. `WrapperRegistry` remains the
/// sole durable authorization source. In particular, the broker request's bundle and package
/// identifiers are claims: the service verifies them against the signed bundle and its manifest.
public actor WrapperApprovalService {
    /// Failures raised while validating or resolving one approval request.
    public enum Failure: Error, Equatable, Sendable {
        /// The bundle could not be read or was not a supported app bundle.
        case invalidBundle
        /// The bundle signature did not pass strict static validation.
        case invalidSignature
        /// A claim, plist identity, signed identifier, manifest identity, or mapped ID disagreed.
        case identityMismatch
        /// The bundle or manifest contains unsupported or inconsistent version metadata.
        case invalidVersion
        /// The signature type is known, but notarization or signer identity could not be verified.
        case signerVerificationUnavailable
        /// The manifest could not be decoded as a bounded wrapper document.
        case invalidManifest
        /// A pending request already exists for this bundle identifier.
        case alreadyPending
        /// The service has accepted five requests in the trailing minute.
        case rateLimited
        /// The same bundle identifier and code hash were denied within the last 24 hours.
        case recentlyDenied
        /// The request is unknown, expired, or has already been resolved.
        case unknownApproval
        /// Another decision is already being committed for this request.
        case decisionInProgress
        /// The bookmark needed for durable authorization could not be created.
        case bookmarkUnavailable
        /// The durable registry could not be read or atomically written.
        case registry(WrapperRegistry.Failure)
    }

    private struct PendingApproval {
        let challenge: WrapperApprovalChallenge
        let validated: ValidatedWrapper
        let identity: ApprovalRequestIdentity
        let createdAt: Date
        let deadline: Date
        var isCommittingDecision = false
        var deadlineElapsed = false
        var hasIndependentConfirmation = false
        var timeoutTask: Task<Void, Never>?
    }

    private struct ApprovalRequestIdentity: Equatable, Sendable {
        let bundlePath: String
        let bundleID: String
        let packageID: RuntimePackageID
        let cdhash: String

        init(_ validated: ValidatedWrapper) {
            bundlePath = validated.bundleURL.path
            bundleID = validated.bundleID
            packageID = validated.packageID
            cdhash = validated.cdhash
        }
    }

    private struct PreparingApproval {
        let token: UUID
        let identity: ApprovalRequestIdentity
        let task: Task<Result<WrapperApprovalChallenge, Failure>, Never>
    }

    private struct CompletedApproval {
        let outcome: RuntimeWrapperApprovalOutcome
        let completedAt: Date
    }

    private struct ValidatedWrapper: Sendable {
        let bundleURL: URL
        let bundleID: String
        let packageID: RuntimePackageID
        let kind: WrapperRegistryFile.Entry.Kind
        let cdhash: String
        let launcherVersion: String
        let launcherAPI: String
        let formatVersion: Int
        let displayName: String
        let signer: RuntimeWrapperSignerSummary
        let integrations: RuntimeWrapperIntegrationSummary
    }

    private static let maximumRequestsPerMinute = 5
    private static let requestWindow: TimeInterval = 60
    private static let pendingLifetime: TimeInterval = 10 * 60
    private static let denialLifetime: TimeInterval = 24 * 60 * 60
    private static let completedLifetime: TimeInterval = 5 * 60
    fileprivate static let maximumManifestBytes = 64 * 1024

    private let registry: WrapperRegistry
    private let inspector: any WrapperBundleInspecting
    private let bookmarkFactory: @Sendable (URL) throws -> Data
    private let monotonicNow: @Sendable () -> TimeInterval
    private let wallClock: @Sendable () -> Date
    private let onResolution: @Sendable (ApprovalID) -> Void

    private var pendingByID: [ApprovalID: PendingApproval] = [:]
    private var pendingApprovalByBundleID: [String: ApprovalID] = [:]
    private var preparingApprovalByBundleID: [String: PreparingApproval] = [:]
    private var independentConfirmationsByBundleID: [String: Int] = [:]
    private var requestTimes: [TimeInterval] = []
    private var completedByID: [ApprovalID: CompletedApproval] = [:]
    private var completionOrder: [ApprovalID] = []
    private var waiters: [ApprovalID: [UUID: CheckedContinuation<RuntimeWrapperApprovalOutcome, Never>]] = [:]

    /// Creates the production approval service, using Security.framework and security-scoped bookmarks.
    public init(
        registry: WrapperRegistry,
        onResolution: @escaping @Sendable (ApprovalID) -> Void = { _ in }
    ) {
        self.init(
            registry: registry,
            inspector: SecurityWrapperBundleInspector(),
            bookmarkFactory: Self.createSecurityScopedBookmark,
            monotonicNow: { ProcessInfo.processInfo.systemUptime },
            wallClock: { Date() },
            onResolution: onResolution
        )
    }

    init(
        registry: WrapperRegistry,
        inspector: any WrapperBundleInspecting,
        bookmarkFactory: @escaping @Sendable (URL) throws -> Data,
        monotonicNow: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        wallClock: @escaping @Sendable () -> Date = { Date() },
        onResolution: @escaping @Sendable (ApprovalID) -> Void = { _ in }
    ) {
        self.registry = registry
        self.inspector = inspector
        self.bookmarkFactory = bookmarkFactory
        self.monotonicNow = monotonicNow
        self.wallClock = wallClock
        self.onResolution = onResolution
    }

    /// Validates a broker request and stores its prompt until a decision or the ten-minute timeout.
    ///
    /// The package installation fact is supplied by the host's package manager; it is not read
    /// from or inferred from the wrapper bundle.
    public func prepareApproval(
        _ request: RuntimeWrapperApprovalBrokerRequest,
        packageInstalled: Bool
    ) async throws(Failure) -> WrapperApprovalChallenge {
        try await prepareApproval(
            request,
            isPackageInstalled: { _ in packageInstalled }
        )
    }

    /// Validates a broker request and obtains the installed-package fact only after validation
    /// and admission control have succeeded.
    public func prepareApproval(
        _ request: RuntimeWrapperApprovalBrokerRequest,
        isPackageInstalled: @escaping @Sendable (RuntimePackageID) async -> Bool
    ) async throws(Failure) -> WrapperApprovalChallenge {
        try await prepareApproval(
            request,
            packageStatus: { packageID in
                WrapperApprovalPackageStatus(
                    isInstalled: await isPackageInstalled(packageID)
                )
            }
        )
    }

    /// Validates a broker request and obtains installed package details after admission control.
    public func prepareApproval(
        _ request: RuntimeWrapperApprovalBrokerRequest,
        packageStatus: @escaping @Sendable (RuntimePackageID) async -> WrapperApprovalPackageStatus
    ) async throws(Failure) -> WrapperApprovalChallenge {
        let validated = try validate(request)
        return try await prepareValidated(
            validated,
            packageStatus: packageStatus
        )
    }

    /// Inspects a request without creating a challenge, consuming rate limit, or looking up package state.
    ///
    /// RuntimeHost uses these validated facts only to pin the code-signing requirement on the
    /// one-use approval endpoint. The endpoint must call `prepareApproval(_:expectedIdentity:isPackageInstalled:)`
    /// before presenting a prompt.
    public func approvalEndpointIdentity(
        for request: RuntimeWrapperApprovalBrokerRequest
    ) throws(Failure) -> WrapperApprovalEndpointIdentity {
        let validated = try validate(request)
        return endpointIdentity(for: validated)
    }

    /// Checks whether this exact validated wrapper identity is already authorized.
    ///
    /// RuntimeHost uses this on the restricted approval endpoint after a transport failure. A
    /// healthy, already-registered wrapper can then reconnect without creating a redundant prompt.
    public func isAlreadyApproved(
        _ request: RuntimeWrapperApprovalBrokerRequest,
        expectedIdentity: WrapperApprovalEndpointIdentity
    ) async -> Bool {
        guard let validated = try? validate(request),
            endpointIdentity(for: validated) == expectedIdentity,
            let registryContents = try? await registry.read()
        else {
            return false
        }

        return registryContents.wrappers.contains { entry in
            guard
                entry.bundleID == validated.bundleID,
                entry.packageID == validated.packageID,
                entry.state == .active || entry.state == .refreshing
            else {
                return false
            }
            return entry.cdhash == validated.cdhash
                || (entry.state == .refreshing && entry.pendingCdhash == validated.cdhash)
        }
    }

    /// Revalidates a bundle after the caller connected to its code-signing-restricted endpoint.
    ///
    /// A bundle replaced after endpoint issuance cannot be approved through the old connection.
    public func prepareApproval(
        _ request: RuntimeWrapperApprovalBrokerRequest,
        expectedIdentity: WrapperApprovalEndpointIdentity,
        isPackageInstalled: @escaping @Sendable (RuntimePackageID) async -> Bool
    ) async throws(Failure) -> WrapperApprovalChallenge {
        try await prepareApproval(
            request,
            expectedIdentity: expectedIdentity,
            packageStatus: { packageID in
                WrapperApprovalPackageStatus(
                    isInstalled: await isPackageInstalled(packageID)
                )
            }
        )
    }

    /// Revalidates the bundle and obtains installed package details after the endpoint is used.
    public func prepareApproval(
        _ request: RuntimeWrapperApprovalBrokerRequest,
        expectedIdentity: WrapperApprovalEndpointIdentity,
        packageStatus: @escaping @Sendable (RuntimePackageID) async -> WrapperApprovalPackageStatus
    ) async throws(Failure) -> WrapperApprovalChallenge {
        let validated = try validate(request)
        guard endpointIdentity(for: validated) == expectedIdentity else {
            throw .identityMismatch
        }
        return try await prepareValidated(
            validated,
            packageStatus: packageStatus
        )
    }

    /// Validates a user-selected bundle without accepting package or bundle identifiers from the caller.
    ///
    /// This is the control-endpoint entry point used by `apkrun wrapper approve`.
    public func prepareApproval(
        bundlePath: String,
        packageInstalled: Bool
    ) async throws(Failure) -> WrapperApprovalChallenge {
        try await prepareApproval(bundlePath: bundlePath, isPackageInstalled: { _ in packageInstalled })
    }

    /// Validates a user-selected bundle and derives the installed-package fact from the host.
    public func prepareApproval(
        bundlePath: String,
        isPackageInstalled: @escaping @Sendable (RuntimePackageID) async -> Bool
    ) async throws(Failure) -> WrapperApprovalChallenge {
        try await prepareApproval(
            bundlePath: bundlePath,
            packageStatus: { packageID in
                WrapperApprovalPackageStatus(
                    isInstalled: await isPackageInstalled(packageID)
                )
            }
        )
    }

    /// Validates a user-selected bundle and includes installed package version details.
    public func prepareApproval(
        bundlePath: String,
        packageStatus: @escaping @Sendable (RuntimePackageID) async -> WrapperApprovalPackageStatus
    ) async throws(Failure) -> WrapperApprovalChallenge {
        let bundleURL = try canonicalBundleURL(bundlePath)
        let evidence = try inspect(bundleURL: bundleURL)
        guard let packageID = RuntimePackageID(rawValue: evidence.plistPackageID),
            let request = RuntimeWrapperApprovalBrokerRequest(
                bundlePath: bundleURL.path,
                bundleID: evidence.bundleIdentifier,
                packageID: packageID
            )
        else {
            throw .identityMismatch
        }
        let validated = try validate(evidence: evidence, request: request, bundleURL: bundleURL)
        return try await prepareValidated(
            validated,
            packageStatus: packageStatus,
            retainForIndependentConfirmation: true
        )
    }

    private func validate(
        _ request: RuntimeWrapperApprovalBrokerRequest
    ) throws(Failure) -> ValidatedWrapper {
        let bundleURL = try canonicalBundleURL(request.bundlePath)
        let evidence = try inspect(bundleURL: bundleURL)
        return try validate(evidence: evidence, request: request, bundleURL: bundleURL)
    }

    private func endpointIdentity(for validated: ValidatedWrapper) -> WrapperApprovalEndpointIdentity {
        WrapperApprovalEndpointIdentity(
            bundlePath: validated.bundleURL.path,
            bundleID: validated.bundleID,
            packageID: validated.packageID,
            cdhash: validated.cdhash
        )
    }

    private func canonicalBundleURL(_ path: String) throws(Failure) -> URL {
        guard path.hasPrefix("/"), path.utf8.count <= 1024, path.hasSuffix(".app") else {
            throw .invalidBundle
        }
        let bundleURL = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard bundleURL.path.utf8.count <= 1024, bundleURL.path.hasSuffix(".app") else {
            throw .invalidBundle
        }
        return bundleURL
    }

    private func inspect(bundleURL: URL) throws(Failure) -> WrapperBundleEvidence {
        do {
            return try inspector.inspect(bundleURL: bundleURL)
        } catch let error as WrapperBundleInspectionFailure {
            switch error {
            case .invalidSignature:
                throw .invalidSignature
            case .invalidBundle:
                throw .invalidBundle
            case .signerVerificationUnavailable:
                throw .signerVerificationUnavailable
            }
        } catch {
            throw .invalidBundle
        }
    }

    private func prepareValidated(
        _ validated: ValidatedWrapper,
        packageStatus: @escaping @Sendable (RuntimePackageID) async -> WrapperApprovalPackageStatus,
        retainForIndependentConfirmation: Bool = false
    ) async throws(Failure) -> WrapperApprovalChallenge {
        let now = wallClock()
        expirePending(now: now)
        purgeCompleted(now: now)

        let identity = ApprovalRequestIdentity(validated)
        if retainForIndependentConfirmation {
            independentConfirmationsByBundleID[validated.bundleID, default: 0] += 1
        }
        defer {
            if retainForIndependentConfirmation {
                releaseIndependentConfirmation(for: validated.bundleID)
            }
        }
        if let approvalID = pendingApprovalByBundleID[validated.bundleID] {
            guard let pending = pendingByID[approvalID] else {
                pendingApprovalByBundleID.removeValue(forKey: validated.bundleID)
                throw .alreadyPending
            }
            guard pending.identity == identity else {
                throw .alreadyPending
            }
            if retainForIndependentConfirmation {
                var retained = pending
                retained.hasIndependentConfirmation = true
                pendingByID[approvalID] = retained
            }
            return pending.challenge
        }

        if let preparation = preparingApprovalByBundleID[validated.bundleID] {
            guard preparation.identity == identity else {
                throw .alreadyPending
            }
            let challenge = try await awaitPreparation(preparation, bundleID: validated.bundleID)
            if retainForIndependentConfirmation,
                var pending = pendingByID[challenge.approvalID]
            {
                pending.hasIndependentConfirmation = true
                pendingByID[challenge.approvalID] = pending
            }
            return challenge
        }

        let monotonicTime = monotonicNow()
        requestTimes.removeAll { monotonicTime - $0 >= Self.requestWindow || monotonicTime < $0 }
        guard requestTimes.count < Self.maximumRequestsPerMinute else {
            throw .rateLimited
        }
        requestTimes.append(monotonicTime)

        let token = UUID()
        let task: Task<Result<WrapperApprovalChallenge, Failure>, Never> = Task { [weak self] in
            guard let self else {
                return .failure(.invalidBundle)
            }
            do {
                let challenge = try await self.createPendingApproval(
                    validated,
                    identity: identity,
                    packageStatus: packageStatus,
                    now: now
                )
                return .success(challenge)
            } catch let failure as Failure {
                return .failure(failure)
            } catch {
                return .failure(.invalidBundle)
            }
        }
        let preparation = PreparingApproval(token: token, identity: identity, task: task)
        preparingApprovalByBundleID[validated.bundleID] = preparation
        let challenge = try await awaitPreparation(preparation, bundleID: validated.bundleID)
        if retainForIndependentConfirmation,
            var pending = pendingByID[challenge.approvalID]
        {
            pending.hasIndependentConfirmation = true
            pendingByID[challenge.approvalID] = pending
        }
        return challenge
    }

    private func releaseIndependentConfirmation(for bundleID: String) {
        guard let count = independentConfirmationsByBundleID[bundleID] else {
            return
        }
        if count <= 1 {
            independentConfirmationsByBundleID.removeValue(forKey: bundleID)
        } else {
            independentConfirmationsByBundleID[bundleID] = count - 1
        }
    }

    private func awaitPreparation(
        _ preparation: PreparingApproval,
        bundleID: String
    ) async throws(Failure) -> WrapperApprovalChallenge {
        let result = await preparation.task.value
        if preparingApprovalByBundleID[bundleID]?.token == preparation.token {
            preparingApprovalByBundleID.removeValue(forKey: bundleID)
        }
        return try result.get()
    }

    private func createPendingApproval(
        _ validated: ValidatedWrapper,
        identity: ApprovalRequestIdentity,
        packageStatus: @Sendable (RuntimePackageID) async -> WrapperApprovalPackageStatus,
        now: Date
    ) async throws(Failure) -> WrapperApprovalChallenge {
        let registryContents: WrapperRegistryFile
        do {
            registryContents = try await registry.read()
        } catch let failure {
            throw .registry(failure)
        }

        guard
            !registryContents.denied.contains(where: {
                $0.bundleID == validated.bundleID
                    && $0.cdhash == validated.cdhash
                    && $0.until > now
            })
        else {
            throw .recentlyDenied
        }

        let packageStatus = await packageStatus(validated.packageID)
        let replacingPath = registryContents.wrappers.first(where: {
            $0.packageID == validated.packageID && $0.state == .active && $0.path != validated.bundleURL.path
        })?.path
        let approvalID = ApprovalID()
        guard
            let prompt = RuntimeWrapperApprovalPrompt(
                approvalID: approvalID,
                bundlePath: validated.bundleURL.path,
                bundleID: validated.bundleID,
                packageID: validated.packageID,
                displayName: validated.displayName,
                signer: validated.signer,
                packageInstalled: packageStatus.isInstalled,
                installedVersion: packageStatus.installedVersion,
                integrations: validated.integrations,
                replacingBundlePath: replacingPath
            )
        else {
            throw .invalidBundle
        }

        let challenge = WrapperApprovalChallenge(prompt: prompt)
        let deadline = now.addingTimeInterval(Self.pendingLifetime)
        var pending = PendingApproval(
            challenge: challenge,
            validated: validated,
            identity: identity,
            createdAt: now,
            deadline: deadline,
            hasIndependentConfirmation: independentConfirmationsByBundleID[validated.bundleID, default: 0] > 0
        )
        pending.timeoutTask = makeTimeoutTask(for: approvalID)
        pendingByID[approvalID] = pending
        pendingApprovalByBundleID[validated.bundleID] = approvalID
        return challenge
    }

    /// Commits an authenticated user's allow or deny decision.
    ///
    /// Callers must authenticate the control endpoint before invoking this method. The request
    /// identifier only locates the pending decision; it never grants package access by itself.
    public func decide(approvalID: ApprovalID, allow: Bool) async throws(Failure) {
        let now = wallClock()
        expirePending(now: now)
        purgeCompleted(now: now)
        guard var pending = pendingByID[approvalID] else {
            throw .unknownApproval
        }
        guard !pending.isCommittingDecision else {
            throw .decisionInProgress
        }

        pending.isCommittingDecision = true
        pendingByID[approvalID] = pending

        do {
            let entry: WrapperRegistryFile.Entry?
            let denial: WrapperRegistryFile.DeniedEntry?
            if allow {
                let bookmark: Data
                do {
                    bookmark = try bookmarkFactory(pending.validated.bundleURL)
                } catch {
                    throw Failure.bookmarkUnavailable
                }
                guard (1...8192).contains(bookmark.count) else {
                    throw Failure.bookmarkUnavailable
                }
                do {
                    entry = try WrapperRegistryFile.Entry(
                        bundleID: pending.validated.bundleID,
                        packageID: pending.validated.packageID,
                        kind: pending.validated.kind,
                        state: .active,
                        path: pending.validated.bundleURL.path,
                        bookmark: bookmark,
                        cdhash: pending.validated.cdhash,
                        launcherVersion: pending.validated.launcherVersion,
                        launcherAPI: pending.validated.launcherAPI,
                        formatVersion: pending.validated.formatVersion,
                        fileName: pending.validated.bundleURL.deletingPathExtension().lastPathComponent,
                        displayName: pending.validated.displayName,
                        customization: .init(displayName: nil, iconFile: nil),
                        iconDigest: nil,
                        approval: .user,
                        createdAt: now,
                        refreshedAt: nil,
                        lastValidatedAt: now
                    )
                } catch {
                    throw Failure.invalidBundle
                }
                denial = nil
            } else {
                do {
                    denial = try WrapperRegistryFile.DeniedEntry(
                        bundleID: pending.validated.bundleID,
                        cdhash: pending.validated.cdhash,
                        until: now.addingTimeInterval(Self.denialLifetime)
                    )
                } catch {
                    throw Failure.invalidBundle
                }
                entry = nil
            }

            try await registry.updateAtomically(
                now: now,
                transform: { (current: WrapperRegistryFile) throws(WrapperRegistry.Failure) -> WrapperRegistryFile in
                    let wrappers: [WrapperRegistryFile.Entry]
                    let denied: [WrapperRegistryFile.DeniedEntry]
                    if let entry {
                        wrappers = current.wrappers.filter { $0.bundleID != entry.bundleID } + [entry]
                        denied = current.denied.filter {
                            !($0.bundleID == entry.bundleID && $0.cdhash == entry.cdhash)
                        }
                    } else if let denial {
                        wrappers = current.wrappers
                        denied =
                            current.denied.filter {
                                !($0.bundleID == denial.bundleID && $0.cdhash == denial.cdhash)
                            } + [denial]
                    } else {
                        throw WrapperRegistry.Failure.invalidDocument
                    }
                    return try WrapperRegistryFile(wrappers: wrappers, denied: denied)
                }
            )
            resolve(approvalID, outcome: allow ? .approved : .denied, now: now)
        } catch let failure as Failure {
            restorePendingAfterFailedDecision(approvalID, now: wallClock())
            throw failure
        } catch let failure as WrapperRegistry.Failure {
            restorePendingAfterFailedDecision(approvalID, now: wallClock())
            throw .registry(failure)
        } catch {
            restorePendingAfterFailedDecision(approvalID, now: wallClock())
            throw .invalidBundle
        }
    }

    /// Waits for the user decision, returning `timedOut` when the ten-minute deadline elapses.
    public func waitForDecision(approvalID: ApprovalID) async -> RuntimeWrapperApprovalOutcome {
        await waitForDecision(approvalID: approvalID, onWaiterRegistered: {})
    }

    /// Waits for a decision and invokes `onWaiterRegistered` after this caller owns a cancellable wait.
    ///
    /// The callback runs synchronously on the service actor after registration and before the
    /// method suspends. RuntimeHost uses it to publish and open the prompt only after connection
    /// cancellation can remove the challenge.
    public func waitForDecision(
        approvalID: ApprovalID,
        onWaiterRegistered: @escaping @Sendable () -> Void
    ) async -> RuntimeWrapperApprovalOutcome {
        let now = wallClock()
        expirePending(now: now)
        purgeCompleted(now: now)
        if let completed = completedByID[approvalID] {
            return completed.outcome
        }
        guard pendingByID[approvalID] != nil else {
            return .unknown
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            if Task.isCancelled {
                cancelWaiter(approvalID: approvalID, waiterID: waiterID)
                return .timedOut
            }
            return await withCheckedContinuation { continuation in
                guard pendingByID[approvalID] != nil else {
                    continuation.resume(returning: completedByID[approvalID]?.outcome ?? .unknown)
                    return
                }
                waiters[approvalID, default: [:]][waiterID] = continuation
                onWaiterRegistered()
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(approvalID: approvalID, waiterID: waiterID)
            }
        }
    }

    private func cancelWaiter(approvalID: ApprovalID, waiterID: UUID) {
        let continuation = waiters[approvalID]?.removeValue(forKey: waiterID)
        if waiters[approvalID]?.isEmpty == true {
            waiters.removeValue(forKey: approvalID)
        }
        continuation?.resume(returning: .timedOut)

        guard let pending = pendingByID[approvalID], !pending.isCommittingDecision else {
            return
        }
        guard waiters[approvalID]?.isEmpty != false, !pending.hasIndependentConfirmation else {
            return
        }
        resolve(approvalID, outcome: .timedOut, now: wallClock())
    }

    /// Expires pending requests at an injected wall-clock instant.
    ///
    /// The explicit time parameter also lets tests exercise deadline behavior without sleeping.
    @discardableResult
    public func expirePending(now: Date = Date()) -> [ApprovalID] {
        let expired = pendingByID.compactMap { approvalID, pending in
            pending.deadline <= now ? approvalID : nil
        }
        for approvalID in expired {
            if var pending = pendingByID[approvalID], pending.isCommittingDecision {
                pending.deadlineElapsed = true
                pendingByID[approvalID] = pending
            } else {
                resolve(approvalID, outcome: .timedOut, now: now)
            }
        }
        purgeCompleted(now: now)
        return expired
    }

    /// Returns prompts that are still awaiting a user decision.
    public func pendingChallenges() -> [WrapperApprovalChallenge] {
        pendingByID.values
            .filter { !$0.isCommittingDecision }
            .map(\.challenge)
            .sorted { $0.approvalID.wireValue < $1.approvalID.wireValue }
    }

    /// Returns the existing challenge for an exact canonical bundle path, if one is pending.
    ///
    /// This lets a control client confirm a request already opened by the wrapper without
    /// creating another request or deriving a grant from the path. The returned prompt retains
    /// the facts captured by the original validation.
    public func pendingChallenge(bundlePath: String) -> WrapperApprovalChallenge? {
        guard bundlePath.hasPrefix("/") else {
            return nil
        }
        let canonicalPath = URL(fileURLWithPath: bundlePath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return pendingByID.values.first {
            !$0.isCommittingDecision && $0.validated.bundleURL.path == canonicalPath
        }?.challenge
    }

    private func validate(
        evidence: WrapperBundleEvidence,
        request: RuntimeWrapperApprovalBrokerRequest,
        bundleURL: URL
    ) throws(Failure) -> ValidatedWrapper {
        let decoder = JSONDecoder()
        guard evidence.wrapperDocument.count <= Self.maximumManifestBytes,
            let document = try? decoder.decode(WrapperDocument.self, from: evidence.wrapperDocument)
        else {
            throw .invalidManifest
        }

        guard let plistPackageID = RuntimePackageID(rawValue: evidence.plistPackageID),
            evidence.bundleIdentifier == request.bundleID,
            evidence.signedIdentifier == evidence.bundleIdentifier,
            request.packageID == plistPackageID,
            document.application.packageID == plistPackageID,
            BundleIDMapper.map(plistPackageID) == evidence.bundleIdentifier
        else {
            throw .identityMismatch
        }

        guard evidence.wrapperFormatVersion == document.formatVersion,
            evidence.wrapperKind == document.kind.rawValue,
            evidence.launcherAPI == document.runtime.launcherAPI.rawValue,
            let launcherVersion = WrapperMinimumRuntimeVersion(rawValue: evidence.launcherVersion),
            isAtLeast(launcherVersion.rawValue, document.runtime.minimumVersion.rawValue)
        else {
            throw .invalidVersion
        }
        guard let kind = WrapperRegistryFile.Entry.Kind(rawValue: document.kind.rawValue) else {
            throw .invalidManifest
        }

        guard Self.isValidCDHash(evidence.cdhash) else {
            throw .invalidSignature
        }
        guard let signer = evidence.signerSummary else {
            throw .signerVerificationUnavailable
        }

        let integrations = integrationSummary(document.integration)
        return ValidatedWrapper(
            bundleURL: bundleURL,
            bundleID: evidence.bundleIdentifier,
            packageID: plistPackageID,
            kind: kind,
            cdhash: evidence.cdhash,
            launcherVersion: launcherVersion.rawValue,
            launcherAPI: evidence.launcherAPI,
            formatVersion: document.formatVersion,
            displayName: document.application.displayName,
            signer: signer,
            integrations: integrations
        )
    }

    private func integrationSummary(_ integration: WrapperIntegration?) -> RuntimeWrapperIntegrationSummary {
        RuntimeWrapperIntegrationSummary(
            clipboard: integration?.clipboard ?? false,
            notifications: integration?.notifications ?? false,
            links: integration?.links != nil,
            files: integration?.files ?? false,
            sharedFolders: integration?.sharedFolders.map { $0 != .off } ?? false,
            microphone: integration?.microphone ?? false
        )
    }

    private func isAtLeast(_ actual: String, _ minimum: String) -> Bool {
        let actualComponents = actual.split(separator: ".").compactMap { UInt64($0) }
        let minimumComponents = minimum.split(separator: ".").compactMap { UInt64($0) }
        guard actualComponents.count == 3, minimumComponents.count == 3 else {
            return false
        }
        for index in 0..<3 where actualComponents[index] != minimumComponents[index] {
            return actualComponents[index] > minimumComponents[index]
        }
        return true
    }

    private func makeTimeoutTask(for approvalID: ApprovalID) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.pendingLifetime))
            } catch {
                return
            }
            await self?.expireOne(approvalID, now: self?.wallClock() ?? Date())
        }
    }

    private func expireOne(_ approvalID: ApprovalID, now: Date) {
        guard let pending = pendingByID[approvalID], pending.deadline <= now else {
            return
        }
        if pending.isCommittingDecision {
            var updated = pending
            updated.deadlineElapsed = true
            pendingByID[approvalID] = updated
        } else {
            resolve(approvalID, outcome: .timedOut, now: now)
        }
    }

    private func restorePendingAfterFailedDecision(_ approvalID: ApprovalID, now: Date) {
        guard var pending = pendingByID[approvalID] else {
            return
        }
        pending.isCommittingDecision = false
        if pending.deadlineElapsed || pending.deadline <= now {
            resolve(approvalID, outcome: .timedOut, now: now)
        } else {
            pendingByID[approvalID] = pending
        }
    }

    private func resolve(
        _ approvalID: ApprovalID,
        outcome: RuntimeWrapperApprovalOutcome,
        now: Date
    ) {
        guard let pending = pendingByID.removeValue(forKey: approvalID) else {
            return
        }
        pending.timeoutTask?.cancel()
        if pendingApprovalByBundleID[pending.validated.bundleID] == approvalID {
            pendingApprovalByBundleID.removeValue(forKey: pending.validated.bundleID)
        }
        onResolution(approvalID)
        completedByID[approvalID] = CompletedApproval(outcome: outcome, completedAt: now)
        completionOrder.append(approvalID)
        if let resolvedWaiters = waiters.removeValue(forKey: approvalID) {
            for waiter in resolvedWaiters.values {
                waiter.resume(returning: outcome)
            }
        }
        trimCompleted(to: 64)
    }

    private func purgeCompleted(now: Date) {
        for approvalID in completionOrder
        where completedByID[approvalID]?.completedAt
            .addingTimeInterval(Self.completedLifetime) ?? .distantPast <= now
        {
            completedByID.removeValue(forKey: approvalID)
        }
        completionOrder.removeAll { completedByID[$0] == nil }
    }

    private func trimCompleted(to limit: Int) {
        while completionOrder.count > limit {
            let removed = completionOrder.removeFirst()
            completedByID.removeValue(forKey: removed)
        }
    }
}

struct WrapperBundleEvidence: Equatable, Sendable {
    let bundleIdentifier: String
    let signedIdentifier: String
    let plistPackageID: String
    let wrapperFormatVersion: Int
    let wrapperKind: String
    let launcherVersion: String
    let launcherAPI: String
    let wrapperDocument: Data
    let cdhash: String
    let signerSummary: RuntimeWrapperSignerSummary?
}

protocol WrapperBundleInspecting: Sendable {
    func inspect(bundleURL: URL) throws -> WrapperBundleEvidence
}

enum WrapperBundleInspectionFailure: Error {
    case invalidBundle
    case invalidSignature
    case signerVerificationUnavailable
}

private struct SecurityWrapperBundleInspector: WrapperBundleInspecting {
    func inspect(bundleURL: URL) throws -> WrapperBundleEvidence {
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)
        guard bundleURL.path.hasSuffix(".app"),
            fileManager.fileExists(atPath: bundleURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw WrapperBundleInspectionFailure.invalidBundle
        }

        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let infoURL = contentsURL.appendingPathComponent("Info.plist", isDirectory: false)
        let manifestURL =
            contentsURL
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("wrapper.json", isDirectory: false)
        guard let infoData = try? Data(contentsOf: infoURL),
            infoData.count <= WrapperApprovalService.maximumManifestBytes,
            let info = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
            let manifestAttributes = try? fileManager.attributesOfItem(atPath: manifestURL.path),
            let manifestSize = manifestAttributes[.size] as? NSNumber,
            manifestSize.intValue >= 1,
            manifestSize.intValue <= WrapperApprovalService.maximumManifestBytes,
            let manifest = try? Data(contentsOf: manifestURL)
        else {
            throw WrapperBundleInspectionFailure.invalidBundle
        }

        guard let bundleIdentifier = info["CFBundleIdentifier"] as? String,
            let packageID = info["APKRunPackageID"] as? String,
            let formatVersion = info["APKRunWrapperFormat"] as? NSNumber,
            let kind = info["APKRunWrapperKind"] as? String,
            let launcherVersion = info["APKRunLauncherVersion"] as? String,
            let launcherAPI = info["APKRunLauncherAPI"] as? String
        else {
            throw WrapperBundleInspectionFailure.invalidBundle
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
            let staticCode
        else {
            throw WrapperBundleInspectionFailure.invalidSignature
        }
        let strictFlags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidity(staticCode, strictFlags, nil) == errSecSuccess else {
            throw WrapperBundleInspectionFailure.invalidSignature
        }

        var signingInformation: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &signingInformation
            ) == errSecSuccess,
            let signingInformation = signingInformation as? [String: Any],
            let signedIdentifier = signingInformation[kSecCodeInfoIdentifier as String] as? String,
            let cdhashData = signingInformation[kSecCodeInfoUnique as String] as? Data,
            cdhashData.count == 20
        else {
            throw WrapperBundleInspectionFailure.invalidSignature
        }

        let cdhash = cdhashData.map { String(format: "%02x", $0) }.joined()
        guard let signerSummary = Self.signerSummary(from: signingInformation) else {
            throw WrapperBundleInspectionFailure.signerVerificationUnavailable
        }
        return WrapperBundleEvidence(
            bundleIdentifier: bundleIdentifier,
            signedIdentifier: signedIdentifier,
            plistPackageID: packageID,
            wrapperFormatVersion: formatVersion.intValue,
            wrapperKind: kind,
            launcherVersion: launcherVersion,
            launcherAPI: launcherAPI,
            wrapperDocument: manifest,
            cdhash: cdhash,
            signerSummary: signerSummary
        )
    }

    private static func signerSummary(from signingInformation: [String: Any]) -> RuntimeWrapperSignerSummary? {
        let cms = signingInformation[kSecCodeInfoCMS as String] as? Data
        guard let cms, !cms.isEmpty else {
            return RuntimeWrapperSignerSummary(kind: .adHoc)
        }

        guard let teamIdentifier = signingInformation[kSecCodeInfoTeamIdentifier as String] as? String,
            let signer = RuntimeWrapperSignerSummary(
                kind: .teamSigned,
                teamIdentifier: teamIdentifier
            )
        else {
            return nil
        }

        // SecStaticCode validation establishes signature integrity and certificate validity, but
        // the public signing-information dictionary does not establish certificate class or
        // notarization status. Report only the team identifier rather than infer Developer ID.
        return signer
    }
}

extension WrapperApprovalService {
    fileprivate static func createSecurityScopedBookmark(for bundleURL: URL) throws -> Data {
        try bundleURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    fileprivate static func isValidCDHash(_ value: String) -> Bool {
        value.utf8.count == 40
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
