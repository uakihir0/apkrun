import Foundation
import RuntimeAPI
import Testing

@testable import WrapperCore

@Test func approvalWritesOnlyValidatedFactsToTheRegistry() async throws {
    let rootURL = temporaryDirectory(named: "WrapperApprovalAllow")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let packageID = try #require(RuntimePackageID(rawValue: "com.example.approved"))
    let bundleURL = rootURL.appendingPathComponent("Approved.app", isDirectory: true)
    let evidence = try makeEvidence(packageID: packageID)
    let service = makeService(registryURL: rootURL.appendingPathComponent("registry.json"), evidence: evidence)
    let request = try #require(
        RuntimeWrapperApprovalBrokerRequest(
            bundlePath: bundleURL.path,
            bundleID: BundleIDMapper.map(packageID),
            packageID: packageID
        )
    )

    let challenge = try await service.prepareApproval(request, packageInstalled: true)
    #expect(challenge.prompt.displayName == "Approved App")
    #expect(challenge.prompt.packageInstalled)
    #expect(challenge.prompt.integrations.clipboard)
    #expect(challenge.prompt.integrations.links)

    let waiter = Task {
        await service.waitForDecision(approvalID: challenge.approvalID)
    }
    try await service.decide(approvalID: challenge.approvalID, allow: true)

    #expect(await waiter.value == .approved)
    let approvalIdentity = try await service.approvalEndpointIdentity(for: request)
    #expect(await service.isAlreadyApproved(request, expectedIdentity: approvalIdentity))
    let registry = try await WrapperRegistry(fileURL: rootURL.appendingPathComponent("registry.json")).read()
    let entry = try #require(registry.wrappers.first)
    #expect(entry.bundleID == BundleIDMapper.map(packageID))
    #expect(entry.packageID == packageID)
    #expect(entry.kind == .local)
    #expect(entry.state == .active)
    #expect(entry.approval == .user)
    #expect(entry.cdhash == evidence.cdhash)
    #expect(entry.path == bundleURL.resolvingSymlinksInPath().standardizedFileURL.path)
    #expect(entry.bookmark == Data([1, 2, 3]))
    #expect(registry.denied.isEmpty)
}

@Test func concurrentApprovalsForDifferentBundlesPreserveEveryRegistryEntry() async throws {
    let rootURL = temporaryDirectory(named: "WrapperApprovalConcurrentDecisions")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let registryURL = rootURL.appendingPathComponent("registry.json")
    let service = makeService(
        registryURL: registryURL,
        evidenceForPackage: { try makeEvidence(packageID: $0) }
    )
    var challenges: [WrapperApprovalChallenge] = []
    for index in 0..<5 {
        let packageID = try #require(RuntimePackageID(rawValue: "com.example.concurrent\(index)"))
        let request = try #require(
            RuntimeWrapperApprovalBrokerRequest(
                bundlePath: rootURL.appendingPathComponent("Bundle-\(packageID.rawValue).app").path,
                bundleID: BundleIDMapper.map(packageID),
                packageID: packageID
            )
        )
        challenges.append(try await service.prepareApproval(request, packageInstalled: true))
    }

    try await withThrowingTaskGroup(of: Void.self) { group in
        for challenge in challenges {
            group.addTask {
                try await service.decide(approvalID: challenge.approvalID, allow: true)
            }
        }
        try await group.waitForAll()
    }

    let registry = try await WrapperRegistry(fileURL: registryURL).read()
    #expect(registry.wrappers.count == 5)
    #expect(Set(registry.wrappers.map(\.packageID)).count == 5)
    #expect(registry.wrappers.allSatisfy { $0.state == .active && $0.approval == .user })
}

