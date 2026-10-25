import APKStoreCore
import DiagnosticsCore
import Foundation
import RuntimeAPI
import Testing

@testable import RuntimeHost

private enum PackageEventMonitorTestFailure: Error {
    case transientConnection
    case unexpectedOperation
}

private actor PackageEventMonitorTestChannel: StoreAgentChannel, StoreAgentDisconnectionEventSource {
    nonisolated let capabilities: StoreCapabilities = [.metadata]
    nonisolated let packageEvents: AsyncStream<StorePackageEvent>
    nonisolated let disconnectionEvents: AsyncStream<Void>
    private let eventContinuation: AsyncStream<StorePackageEvent>.Continuation
    private let disconnectionContinuation: AsyncStream<Void>.Continuation
    private let connectionState = PackageEventMonitorConnectionState()
    private var packagesByID: [PackageID: StorePackageInfo]
    private(set) var managedPackageListCount = 0
    private var managedPackageListWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(info: StorePackageInfo) {
        let stream = AsyncStream.makeStream(of: StorePackageEvent.self)
        packageEvents = stream.stream
        eventContinuation = stream.continuation
        let disconnections = AsyncStream.makeStream(of: Void.self)
        disconnectionEvents = disconnections.stream
        disconnectionContinuation = disconnections.continuation
        packagesByID = [info.packageID: info]
    }

    nonisolated var isConnected: Bool { connectionState.isConnected }

    func emit(_ event: StorePackageEvent) {
        eventContinuation.yield(event)
    }

    func setInventory(_ packages: [StorePackageInfo]) {
        packagesByID = Dictionary(uniqueKeysWithValues: packages.map { ($0.packageID, $0) })
    }

    func disconnect() {
        connectionState.disconnect()
        disconnectionContinuation.yield(())
    }

    func waitForManagedPackageLists(_ count: Int) async {
        guard managedPackageListCount < count else { return }
        await withCheckedContinuation { continuation in
            managedPackageListWaiters.append((count, continuation))
        }
    }

    func install(_ request: StoreInstallRequest, files: [URL]) async throws -> StorePackageInfo {
        throw PackageEventMonitorTestFailure.unexpectedOperation
    }

    func uninstall(_ package: PackageID, keepData: Bool) async throws {
        throw PackageEventMonitorTestFailure.unexpectedOperation
    }

    func packageInfo(_ package: PackageID) async throws -> StorePackageInfo? {
        packagesByID[package]
    }

    func listPackages(_ filter: StorePackageFilter) async throws -> [StorePackageSummary] {
        packagesByID.values
            .sorted { $0.packageID.rawValue < $1.packageID.rawValue }
            .map { info in
                StorePackageSummary(
                    packageID: info.packageID,
                    displayName: info.displayName,
                    versionCode: info.versionCode,
                    launchable: info.launchableComponent != nil,
                    userInstalled: true
                )
            }
    }

    func listManagedPackages() async throws -> [StorePackageInfo] {
        managedPackageListCount += 1
        let ready = managedPackageListWaiters.filter { $0.0 <= managedPackageListCount }
        managedPackageListWaiters.removeAll { $0.0 <= managedPackageListCount }
        for waiter in ready {
            waiter.1.resume()
        }
        return packagesByID.values.sorted { $0.packageID.rawValue < $1.packageID.rawValue }
    }

    func close() async {
        disconnect()
        eventContinuation.finish()
        disconnectionContinuation.finish()
    }
}

@Test(.timeLimit(.minutes(1)))
func embeddedPackageServicePersistsAddedAndRemovedPackagesFromPackageEvents() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-package-event-inventory-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
    let originalID = try #require(PackageID(rawValue: "com.example.original"))
    let addedID = try #require(PackageID(rawValue: "com.example.external"))
    let originalInfo = StorePackageInfo(
        packageID: originalID,
        displayName: "Original app",
        versionCode: 1,
        enabled: true,
        launchableComponent: "\(originalID.rawValue)/.MainActivity",
        targetSDK: 35,
        minSDK: 24
    )
    let addedInfo = StorePackageInfo(
        packageID: addedID,
        displayName: "External app",
        versionCode: 2,
        enabled: true,
        launchableComponent: "\(addedID.rawValue)/.MainActivity",
        targetSDK: 35,
        minSDK: 24
    )
    let channel = PackageEventMonitorTestChannel(info: originalInfo)
    let access = PackageEventMonitorTestAccess(channel: channel, generation: UUID(), transientFailures: 0)
    let service = EmbeddedPackageService(paths: paths)
    try await service.open()
    let inventoryReader = PackageStore(packagesDirectory: paths.packagesDirectory)
    try await inventoryReader.open()
    await service.attachRuntimeAccessForTesting(access)
    await channel.waitForManagedPackageLists(1)
    try await waitForAndroidInventory(
        in: inventoryReader,
        packageIDs: [originalID]
    )

    await channel.setInventory([originalInfo, addedInfo])
    await channel.emit(StorePackageEvent(packageID: addedID, kind: .added, versionCode: 2))
    await channel.waitForManagedPackageLists(2)
    try await waitForAndroidInventory(
        in: inventoryReader,
        packageIDs: [originalID, addedID]
    )

    await channel.setInventory([addedInfo])
    await channel.emit(StorePackageEvent(packageID: originalID, kind: .removed, versionCode: 1))
    await channel.waitForManagedPackageLists(3)
    try await waitForAndroidInventory(in: inventoryReader, packageIDs: [addedID])

    await service.detachRuntime()
    let cachedPackages = try await service.listPackages(RuntimeListPackagesRequest(filter: .all))
    #expect(cachedPackages.source == .cachedAndroid)
    #expect(cachedPackages.packages.map(\.packageID.rawValue) == [addedID.rawValue])
    #expect(cachedPackages.packages[0].displayName == "External app")
    #expect(!cachedPackages.packages[0].managed)
}

