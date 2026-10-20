import APKStoreCore
import DiagnosticsCore
import Foundation
import RuntimeAPI
import Testing

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
