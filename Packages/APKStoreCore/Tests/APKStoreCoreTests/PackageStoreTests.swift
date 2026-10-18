import Foundation
import Testing

@testable import APKStoreCore

private struct InjectedStoreCrash: Error {}
private enum SimulatedGuestFailure: Error {
    case installFailedAfterCommit
    case installFailedBeforeCommit
    case queryUnavailable
}

private actor FakeStoreChannel: StoreAgentChannel {
    nonisolated let capabilities: StoreCapabilities = [.install, .metadata, .downgradeReinstall]

    private var packages: [PackageID: StorePackageInfo] = [:]
    private(set) var lastKeepData: Bool?
    private var installThrowsAfterCommit = false
    private var installThrowsBeforeCommit = false
    private var queryThrows = false
    private var queryUnavailableAfterInstall = false

    func configureInstallFailureAfterCommit(queryUnavailable: Bool) {
        installThrowsAfterCommit = true
        queryUnavailableAfterInstall = queryUnavailable
    }

    func seed(_ info: StorePackageInfo) {
        packages[info.packageID] = info
    }

    func configureInstallFailureBeforeCommit() {
        installThrowsBeforeCommit = true
    }

    func makeQueriesAvailable() {
        queryThrows = false
    }

    func configureInstallSuccess() {
        installThrowsAfterCommit = false
        installThrowsBeforeCommit = false
        queryUnavailableAfterInstall = false
        queryThrows = false
    }

    func install(_ request: StoreInstallRequest, files: [URL]) async throws -> StorePackageInfo {
        #expect(!files.isEmpty)
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        if installThrowsBeforeCommit {
            throw SimulatedGuestFailure.installFailedBeforeCommit
        }
        let info = StorePackageInfo(
            packageID: request.packageID,
            displayName: "Example",
            versionCode: request.versionCode,
            versionName: "1.0",
            enabled: true,
            launchableComponent: "\(request.packageID.rawValue)/.MainActivity",
            installerPackage: PackageID(rawValue: "io.apkrun.store"),
            firstInstallTime: Date(timeIntervalSince1970: 100),
            lastUpdateTime: Date(timeIntervalSince1970: 200),
            targetSDK: 35,
            minSDK: 24
        )
        packages[request.packageID] = info
        if installThrowsAfterCommit {
            queryThrows = queryUnavailableAfterInstall
            throw SimulatedGuestFailure.installFailedAfterCommit
        }
        return info
    }

    func uninstall(_ package: PackageID, keepData: Bool) async throws {
        lastKeepData = keepData
        packages[package] = nil
    }

    func packageInfo(_ package: PackageID) async throws -> StorePackageInfo? {
        if queryThrows {
            throw SimulatedGuestFailure.queryUnavailable
        }
        return packages[package]
    }

    func listPackages(_ filter: StorePackageFilter) async throws -> [StorePackageSummary] {
        packages.values.map {
            StorePackageSummary(
                packageID: $0.packageID,
                displayName: $0.displayName,
                versionCode: $0.versionCode,
                launchable: $0.launchableComponent != nil,
                userInstalled: true
            )
        }
    }
}

private actor FakeStoreRuntime: StoreRuntimeAccess {
    private let channel: FakeStoreChannel
    private let generation: UUID

    init(channel: FakeStoreChannel, generation: UUID = UUID()) {
        self.channel = channel
        self.generation = generation
    }

    func withStoreAgent<T: Sendable>(
        _ operation: UUID,
        _ body: @Sendable (any StoreAgentChannel) async throws -> T
    ) async throws -> T {
        try await body(channel)
    }

    func userdataGeneration() async -> UUID? {
        generation
    }
}

@Test func packageStoreImportsPrivateCopiesAndComputesCanonicalDigest() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)

    let store = PackageStore(
        packagesDirectory: temporary.appendingPathComponent("Packages", isDirectory: true),
        inspector: { _ in facts() }
    )
    try await store.open()
    let preview = try await store.importPackage(files: [input])

    let packages = try await store.listManagedPackages()
    #expect(packages.isEmpty)
    #expect(preview.packageID.rawValue == "io.apkrun.fixture.hellotext")
    #expect(preview.versionCode == 7)
    #expect(preview.artifactSet.files.map(\.name) == ["base.apk"])
    #expect(
        preview.artifactSet.setDigest
            == (try ArtifactSet.computeSetDigest(for: preview.artifactSet.files))
    )

    let storedAPK =
        temporary
        .appendingPathComponent("Packages/io.apkrun.fixture.hellotext/incoming/\(preview.ticket.uuidString)/base.apk")
    #expect(try Data(contentsOf: storedAPK) == Data("base apk bytes".utf8))
    #expect(storedAPK != input)
}