private func waitForAndroidInventory(
    in store: PackageStore,
    packageIDs expected: [PackageID]
) async throws {
    let expectedIDs = expected.map(\.rawValue).sorted()
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    while clock.now < deadline {
        if let snapshot = try await store.lastKnownAndroidInventory(),
            snapshot.packages.map(\.packageID.rawValue).sorted() == expectedIDs
        {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("The persisted Android inventory did not converge to \(expectedIDs).")
}

private final class PackageEventMonitorConnectionState: @unchecked Sendable {
    private let lock = NSLock()
    private var connected = true

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connected
    }

    func disconnect() {
        lock.lock()
        connected = false
        lock.unlock()
    }
}

private actor PackageEventMonitorTestAccess: StoreRuntimeAccess {
    private let channel: PackageEventMonitorTestChannel
    private let generation: UUID
    private let transientFailures: Int
    private var acquisitionCount = 0
    private var acquisitionWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(channel: PackageEventMonitorTestChannel, generation: UUID, transientFailures: Int) {
        self.channel = channel
        self.generation = generation
        self.transientFailures = transientFailures
    }

    func withStoreAgent<T: Sendable>(
        _ operation: UUID,
        _ body: @Sendable (any StoreAgentChannel) async throws -> T
    ) async throws -> T {
        acquisitionCount += 1
        resumeAcquisitionWaiters()
        if acquisitionCount <= transientFailures {
            throw PackageEventMonitorTestFailure.transientConnection
        }
        return try await body(channel)
    }

    func userdataGeneration() async -> UUID? {
        generation
    }

    func waitForAcquisitions(_ count: Int) async {
        guard acquisitionCount < count else { return }
        await withCheckedContinuation { acquisitionWaiters.append((count, $0)) }
    }

    private func resumeAcquisitionWaiters() {
        let ready = acquisitionWaiters.filter { $0.0 <= acquisitionCount }
        acquisitionWaiters.removeAll { $0.0 <= acquisitionCount }
        for waiter in ready {
            waiter.1.resume()
        }
    }
}

private actor PackageEventReconnectTestAccess: StoreRuntimeAccess {
    private var channel: PackageEventMonitorTestChannel
    private let replacement: PackageEventMonitorTestChannel
    private let generation: UUID
    private var reconnectionCount = 0
    private var reconnectionWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(
        channel: PackageEventMonitorTestChannel,
        replacement: PackageEventMonitorTestChannel,
        generation: UUID
    ) {
        self.channel = channel
        self.replacement = replacement
        self.generation = generation
    }

    func withStoreAgent<T: Sendable>(
        _ operation: UUID,
        _ body: @Sendable (any StoreAgentChannel) async throws -> T
    ) async throws -> T {
        _ = operation
        if !channel.isConnected {
            await channel.close()
            channel = replacement
            reconnectionCount += 1
            let ready = reconnectionWaiters.filter { $0.0 <= reconnectionCount }
            reconnectionWaiters.removeAll { $0.0 <= reconnectionCount }
            for waiter in ready {
                waiter.1.resume()
            }
        }
        return try await body(channel)
    }

    func userdataGeneration() async -> UUID? {
        generation
    }

    func close() async {
        await channel.close()
    }

    func waitForReconnections(_ count: Int) async {
        guard reconnectionCount < count else { return }
        await withCheckedContinuation { continuation in
            reconnectionWaiters.append((count, continuation))
        }
    }
}

@Test func downgradeFailurePreservesInstalledAndCandidateVersions() {
    let error = EmbeddedPackageService.wireError(
        for: PackageStoreFailure.downgradeRefused(installed: 18, candidate: 12)
    )

    #expect(error.code == "store.downgradeRefused")
    #expect(error.message.contains("12"))
    #expect(error.message.contains("18"))
    #expect(error.remediation?.contains("newer APK") == true)
}

@Test func storeAgentInstallStatusesMapToDocumentedStoreErrors() {
    let failures: [(status: Int32, code: String, message: String, remediation: String)] = [
        (
            5,
            "store.guestInstallFailed",
            "Android refused this app because it conflicts with an installed app.",
            "Uninstall the conflicting app, then try again."
        ),
        (
            4,
            "store.guestInstallFailed",
            "This app is not compatible with this version of Android.",
            "Report the problem, so that APKRun can detect this before the install."
        ),
        (
            7,
            "store.guestInstallFailed",
            "The app file is damaged or isn't what was expected.",
            "Download the app again, then try again."
        ),
        (
            8,
            "store.guestInstallFailed",
            "Android does not allow installing this app.",
            "If you think this is wrong, report the problem."
        ),
        (3, "store.guestInstallFailed", "Installation was interrupted.", "Try again."),
        (
            6,
            "store.guestStorageFull",
            "Android is out of storage.",
            "Increase Android storage in Settings → Runtime."
        ),
        (
            9,
            "store.userActionRequired",
            "Android asked for confirmation, which APKRun does not support.",
            "Report the problem."
        ),
    ]

    for failure in failures {
        let error = EmbeddedPackageService.wireError(
            for: StoreAgentSupervisorFailure.installFailed(
                status: failure.status,
                legacyStatus: "INSTALL_PARSE_FAILED_INTERNAL_ERROR",
                message: "private Android detail"
            )
        )
        #expect(error.code == failure.code)
        #expect(error.message == failure.message)
        #expect(error.remediation == failure.remediation)
        #expect(!error.message.contains("private Android detail"))
    }
}

@Test func unknownStoreAgentInstallStatusUsesGenericGuestInstallFailure() {
    let error = EmbeddedPackageService.wireError(
        for: StoreAgentSupervisorFailure.installFailed(
            status: 99,
            legacyStatus: "unknown",
            message: "unrecognized guest message"
        )
    )

    #expect(error.code == "store.guestInstallFailed")
    #expect(error.message == "Android couldn't install this app.")
    #expect(error.remediation == "Try again. If it fails again, create a diagnostics report.")
}

@Test func runtimePackageInstallResultClassifiesInstallsAndReplacements() throws {
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let summary = RuntimePackageSummary(
        packageID: packageID,
        displayName: "Hello Text",
        versionCode: 8,
        state: .installed
    )

    #expect(
        RuntimePackageInstallResult(
            summary: summary,
            previousVersionCode: nil,
            restoredRetainedData: false
        ).change == .installed(summary)
    )
    #expect(
        RuntimePackageInstallResult(
            summary: summary,
            previousVersionCode: 7,
            restoredRetainedData: true
        ).change == .installed(summary)
    )
    #expect(
        RuntimePackageInstallResult(
            summary: summary,
            previousVersionCode: 8,
            restoredRetainedData: false
        ).change == .updated(summary, from: 8)
    )
    #expect(
        RuntimePackageInstallResult(
            summary: summary,
            previousVersionCode: 7,
            restoredRetainedData: false
        ).change == .updated(summary, from: 7)
    )
    #expect(
        RuntimePackageInstallResult(
            summary: summary,
            previousVersionCode: 7,
            restoredRetainedData: false,
            cleanupDeferred: true
        ).cleanupDeferred
    )
}

