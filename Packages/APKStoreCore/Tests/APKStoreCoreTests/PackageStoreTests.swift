import Foundation
import Testing

@testable import APKStoreCore

private struct InjectedStoreCrash: Error {}
private enum SimulatedGuestFailure: Error {
    case installFailedAfterCommit
    case installFailedBeforeCommit
    case uninstallFailed
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
    private var uninstallThrowsAfterRemoval = false
    private var pauseNextUninstall = false
    private var uninstallStarted = false
    private var uninstallStartWaiter: CheckedContinuation<Void, Never>?
    private var uninstallReleaseWaiter: CheckedContinuation<Void, Never>?

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

    func configureUninstallFailureAfterRemoval() {
        uninstallThrowsAfterRemoval = true
    }

    func pauseUninstall() {
        pauseNextUninstall = true
        uninstallStarted = false
    }

    func waitForUninstallStart() async {
        guard !uninstallStarted else { return }
        await withCheckedContinuation { continuation in
            uninstallStartWaiter = continuation
        }
    }

    func continueUninstall() {
        uninstallReleaseWaiter?.resume()
        uninstallReleaseWaiter = nil
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
        if pauseNextUninstall {
            pauseNextUninstall = false
            uninstallStarted = true
            uninstallStartWaiter?.resume()
            uninstallStartWaiter = nil
            await withCheckedContinuation { continuation in
                uninstallReleaseWaiter = continuation
            }
        }
        packages[package] = nil
        if uninstallThrowsAfterRemoval {
            throw SimulatedGuestFailure.uninstallFailed
        }
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

private actor CompletionFlag {
    private(set) var isComplete = false

    func complete() {
        isComplete = true
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

@Test func packageStoresOpenedBeforeAnotherWriteKeepJournalSequencesMonotonic() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let channel = FakeStoreChannel()
    let runtime = FakeStoreRuntime(channel: channel)
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let packagesDirectory = temporary.appendingPathComponent("Packages", isDirectory: true)
    let firstStore = PackageStore(
        packagesDirectory: packagesDirectory,
        runtimeAccess: runtime,
        inspector: { _ in facts() }
    )
    try await firstStore.open()
    let preview = try await firstStore.importPackage(files: [input])
    _ = try await firstStore.installImported(ticket: preview.ticket)

    let secondStore = PackageStore(
        packagesDirectory: packagesDirectory,
        inspector: { _ in facts() }
    )
    try await secondStore.open()
    let packageID = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    try await firstStore.forget(packageID: packageID)
    await #expect(throws: PackageStoreFailure.packageNotFound) {
        try await secondStore.forget(packageID: packageID)
    }

    let reopened = PackageStore(
        packagesDirectory: packagesDirectory,
        inspector: { _ in facts() }
    )
    try await reopened.open()
    #expect(await reopened.journalIssue == nil)
    #expect(try await reopened.listManagedPackages().isEmpty)

    let journalURL = packagesDirectory.appendingPathComponent("journal.jsonl")
    let journalText = try String(contentsOf: journalURL, encoding: .utf8)
    let sequences =
        try journalText
        .split(separator: "\n")
        .map { line -> Int in
            let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return try #require(object["seq"] as? Int)
        }
    #expect(sequences == Array(1...sequences.count))
}

@Test func packageStoreDoesNotClaimDataOutcomeWhenUninstallFailedAndPackageIsAbsent() async throws {
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
    let installed = try await store.installImported(ticket: preview.ticket)
    await channel.configureUninstallFailureAfterRemoval()

    await #expect(
        throws: PackageStoreFailure.uninstallDataUnverified(installed.packageId)
    ) {
        try await store.uninstall(packageID: installed.packageId, keepData: true)
    }

    let records = try await store.listManagedPackages()
    #expect(records.first?.state == .installed)
    #expect(await channel.lastKeepData == true)
}

@Test func packageStoreDoesNotClaimDataWasDeletedWhenUninstallFailedAndPackageIsAbsent() async throws {
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
    let installed = try await store.installImported(ticket: preview.ticket)
    await channel.configureUninstallFailureAfterRemoval()

    await #expect(
        throws: PackageStoreFailure.uninstallDataUnverified(installed.packageId)
    ) {
        try await store.uninstall(packageID: installed.packageId, keepData: false)
    }