@Test func approvalRejectsClaimAndManifestIdentityMismatch() async throws {
    let rootURL = temporaryDirectory(named: "WrapperApprovalIdentity")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let packageID = try #require(RuntimePackageID(rawValue: "com.example.identity"))
    let claimedPackageID = try #require(RuntimePackageID(rawValue: "com.example.claimed"))
    let service = makeService(
        registryURL: rootURL.appendingPathComponent("registry.json"),
        evidence: try makeEvidence(packageID: packageID)
    )
    let mismatchedRequest = try #require(
        RuntimeWrapperApprovalBrokerRequest(
            bundlePath: rootURL.appendingPathComponent("Identity.app").path,
            bundleID: BundleIDMapper.map(packageID),
            packageID: claimedPackageID
        )
    )

    await #expect(throws: WrapperApprovalService.Failure.identityMismatch) {
        try await service.prepareApproval(mismatchedRequest, packageInstalled: false)
    }
    #expect(await service.pendingChallenges().isEmpty)
}

@Test func approvalRequiresTheDeterministicBundleIDMapping() async throws {
    let rootURL = temporaryDirectory(named: "WrapperApprovalMappedIdentity")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let packageID = try #require(RuntimePackageID(rawValue: "com.example.mapping"))
    let validEvidence = try makeEvidence(packageID: packageID)
    let mismatchedBundleID = "io.apkrun.android.com.example.other"
    let evidence = WrapperBundleEvidence(
        bundleIdentifier: mismatchedBundleID,
        signedIdentifier: mismatchedBundleID,
        plistPackageID: packageID.rawValue,
        wrapperFormatVersion: validEvidence.wrapperFormatVersion,
        wrapperKind: validEvidence.wrapperKind,
        launcherVersion: validEvidence.launcherVersion,
        launcherAPI: validEvidence.launcherAPI,
        wrapperDocument: validEvidence.wrapperDocument,
        cdhash: validEvidence.cdhash,
        signerSummary: validEvidence.signerSummary
    )
    let service = makeService(registryURL: rootURL.appendingPathComponent("registry.json"), evidence: evidence)
    let request = try #require(
        RuntimeWrapperApprovalBrokerRequest(
            bundlePath: rootURL.appendingPathComponent("Wrong-Mapping.app").path,
            bundleID: mismatchedBundleID,
            packageID: packageID
        )
    )

    await #expect(throws: WrapperApprovalService.Failure.identityMismatch) {
        try await service.prepareApproval(request, packageInstalled: false)
    }
}

@Test func approvalRejectsVersionDisagreementAndMalformedBundleIdentity() async throws {
    let rootURL = temporaryDirectory(named: "WrapperApprovalVersions")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let packageID = try #require(RuntimePackageID(rawValue: "com.example.version"))
    let validEvidence = try makeEvidence(packageID: packageID)
    let evidence = WrapperBundleEvidence(
        bundleIdentifier: validEvidence.bundleIdentifier,
        signedIdentifier: validEvidence.signedIdentifier,
        plistPackageID: validEvidence.plistPackageID,
        wrapperFormatVersion: validEvidence.wrapperFormatVersion,
        wrapperKind: validEvidence.wrapperKind,
        launcherVersion: validEvidence.launcherVersion,
        launcherAPI: "1.13",
        wrapperDocument: validEvidence.wrapperDocument,
        cdhash: validEvidence.cdhash,
        signerSummary: validEvidence.signerSummary
    )
    let service = makeService(registryURL: rootURL.appendingPathComponent("registry.json"), evidence: evidence)
    let request = try #require(
        RuntimeWrapperApprovalBrokerRequest(
            bundlePath: rootURL.appendingPathComponent("Version.app").path,
            bundleID: BundleIDMapper.map(packageID),
            packageID: packageID
        )
    )

    await #expect(throws: WrapperApprovalService.Failure.invalidVersion) {
        try await service.prepareApproval(request, packageInstalled: false)
    }

    let wrongBundleID = try #require(
        RuntimeWrapperApprovalBrokerRequest(
            bundlePath: rootURL.appendingPathComponent("Wrong-ID.app").path,
            bundleID: "io.apkrun.android.com.example.other",
            packageID: packageID
        )
    )
    await #expect(throws: WrapperApprovalService.Failure.identityMismatch) {
        try await service.prepareApproval(wrongBundleID, packageInstalled: false)
    }
}