@Test(.timeLimit(.minutes(1)))
func embeddedPackageServiceRetriesTransientStoreEventMonitorConnection() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-package-event-retry-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
    let packageID = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let generation = UUID()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let packageDirectory = paths.packagesDirectory.appendingPathComponent(packageID.rawValue, isDirectory: true)
    try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
    let existingRecord = PackageRecord(
        packageId: packageID,
        displayName: "HelloText old",
        versionCode: 1,
        signingCertificates: [],
        installer: .apkrun,
        state: .installed,
        artifacts: ArtifactSlots(currentMatchesAndroid: true),
        android: AndroidPackageFacts(
            minSdk: 24,
            targetSdk: 35,
            nativeAbis: [],
            userdataGeneration: generation,
            lastSyncedAt: now
        ),
        source: PackageSource(kind: .file, at: now, origin: .cli, fileNames: ["HelloText.apk"], container: .apk),
        createdAt: now,
        updatedAt: now
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(existingRecord).write(to: packageDirectory.appendingPathComponent("metadata.json"))

    let initialInfo = StorePackageInfo(
        packageID: packageID,
        displayName: "HelloText old",
        versionCode: 1,
        enabled: true,
        launchableComponent: "\(packageID.rawValue)/.MainActivity",
        targetSDK: 35,
        minSDK: 24
    )
    let updatedInfo = StorePackageInfo(
        packageID: packageID,
        displayName: "HelloText updated",
        versionCode: 2,
        enabled: true,
        launchableComponent: "\(packageID.rawValue)/.MainActivity",
        targetSDK: 36,
        minSDK: 24
    )
    let channel = PackageEventMonitorTestChannel(info: initialInfo)
    let access = PackageEventMonitorTestAccess(
        channel: channel,
        generation: generation,
        transientFailures: 1
    )
    let service = EmbeddedPackageService(paths: paths)
    try await service.open()
    let inventoryReader = PackageStore(packagesDirectory: paths.packagesDirectory)
    try await inventoryReader.open()
    await service.attachRuntimeAccessForTesting(access)
    await access.waitForAcquisitions(2)
    await channel.waitForManagedPackageLists(1)
    try await waitForAndroidInventory(in: inventoryReader, packageIDs: [packageID])

    let runtimePackageID = try #require(RuntimePackageID(rawValue: packageID.rawValue))
    let initialDetails = try await service.packageInfo(RuntimePackageRequest(packageID: runtimePackageID))
    #expect(initialDetails.summary.versionCode == 1)
    #expect(initialDetails.summary.displayName == "HelloText old")

    await channel.setInventory([updatedInfo])
    await channel.emit(StorePackageEvent(packageID: packageID, kind: .replaced, versionCode: 2))
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(30))
    var refreshed: RuntimePackageDetails?
    while clock.now < deadline {
        let details = try await service.packageInfo(RuntimePackageRequest(packageID: runtimePackageID))
        if details.summary.versionCode == 2 {
            refreshed = details
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(refreshed?.summary.versionCode == 2)
    #expect(refreshed?.summary.displayName == "HelloText updated")

    await service.detachRuntime()
}

@Test(.timeLimit(.minutes(1)))
func embeddedPackageServiceReconcilesInstalledPackagesAfterReconnectWhenEventsStreamSurvives() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-package-reconnect-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
    let packageID = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let generation = UUID()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let packageDirectory = paths.packagesDirectory.appendingPathComponent(packageID.rawValue, isDirectory: true)
    try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
    let existingRecord = PackageRecord(
        packageId: packageID,
        displayName: "HelloText old",
        versionCode: 1,
        signingCertificates: [],
        installer: .apkrun,
        state: .installed,
        artifacts: ArtifactSlots(currentMatchesAndroid: true),
        android: AndroidPackageFacts(
            minSdk: 24,
            targetSdk: 35,
            nativeAbis: [],
            userdataGeneration: generation,
            lastSyncedAt: now
        ),
        source: PackageSource(kind: .file, at: now, origin: .cli, fileNames: ["HelloText.apk"], container: .apk),
        createdAt: now,
        updatedAt: now
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(existingRecord).write(to: packageDirectory.appendingPathComponent("metadata.json"))

    let firstInfo = StorePackageInfo(
        packageID: packageID,
        displayName: "HelloText old",
        versionCode: 1,
        enabled: true,
        launchableComponent: "\(packageID.rawValue)/.MainActivity",
        targetSDK: 35,
        minSDK: 24
    )
    let reconnectedInfo = StorePackageInfo(
        packageID: packageID,
        displayName: "HelloText after reconnect",
        versionCode: 2,
        enabled: true,
        launchableComponent: "\(packageID.rawValue)/.MainActivity",
        targetSDK: 36,
        minSDK: 24
    )
    let previousChannel = PackageEventMonitorTestChannel(info: firstInfo)
    let reconnectedChannel = PackageEventMonitorTestChannel(info: reconnectedInfo)
    let access = PackageEventReconnectTestAccess(
        channel: previousChannel,
        replacement: reconnectedChannel,
        generation: generation
    )
    let service = EmbeddedPackageService(paths: paths)
    try await service.open()
    await service.attachRuntimeAccessForTesting(access)

    // The initial inventory confirms the monitor has subscribed to the old session.
    await previousChannel.waitForManagedPackageLists(1)
    await previousChannel.disconnect()

    // The package event stream stays open; only the independent disconnect signal can wake the monitor.
    await access.waitForReconnections(1)
    await reconnectedChannel.waitForManagedPackageLists(1)

    let runtimePackageID = try #require(RuntimePackageID(rawValue: packageID.rawValue))
    let details = try await service.packageInfo(RuntimePackageRequest(packageID: runtimePackageID))
    #expect(details.summary.versionCode == 2)
    #expect(details.summary.displayName == "HelloText after reconnect")
    #expect(details.summary.state == .installed)

    await service.detachRuntime()
}

@Test func embeddedPackageServicePackageEventRetryDelayIsCapped() {
    #expect(EmbeddedPackageService.packageEventRetryDelay(for: 0) == .milliseconds(100))
    #expect(EmbeddedPackageService.packageEventRetryDelay(for: 1) == .milliseconds(200))
    #expect(EmbeddedPackageService.packageEventRetryDelay(for: 5) == .seconds(2))
    #expect(EmbeddedPackageService.packageEventRetryDelay(for: 50) == .seconds(2))
}

@Test(.timeLimit(.minutes(1)))
func embeddedPackageServiceListsUnreadablePackagesAndReturnsTheirTypedError() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-package-service-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
    let packageID = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let packageDirectory = paths.packagesDirectory.appendingPathComponent(packageID.rawValue, isDirectory: true)
    try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
    try Data("{invalid".utf8).write(to: packageDirectory.appendingPathComponent("metadata.json"))

    let service = EmbeddedPackageService(paths: paths)
    try await service.open()

    let packages = try await service.listPackages(RuntimeListPackagesRequest())
    #expect(packages.packages.count == 1)
    #expect(packages.packages[0].packageID.rawValue == packageID.rawValue)
    #expect(packages.packages[0].versionCode == nil)
    #expect(packages.packages[0].managed)
    #expect(packages.packages[0].state == .broken("metadataUnreadable"))
    #expect(packages.source == .managedRecords)
    do {
        _ = try await service.packageInfo(
            RuntimePackageRequest(packageID: try #require(RuntimePackageID(rawValue: packageID.rawValue)))
        )
        Issue.record("An unreadable package record must surface its integrity error.")
    } catch {
        let wireError = try #require(error as? RuntimeWireError)
        #expect(wireError.code == "store.metadataUnreadable")
    }
}

@Test(.timeLimit(.minutes(1)))
func embeddedPackageServiceListsLastKnownUnmanagedPackagesWhileRuntimeIsStopped() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-package-service-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
    let packageID = try #require(PackageID(rawValue: "com.example.outside"))
    let store = PackageStore(packagesDirectory: paths.packagesDirectory)
    try await store.open()
    _ = try await store.saveLastKnownAndroidInventory([
        StorePackageSummary(
            packageID: packageID,
            displayName: "Outside app",
            versionCode: 42,
            launchable: true,
            userInstalled: true
        )
    ])

    let service = EmbeddedPackageService(paths: paths)
    try await service.open()
    let packages = try await service.listPackages(RuntimeListPackagesRequest(filter: .all))

    #expect(packages.packages.count == 1)
    #expect(packages.packages[0].packageID.rawValue == packageID.rawValue)
    #expect(packages.packages[0].displayName == "Outside app")
    #expect(packages.packages[0].versionCode == 42)
    #expect(!packages.packages[0].managed)
    #expect(packages.packages[0].updateAuthority == .external)
    #expect(packages.source == .cachedAndroid)
    #expect(packages.observedAt != nil)
}

