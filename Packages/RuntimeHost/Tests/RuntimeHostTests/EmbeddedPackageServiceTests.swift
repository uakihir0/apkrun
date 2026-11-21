import APKStoreCore
import DiagnosticsCore
import Foundation
import RuntimeAPI
import Testing
import WrapperCore

@testable import RuntimeHost

@Test func downgradeFailurePreservesInstalledAndCandidateVersions() {
    let error = EmbeddedPackageService.wireError(
        for: PackageStoreFailure.downgradeRefused(installed: 18, candidate: 12)
    )

    #expect(error.code == "store.downgradeRefused")
    #expect(error.message.contains("12"))
    #expect(error.message.contains("18"))
    #expect(error.remediation?.contains("newer APK") == true)
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

    let service = EmbeddedPackageService(
        paths: paths,
        importVerifier: PackageStore.legacyImportVerifier
    )
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
    let store = PackageStore(
        packagesDirectory: paths.packagesDirectory,
        importVerifier: PackageStore.legacyImportVerifier

    )
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

    let service = EmbeddedPackageService(
        paths: paths,
        importVerifier: PackageStore.legacyImportVerifier

    )
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

    let service = EmbeddedPackageService(
        paths: paths,
        importVerifier: PackageStore.legacyImportVerifier

    )
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

    let store = PackageStore(
        packagesDirectory: paths.packagesDirectory,
        importVerifier: PackageStore.legacyImportVerifier

    )
    try await store.open()
    _ = try await store.saveLastKnownAndroidInventory([])

    let service = EmbeddedPackageService(
        paths: paths,
        importVerifier: PackageStore.legacyImportVerifier

    )
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
    let service = EmbeddedPackageService(
        sessionService: sessionService,
        importVerifier: PackageStore.legacyImportVerifier

    )

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
        sessionService: sessionService,
        importVerifier: PackageStore.legacyImportVerifier

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
        },
        importVerifier: PackageStore.legacyImportVerifier

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
func embeddedPackageServiceModeOnlyReinstallKeepsAuthorityAndProvider() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-package-service-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
    let package = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    final class InspectVersion: @unchecked Sendable { var code: VersionCode = 12 }
    let inspectVersion = InspectVersion()
    let service = EmbeddedPackageService(
        paths: paths,
        inspector: { _ in
            APKFacts(
                packageID: package,
                versionCode: inspectVersion.code,
                versionName: "1.2",
                splitName: nil,
                displayName: "Hello Text",
                minSDK: 23,
                targetSDK: 35,
                nativeABIs: []
            )
        },
        importVerifier: PackageStore.legacyImportVerifier,
        runtimeAccess: FakeInstalledRuntimeAccess()
    )
    try await service.open()

    func install(_ options: RuntimeInstallOptions) async throws {
        let source = root.appendingPathComponent("hello-\(inspectVersion.code).apk")
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
        _ = try await service.installImportedWithChange(
            RuntimeInstallImportedRequest(ticket: preview.ticket, options: options),
            beforeStoreMutation: {})
    }

    try await install(
        RuntimeInstallOptions(
            authority: .apkrun,
            provider: try #require(ProviderSpec(spec: "direct:https://updates.example.com/app.json")),
            updateMode: .automatic))
    var record = try #require(
        await service.store.listManagedPackages().first { $0.packageId == package })
    #expect(record.updateAuthority == .apkrun)
    #expect(record.updateProvider != nil)

    inspectVersion.code = 13
    try await install(
        RuntimeInstallOptions(authority: .manual, updateMode: .notifyOnly))
    record = try #require(
        await service.store.listManagedPackages().first { $0.packageId == package })
    #expect(record.updateAuthority == .apkrun)
    #expect(record.updateProvider != nil)
    let settings = try #require(await service.store.packageSettings(for: package))
    #expect(settings.updateMode == "notifyOnly")
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
        },
        importVerifier: PackageStore.legacyImportVerifier

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
        },
        importVerifier: PackageStore.legacyImportVerifier

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
    let service = EmbeddedPackageService(
        paths: paths,
        importVerifier: PackageStore.legacyImportVerifier

    )
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
        },
        importVerifier: PackageStore.legacyImportVerifier

    )
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
        hostFreeSpace: { _ in 0 },
        importVerifier: PackageStore.legacyImportVerifier

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

