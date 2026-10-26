import APKStoreCore
import Darwin
import Foundation
import Testing

private enum CrashProbeEnvironment {
    static let mode = "APKRUN_PACKAGE_STORE_CRASH_PROBE"
    static let root = "APKRUN_PACKAGE_STORE_CRASH_ROOT"
    static let keepData = "APKRUN_PACKAGE_STORE_CRASH_KEEP_DATA"
    static let lostUninstallReply = "APKRUN_PACKAGE_STORE_CRASH_AFTER_GUEST_UNINSTALL"
}

private enum CrashProbeFailure: Error {
    case missingTestBundlePath
}

private let fixturePackageID = PackageID(rawValue: "io.apkrun.fixture.crashprobe")!
private let fixtureVersionCode: VersionCode = 7
private let storeDirectoryName = "Packages"

private struct GuestPackageSnapshot: Codable {
    var packageID: String
    var versionCode: VersionCode
    var lastUpdateTime: Date
}

private enum UninstallRecoveryExpectation {
    case stillInstalled
    case ambiguous
    case uninstalledKeepingData
    case uninstalled
}

private actor FileBackedStoreAgent: StoreAgentChannel {
    nonisolated let capabilities: StoreCapabilities = [.install, .metadata, .downgradeReinstall]

    private let snapshotURL: URL
    private let fileManager = FileManager.default

    init(snapshotURL: URL) {
        self.snapshotURL = snapshotURL
    }

    func install(_ request: StoreInstallRequest, files: [URL]) async throws -> StorePackageInfo {
        guard !files.isEmpty, files.allSatisfy({ fileManager.fileExists(atPath: $0.path) }) else {
            throw PackageStoreFailure.invalidImport
        }
        let snapshot = GuestPackageSnapshot(
            packageID: request.packageID.rawValue,
            versionCode: request.versionCode,
            lastUpdateTime: Date()
        )
        try write(snapshot)
        return packageInfo(snapshot)
    }

    func uninstall(_ package: PackageID, keepData: Bool) async throws {
        if let snapshot = try read(), snapshot.packageID == package.rawValue {
            try fileManager.removeItem(at: snapshotURL)
        }
        if ProcessInfo.processInfo.environment[CrashProbeEnvironment.lostUninstallReply] == "1" {
            // Model the guest committing the uninstall immediately before apkrund loses the reply.
            Darwin._exit(87)
        }
    }

    func packageInfo(_ package: PackageID) async throws -> StorePackageInfo? {
        guard let snapshot = try read(), snapshot.packageID == package.rawValue else { return nil }
        return packageInfo(snapshot)
    }

    func listPackages(_ filter: StorePackageFilter) async throws -> [StorePackageSummary] {
        guard let snapshot = try read(),
            let packageID = PackageID(rawValue: snapshot.packageID)
        else {
            return []
        }
        return [
            StorePackageSummary(
                packageID: packageID,
                displayName: "Crash Probe",
                versionCode: snapshot.versionCode,
                launchable: true,
                userInstalled: true
            )
        ]
    }

    private func read() throws -> GuestPackageSnapshot? {
        guard fileManager.fileExists(atPath: snapshotURL.path) else { return nil }
        return try JSONDecoder().decode(GuestPackageSnapshot.self, from: Data(contentsOf: snapshotURL))
    }

    private func write(_ snapshot: GuestPackageSnapshot) throws {
        try fileManager.createDirectory(
            at: snapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(snapshot).write(to: snapshotURL, options: .atomic)
    }

    private func packageInfo(_ snapshot: GuestPackageSnapshot) -> StorePackageInfo {
        StorePackageInfo(
            packageID: PackageID(rawValue: snapshot.packageID)!,
            displayName: "Crash Probe",
            versionCode: snapshot.versionCode,
            versionName: "1.0",
            enabled: true,
            launchableComponent: "\(snapshot.packageID)/.MainActivity",
            installerPackage: PackageID(rawValue: "io.apkrun.store"),
            firstInstallTime: snapshot.lastUpdateTime,
            lastUpdateTime: snapshot.lastUpdateTime,
            targetSDK: 35,
            minSDK: 24
        )
    }
}

private struct FileBackedStoreRuntime: StoreRuntimeAccess {
    let channel: FileBackedStoreAgent
    let generation = UUID(uuidString: "c4f05b2e-b583-4d4d-b92f-925285b6018c")!

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

@Test func packageStoreProcessCrashRecoveryCoversEveryFirstInstallJournalStep() async throws {
    guard ProcessInfo.processInfo.environment[CrashProbeEnvironment.mode] == nil else { return }

    let steps = [
        "begin",
        "guestCommitRequested",
        "guestInstalled",
        "filesPromoted",
        "metadataWritten",
        "commit",
    ]
    for (index, step) in steps.enumerated() {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let exit = try runCrashProbe(root: root, mode: "firstInstall", fault: "firstInstall:\(step)")
        #expect(exit == 86, "firstInstall:\(step) must terminate the child through _exit(86), got \(exit).")

        let channel = makeChannel(root: root)
        let store = makeStore(root: root, runtime: FileBackedStoreRuntime(channel: channel))
        try await store.open()
        try await store.recoverPendingTransactions()

        let shouldBeInstalled = index >= steps.firstIndex(of: "guestInstalled")!
        let record = try await store.listManagedPackages().first
        let guestPackage = try await channel.packageInfo(fixturePackageID)
        let currentAPK = currentAPKURL(root: root)
        #expect((record != nil) == shouldBeInstalled, "unexpected host record after firstInstall:\(step)")
        #expect((guestPackage != nil) == shouldBeInstalled, "unexpected guest package after firstInstall:\(step)")
        #expect(FileManager.default.fileExists(atPath: currentAPK.path) == shouldBeInstalled)
        if let record {
            #expect(record.versionCode == fixtureVersionCode)
        }
    }
}

@Test func packageStoreProcessCrashRecoveryCoversEveryUninstallJournalStep() async throws {
    guard ProcessInfo.processInfo.environment[CrashProbeEnvironment.mode] == nil else { return }

    let cases: [(step: String, keepData: Bool)] = [
        ("begin", false),
        ("guestUninstallRequested", false),
        ("guestUninstallReplyReceived", false),
        ("guestUninstalled", false),
        ("filesRemoved", false),
        ("recordRemoved", false),
        ("commit", false),
        ("begin", true),
        ("guestUninstallRequested", true),
        ("guestUninstallReplyReceived", true),
        ("guestUninstalled", true),
        ("filesRemoved", true),
        ("metadataWritten", true),
        ("commit", true),
        ("trashCleanup", false),
        ("trashCleanup", true),
    ]

    for crashCase in cases {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try await installFixture(at: root)
        let exit = try runCrashProbe(
            root: root,
            mode: "uninstall",
            fault: "uninstall:\(crashCase.step)",
            keepData: crashCase.keepData
        )
        #expect(
            exit == 86,
            "uninstall:\(crashCase.step), keepData=\(crashCase.keepData) must terminate the child through _exit(86), got \(exit)."
        )

        let channel = makeChannel(root: root)
        let store = makeStore(root: root, runtime: FileBackedStoreRuntime(channel: channel))
        try await store.open()
        try await store.recoverPendingTransactions()
        let expectation: UninstallRecoveryExpectation
        if crashCase.step == "begin" || crashCase.step == "guestUninstallRequested" {
            expectation = .stillInstalled
        } else if crashCase.step == "guestUninstallReplyReceived" {
            expectation = .ambiguous
        } else {
            expectation = crashCase.keepData ? .uninstalledKeepingData : .uninstalled
        }
        try await expectUninstallRecovery(
            root: root,
            store: store,
            channel: channel,
            expectation: expectation,
            keepData: crashCase.keepData
        )
        if crashCase.step == "guestUninstallReplyReceived" {
            let pendingTransaction = try #require(uninstallTransaction(in: journalEntries(root: root)))
            #expect(pendingTransaction.hasTerminalRecord == false)
            #expect(pendingTransaction.lastStep == "guestUninstallRequested")
        }
    }
}

@Test func packageStoreProcessCrashAfterGuestUninstallReplyKeepsAmbiguousTransactionPending() async throws {
    guard ProcessInfo.processInfo.environment[CrashProbeEnvironment.mode] == nil else { return }

    for keepData in [false, true] {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await installFixture(at: root)

        let exit = try runCrashProbe(
            root: root,
            mode: "lostUninstallReply",
            fault: nil,
            keepData: keepData
        )
        #expect(exit == 87, "the fake guest must commit then terminate before replying, got \(exit).")

        let channel = makeChannel(root: root)
        let store = makeStore(root: root, runtime: FileBackedStoreRuntime(channel: channel))
        try await store.open()
        try await store.recoverPendingTransactions()
        try await expectUninstallRecovery(
            root: root,
            store: store,
            channel: channel,
            expectation: .ambiguous,
            keepData: keepData
        )

        let pendingTransaction = try #require(uninstallTransaction(in: journalEntries(root: root)))
        #expect(pendingTransaction.hasTerminalRecord == false)
        #expect(pendingTransaction.lastStep == "guestUninstallRequested")
    }
}

@Test func packageStoreCrashProbeWorker() async throws {
    guard let mode = ProcessInfo.processInfo.environment[CrashProbeEnvironment.mode] else { return }
    guard let rootPath = ProcessInfo.processInfo.environment[CrashProbeEnvironment.root] else {
        Issue.record("Crash probe child is missing its isolated root.")
        return
    }

    let root = URL(fileURLWithPath: rootPath, isDirectory: true)
    guard root.path.hasPrefix(URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path) else {
        Issue.record("Crash probe root must be inside the system temporary directory.")
        return
    }

    let channel = makeChannel(root: root)
    let store = makeStore(
        root: root,
        runtime: FileBackedStoreRuntime(channel: channel),
        useEnvironmentFaults: true
    )
    try await store.open()

    switch mode {
    case "firstInstall":
        let fixture = fixtureAPKURL(root: root)
        try Data("APKRun PackageStore crash fixture".utf8).write(to: fixture)
        let preview = try await store.importPackage(files: [fixture])
        _ = try await store.installImported(ticket: preview.ticket)
    case "uninstall", "lostUninstallReply":
        let keepData = ProcessInfo.processInfo.environment[CrashProbeEnvironment.keepData] == "1"
        try await store.uninstall(packageID: fixturePackageID, keepData: keepData)
    default:
        Issue.record("Unknown crash probe mode: \(mode)")
    }
}

@Test func packageStoreCrashProbeArgumentsInsertWorkerFilterWithoutOuterFilter() throws {
    let commandLineArguments = [
        "test-runner",
        "--test-bundle-path",
        "/tmp/APKStoreCoreSystemTests.xctest",
        "--test-configuration",
        "debug",
    ]
    #expect(
        try crashProbeArguments(from: commandLineArguments)
            == [
                "--test-bundle-path",
                "/tmp/APKStoreCoreSystemTests.xctest",
                "--filter",
                "packageStoreCrashProbeWorker",
                "--test-configuration",
                "debug",
            ]
    )
}