@Test(.timeLimit(.minutes(1)))
func embeddedPackageServiceReportsUnreadableCachedAndroidInventory() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-package-service-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
    try FileManager.default.createDirectory(at: paths.packagesDirectory, withIntermediateDirectories: true)
    try Data("{invalid".utf8).write(to: paths.packagesDirectory.appendingPathComponent("android-inventory.json"))

    let service = EmbeddedPackageService(paths: paths)
    try await service.open()
    do {
        _ = try await service.listPackages(RuntimeListPackagesRequest(filter: .all))
        Issue.record("A corrupt Android inventory must not be presented as a valid empty cache.")
    } catch {
        #expect(error.code == "store.androidInventoryUnreadable")
    }
}

@Test(.timeLimit(.minutes(1)))
func embeddedPackageServiceMarksManagedPackagesMissingFromCachedInventory() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-package-service-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
    let packageID = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let packageDirectory = paths.packagesDirectory.appendingPathComponent(packageID.rawValue, isDirectory: true)
    try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let record = PackageRecord(
        packageId: packageID,
        displayName: "HelloText",
        versionCode: 1,
        signingCertificates: [],
        installer: .apkrun,
        state: .installed,
        artifacts: ArtifactSlots(currentMatchesAndroid: true),
        android: AndroidPackageFacts(
            minSdk: 24,
            targetSdk: 35,
            nativeAbis: [],
            userdataGeneration: UUID(),
            lastSyncedAt: now
        ),
        source: PackageSource(kind: .file, at: now, origin: .cli, fileNames: ["HelloText.apk"], container: .apk),
        createdAt: now,
        updatedAt: now
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(record).write(to: packageDirectory.appendingPathComponent("metadata.json"))

    let store = PackageStore(packagesDirectory: paths.packagesDirectory)
    try await store.open()
    _ = try await store.saveLastKnownAndroidInventory([])

    let service = EmbeddedPackageService(paths: paths)
    try await service.open()
    let result = try await service.listPackages(RuntimeListPackagesRequest(filter: .all))

    #expect(result.source == .cachedAndroid)
    #expect(result.packages.count == 1)
    #expect(result.packages[0].managed)
    #expect(result.packages[0].state == .broken("removedInAndroid"))
}