/// A Store Agent stand-in that accepts every install and remembers the last
/// installed package so reinstall flows can query it back.
private struct FakeInstalledRuntimeAccess: StoreRuntimeAccess {
    private let channel = FakeInstalledStoreAgentChannel()

    func withStoreAgent<T: Sendable>(
        _ operation: UUID,
        _ body: @Sendable (any StoreAgentChannel) async throws -> T
    ) async throws -> T {
        try await body(channel)
    }

    func userdataGeneration() async -> UUID? { nil }
}

private final class FakeInstalledStoreAgentChannel: StoreAgentChannel, @unchecked Sendable {
    let capabilities: StoreCapabilities = [.install, .metadata]
    private var installed: StorePackageInfo?

    func install(_ request: StoreInstallRequest, files: [URL]) async throws -> StorePackageInfo {
        let info = StorePackageInfo(
            packageID: request.packageID,
            displayName: "Hello Text",
            versionCode: request.versionCode,
            versionName: "1.2",
            enabled: true,
            targetSDK: 35,
            minSDK: 23,
            signingDigests: request.signerDigests
        )
        installed = info
        return info
    }

    func uninstall(_ package: PackageID, keepData: Bool) async throws {
        installed = nil
    }

    func packageInfo(_ package: PackageID) async throws -> StorePackageInfo? {
        installed?.packageID == package ? installed : nil
    }

    func listPackages(_ filter: StorePackageFilter) async throws -> [StorePackageSummary] { [] }
}

// MARK: - importBootstrap (wrapper-json.md §3.4)

private let bootstrapTestSigner = "sha256:" + String(repeating: "ab", count: 32)

private func bootstrapTestSignerDigest() throws -> SHA256Digest {
    try #require(SHA256Digest(hex: String(repeating: "ab", count: 32)))
}

private func bootstrapEntry(packageID: PackageID, kind: WrapperKind = .portable) -> WrapperRegistryEntry {
    WrapperRegistryEntry(
        bundleId: "io.apkrun.android.\(packageID.rawValue.replacingOccurrences(of: "-", with: "_"))",
        packageId: packageID.rawValue,
        kind: kind,
        state: .active,
        path: "/Applications/Hello.app",
        cdhash: String(repeating: "0", count: 40),
        launcherVersion: "1",
        launcherAPI: "1.26",
        fileName: "Hello.app",
        displayName: "Hello Text",
        createdAt: Date()
    )
}

private func bootstrapWrapperDocument(
    packageID: PackageID,
    updates: WrapperDocument.Updates? = nil,
    window: WrapperDocument.Window? = nil,
    integration: WrapperDocument.Integration? = nil
) -> WrapperDocument {
    WrapperDocument(
        kind: .portable,
        application: .init(packageId: packageID.rawValue, displayName: "Hello Text"),
        runtime: .init(minimumVersion: "1", launcherAPI: "1.26"),
        window: window,
        updates: updates,
        integration: integration
    )
}

private func bootstrapDocumentJSON(
    packageID: PackageID,
    files: [(name: String, bytes: Data)],
    signers: [String]? = nil,
    setDigest: String? = nil,
    versionCode: Int64 = 12,
    versionName: String? = "1.2"
) throws -> Data {
    let entries = files.map {
        BootstrapFileEntry(
            name: $0.name,
            sha256: SHA256Digest(data: $0.bytes).rawValue,
            size: Int64($0.bytes.count)
        )
    }
    let document = BootstrapDocument(
        packageId: packageID.rawValue,
        versionCode: versionCode,
        versionName: versionName,
        setDigest: setDigest ?? BootstrapSetDigest.compute(files: entries),
        signers: signers ?? [bootstrapTestSigner],
        files: entries
    )
    return try BootstrapDocumentCodec.encode(document)
}