@Test func packageStoreKeepsAmbiguousFirstInstallPendingUntilSameSetRetry() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let channel = FakeStoreChannel()
    let runtime = FakeStoreRuntime(channel: channel)
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let packages = temporary.appendingPathComponent("Packages", isDirectory: true)
    let createdAt = Date(timeIntervalSince1970: 1_000)
    let expiredAt = createdAt.addingTimeInterval(2 * 60 * 60)
    let store = PackageStore(
        packagesDirectory: packages,
        runtimeAccess: runtime,
        inspector: { _ in facts() },
        clock: { createdAt }
    )
    try await store.open()
    let preview = try await store.importPackage(files: [input])
    await channel.configureInstallFailureAfterCommit(queryUnavailable: true)

    do {
        _ = try await store.installImported(ticket: preview.ticket)
        Issue.record("Expected an install error while PackageManager was unavailable.")
    } catch is SimulatedGuestFailure {
        // The first request may have committed even though both calls failed.
    }

    let incoming = packages
        .appendingPathComponent("io.apkrun.fixture.hellotext/incoming/\(preview.ticket.uuidString)")
    #expect(FileManager.default.fileExists(atPath: incoming.appendingPathComponent("base.apk").path))
    let journal = try String(contentsOf: packages.appendingPathComponent("journal.jsonl"), encoding: .utf8)
    #expect(!journal.contains("\"op\":\"abort\""))

    await channel.makeQueriesAvailable()
    let recoveredStore = PackageStore(
        packagesDirectory: packages,
        runtimeAccess: runtime,
        inspector: { _ in facts() },
        clock: { expiredAt }
    )
    try await recoveredStore.open()
    try await recoveredStore.recoverPendingTransactions()
    #expect(try await recoveredStore.listManagedPackages().isEmpty)
    #expect(FileManager.default.fileExists(atPath: incoming.appendingPathComponent("base.apk").path))

    // PackageManager has no transaction receipt, so a matching package after an uncertain
    // first-install error remains ambiguous. Retrying the same ticket gives the channel a
    // successful install result that can safely promote the artifact set.
    await channel.configureInstallSuccess()
    let record = try await recoveredStore.installImported(ticket: preview.ticket)
    #expect(record.versionCode == preview.versionCode)
    #expect(try await recoveredStore.listManagedPackages().count == 1)
    try await recoveredStore.recoverPendingTransactions()
    #expect(try await recoveredStore.listManagedPackages().count == 1)
}

@Test func packageStoreDoesNotClaimAnUnchangedUnmanagedPackageAfterInstallFailure() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let packageID = PackageID(rawValue: "io.apkrun.fixture.hellotext")!
    let channel = FakeStoreChannel()
    let unmanaged = StorePackageInfo(
        packageID: packageID,
        displayName: "Unmanaged HelloText",
        versionCode: 7,
        versionName: "1.0",
        enabled: true,
        launchableComponent: "\(packageID.rawValue)/.MainActivity",
        firstInstallTime: Date(timeIntervalSince1970: 100),
        lastUpdateTime: Date(timeIntervalSince1970: 200),
        targetSDK: 35,
        minSDK: 24
    )
    await channel.seed(unmanaged)
    await channel.configureInstallFailureBeforeCommit()
    let runtime = FakeStoreRuntime(channel: channel)
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("different apk bytes".utf8).write(to: input)
    let packages = temporary.appendingPathComponent("Packages", isDirectory: true)
    let store = PackageStore(
        packagesDirectory: packages,
        runtimeAccess: runtime,
        inspector: { _ in facts() }
    )
    try await store.open()
    let preview = try await store.importPackage(files: [input])

    do {
        _ = try await store.installImported(ticket: preview.ticket)
        Issue.record("Expected the install error.")
    } catch is SimulatedGuestFailure {
        // The guest still has the same unmanaged package and the channel did not install.
    }

    #expect(try await store.listManagedPackages().isEmpty)
    #expect(
        !FileManager.default.fileExists(
            atPath: packages.appendingPathComponent("io.apkrun.fixture.hellotext/current/base.apk").path
        )
    )
    try await store.recoverPendingTransactions()
    #expect(try await store.listManagedPackages().isEmpty)
    #expect(
        !FileManager.default.fileExists(
            atPath: packages.appendingPathComponent("io.apkrun.fixture.hellotext/current/base.apk").path
        )
    )
}