@Test func approvalEnforcesFiveRequestsPerMinute() async throws {
    let rootURL = temporaryDirectory(named: "WrapperApprovalRateLimit")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let lookupCounter = ApprovalLookupCounter()
    let service = makeService(
        registryURL: rootURL.appendingPathComponent("registry.json"),
        evidenceForPackage: { try makeEvidence(packageID: $0) }
    )
    for index in 0..<5 {
        let packageID = try #require(RuntimePackageID(rawValue: "com.example.rate\(index)"))
        let request = try #require(
            RuntimeWrapperApprovalBrokerRequest(
                bundlePath: rootURL.appendingPathComponent("Bundle-\(packageID.rawValue).app").path,
                bundleID: BundleIDMapper.map(packageID),
                packageID: packageID
            )
        )
        _ = try await service.prepareApproval(
            request,
            isPackageInstalled: { _ in
                await lookupCounter.increment()
                return false
            }
        )
    }
    let overLimitPackageID = try #require(RuntimePackageID(rawValue: "com.example.rateLimit"))
    let overLimitRequest = try #require(
        RuntimeWrapperApprovalBrokerRequest(
            bundlePath: rootURL.appendingPathComponent("Bundle-\(overLimitPackageID.rawValue).app").path,
            bundleID: BundleIDMapper.map(overLimitPackageID),
            packageID: overLimitPackageID
        )
    )

    await #expect(throws: WrapperApprovalService.Failure.rateLimited) {
        try await service.prepareApproval(
            overLimitRequest,
            isPackageInstalled: { _ in
                await lookupCounter.increment()
                return false
            }
        )
    }

    let pending = await service.pendingChallenges()
    #expect(pending.count == 5)
    #expect(await lookupCounter.value == 5)
}

@Test func identicalBrokerRequestsJoinAndConflictingBundlePathsAreRejected() async throws {
    let rootURL = temporaryDirectory(named: "WrapperApprovalPendingUniqueness")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let packageID = try #require(RuntimePackageID(rawValue: "com.example.singlePending"))
    let bundlePath = rootURL.appendingPathComponent("Bundle-\(packageID.rawValue).app").path
    let request = try #require(
        RuntimeWrapperApprovalBrokerRequest(
            bundlePath: bundlePath,
            bundleID: BundleIDMapper.map(packageID),
            packageID: packageID
        )
    )
    let service = makeService(
        registryURL: rootURL.appendingPathComponent("registry.json"),
        evidence: try makeEvidence(packageID: packageID)
    )
    let lookupCounter = ApprovalLookupCounter()

    let challenge = try await service.prepareApproval(
        request,
        isPackageInstalled: { _ in
            await lookupCounter.increment()
            return false
        }
    )
    #expect(await service.pendingChallenge(bundlePath: bundlePath) == challenge)
    #expect(await service.pendingChallenge(bundlePath: rootURL.appendingPathComponent("Other.app").path) == nil)
    let equivalentBundlePath =
        rootURL
        .appendingPathComponent("Transient", isDirectory: true)
        .appendingPathComponent("..", isDirectory: true)
        .appendingPathComponent("Bundle-\(packageID.rawValue).app")
        .path
    let duplicateRequest = try #require(
        RuntimeWrapperApprovalBrokerRequest(
            bundlePath: equivalentBundlePath,
            bundleID: BundleIDMapper.map(packageID),
            packageID: packageID
        )
    )
    let duplicateChallenge = try await service.prepareApproval(
        duplicateRequest,
        isPackageInstalled: { _ in
            await lookupCounter.increment()
            return false
        }
    )
    #expect(duplicateChallenge == challenge)

    let conflictingPath =
        rootURL
        .appendingPathComponent("Second", isDirectory: true)
        .appendingPathComponent("Bundle-\(packageID.rawValue).app")
        .path
    let conflictingRequest = try #require(
        RuntimeWrapperApprovalBrokerRequest(
            bundlePath: conflictingPath,
            bundleID: BundleIDMapper.map(packageID),
            packageID: packageID
        )
    )
    await #expect(throws: WrapperApprovalService.Failure.alreadyPending) {
        try await service.prepareApproval(conflictingRequest, packageInstalled: false)
    }
    #expect(await lookupCounter.value == 1)
    #expect(await service.pendingChallenges() == [challenge])
}