private func bootstrapService(
    paths: APKRunPaths,
    packageID: PackageID
) -> EmbeddedPackageService {
    let signer = try! bootstrapTestSignerDigest()
    return EmbeddedPackageService(
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
        sessionService: PackageMutationTestSessionService(),
        importVerifier: { staged, _, inspect in
            var facts: [APKFacts] = []
            for url in staged { facts.append(try await inspect(url)) }
            return PackageStore.VerifiedImport(
                files: staged,
                facts: facts,
                signerDigests: [signer],
                lineage: [signer],
                warnings: [],
                excludedSplits: []
            )
        },
        runtimeAccess: FakeInstalledRuntimeAccess()
    )
}

private func bootstrapHandles(
    _ files: [(name: String, bytes: Data)],
    in root: URL
) throws -> [FileHandle] {
    try files.map { file in
        let url = root.appendingPathComponent(file.name)
        try file.bytes.write(to: url)
        return try FileHandle(forReadingFrom: url)
    }
}

private func bootstrapRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-bootstrap-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test(.timeLimit(.minutes(1)))
func importBootstrapInstallsAndMarksTheWrapperBootstrapSource() async throws {
    let root = try bootstrapRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
    let packageID = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let service = bootstrapService(paths: paths, packageID: packageID)
    try await service.open()

    let apk = Data("apk-test-bytes".utf8)
    let json = try bootstrapDocumentJSON(packageID: packageID, files: [("base.apk", apk)])
    let handles = try bootstrapHandles([("base.apk", apk)], in: root)
    defer { for handle in handles { try? handle.close() } }

    let summary = try await service.importBootstrap(
        entry: bootstrapEntry(packageID: packageID),
        wrapperDocument: bootstrapWrapperDocument(packageID: packageID),
        bootstrapJSON: json,
        files: handles
    )
    #expect(summary.packageID.rawValue == packageID.rawValue)
    #expect(summary.versionCode == 12)

    let records = try await service.store.listManagedPackages()
    let record = try #require(records.first { $0.packageId == packageID })
    #expect(record.source.kind == .wrapperBootstrap)
    #expect(record.source.wrapperBundleId == "io.apkrun.android.\(packageID.rawValue)")
}

@Test(.timeLimit(.minutes(1)))
func importBootstrapRefusesAnInstalledPackage() async throws {
    let root = try bootstrapRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
    let packageID = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let service = bootstrapService(paths: paths, packageID: packageID)
    try await service.open()

    // First bootstrap succeeds; the second hits B2 (alreadyInstalled).
    let apk = Data("apk-test-bytes".utf8)
    let json = try bootstrapDocumentJSON(packageID: packageID, files: [("base.apk", apk)])
    let first = try bootstrapHandles([("base.apk", apk)], in: root)
    _ = try await service.importBootstrap(
        entry: bootstrapEntry(packageID: packageID),
        wrapperDocument: bootstrapWrapperDocument(packageID: packageID),
        bootstrapJSON: json,
        files: first
    )
    for handle in first { try? handle.close() }

    let second = try bootstrapHandles([("base.apk", apk)], in: root)
    defer { for handle in second { try? handle.close() } }
    do {
        _ = try await service.importBootstrap(
            entry: bootstrapEntry(packageID: packageID),
            wrapperDocument: bootstrapWrapperDocument(packageID: packageID),
            bootstrapJSON: json,
            files: second
        )
        Issue.record("importBootstrap must refuse a package that is already installed.")
    } catch let wireError as RuntimeWireError {
        #expect(wireError.code == "wrapper.bootstrapNotAllowed")
    }
}