@Test func packageStoreCrashProbeArgumentsReplaceOuterFilter() throws {
    let commandLineArguments = [
        "test-runner",
        "--test-bundle-path",
        "/tmp/APKStoreCoreSystemTests.xctest",
        "--filter",
        "packageStoreProcessCrashRecoveryCoversEveryUninstallJournalStep",
    ]
    #expect(
        try crashProbeArguments(from: commandLineArguments)
            == [
                "--test-bundle-path",
                "/tmp/APKStoreCoreSystemTests.xctest",
                "--filter",
                "packageStoreCrashProbeWorker",
            ]
    )
}

private func makeStore(
    root: URL,
    runtime: (any StoreRuntimeAccess)?,
    useEnvironmentFaults: Bool = false
) -> PackageStore {
    let noFaults: PackageStore.FaultInjector = { _, _ in }
    let faultInjector = useEnvironmentFaults ? nil : noFaults
    return PackageStore(
        packagesDirectory: packagesURL(root: root),
        runtimeAccess: runtime,
        inspector: { _ in fixtureFacts() },
        faultInjector: faultInjector
    )
}

private func makeChannel(root: URL) -> FileBackedStoreAgent {
    FileBackedStoreAgent(
        snapshotURL: root.appendingPathComponent("Guest/package.json", isDirectory: false)
    )
}