@Test func packageStoreRecoversPromotedArtifactsAfterTicketAgeExpires() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let channel = FakeStoreChannel()
    let runtime = FakeStoreRuntime(channel: channel)
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let packages = temporary.appendingPathComponent("Packages", isDirectory: true)
    let createdAt = Date(timeIntervalSince1970: 1_000)
    let expiredAt = createdAt.addingTimeInterval(2 * 60 * 60)
    let crashingStore = PackageStore(
        packagesDirectory: packages,
        runtimeAccess: runtime,
        inspector: { _ in facts() },
        clock: { createdAt },
        faultInjector: { kind, step in
            if kind == "firstInstall", step == "filesPromoted" {
                throw InjectedStoreCrash()
            }
        }
    )
    try await crashingStore.open()
    let preview = try await crashingStore.importPackage(files: [input])
    do {
        _ = try await crashingStore.installImported(ticket: preview.ticket)
        Issue.record("Expected the injected interruption after promotion.")
    } catch is InjectedStoreCrash {
        // The APK set is in current/, but the record and commit are still pending.
    }

    let recoveredStore = PackageStore(
        packagesDirectory: packages,
        runtimeAccess: runtime,
        inspector: { _ in facts() },
        clock: { expiredAt }
    )
    try await recoveredStore.open()
    try await recoveredStore.recoverPendingTransactions()

    let recovered = try #require(try await recoveredStore.listManagedPackages().first)
    #expect(recovered.packageId == preview.packageID)
    #expect(recovered.versionCode == preview.versionCode)
    #expect(
        FileManager.default.fileExists(
            atPath: packages.appendingPathComponent("io.apkrun.fixture.hellotext/current/base.apk").path
        )
    )
    #expect(
        !FileManager.default.fileExists(
            atPath: packages.appendingPathComponent("io.apkrun.fixture.hellotext/current/ticket.json").path
        )
    )
}

@Test func packageStoreChecksImportLimitsAndAvailableSpaceBeforeCopying() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let input = temporary.appendingPathComponent("tiny.apk")
    try Data("apk".utf8).write(to: input)
    let packages = temporary.appendingPathComponent("Packages", isDirectory: true)
    let store = PackageStore(
        packagesDirectory: packages,
        inspector: { _ in facts() },
        hostFreeSpace: { _ in 64 }
    )
    try await store.open()

    do {
        _ = try await store.importPackage(files: [input])
        Issue.record("Expected the insufficient-space guard to reject the import.")
    } catch let failure as PackageStoreFailure {
        guard case .insufficientHostSpace(let needed, let available) = failure else {
            Issue.record("Unexpected package-store failure: \(failure)")
            return
        }
        #expect(needed > available)
    }

    do {
        _ = try await store.importPackage(files: Array(repeating: input, count: 257))
        Issue.record("Expected the APK-count limit to reject the import.")
    } catch let failure as PackageStoreFailure {
        #expect(failure == .tooManyImportFiles)
    }
}

@Test func packageStoreAcceptsImportWhenSpaceMatchesItsPreflightEstimate() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let input = temporary.appendingPathComponent("HelloText.apk")
    let bytes = Data(repeating: 0xA5, count: 1_100_000)
    try bytes.write(to: input)
    let reserve: Int64 = 2 * 1_024 * 1_024 * 1_024
    let required = Int64(bytes.count) * 2 + reserve
    let store = PackageStore(
        packagesDirectory: temporary.appendingPathComponent("Packages", isDirectory: true),
        inspector: { _ in facts() },
        hostFreeSpace: { _ in required }
    )
    try await store.open()

    let preview = try await store.importPackage(files: [input])
    #expect(preview.artifactSet.files.first?.size == Int64(bytes.count))
}

@Test func packageStoreInstallsAndUninstallsWithOrWithoutKeptData() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let channel = FakeStoreChannel()
    let runtime = FakeStoreRuntime(channel: channel)
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let store = PackageStore(
        packagesDirectory: temporary.appendingPathComponent("Packages", isDirectory: true),
        runtimeAccess: runtime,
        inspector: { _ in facts() }
    )
    try await store.open()

    let preview = try await store.importPackage(files: [input])
    let record = try await store.installImported(ticket: preview.ticket)
    #expect(record.state == .installed)
    #expect(record.versionCode == 7)
    #expect(record.updateAuthority == .manual)

    let packageDirectory = temporary.appendingPathComponent("Packages/io.apkrun.fixture.hellotext")
    let current = packageDirectory.appendingPathComponent("current", isDirectory: true)
    #expect(FileManager.default.fileExists(atPath: current.appendingPathComponent("base.apk").path))
    #expect(FileManager.default.fileExists(atPath: current.appendingPathComponent("artifact.json").path))
    #expect(FileManager.default.fileExists(atPath: packageDirectory.appendingPathComponent("metadata.json").path))

    try await store.uninstall(packageID: record.packageId, keepData: true)
    let retained = try #require(try await store.listManagedPackages().first)
    #expect(retained.state == .uninstalledKeepingData)
    #expect(!FileManager.default.fileExists(atPath: current.path))
    #expect(await channel.lastKeepData == true)

    let secondPreview = try await store.importPackage(files: [input])
    let reinstalled = try await store.installImported(ticket: secondPreview.ticket)
    #expect(reinstalled.state == .installed)
    try await store.uninstall(packageID: record.packageId)
    #expect(try await store.listManagedPackages().isEmpty)
    #expect(await channel.lastKeepData == false)
    #expect(!FileManager.default.fileExists(atPath: packageDirectory.path))
}