@Test(.timeLimit(.minutes(1)))
func embeddedPackageServiceRoutesLaunchAndTerminateThroughRuntimeSessionService() async throws {
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let sessionService = FakePackageRuntimeSessionService()
    let service = EmbeddedPackageService(sessionService: sessionService)

    let launch = try await service.launch(RuntimeLaunchRequest(packageID: package))
    #expect(launch.packageID == package)
    #expect(launch.state == .running)
    let terminate = try await service.terminate(RuntimeTerminateRequest(packageID: package))
    #expect(terminate.packageID == package)
    #expect(terminate.hadSession)
    #expect(await sessionService.launchedPackageIDs == [package])
    #expect(await sessionService.terminatedPackageIDs == [package])
}

@Test(.timeLimit(.minutes(1)))
func embeddedPackageServiceRejectsInstallWhileThePackageHasAnActiveSession() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-package-session-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
    let packageID = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let runtimePackageID = try #require(RuntimePackageID(rawValue: packageID.rawValue))
    let launchError = PackageMutationErrorProbe()
    let sessionService = PackageMutationTestSessionService(
        activePackageID: runtimePackageID,
        launchError: launchError
    )
    let service = EmbeddedPackageService(
        paths: paths,
        inspector: { _ in
            APKFacts(
                packageID: packageID,
                versionCode: 12,
                versionName: "1.2",
                splitName: nil,
                displayName: "Hello Text",
                minSDK: 23,
                targetSDK: 35,
                nativeABIs: []
            )
        },
        sessionService: sessionService
    )
    await sessionService.setPackageService(service)
    try await service.open()

    let source = root.appendingPathComponent("hello.apk")
    try Data("apk-test-bytes".utf8).write(to: source)
    let handle = try FileHandle(forReadingFrom: source)
    defer { try? handle.close() }
    let preview = try await service.importPackage(
        RuntimeImportPackageRequest(
            files: [RuntimeImportSourceFile(fileIndex: 0, name: "hello.apk")],
            origin: .cli
        ),
        files: [handle]
    )
    let boundaryProbe = PackageMutationBoundaryProbe()

    do {
        _ = try await service.installImportedWithChange(
            RuntimeInstallImportedRequest(ticket: preview.ticket),
            beforeStoreMutation: { await boundaryProbe.markEntered() }
        )
        Issue.record("An install must not replace a package with an active app session.")
    } catch let wireError as RuntimeWireError {
        #expect(wireError.code == "store.packageInUse")
    }

    #expect(!(await boundaryProbe.wasEntered()))
    #expect(await launchError.code == "store.operationInProgress")
    #expect(try await service.launch(RuntimeLaunchRequest(packageID: runtimePackageID)).state == .running)
}