    let records = try await store.listManagedPackages()
    #expect(records.first?.state == .installed)
    #expect(await channel.lastKeepData == false)
}

@Test func packageStoreLeavesAmbiguousUninstallInspectableAndForgetResolvesItWithoutClaimingDataOutcome() async throws {
    for keepData in [true, false] {
        for forgetCrashStep in ["begin", "uninstallOutcomesResolved", "filesRemoved", "recordRemoved"] {
            let temporary = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: temporary) }
            let channel = FakeStoreChannel()
            let runtime = FakeStoreRuntime(channel: channel)
            let input = temporary.appendingPathComponent("HelloText.apk")
            try Data("base apk bytes".utf8).write(to: input)
            let packages = temporary.appendingPathComponent("Packages", isDirectory: true)
            let forgettingStore = PackageStore(
                packagesDirectory: packages,
                inspector: { _ in facts() },
                faultInjector: { kind, step in
                    if kind == "forget", step == forgetCrashStep {
                        throw InjectedStoreCrash()
                    }
                }
            )
            try await forgettingStore.open()
            let crashingStore = PackageStore(
                packagesDirectory: packages,
                runtimeAccess: runtime,
                inspector: { _ in facts() },
                faultInjector: { kind, step in
                    if kind == "uninstall", step == "guestUninstallRequested" {
                        throw InjectedStoreCrash()
                    }
                }
            )
            try await crashingStore.open()
            let preview = try await crashingStore.importPackage(files: [input])
            let installed = try await crashingStore.installImported(ticket: preview.ticket)
            do {
                try await crashingStore.uninstall(packageID: installed.packageId, keepData: keepData)
                Issue.record("Expected an interruption after the guest uninstall request.")
            } catch is InjectedStoreCrash {
                // The guest removed the package, but the host did not record its result.
            }

            let recoveredStore = PackageStore(
                packagesDirectory: packages,
                runtimeAccess: runtime,
                inspector: { _ in facts() }
            )
            try await recoveredStore.open()
            try await recoveredStore.recoverPendingTransactions()

            let record = try #require(try await recoveredStore.listManagedPackages().first)
            #expect(record.state == .installed)
            #expect(try await channel.listPackages(.all).allSatisfy { $0.packageID != installed.packageId })
            #expect(
                FileManager.default.fileExists(
                    atPath: packages.appendingPathComponent("\(installed.packageId.rawValue)/current/base.apk").path
                )
            )
            let journal = try String(contentsOf: packages.appendingPathComponent("journal.jsonl"), encoding: .utf8)
            let entries =
                try journal
                .split(separator: "\n")
                .map { line -> [String: Any] in
                    try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                }
            let uninstallBegin = try #require(
                entries.first { $0["kind"] as? String == "uninstall" && $0["op"] as? String == "begin" }
            )
            let uninstallTransaction = try #require(uninstallBegin["txn"] as? String)
            #expect(
                !entries.contains {
                    $0["txn"] as? String == uninstallTransaction
                        && ["commit", "abort"].contains($0["op"] as? String ?? "")
                }
            )
            #expect(
                !entries.contains {
                    $0["txn"] as? String == uninstallTransaction && $0["step"] as? String == "guestUninstalled"
                }
            )

            do {
                try await forgettingStore.forget(packageID: installed.packageId)
                Issue.record("Expected an interruption during the host-side forget.")
            } catch is InjectedStoreCrash {
                // The persisted forget intent must finish on the next open.
            }

            let finalStore = PackageStore(
                packagesDirectory: packages,
                inspector: { _ in facts() }
            )
            try await finalStore.open()
            #expect(try await finalStore.listManagedPackages().isEmpty)
            #expect(
                !FileManager.default.fileExists(
                    atPath: packages.appendingPathComponent("\(installed.packageId.rawValue)/current/base.apk").path
                )
            )

            let resolvedJournal = try String(
                contentsOf: packages.appendingPathComponent("journal.jsonl"),
                encoding: .utf8
            )
            let resolvedEntries =
                try resolvedJournal
                .split(separator: "\n")
                .map { line -> [String: Any] in
                    try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                }
            let resolvedUninstall = try #require(
                resolvedEntries.first {
                    $0["txn"] as? String == uninstallTransaction && $0["op"] as? String == "abort"
                }
            )
            #expect(resolvedUninstall["reason"] as? String == "userChoseForgetWithUnverifiedUninstallOutcome")
            let resolvedForgetBegin = try #require(
                resolvedEntries.first { $0["kind"] as? String == "forget" && $0["op"] as? String == "begin" }
            )
            #expect(resolvedForgetBegin["reason"] as? String == "resolvesUnverifiedUninstall")
            let forgetTransaction = try #require(resolvedForgetBegin["txn"] as? String)
            #expect(
                resolvedEntries.contains {
                    $0["txn"] as? String == forgetTransaction && $0["op"] as? String == "commit"
                }
            )
        }
    }
}