@Test func packageStoreRecoversInstallInterruptedAfterGuestCommit() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let channel = FakeStoreChannel()
    let runtime = FakeStoreRuntime(channel: channel)
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let packages = temporary.appendingPathComponent("Packages", isDirectory: true)

    let crashingStore = PackageStore(
        packagesDirectory: packages,
        runtimeAccess: runtime,
        inspector: { _ in facts() },
        faultInjector: { kind, step in
            if kind == "firstInstall", step == "guestInstalled" {
                throw InjectedStoreCrash()
            }
        }
    )
    try await crashingStore.open()
    let preview = try await crashingStore.importPackage(files: [input])
    do {
        _ = try await crashingStore.installImported(ticket: preview.ticket)
        Issue.record("Expected the injected interruption.")
    } catch is InjectedStoreCrash {
        // The guest has the package while the host still has a journaled incoming set.
    }

    let recoveredStore = PackageStore(
        packagesDirectory: packages,
        runtimeAccess: runtime,
        inspector: { _ in facts() }
    )
    try await recoveredStore.open()
    try await recoveredStore.recoverPendingTransactions()

    let recovered = try #require(try await recoveredStore.listManagedPackages().first)
    #expect(recovered.packageId == preview.packageID)
    #expect(recovered.versionCode == preview.versionCode)
    #expect(
        FileManager.default.fileExists(
            atPath:
                packages
                .appendingPathComponent("io.apkrun.fixture.hellotext/current/base.apk")
                .path
        )
    )
}

@Test func packageStoreTruncatesTornJournalTailAndContinuesRecovery() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let packages = temporary.appendingPathComponent("Packages", isDirectory: true)
    let runtime = FakeStoreRuntime(channel: FakeStoreChannel())
    let store = PackageStore(
        packagesDirectory: packages,
        runtimeAccess: runtime,
        inspector: { _ in facts() },
        faultInjector: { kind, step in
            if kind == "firstInstall", step == "begin" {
                throw InjectedStoreCrash()
            }
        }
    )
    try await store.open()
    let preview = try await store.importPackage(files: [input])
    do {
        _ = try await store.installImported(ticket: preview.ticket)
        Issue.record("Expected interruption after the begin record.")
    } catch is InjectedStoreCrash {
        // The durable journal now contains an unfinished begin record.
    }

    let journal = packages.appendingPathComponent("journal.jsonl")
    let handle = try FileHandle(forWritingTo: journal)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{torn".utf8))
    try handle.close()

    let reopened = PackageStore(
        packagesDirectory: packages,
        runtimeAccess: runtime,
        inspector: { _ in facts() }
    )
    try await reopened.open()
    #expect(await reopened.journalIssue != nil)
    #expect(try await reopened.listManagedPackages().isEmpty)
    #expect(try Data(contentsOf: journal).last == 0x0A)
}

@Test func packageStoreImportTicketsExpireWithTheStoreProcess() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let packages = temporary.appendingPathComponent("Packages", isDirectory: true)
    let originalStore = PackageStore(packagesDirectory: packages, inspector: { _ in facts() })
    try await originalStore.open()
    let preview = try await originalStore.importPackage(files: [input])

    let restartedStore = PackageStore(packagesDirectory: packages, inspector: { _ in facts() })
    try await restartedStore.open()
    do {
        _ = try await restartedStore.installImported(ticket: preview.ticket)
        Issue.record("An import ticket must not survive the store process.")
    } catch let failure as PackageStoreFailure {
        #expect(failure == .importTicketNotFound)
    }
    #expect(
        !FileManager.default.fileExists(
            atPath:
                packages
                .appendingPathComponent("io.apkrun.fixture.hellotext/incoming/\(preview.ticket.uuidString)")
                .path
        )
    )
}

private func facts() -> APKFacts {
    APKFacts(
        packageID: PackageID(rawValue: "io.apkrun.fixture.hellotext")!,
        versionCode: 7,
        versionName: "1.0",
        splitName: nil,
        displayName: "HelloText",
        minSDK: 24,
        targetSDK: 35,
        nativeABIs: ["arm64-v8a"]
    )
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PackageStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