@Test(.timeLimit(.minutes(1)))
func embeddedPackageServiceImportsIndexedFileHandlesWithoutStartingAndroid() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-package-service-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
    let package = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let service = EmbeddedPackageService(
        paths: paths,
        inspector: { _ in
            APKFacts(
                packageID: package,
                versionCode: 12,
                versionName: "1.2",
                splitName: nil,
                displayName: "Hello Text",
                minSDK: 23,
                targetSDK: 35,
                nativeABIs: []
            )
        }
    )
    try await service.open()

    let source = root.appendingPathComponent("hello.apk")
    try Data("apk-test-bytes".utf8).write(to: source)
    let handle = try FileHandle(forReadingFrom: source)
    defer { try? handle.close() }
    try handle.seek(toOffset: 4)

    let preview = try await service.importPackage(
        RuntimeImportPackageRequest(
            files: [RuntimeImportSourceFile(fileIndex: 0, name: "hello.apk")],
            origin: .cli
        ),
        files: [handle]
    )

    #expect(preview.packageID.rawValue == package.rawValue)
    #expect(preview.versionCode == 12)
    #expect(preview.displayName == "Hello Text")
    #expect(preview.relation == .newPackage)
    #expect(preview.files.count == 1)
    #expect(
        try await service.packageIDForInstall(RuntimeInstallImportedRequest(ticket: preview.ticket))
            == preview.packageID
    )
    #expect(try handle.offset() == 4)
    #expect(try await service.listPackages(RuntimeListPackagesRequest()).packages == [])
    let stagingRoot = paths.packagesDirectory.appendingPathComponent(".client-imports", isDirectory: true)
    #expect(try FileManager.default.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil).isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func embeddedPackageServiceStagesSameSetPreviewForGuestVerification() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-package-service-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
    let packageID = try #require(PackageID(rawValue: "com.example.same"))
    let contents = Data("same-apk-content".utf8)
    let file = ArtifactFile(
        name: "base.apk",
        splitName: nil,
        size: Int64(contents.count),
        sha256: SHA256Digest(data: contents)
    )
    let setDigest = try ArtifactSet.computeSetDigest(for: [file])
    let packageDirectory = paths.packagesDirectory.appendingPathComponent(packageID.rawValue, isDirectory: true)
    try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let record = PackageRecord(
        packageId: packageID,
        displayName: "Same app",
        versionCode: 12,
        versionName: "1.2",
        signingCertificates: [],
        installer: .apkrun,
        state: .installed,
        artifacts: ArtifactSlots(
            current: ArtifactSlotSummary(
                versionCode: 12,
                versionName: "1.2",
                setDigest: setDigest,
                size: Int64(contents.count),
                fileCount: 1
            ),
            currentMatchesAndroid: true
        ),
        android: AndroidPackageFacts(
            minSdk: 23,
            targetSdk: 35,
            nativeAbis: [],
            userdataGeneration: UUID(),
            lastSyncedAt: now
        ),
        source: PackageSource(
            kind: .file,
            at: now,
            origin: .cli,
            fileNames: ["base.apk"],
            container: .apk
        ),
        createdAt: now,
        updatedAt: now
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(record).write(to: packageDirectory.appendingPathComponent("metadata.json"))

    let source = root.appendingPathComponent("base.apk")
    try contents.write(to: source)
    let handle = try FileHandle(forReadingFrom: source)
    defer { try? handle.close() }
    let service = EmbeddedPackageService(
        paths: paths,
        inspector: { _ in
            APKFacts(
                packageID: packageID,
                versionCode: 12,
                versionName: "1.2",
                splitName: nil,
                displayName: "Same app",
                minSDK: 23,
                targetSDK: 35,
                nativeABIs: []
            )
        }
    )
    try await service.open()
    let preview = try await service.importPackage(
        RuntimeImportPackageRequest(
            files: [RuntimeImportSourceFile(fileIndex: 0, name: "base.apk")],
            origin: .cli
        ),
        files: [handle]
    )

    #expect(preview.relation == .sameAsInstalled)
    let persistedTicket = paths.packagesDirectory
        .appendingPathComponent(packageID.rawValue, isDirectory: true)
        .appendingPathComponent("incoming", isDirectory: true)
        .appendingPathComponent(preview.ticket.rawValue, isDirectory: true)
        .appendingPathComponent("artifact.json")
    #expect(FileManager.default.fileExists(atPath: persistedTicket.path))
}