@Test func controlPathJoinsTheBrokerChallengeWithoutRepeatingPackageLookup() async throws {
    let rootURL = temporaryDirectory(named: "WrapperApprovalControlEntry")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let packageID = try #require(RuntimePackageID(rawValue: "com.example.control"))
    let bundlePath = rootURL.appendingPathComponent("Bundle-\(packageID.rawValue).app").path
    let service = makeService(
        registryURL: rootURL.appendingPathComponent("registry.json"),
        evidenceForPackage: { try makeEvidence(packageID: $0) }
    )
    let lookupCounter = ApprovalLookupCounter()

    let request = try #require(
        RuntimeWrapperApprovalBrokerRequest(
            bundlePath: bundlePath,
            bundleID: BundleIDMapper.map(packageID),
            packageID: packageID
        )
    )
    let challenge = try await service.prepareApproval(
        request,
        isPackageInstalled: { _ in
            await lookupCounter.increment()
            return false
        }
    )
    #expect(challenge.prompt.packageID == packageID)
    #expect(challenge.prompt.bundleID == BundleIDMapper.map(packageID))
    #expect(await service.pendingChallenge(bundlePath: bundlePath) == challenge)

    let controlChallenge = try await service.prepareApproval(
        bundlePath: bundlePath,
        isPackageInstalled: { _ in
            await lookupCounter.increment()
            return true
        }
    )
    #expect(controlChallenge == challenge)
    #expect(await lookupCounter.value == 1)
}

@Test func duplicateRequestJoinsAnInFlightPreparation() async throws {
    let rootURL = temporaryDirectory(named: "WrapperApprovalInFlightJoin")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let packageID = try #require(RuntimePackageID(rawValue: "com.example.inFlight"))
    let bundlePath = rootURL.appendingPathComponent("Bundle-\(packageID.rawValue).app").path
    let request = try #require(
        RuntimeWrapperApprovalBrokerRequest(
            bundlePath: bundlePath,
            bundleID: BundleIDMapper.map(packageID),
            packageID: packageID
        )
    )
    let service = makeService(
        registryURL: rootURL.appendingPathComponent("registry.json"),
        evidenceForPackage: { try makeEvidence(packageID: $0) }
    )
    let lookupCounter = ApprovalLookupCounter()
    let lookupGate = ApprovalLookupGate()
    let lookup: @Sendable (RuntimePackageID) async -> Bool = { _ in
        await lookupCounter.increment()
        await lookupGate.holdUntilReleased()
        return false
    }

    let firstRequest = Task {
        try await service.prepareApproval(request, isPackageInstalled: lookup)
    }
    await lookupGate.waitUntilStarted()
    let secondRequest = Task {
        try await service.prepareApproval(request, isPackageInstalled: lookup)
    }
    await lookupGate.release()

    let firstChallenge = try await firstRequest.value
    let secondChallenge = try await secondRequest.value
    #expect(firstChallenge == secondChallenge)
    #expect(await lookupCounter.value == 1)
    #expect(await service.pendingChallenges() == [firstChallenge])
}