private func fixtureFacts() -> APKFacts {
    APKFacts(
        packageID: fixturePackageID,
        versionCode: fixtureVersionCode,
        versionName: "1.0",
        splitName: nil,
        displayName: "Crash Probe",
        minSDK: 24,
        targetSDK: 35,
        nativeABIs: ["arm64-v8a"]
    )
}

private func packagesURL(root: URL) -> URL {
    root.appendingPathComponent(storeDirectoryName, isDirectory: true)
}

private func fixtureAPKURL(root: URL) -> URL {
    root.appendingPathComponent("fixture.apk")
}

private func currentAPKURL(root: URL) -> URL {
    packagesURL(root: root)
        .appendingPathComponent(fixturePackageID.rawValue, isDirectory: true)
        .appendingPathComponent("current", isDirectory: true)
        .appendingPathComponent("base.apk")
}

private func makeTemporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "APKStoreCoreSystemTests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func installFixture(at root: URL) async throws {
    let channel = makeChannel(root: root)
    let store = makeStore(root: root, runtime: FileBackedStoreRuntime(channel: channel))
    try await store.open()
    let fixture = fixtureAPKURL(root: root)
    try Data("APKRun PackageStore crash fixture".utf8).write(to: fixture)
    let preview = try await store.importPackage(files: [fixture])
    _ = try await store.installImported(ticket: preview.ticket)
}