@Test func packageStoreSerializesForgetAgainstAnUninstallInAnotherStore() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let channel = FakeStoreChannel()
    let runtime = FakeStoreRuntime(channel: channel)
    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    let packagesDirectory = temporary.appendingPathComponent("Packages", isDirectory: true)
    let firstStore = PackageStore(
        packagesDirectory: packagesDirectory,
        runtimeAccess: runtime,
        inspector: { _ in facts() }
    )
    try await firstStore.open()
    let preview = try await firstStore.importPackage(files: [input])
    let installed = try await firstStore.installImported(ticket: preview.ticket)

    let secondStore = PackageStore(
        packagesDirectory: packagesDirectory,
        runtimeAccess: runtime,
        inspector: { _ in facts() }
    )
    try await secondStore.open()
    await channel.pauseUninstall()
    let uninstallTask = Task {
        try await firstStore.uninstall(packageID: installed.packageId, keepData: true)
    }
    await channel.waitForUninstallStart()

    let completion = CompletionFlag()
    let forgetTask = Task {
        try await secondStore.forget(packageID: installed.packageId)
        await completion.complete()
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(!(await completion.isComplete))
    await channel.continueUninstall()
    try await uninstallTask.value
    try await forgetTask.value

    #expect(await completion.isComplete)
    #expect(try await firstStore.listManagedPackages().isEmpty)
    #expect(try await secondStore.listManagedPackages().isEmpty)
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
    let preview = try await store.importPackage(files: [input], origin: .cli)
    await channel.configureInstallFailureAfterCommit(queryUnavailable: true)

    do {
        _ = try await store.installImported(ticket: preview.ticket)
        Issue.record("Expected an install error while PackageManager was unavailable.")
    } catch is SimulatedGuestFailure {
        // The first request may have committed even though both calls failed.
    }

    let incoming =
        packages
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
    #expect(record.source.origin == .cli)
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

@Test func packageStoreKeepsMiddleJournalCorruptionReadOnly() async throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let packages = temporary.appendingPathComponent("Packages", isDirectory: true)
    try FileManager.default.createDirectory(at: packages, withIntermediateDirectories: true)
    let journal = packages.appendingPathComponent("journal.jsonl")
    let corruptJournal = Data("{invalid}\n{\"seq\":2}\n".utf8)
    try corruptJournal.write(to: journal)

    let store = PackageStore(packagesDirectory: packages, inspector: { _ in facts() })
    try await store.open()

    #expect(await store.journalIssue == "invalid journal line")
    #expect(try await store.listManagedPackages().isEmpty)
    #expect(try Data(contentsOf: journal) == corruptJournal)

    let input = temporary.appendingPathComponent("HelloText.apk")
    try Data("base apk bytes".utf8).write(to: input)
    do {
        _ = try await store.importPackage(files: [input])
        Issue.record("A store with a corrupt journal must reject writes.")
    } catch let failure as PackageStoreFailure {
        #expect(failure == .journalUnreadable)
    }
    #expect(try Data(contentsOf: journal) == corruptJournal)
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