@Test func invalidAndRateLimitedRequestsDoNotLookUpInstalledPackages() async throws {
    let rootURL = temporaryDirectory(named: "WrapperApprovalLookupOrdering")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let lookupCounter = ApprovalLookupCounter()
    let service = makeService(
        registryURL: rootURL.appendingPathComponent("registry.json"),
        evidenceForPackage: { try makeEvidence(packageID: $0) }
    )
    let packageID = try #require(RuntimePackageID(rawValue: "com.example.lookup"))
    let claimedPackageID = try #require(RuntimePackageID(rawValue: "com.example.other"))
    let invalidRequest = try #require(
        RuntimeWrapperApprovalBrokerRequest(
            bundlePath: rootURL.appendingPathComponent("Bundle-\(packageID.rawValue).app").path,
            bundleID: BundleIDMapper.map(packageID),
            packageID: claimedPackageID
        )
    )

    await #expect(throws: WrapperApprovalService.Failure.identityMismatch) {
        try await service.prepareApproval(
            invalidRequest,
            isPackageInstalled: { _ in
                await lookupCounter.increment()
                return false
            }
        )
    }
    #expect(await lookupCounter.value == 0)

    for index in 0..<5 {
        let acceptedPackageID = try #require(RuntimePackageID(rawValue: "com.example.lookup\(index)"))
        let request = try #require(
            RuntimeWrapperApprovalBrokerRequest(
                bundlePath: rootURL.appendingPathComponent("Bundle-\(acceptedPackageID.rawValue).app").path,
                bundleID: BundleIDMapper.map(acceptedPackageID),
                packageID: acceptedPackageID
            )
        )
        _ = try await service.prepareApproval(
            request,
            isPackageInstalled: { _ in
                await lookupCounter.increment()
                return false
            }
        )
    }

    let rateLimitedPackageID = try #require(RuntimePackageID(rawValue: "com.example.lookupLimited"))
    let rateLimitedRequest = try #require(
        RuntimeWrapperApprovalBrokerRequest(
            bundlePath: rootURL.appendingPathComponent("Bundle-\(rateLimitedPackageID.rawValue).app").path,
            bundleID: BundleIDMapper.map(rateLimitedPackageID),
            packageID: rateLimitedPackageID
        )
    )
    await #expect(throws: WrapperApprovalService.Failure.rateLimited) {
        try await service.prepareApproval(
            rateLimitedRequest,
            isPackageInstalled: { _ in
                await lookupCounter.increment()
                return false
            }
        )
    }
    #expect(await lookupCounter.value == 5)
}

@Test func approvalRejectsMissingSignerVerificationAtTheInspectorBoundary() async throws {
    let rootURL = temporaryDirectory(named: "WrapperApprovalSigner")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let packageID = try #require(RuntimePackageID(rawValue: "com.example.signer"))
    let validEvidence = try makeEvidence(packageID: packageID)
    let evidence = WrapperBundleEvidence(
        bundleIdentifier: validEvidence.bundleIdentifier,
        signedIdentifier: validEvidence.signedIdentifier,
        plistPackageID: validEvidence.plistPackageID,
        wrapperFormatVersion: validEvidence.wrapperFormatVersion,
        wrapperKind: validEvidence.wrapperKind,
        launcherVersion: validEvidence.launcherVersion,
        launcherAPI: validEvidence.launcherAPI,
        wrapperDocument: validEvidence.wrapperDocument,
        cdhash: validEvidence.cdhash,
        signerSummary: nil
    )
    let service = makeService(
        registryURL: rootURL.appendingPathComponent("registry.json"),
        evidence: evidence
    )

    await #expect(throws: WrapperApprovalService.Failure.signerVerificationUnavailable) {
        try await service.prepareApproval(
            bundlePath: rootURL.appendingPathComponent("Signer.app").path,
            packageInstalled: false
        )
    }
}

@Test func denialIsPersistedForTwentyFourHoursAndBlocksTheSameCodeHash() async throws {
    let rootURL = temporaryDirectory(named: "WrapperApprovalDeny")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let clock = ApprovalTestClock()
    let packageID = try #require(RuntimePackageID(rawValue: "com.example.denied"))
    let bundleURL = rootURL.appendingPathComponent("Denied.app", isDirectory: true)
    let evidence = try makeEvidence(packageID: packageID)
    let registryURL = rootURL.appendingPathComponent("registry.json")
    let service = makeService(registryURL: registryURL, evidence: evidence, clock: clock)
    let request = try #require(
        RuntimeWrapperApprovalBrokerRequest(
            bundlePath: bundleURL.path,
            bundleID: BundleIDMapper.map(packageID),
            packageID: packageID
        )
    )
    let challenge = try await service.prepareApproval(request, packageInstalled: false)
    try await service.decide(approvalID: challenge.approvalID, allow: false)

    let registry = try await WrapperRegistry(fileURL: registryURL).read()
    #expect(registry.wrappers.isEmpty)
    #expect(registry.denied.count == 1)
    #expect(registry.denied.first?.bundleID == BundleIDMapper.map(packageID))
    #expect(registry.denied.first?.cdhash == evidence.cdhash)
    #expect(registry.denied.first?.until == clock.now.addingTimeInterval(24 * 60 * 60))

    await #expect(throws: WrapperApprovalService.Failure.recentlyDenied) {
        try await service.prepareApproval(request, packageInstalled: false)
    }
}