private func runCrashProbe(
    root: URL,
    mode: String,
    fault: String?,
    keepData: Bool = false
) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = try crashProbeArguments(from: CommandLine.arguments)
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: "APKRUN_STORE_FAULT")
    environment.removeValue(forKey: CrashProbeEnvironment.mode)
    environment.removeValue(forKey: CrashProbeEnvironment.root)
    environment.removeValue(forKey: CrashProbeEnvironment.keepData)
    environment.removeValue(forKey: CrashProbeEnvironment.lostUninstallReply)
    environment[CrashProbeEnvironment.mode] = mode
    environment[CrashProbeEnvironment.root] = root.path
    environment[CrashProbeEnvironment.keepData] = keepData ? "1" : "0"
    if let fault {
        environment["APKRUN_STORE_FAULT"] = fault
    }
    if mode == "lostUninstallReply" {
        environment[CrashProbeEnvironment.lostUninstallReply] = "1"
    }
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

private func crashProbeArguments(from commandLineArguments: [String]) throws -> [String] {
    guard
        let bundlePathArgument = commandLineArguments.firstIndex(of: "--test-bundle-path"),
        commandLineArguments.indices.contains(bundlePathArgument + 1)
    else {
        throw CrashProbeFailure.missingTestBundlePath
    }
    var arguments = Array(commandLineArguments.dropFirst())
    if let filterArgument = arguments.firstIndex(of: "--filter"),
        arguments.indices.contains(filterArgument + 1)
    {
        arguments[filterArgument + 1] = "packageStoreCrashProbeWorker"
    } else {
        arguments.insert(contentsOf: ["--filter", "packageStoreCrashProbeWorker"], at: bundlePathArgument + 1)
    }
    return arguments
}

private func expectUninstallRecovery(
    root: URL,
    store: PackageStore,
    channel: FileBackedStoreAgent,
    expectation: UninstallRecoveryExpectation,
    keepData: Bool
) async throws {
    let records = try await store.listManagedPackages()
    let guestPackage = try await channel.packageInfo(fixturePackageID)
    let currentAPKExists = FileManager.default.fileExists(atPath: currentAPKURL(root: root).path)

    switch expectation {
    case .stillInstalled:
        #expect(guestPackage != nil)
        #expect(records.count == 1)
        #expect(records.first?.state == .installed)
        #expect(currentAPKExists)
    case .ambiguous:
        #expect(guestPackage == nil, "An absent guest package after an unrecorded uninstall reply stays ambiguous.")
        #expect(records.count == 1)
        #expect(records.first?.state == .installed)
        #expect(currentAPKExists)
    case .uninstalledKeepingData:
        #expect(guestPackage == nil)
        #expect(keepData)
        #expect(records.count == 1)
        #expect(records.first?.state == .uninstalledKeepingData)
        #expect(!currentAPKExists)
    case .uninstalled:
        #expect(guestPackage == nil)
        #expect(!keepData)
        #expect(records.isEmpty)
        #expect(!currentAPKExists)
    }
}

private struct UninstallJournalState {
    var lastStep: String?
    var hasTerminalRecord: Bool
}

private func journalEntries(root: URL) throws -> [[String: Any]] {
    let journalURL = packagesURL(root: root).appendingPathComponent("journal.jsonl")
    let text = try String(contentsOf: journalURL, encoding: .utf8)
    return try text.split(whereSeparator: \.isNewline).map { line in
        try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
}

private func uninstallTransaction(in entries: [[String: Any]]) -> UninstallJournalState? {
    guard
        let begin = entries.first(where: {
            $0["kind"] as? String == "uninstall" && $0["op"] as? String == "begin"
        }), let transactionID = begin["txn"] as? String
    else {
        return nil
    }

    let transactionEntries = entries.filter { $0["txn"] as? String == transactionID }
    let lastStep = transactionEntries.last(where: { $0["op"] as? String == "step" })?["step"] as? String
    let hasTerminalRecord = transactionEntries.contains {
        ["commit", "abort"].contains($0["op"] as? String ?? "")
    }
    return UninstallJournalState(lastStep: lastStep, hasTerminalRecord: hasTerminalRecord)
}