@Test(.timeLimit(.minutes(1)))
func embeddedPackageServiceReadsISO8601ArtifactMetadata() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-package-artifact-metadata-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
    let packageID = try #require(PackageID(rawValue: "com.example.artifact"))
    let runtimePackageID = try #require(RuntimePackageID(rawValue: packageID.rawValue))
    let contents = Data("artifact contents".utf8)
    let file = ArtifactFile(
        name: "base.apk",
        splitName: nil,
        size: Int64(contents.count),
        sha256: SHA256Digest(data: contents)
    )
    let setDigest = try ArtifactSet.computeSetDigest(for: [file])
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let artifactSet = ArtifactSet(
        packageID: packageID,
        versionCode: 7,
        versionName: "7",
        files: [file],
        setDigest: setDigest,
        signerDigests: [],
        lineage: [],
        inspection: InspectionProvenance(
            aapt2Version: "test",
            verifierVersion: "test",
            inspectedAt: now,
            hostChecksPerformed: ["sha256"]
        )
    )
    let packageDirectory = paths.packagesDirectory.appendingPathComponent(packageID.rawValue, isDirectory: true)
    let currentDirectory = packageDirectory.appendingPathComponent("current", isDirectory: true)
    try FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
    try contents.write(to: currentDirectory.appendingPathComponent(file.name))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(artifactSet).write(to: currentDirectory.appendingPathComponent("artifact.json"))

    let record = PackageRecord(
        packageId: packageID,
        displayName: "Artifact app",
        versionCode: artifactSet.versionCode,
        versionName: artifactSet.versionName,
        signingCertificates: [],
        installer: .apkrun,
        state: .installed,
        artifacts: ArtifactSlots(
            current: ArtifactSlotSummary(
                versionCode: artifactSet.versionCode,
                versionName: artifactSet.versionName,
                setDigest: setDigest,
                size: Int64(contents.count),
                fileCount: 1
            ),
            currentMatchesAndroid: true
        ),
        android: AndroidPackageFacts(
            minSdk: 23,
            targetSdk: 35,
            nativeAbis: [],
            userdataGeneration: UUID(),
            lastSyncedAt: now
        ),
        source: PackageSource(kind: .file, at: now, origin: .cli, fileNames: [file.name], container: .apk),
        createdAt: now,
        updatedAt: now
    )
    try encoder.encode(record).write(to: packageDirectory.appendingPathComponent("metadata.json"))

    let service = EmbeddedPackageService(paths: paths)
    try await service.open()
    let details = try await service.packageInfo(RuntimePackageRequest(packageID: runtimePackageID))
    #expect(details.files.map(\.name) == ["base.apk"])
    #expect(details.artifactBytes == Int64(contents.count))
}

@Test(.timeLimit(.minutes(1)))
func embeddedPackageServiceKeepsTheStoreImportLimitAboveDaemonTransportLimit() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-package-service-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
    let package = try #require(PackageID(rawValue: "io.apkrun.fixture.hellosplit"))
    let sources = (0..<21).map { index in
        root.appendingPathComponent(index == 0 ? "base.apk" : "split-\(index).apk")
    }
    for (index, source) in sources.enumerated() {
        try Data("apk-\(index)".utf8).write(to: source)
    }
    let handles = try sources.map { try FileHandle(forReadingFrom: $0) }
    defer {
        for handle in handles {
            try? handle.close()
        }
    }

    let service = EmbeddedPackageService(
        paths: paths,
        inspector: { url in
            let name = url.deletingPathExtension().lastPathComponent
            let index = Int(name.dropFirst("input-".count)) ?? 0
            return APKFacts(
                packageID: package,
                versionCode: 12,
                versionName: "1.2",
                splitName: index == 0 ? nil : "config\(index)",
                displayName: "Hello Split",
                minSDK: 23,
                targetSDK: 35,
                nativeABIs: []
            )
        }
    )
    try await service.open()

    let preview = try await service.importPackage(
        RuntimeImportPackageRequest(
            files: sources.enumerated().map { index, source in
                RuntimeImportSourceFile(fileIndex: index, name: source.lastPathComponent)
            },
            origin: .cli
        ),
        files: handles
    )

    #expect(preview.files.count == 21)
}

@Test(.timeLimit(.minutes(1)))
func embeddedPackageServiceRequiresEveryImportHandleToBeMappedExactlyOnce() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-package-service-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
    let service = EmbeddedPackageService(paths: paths)
    try await service.open()

    let first = root.appendingPathComponent("first.apk")
    let second = root.appendingPathComponent("second.apk")
    try Data("first".utf8).write(to: first)
    try Data("second".utf8).write(to: second)
    let handles = try [first, second].map { try FileHandle(forReadingFrom: $0) }
    defer {
        for handle in handles {
            try? handle.close()
        }
    }

    do {
        _ = try await service.importPackage(
            RuntimeImportPackageRequest(
                files: [RuntimeImportSourceFile(fileIndex: 0, name: "first.apk")],
                origin: .cli
            ),
            files: handles
        )
        Issue.record("An import must not accept unused file handles.")
    } catch {
        #expect(error.code == "store.invalidImport")
    }
}