@Test func pendingApprovalExpiresAfterTenMinutesAndResolvesItsWaiter() async throws {
    let rootURL = temporaryDirectory(named: "WrapperApprovalTimeout")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let clock = ApprovalTestClock()
    let packageID = try #require(RuntimePackageID(rawValue: "com.example.timeout"))
    let service = makeService(
        registryURL: rootURL.appendingPathComponent("registry.json"),
        evidence: try makeEvidence(packageID: packageID),
        clock: clock
    )
    let request = try #require(
        RuntimeWrapperApprovalBrokerRequest(
            bundlePath: rootURL.appendingPathComponent("Timeout.app").path,
            bundleID: BundleIDMapper.map(packageID),
            packageID: packageID
        )
    )
    let challenge = try await service.prepareApproval(request, packageInstalled: false)
    let waiter = Task {
        await service.waitForDecision(approvalID: challenge.approvalID)
    }

    clock.advance(by: 10 * 60 + 1)
    let expired = await service.expirePending(now: clock.now)

    #expect(expired == [challenge.approvalID])
    #expect(await waiter.value == .timedOut)
    #expect(await service.pendingChallenges().isEmpty)
    await #expect(throws: WrapperApprovalService.Failure.unknownApproval) {
        try await service.decide(approvalID: challenge.approvalID, allow: true)
    }
}

@Test func cancellingTheLastWrapperWaiterRemovesItsPendingChallenge() async throws {
    let rootURL = temporaryDirectory(named: "WrapperApprovalDisconnectCancellation")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let packageID = try #require(RuntimePackageID(rawValue: "com.example.disconnect"))
    let service = makeService(
        registryURL: rootURL.appendingPathComponent("registry.json"),
        evidence: try makeEvidence(packageID: packageID)
    )
    let request = try #require(
        RuntimeWrapperApprovalBrokerRequest(
            bundlePath: rootURL.appendingPathComponent("Disconnect.app").path,
            bundleID: BundleIDMapper.map(packageID),
            packageID: packageID
        )
    )
    let challenge = try await service.prepareApproval(request, packageInstalled: false)
    let waiter = Task {
        await service.waitForDecision(approvalID: challenge.approvalID)
    }

    waiter.cancel()

    #expect(await waiter.value == .timedOut)
    #expect(await service.pendingChallenges().isEmpty)
    await #expect(throws: WrapperApprovalService.Failure.unknownApproval) {
        try await service.decide(approvalID: challenge.approvalID, allow: true)
    }
}

@Test func cancellingAWrapperWaiterPreservesAChallengePreparedForCLIConfirmation() async throws {
    let rootURL = temporaryDirectory(named: "WrapperApprovalCLIRetention")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let packageID = try #require(RuntimePackageID(rawValue: "com.example.cliRetention"))
    let bundleURL = rootURL.appendingPathComponent("CLIRetention.app", isDirectory: true)
    let registryURL = rootURL.appendingPathComponent("registry.json")
    let service = makeService(
        registryURL: registryURL,
        evidence: try makeEvidence(packageID: packageID)
    )
    let challenge = try await service.prepareApproval(
        bundlePath: bundleURL.path,
        packageInstalled: false
    )
    let waiter = Task {
        await service.waitForDecision(approvalID: challenge.approvalID)
    }

    waiter.cancel()

    #expect(await waiter.value == .timedOut)
    #expect(await service.pendingChallenges() == [challenge])
    try await service.decide(approvalID: challenge.approvalID, allow: true)
    let registry = try await WrapperRegistry(fileURL: registryURL).read()
    #expect(registry.wrappers.count == 1)
    #expect(registry.wrappers.first?.packageID == packageID)
}