@Test(.timeLimit(.minutes(1)))
func importBootstrapRefusesAPackageMismatch() async throws {
    let root = try bootstrapRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
    let packageID = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let otherID = try #require(PackageID(rawValue: "com.example.other"))
    let service = bootstrapService(paths: paths, packageID: packageID)
    try await service.open()

    // The document names a different package than the registered wrapper (B4).
    let apk = Data("apk-test-bytes".utf8)
    let json = try bootstrapDocumentJSON(packageID: otherID, files: [("base.apk", apk)])
    let handles = try bootstrapHandles([("base.apk", apk)], in: root)
    defer { for handle in handles { try? handle.close() } }
    do {
        _ = try await service.importBootstrap(
            entry: bootstrapEntry(packageID: packageID),
            wrapperDocument: bootstrapWrapperDocument(packageID: packageID),
            bootstrapJSON: json,
            files: handles
        )
        Issue.record("importBootstrap must refuse a document for another package.")
    } catch let wireError as RuntimeWireError {
        #expect(wireError.code == "wrapper.bootstrapInvalid")
    }

    // And when the document agrees but the inspected APK does not (B7).
    let badService = EmbeddedPackageService(
        paths: paths,
        inspector: { _ in
            APKFacts(
                packageID: otherID,
                versionCode: 12,
                versionName: "1.2",
                splitName: nil,
                displayName: "Other",
                minSDK: 23,
                targetSDK: 35,
                nativeABIs: []
            )
        },
        sessionService: PackageMutationTestSessionService(),
        importVerifier: { staged, _, inspect in
            var facts: [APKFacts] = []
            for url in staged { facts.append(try await inspect(url)) }
            let signer = try bootstrapTestSignerDigest()
            return PackageStore.VerifiedImport(
                files: staged,
                facts: facts,
                signerDigests: [signer],
                lineage: [signer],
                warnings: [],
                excludedSplits: []
            )
        },
        runtimeAccess: FakeInstalledRuntimeAccess()
    )
    try await badService.open()
    let goodJSON = try bootstrapDocumentJSON(packageID: packageID, files: [("base.apk", apk)])
    let handles2 = try bootstrapHandles([("base.apk", apk)], in: root)
    defer { for handle in handles2 { try? handle.close() } }
    do {
        _ = try await badService.importBootstrap(
            entry: bootstrapEntry(packageID: packageID),
            wrapperDocument: bootstrapWrapperDocument(packageID: packageID),
            bootstrapJSON: goodJSON,
            files: handles2
        )
        Issue.record("importBootstrap must refuse an APK whose identity differs.")
    } catch let wireError as RuntimeWireError {
        #expect(wireError.code == "wrapper.bootstrapInvalid")
    }
}

@Test(.timeLimit(.minutes(1)))
func importBootstrapRefusesAHashMismatch() async throws {
    let root = try bootstrapRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
    let packageID = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let service = bootstrapService(paths: paths, packageID: packageID)
    try await service.open()

    // The document declares the digest of different bytes (B5).
    let declared = Data("other-bytes".utf8)
    let json = try bootstrapDocumentJSON(packageID: packageID, files: [("base.apk", declared)])
    let actual = Data("apk-test-bytes".utf8)
    let handles = try bootstrapHandles([("base.apk", actual)], in: root)
    defer { for handle in handles { try? handle.close() } }
    do {
        _ = try await service.importBootstrap(
            entry: bootstrapEntry(packageID: packageID),
            wrapperDocument: bootstrapWrapperDocument(packageID: packageID),
            bootstrapJSON: json,
            files: handles
        )
        Issue.record("importBootstrap must refuse a file digest mismatch.")
    } catch let wireError as RuntimeWireError {
        #expect(wireError.code == "wrapper.bootstrapInvalid")
    }
}

@Test(.timeLimit(.minutes(1)))
func importBootstrapRefusesMalformedDocuments() async throws {
    let root = try bootstrapRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
    let packageID = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let service = bootstrapService(paths: paths, packageID: packageID)
    try await service.open()

    let apk = Data("apk-test-bytes".utf8)
    let handles = try bootstrapHandles([("base.apk", apk)], in: root)
    defer { for handle in handles { try? handle.close() } }
    do {
        _ = try await service.importBootstrap(
            entry: bootstrapEntry(packageID: packageID),
            wrapperDocument: bootstrapWrapperDocument(packageID: packageID),
            bootstrapJSON: Data("{not json".utf8),
            files: handles
        )
        Issue.record("importBootstrap must refuse an unparseable document.")
    } catch let wireError as RuntimeWireError {
        #expect(wireError.code == "wrapper.bootstrapInvalid")
    }
}