private actor FakePackageRuntimeSessionService: RuntimeSessionService {
    private(set) var launchedPackageIDs: [RuntimePackageID] = []
    private(set) var terminatedPackageIDs: [RuntimePackageID] = []

    func launch(_ request: RuntimeLaunchRequest) async throws(RuntimeWireError) -> RuntimeLaunchResult {
        launchedPackageIDs.append(request.packageID)
        return RuntimeLaunchResult(sessionID: UUID(), packageID: request.packageID, state: .running)
    }

    func terminate(_ request: RuntimeTerminateRequest) async throws(RuntimeWireError) -> RuntimeTerminateResult {
        terminatedPackageIDs.append(request.packageID)
        return RuntimeTerminateResult(packageID: request.packageID, hadSession: true)
    }
}

private actor PackageMutationTestSessionService: RuntimeSessionService, PackageMutationSessionHandling {
    private let activePackageID: RuntimePackageID?
    private let launchError: PackageMutationErrorProbe?
    private var packageService: EmbeddedPackageService?

    init(
        activePackageID: RuntimePackageID? = nil,
        launchError: PackageMutationErrorProbe? = nil
    ) {
        self.activePackageID = activePackageID
        self.launchError = launchError
    }

    func setPackageService(_ packageService: EmbeddedPackageService) {
        self.packageService = packageService
    }

    func launch(_ request: RuntimeLaunchRequest) async throws(RuntimeWireError) -> RuntimeLaunchResult {
        RuntimeLaunchResult(sessionID: UUID(), packageID: request.packageID, state: .running)
    }

    func terminate(_ request: RuntimeTerminateRequest) async throws(RuntimeWireError) -> RuntimeTerminateResult {
        RuntimeTerminateResult(packageID: request.packageID, hadSession: true)
    }

    func hasActiveSession(packageID: RuntimePackageID) async -> Bool {
        if let packageService {
            do {
                _ = try await packageService.launch(RuntimeLaunchRequest(packageID: packageID))
                await launchError?.record("unexpectedLaunch")
            } catch let wireError as RuntimeWireError {
                await launchError?.record(wireError.code)
            } catch {
                await launchError?.record("unexpectedError")
            }
        }
        return activePackageID == packageID
    }

    func endSessionForPackageUninstall(_ request: RuntimeTerminateRequest) async throws(RuntimeWireError) {
        _ = request
    }
}

private actor PackageMutationErrorProbe {
    private(set) var code: String?

    func record(_ code: String) {
        self.code = code
    }
}

private actor PackageMutationBoundaryProbe {
    private var entered = false

    func markEntered() {
        entered = true
    }

    func wasEntered() -> Bool {
        entered
    }
}

@Test(.timeLimit(.minutes(1)))
func embeddedPackageServiceRejectsFileHandlePathTraversal() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-package-service-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
    let service = EmbeddedPackageService(
        paths: paths,
        inspector: { _ in
            throw APKInspectionFailure.inputNotReadable
        })
    let source = root.appendingPathComponent("source.apk")
    try Data("apk".utf8).write(to: source)
    let handle = try FileHandle(forReadingFrom: source)
    defer { try? handle.close() }

    do {
        _ = try await service.importPackage(
            RuntimeImportPackageRequest(
                files: [RuntimeImportSourceFile(fileIndex: 0, name: "../escape.apk")],
                origin: .cli
            ),
            files: [handle]
        )
        Issue.record("An import filename containing a parent path must be rejected.")
    } catch {
        #expect(error.code == "store.invalidSourceFile")
    }
}

@Test(.timeLimit(.minutes(1)))
func embeddedPackageServiceFailsClosedWhenHostSpaceCannotBeRead() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-package-service-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
    let package = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let service = EmbeddedPackageService(
        paths: paths,
        inspector: { _ in
            APKFacts(
                packageID: package,
                versionCode: 12,
                versionName: "1.2",
                splitName: nil,
                displayName: "Hello Text",
                minSDK: 23,
                targetSDK: 35,
                nativeABIs: []
            )
        },
        hostFreeSpace: { _ in 0 }
    )
    try await service.open()

    let source = root.appendingPathComponent("hello.apk")
    try Data("apk-test-bytes".utf8).write(to: source)
    let handle = try FileHandle(forReadingFrom: source)
    defer { try? handle.close() }

    do {
        _ = try await service.importPackage(
            RuntimeImportPackageRequest(
                files: [RuntimeImportSourceFile(fileIndex: 0, name: "hello.apk")],
                origin: .cli
            ),
            files: [handle]
        )
        Issue.record("Import staging must stop when available host space is unknown.")
    } catch {
        #expect(error.code == "store.insufficientHostSpace")
    }

    let stagingRoot = paths.packagesDirectory.appendingPathComponent(".client-imports", isDirectory: true)
    #expect(try FileManager.default.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil).isEmpty)
}