private func makeService(
    registryURL: URL,
    evidence: WrapperBundleEvidence,
    clock: ApprovalTestClock = ApprovalTestClock()
) -> WrapperApprovalService {
    makeService(
        registryURL: registryURL,
        evidenceForPackage: { _ in evidence },
        clock: clock
    )
}

private actor ApprovalLookupCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor ApprovalLookupGate {
    private var hasStarted = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func holdUntilReleased() async {
        hasStarted = true
        for waiter in startedWaiters {
            waiter.resume()
        }
        startedWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !hasStarted else {
            return
        }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private func makeService(
    registryURL: URL,
    evidenceForPackage: @escaping @Sendable (RuntimePackageID) throws -> WrapperBundleEvidence,
    clock: ApprovalTestClock = ApprovalTestClock()
) -> WrapperApprovalService {
    WrapperApprovalService(
        registry: WrapperRegistry(fileURL: registryURL),
        inspector: TestWrapperBundleInspector(evidenceForPackage: evidenceForPackage),
        bookmarkFactory: { _ in Data([1, 2, 3]) },
        monotonicNow: { clock.monotonicNow },
        wallClock: { clock.now }
    )
}

private struct TestWrapperBundleInspector: WrapperBundleInspecting {
    let evidenceForPackage: @Sendable (RuntimePackageID) throws -> WrapperBundleEvidence

    func inspect(bundleURL: URL) throws -> WrapperBundleEvidence {
        let lastComponent = bundleURL.deletingPathExtension().lastPathComponent
        let component = lastComponent.replacingOccurrences(of: "Bundle-", with: "")
        guard let packageID = RuntimePackageID(rawValue: component) else {
            return try evidenceForPackage(try #require(RuntimePackageID(rawValue: "com.example.test")))
        }
        return try evidenceForPackage(packageID)
    }
}

private final class ApprovalTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var monotonic = 100.0
    private var date = Date(timeIntervalSince1970: 1_800_000_000)

    var monotonicNow: TimeInterval {
        lock.withLock { monotonic }
    }

    var now: Date {
        lock.withLock { date }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock {
            monotonic += seconds
            date = date.addingTimeInterval(seconds)
        }
    }
}

private func makeEvidence(packageID: RuntimePackageID) throws -> WrapperBundleEvidence {
    let displayName = "Approved App"
    let application = try WrapperApplication(packageID: packageID, displayName: displayName)
    let window = try WrapperWindow(
        mode: .standard,
        defaultWidth: 960,
        defaultHeight: 720,
        resizable: true
    )
    let document = WrapperDocument(
        kind: .local,
        application: application,
        runtime: WrapperRuntime(
            minimumVersion: try #require(WrapperMinimumRuntimeVersion(rawValue: "1.2.0")),
            launcherAPI: try #require(WrapperLauncherAPIVersion(rawValue: "1.15"))
        ),
        window: window,
        integration: WrapperIntegration(
            clipboard: true,
            notifications: false,
            links: .ask,
            files: false,
            sharedFolders: .off,
            microphone: false
        )
    )
    let manifest = try JSONEncoder().encode(document)
    let bundleID = BundleIDMapper.map(packageID)
    return WrapperBundleEvidence(
        bundleIdentifier: bundleID,
        signedIdentifier: bundleID,
        plistPackageID: packageID.rawValue,
        wrapperFormatVersion: 1,
        wrapperKind: "local",
        launcherVersion: "1.2.3",
        launcherAPI: "1.15",
        wrapperDocument: manifest,
        cdhash: String(repeating: "a", count: 40),
        signerSummary: RuntimeWrapperSignerSummary(kind: .adHoc)
    )
}

private func temporaryDirectory(named name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
}
