import APKStoreCore
import CryptoKit
import Foundation
import GuestProtocol
import RuntimeAPI
import RuntimeCore
import XCTest

@testable import RuntimeHost

/// Store Agent operations over the custom image's vsock ports with developer ADB disabled (#37 T2).
final class StoreAgentInstallTests: AndroidCustomTestCase {
    private static let packageName = "io.apkrun.fixture.hellotext"
    private static let sessionRetryDelays: [Duration] = [
        .milliseconds(25),
        .milliseconds(50),
        .milliseconds(100),
        .milliseconds(200),
        .milliseconds(400),
        .milliseconds(400),
    ]

    func testInstallUpdateMetadataMismatchAndUninstallWithoutAdb() async throws {
        let apk = try Self.fixtureAPK()
        let updateAPK = try Self.updateFixtureAPK()
        try await AndroidBootSession.withBoot(developerMode: false) { session in
            var step = "verify ADB is disabled"
            var completed = false
            defer {
                if !completed {
                    XCTFail("Store Agent integration failed during: \(step)")
                }
            }
            let adbPort = await session.supervisor.developmentADBHostPort
            XCTAssertNil(adbPort, "the custom image must keep development ADB disabled")

            let packageID = try Self.storePackageID()
            let inspector = APKInspector(environment: AndroidTestEnvironment.current())
            let service = EmbeddedPackageService(
                paths: session.paths,
                inspector: { apk in try await inspector.inspect(apk) }
            )

            step = "attach runtime and reconcile initial inventory"
            try await service.attachRuntime(
                context: session.runtimeContext,
                environment: AndroidTestEnvironment.current(),
                startRuntimeIfNeeded: false
            )

            step = "import first APK"
            let preview = try await Self.importAPK(apk, into: service)
            step = "install first APK"
            let installed = try await service.installImported(
                RuntimeInstallImportedRequest(ticket: preview.ticket)
            )
            let runtimePackage = try Self.runtimePackageID()
            XCTAssertEqual(installed.packageID, runtimePackage)
            XCTAssertEqual(installed.versionCode, 1)
            XCTAssertTrue(installed.managed)

            let managed = try await service.listPackages(RuntimeListPackagesRequest(filter: .managed))
            XCTAssertTrue(
                managed.packages.contains { $0.packageID == runtimePackage },
                "The first install did not persist a managed package record."
            )
            let packageDirectory = session.paths.packagesDirectory
                .appendingPathComponent(packageID.rawValue, isDirectory: true)
            let artifactMetadata =
                packageDirectory
                .appendingPathComponent("current", isDirectory: true)
                .appendingPathComponent("artifact.json")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: artifactMetadata.path),
                "The committed Store artifact metadata is missing at \(artifactMetadata.path)."
            )

            step = "read installed metadata"
            let details: RuntimePackageDetails
            do {
                details = try await service.packageInfo(RuntimePackageRequest(packageID: runtimePackage))
            } catch {
                let managedAfterFailure =
                    try? await service.listPackages(RuntimeListPackagesRequest(filter: .managed))
                let directChannel = try? await Self.storeChannel(for: session)
                let directPackageInfo = try? await directChannel?.packageInfo(packageID)
                XCTFail(
                    """
                    packageInfo failed: \(error)
                    Managed records after failure: \(String(describing: managedAfterFailure?.packages.map(\.packageID)))
                    Direct Store Agent metadata: \(String(describing: directPackageInfo))
                    """
                )
                await directChannel?.close()
                throw error
            }
            XCTAssertEqual(details.summary.versionCode, 1)
            XCTAssertEqual(details.files.map(\.name), ["base.apk"])

            step = "reconcile PackageManager inventory"
            let inventory = try await service.listPackages(RuntimeListPackagesRequest(filter: .all))
            XCTAssertEqual(inventory.source, .liveAndroid)
            let livePackage = try XCTUnwrap(
                inventory.packages.first { $0.packageID == runtimePackage },
                "PackageManager does not list the Store Agent install"
            )
            XCTAssertEqual(livePackage.state, .installed)
            XCTAssertTrue(livePackage.managed)

            step = "open direct Store Agent connection for update inspection"
            await service.detachRuntime()
            let channel = try await Self.storeChannel(for: session)
            step = "verify Store Agent installer of record"
            let packageMetadata = try await channel.packageInfo(packageID)
            let installedMetadata = try XCTUnwrap(
                packageMetadata,
                "PackageManager does not return metadata for the Store Agent install"
            )
            XCTAssertEqual(
                installedMetadata.installerPackage?.rawValue,
                "io.apkrun.store",
                "Android did not record the APKRun Store Agent as the installer of record."
            )
            step = "inspect update archive"
            let updateArtifact = try Self.artifactSpec(for: updateAPK)
            let updateArchive = try await channel.inspect([updateArtifact], files: [updateAPK])
            XCTAssertEqual(updateArchive.packageID, packageID)
            XCTAssertEqual(updateArchive.versionCode, 2)

            step = "reject wrong artifact hash through StoreAgentChannel"
            let wrongHashArtifact = StoreArtifactSpec(
                name: updateArtifact.name,
                size: updateArtifact.size,
                sha256: SHA256Digest(data: Data(repeating: 0, count: 32))
            )
            do {
                _ = try await channel.install(
                    StoreInstallRequest(
                        packageID: packageID,
                        versionCode: updateArchive.versionCode,
                        mode: .update,
                        expectedSignerDigests: updateArchive.signingDigests,
                        artifacts: [wrongHashArtifact]
                    ),
                    files: [updateAPK]
                )
                XCTFail("StoreAgentChannel accepted a mismatching artifact digest.")
            } catch let failure as StoreAgentSupervisorFailure {
                XCTAssertEqual(failure, .artifactDigestMismatch("base"))
            }

            step = "reject wrong signer through StoreAgentChannel"
            do {
                _ = try await channel.install(
                    StoreInstallRequest(
                        packageID: packageID,
                        versionCode: updateArchive.versionCode,
                        mode: .update,
                        expectedSignerDigests: [SHA256Digest(data: Data(repeating: 0, count: 32))],
                        artifacts: [updateArtifact]
                    ),
                    files: [updateAPK]
                )
                XCTFail("StoreAgentChannel accepted a mismatching expected signer.")
            } catch let failure as StoreAgentSupervisorFailure {
                XCTAssertEqual(failure, .signerMismatch)
            }
            let packageAfterChannelRefusals = try await channel.packageInfo(packageID)
            XCTAssertEqual(packageAfterChannelRefusals?.versionCode, 1)

            await channel.close()
            step = "open low-level Store Agent protocol connections"
            let (control, artifacts) = try await Self.directStoreConnections(for: session)
            do {
                let updateBytes = try Data(contentsOf: updateAPK)
                let updateDigest = Data(SHA256.hash(data: updateBytes))

                step = "verify guest final signer check before PackageInstaller commit"
                let invalidSignerInstall = try await Self.beginDirectUpdate(
                    packageName: packageID.rawValue,
                    versionCode: updateArchive.versionCode,
                    expectedSignerDigests: [Data(repeating: 0, count: 32)],
                    artifactSize: UInt64(updateBytes.count),
                    artifactDigest: updateDigest,
                    on: control
                )
                let acceptedArtifact = try await Self.streamDirectArtifact(
                    updateBytes,
                    transferID: 2,
                    installID: invalidSignerInstall.installID,
                    digest: updateDigest,
                    on: artifacts
                )
                XCTAssertEqual(acceptedArtifact, .ok)
                _ = try await control.send(GuestCommitInstall(installID: invalidSignerInstall.installID))
                let signerOutcome = try await Self.waitForInstallFinished(
                    invalidSignerInstall.installID,
                    on: control
                )
                XCTAssertEqual(signerOutcome.status, .invalid)
                XCTAssertEqual(signerOutcome.installedVersionCode, 0)
                let packageAfterSignerRefusal = try await control.send(
                    GuestGetStorePackageMetadata(package: packageID.rawValue)
                )
                XCTAssertEqual(packageAfterSignerRefusal.versionCode, 1)

                step = "verify guest rejects corrupted transfer bytes by digest"
                let hashMismatchInstall = try await Self.beginDirectUpdate(
                    packageName: packageID.rawValue,
                    versionCode: updateArchive.versionCode,
                    expectedSignerDigests: [],
                    artifactSize: UInt64(updateBytes.count),
                    artifactDigest: updateDigest,
                    on: control
                )
                var corruptedBytes = updateBytes
                corruptedBytes[corruptedBytes.count / 2] ^= 0xff
                let rejectedArtifact = try await Self.streamDirectArtifact(
                    corruptedBytes,
                    transferID: 4,
                    installID: hashMismatchInstall.installID,
                    digest: updateDigest,
                    on: artifacts
                )
                XCTAssertEqual(rejectedArtifact, .hashMismatch)
                let packageAfterHashRefusal = try await control.send(
                    GuestGetStorePackageMetadata(package: packageID.rawValue)
                )
                XCTAssertEqual(packageAfterHashRefusal.versionCode, 1)
            } catch {
                await artifacts.close()
                await control.close()
                throw error
            }
            await artifacts.close()
            await control.close()

            step = "attach runtime for update"
            try await service.attachRuntime(
                context: session.runtimeContext,
                environment: AndroidTestEnvironment.current(),
                startRuntimeIfNeeded: false
            )
            step = "import update APK"
            let updatePreview = try await Self.importAPK(updateAPK, into: service)
            step = "install update and verify refreshed metadata"
            let updated = try await service.installImported(
                RuntimeInstallImportedRequest(ticket: updatePreview.ticket)
            )
            XCTAssertEqual(updated.versionCode, 2)
            let reconciledUpdate = try await service.packageInfo(
                RuntimePackageRequest(packageID: runtimePackage)
            )
            XCTAssertEqual(reconciledUpdate.summary.versionCode, 2)
            XCTAssertEqual(reconciledUpdate.summary.state, .installed)
            XCTAssertEqual(reconciledUpdate.files.map(\.name), ["base.apk"])

            step = "uninstall and reconcile Android removal"
            await service.detachRuntime()
            let uninstallChannel = try await Self.storeChannel(for: session)
            try await uninstallChannel.uninstall(packageID, keepData: false)
            let removed = try await uninstallChannel.packageInfo(packageID)
            XCTAssertNil(removed, "PackageManager still reports the uninstalled package")
            await uninstallChannel.close()
            try await service.attachRuntime(
                context: session.runtimeContext,
                environment: AndroidTestEnvironment.current(),
                startRuntimeIfNeeded: false
            )
            let reconciled = try await service.listPackages(RuntimeListPackagesRequest(filter: .all))
            let removedRecord = try XCTUnwrap(
                reconciled.packages.first { $0.packageID == runtimePackage },
                "the package record disappeared instead of recording Android removal"
            )
            XCTAssertEqual(removedRecord.state, .broken("removedInAndroid"))
            await service.detachRuntime()
            completed = true
        }
    }

    func testPackageChangedPersistsUnmanagedInventoryAdditionAndRemoval() async throws {
        let apk = try Self.probeFixtureAPK()
        try await AndroidBootSession.withBoot(developerMode: false) { session in
            let packageID = try Self.probePackageID()
            let supervisor = try await Self.storeChannel(for: session)
            let service = EmbeddedPackageService(paths: session.paths)
            let monitorSignals = StoreEventMonitorSignals(packageID: packageID)
            let inventory = PackageStore(packagesDirectory: session.paths.packagesDirectory)

            do {
                try await service.open()
                try await inventory.open()
                await service.attachRuntimeAccessForTesting(
                    SingleStoreChannelAccess(
                        supervisor,
                        packageID: packageID,
                        monitorSignals: monitorSignals,
                        suppressInitialVersionOneEvent: false
                    )
                )
                // The event stream subscribes only after startup inventory has been persisted.
                try await monitorSignals.wait(for: .listening)
                let initialMetadata = try await supervisor.packageInfo(packageID)
                XCTAssertNil(initialMetadata)

                let artifact = try Self.artifactSpec(for: apk)
                let archive = try await supervisor.inspect([artifact], files: [apk])
                let installRequest = StoreInstallRequest(
                    packageID: packageID,
                    versionCode: archive.versionCode,
                    mode: .installNew,
                    expectedSignerDigests: archive.signingDigests,
                    artifacts: [artifact]
                )
                _ = try await supervisor.install(installRequest, files: [apk])
                try await Self.waitForAndroidInventory(
                    in: inventory,
                    packageID: packageID,
                    present: true
                )

                let live = try await service.listPackages(RuntimeListPackagesRequest(filter: .all))
                let unmanaged = try XCTUnwrap(
                    live.packages.first { $0.packageID.rawValue == packageID.rawValue }
                )
                XCTAssertEqual(live.source, .liveAndroid)
                XCTAssertFalse(unmanaged.managed)
                XCTAssertEqual(unmanaged.updateAuthority, .external)

                try await supervisor.uninstall(packageID, keepData: false)
                try await Self.waitForAndroidInventory(
                    in: inventory,
                    packageID: packageID,
                    present: false
                )

                await service.detachRuntime()
                let cached = try await service.listPackages(RuntimeListPackagesRequest(filter: .all))
                XCTAssertEqual(cached.source, .cachedAndroid)
                XCTAssertFalse(
                    cached.packages.contains { $0.packageID.rawValue == packageID.rawValue },
                    "The persisted Android inventory retained an externally removed package."
                )
            } catch {
                await service.detachRuntime()
                await supervisor.close()
                throw error
            }
            await service.detachRuntime()
            await supervisor.close()
        }
    }

    func testPackageChangedReconcilesExternalAndroidUpdateWithoutLiveQuery() async throws {
        let apk = try Self.fixtureAPK()
        let updateAPK = try Self.updateFixtureAPK()
        try await AndroidBootSession.withBoot(developerMode: false) { session in
            let packageID = try Self.storePackageID()
            let runtimePackage = try Self.runtimePackageID()
            let supervisor = try await Self.storeChannel(for: session)
            let inspector = APKInspector(environment: AndroidTestEnvironment.current())
            let service = EmbeddedPackageService(
                paths: session.paths,
                inspector: { apk in try await inspector.inspect(apk) }
            )
            let monitorSignals = StoreEventMonitorSignals(packageID: packageID)

            do {
                try await service.open()
                await service.attachRuntimeAccessForTesting(
                    SingleStoreChannelAccess(
                        supervisor,
                        packageID: packageID,
                        monitorSignals: monitorSignals
                    )
                )
                // Do not install until the empty startup inventory is complete and the event stream is consumed.
                try await monitorSignals.wait(for: .listening)
                let preview = try await Self.importAPK(apk, into: service)
                let installed = try await service.installImported(
                    RuntimeInstallImportedRequest(ticket: preview.ticket)
                )
                XCTAssertEqual(installed.versionCode, 1)
                let initial = try await service.packageInfo(
                    RuntimePackageRequest(packageID: runtimePackage)
                )
                XCTAssertEqual(initial.summary.versionCode, 1)
                XCTAssertEqual(initial.summary.state, .installed)
                // Wait until the v1 event is consumed and deliberately filtered before applying v2.
                // The handler cannot still reconcile this earlier event after this barrier.
                try await monitorSignals.wait(for: .initialInstallEventObserved)

                // The managed record already exists; this subsequent read is persisted and cannot query Android.
                // Its only version change after this point is the PackageChanged event for the external update.
                let updateArtifact = try Self.artifactSpec(for: updateAPK)
                let archive = try await supervisor.inspect([updateArtifact], files: [updateAPK])
                let request = StoreInstallRequest(
                    packageID: packageID,
                    versionCode: archive.versionCode,
                    mode: .update,
                    expectedSignerDigests: archive.signingDigests,
                    artifacts: [updateArtifact]
                )
                let externalUpdate = try await supervisor.install(request, files: [updateAPK])
                XCTAssertEqual(externalUpdate.versionCode, 2)
                try await monitorSignals.wait(for: .packageReplacedVersion2)

                var reconciled: RuntimePackageDetails?
                for _ in 0..<150 {
                    let current = try await service.packageInfo(
                        RuntimePackageRequest(packageID: runtimePackage)
                    )
                    if current.summary.versionCode == 2 {
                        reconciled = current
                        break
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                let eventReconciled = try XCTUnwrap(
                    reconciled,
                    "The persisted package record did not advance after Android emitted PackageChanged."
                )
                XCTAssertEqual(eventReconciled.summary.state, .installed)
            } catch {
                await service.detachRuntime()
                await supervisor.close()
                throw error
            }
            await service.detachRuntime()
        }
    }

    private static func storeChannel(for session: AndroidBootSession) async throws -> StoreAgentSupervisor {
        let transport = VsockGuestTransport { port, timeout in
            try await session.supervisor.connect(vsockPort: port, timeout: timeout)
        }
        return try await StoreAgentSupervisor.connect(transport: transport)
    }

    private static func directStoreConnections(
        for session: AndroidBootSession
    ) async throws -> (GuestConnection, GuestConnection) {
        let transport = VsockGuestTransport { port, timeout in
            try await session.supervisor.connect(vsockPort: port, timeout: timeout)
        }
        for attempt in 0...sessionRetryDelays.count {
            let control = GuestConnection(endpoint: .storeControl, transport: transport)
            var artifacts: GuestConnection?
            do {
                let sessionInfo = try await control.open()
                let openedArtifacts = GuestConnection(
                    endpoint: .storeArtifacts,
                    transport: transport,
                    presentedToken: sessionInfo.sessionToken
                )
                artifacts = openedArtifacts
                _ = try await openedArtifacts.open()
                return (control, openedArtifacts)
            } catch {
                await artifacts?.close()
                await control.close()
                // The guest closes an expired control session on its worker thread; retry while its socket teardown
                // is still in flight so this low-level protocol check does not race the preceding client close.
                guard error == .disconnected, attempt < sessionRetryDelays.count else {
                    throw error
                }
                try await Task.sleep(for: sessionRetryDelays[attempt])
            }
        }
        throw GuestProtocolFailure.disconnected
    }

    private static func beginDirectUpdate(
        packageName: String,
        versionCode: Int64,
        expectedSignerDigests: [Data],
        artifactSize: UInt64,
        artifactDigest: Data,
        on control: GuestConnection
    ) async throws -> GPBeginInstallResult {
        var artifact = GPArtifactSpec()
        artifact.name = "base"
        artifact.size = artifactSize
        artifact.sha256 = artifactDigest

        var request = GPInstallRequest()
        request.expectedPackage = packageName
        request.expectedVersionCode = versionCode
        request.expectedSignerSha256 = expectedSignerDigests
        request.mode = .update
        request.artifacts = [artifact]
        request.installReason = 4  // PackageManager.INSTALL_REASON_USER
        request.packageSource = 1  // PackageInstaller.PACKAGE_SOURCE_OTHER
        return try await control.send(GuestBeginInstall(request))
    }

    private static func streamDirectArtifact(
        _ bytes: Data,
        transferID: UInt64,
        installID: String,
        digest: Data,
        on connection: GuestConnection
    ) async throws -> GPBulkAckStatus {
        var begin = GPBulkBegin()
        begin.kind = .installArtifact
        begin.name = "base"
        begin.mimeType = "application/vnd.android.package-archive"
        begin.size = UInt64(bytes.count)
        begin.sha256 = digest
        begin.context = installID
        var frame = GPBulkFrame()
        frame.transferID = transferID
        frame.kind = .begin(begin)
        try await connection.sendBulkFrame(frame, timeout: .seconds(30))

        let chunkSize = 1_048_576
        for start in stride(from: 0, to: bytes.count, by: chunkSize) {
            let end = min(start + chunkSize, bytes.count)
            frame = GPBulkFrame()
            frame.transferID = transferID
            frame.kind = .chunk(bytes.subdata(in: start..<end))
            try await connection.sendBulkFrame(frame, timeout: .seconds(30))
        }

        frame = GPBulkFrame()
        frame.transferID = transferID
        frame.kind = .end(GPBulkEnd())
        try await connection.sendBulkFrame(frame, timeout: .seconds(30))
        return try await waitForBulkAck(transferID, on: connection)
    }

    private static func waitForBulkAck(
        _ transferID: UInt64,
        on connection: GuestConnection
    ) async throws -> GPBulkAckStatus {
        try await withThrowingTaskGroup(of: GPBulkAckStatus.self) { group in
            group.addTask {
                for await frame in connection.bulkFrames {
                    guard frame.transferID == transferID,
                        case .ack(let acknowledgement)? = frame.kind
                    else {
                        continue
                    }
                    return acknowledgement.status
                }
                throw DirectStoreAgentTestFailure.connectionClosed
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw DirectStoreAgentTestFailure.timedOut
            }
            defer { group.cancelAll() }
            guard let acknowledgement = try await group.next() else {
                throw DirectStoreAgentTestFailure.connectionClosed
            }
            return acknowledgement
        }
    }

    private static func waitForInstallFinished(
        _ installID: String,
        on control: GuestConnection
    ) async throws -> GPInstallFinished {
        try await withThrowingTaskGroup(of: GPInstallFinished.self) { group in
            group.addTask {
                for await event in control.events {
                    guard case .installFinished(let finished)? = event.kind,
                        finished.installID == installID
                    else {
                        continue
                    }
                    return finished
                }
                throw DirectStoreAgentTestFailure.connectionClosed
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw DirectStoreAgentTestFailure.timedOut
            }
            defer { group.cancelAll() }
            guard let finished = try await group.next() else {
                throw DirectStoreAgentTestFailure.connectionClosed
            }
            return finished
        }
    }

    private static func importAPK(
        _ apk: URL,
        into service: EmbeddedPackageService
    ) async throws -> RuntimeImportPreview {
        let file = try FileHandle(forReadingFrom: apk)
        defer { try? file.close() }
        return try await service.importPackage(
            RuntimeImportPackageRequest(
                files: [RuntimeImportSourceFile(fileIndex: 0, name: apk.lastPathComponent)],
                origin: .cli
            ),
            files: [file]
        )
    }

    private static func artifactSpec(for apk: URL) throws -> StoreArtifactSpec {
        let values = try apk.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw XCTSkip("The selected Android fixture is not a non-empty regular APK.")
        }
        return StoreArtifactSpec(
            name: "base",
            size: UInt64(size),
            sha256: SHA256Digest(data: try Data(contentsOf: apk))
        )
    }

    private static func storePackageID() throws -> PackageID {
        try XCTUnwrap(PackageID(rawValue: packageName))
    }

    private static func runtimePackageID() throws -> RuntimePackageID {
        try XCTUnwrap(RuntimePackageID(rawValue: packageName))
    }

    private static func fixtureAPK() throws -> URL {
        guard let path = AndroidTestEnvironment.current()["APKRUN_FIXTURE_APK"],
            !path.isEmpty,
            FileManager.default.fileExists(atPath: path)
        else {
            throw XCTSkip("APKRUN_FIXTURE_APK must point to the staged signed HelloText APK.")
        }
        return URL(fileURLWithPath: path)
    }

    private static func updateFixtureAPK() throws -> URL {
        guard let path = AndroidTestEnvironment.current()["APKRUN_FIXTURE_UPDATE_APK"],
            !path.isEmpty,
            FileManager.default.fileExists(atPath: path)
        else {
            throw XCTSkip("APKRUN_FIXTURE_UPDATE_APK must point to the staged signed HelloText v2 APK.")
        }
        return URL(fileURLWithPath: path)
    }

    private static func probeFixtureAPK() throws -> URL {
        guard let path = AndroidTestEnvironment.current()["APKRUN_FIXTURE_PROBE_APK"],
            !path.isEmpty,
            FileManager.default.fileExists(atPath: path)
        else {
            throw XCTSkip("APKRUN_FIXTURE_PROBE_APK must point to the staged signed HelloProbe APK.")
        }
        return URL(fileURLWithPath: path)
    }

    private static func probePackageID() throws -> PackageID {
        try XCTUnwrap(PackageID(rawValue: "io.apkrun.fixture.helloprobe"))
    }

    private static func waitForAndroidInventory(
        in store: PackageStore,
        packageID: PackageID,
        present: Bool,
        timeout: Duration = .seconds(30)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let snapshot = try await store.lastKnownAndroidInventory(),
                snapshot.packages.contains(where: { $0.packageID == packageID }) == present
            {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail(
            "The persisted Android inventory did not \(present ? "include" : "remove") \(packageID.rawValue)."
        )
    }
}

private enum DirectStoreAgentTestFailure: Error {
    case connectionClosed
    case timedOut
}

private enum StoreEventMonitorSignal: Equatable, Sendable {
    case listening
    case initialInstallEventObserved
    case packageReplacedVersion2
}

private enum StoreEventMonitorReadinessFailure: Error {
    case timedOut
}

private actor StoreEventMonitorSignals {
    private let packageID: PackageID
    private let stream: AsyncStream<StoreEventMonitorSignal>
    private let continuation: AsyncStream<StoreEventMonitorSignal>.Continuation

    init(packageID: PackageID) {
        self.packageID = packageID
        let channel = AsyncStream.makeStream(
            of: StoreEventMonitorSignal.self,
            bufferingPolicy: .bufferingNewest(8)
        )
        stream = channel.stream
        continuation = channel.continuation
    }

    func markReady() {
        continuation.yield(.listening)
    }

    func markPackageChanged(_ event: StorePackageEvent) {
        guard event.packageID == packageID else { return }
        if event.versionCode == 1 {
            continuation.yield(.initialInstallEventObserved)
        } else if event.versionCode == 2, event.kind == .replaced {
            continuation.yield(.packageReplacedVersion2)
        }
    }

    func wait(
        for expectedSignal: StoreEventMonitorSignal,
        timeout: Duration = .seconds(30)
    ) async throws {
        let stream = self.stream
        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await signal in stream {
                    if signal == expectedSignal {
                        return true
                    }
                }
                return false
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return false
                }
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            await group.waitForAll()
            return result
        }
        if !completed {
            throw StoreEventMonitorReadinessFailure.timedOut
        }
    }
}

private actor SingleStoreChannelAccess: StoreRuntimeAccess {
    private let channel: StoreAgentSupervisor
    private let packageID: PackageID
    private let monitorSignals: StoreEventMonitorSignals
    private let suppressInitialVersionOneEvent: Bool

    init(
        _ channel: StoreAgentSupervisor,
        packageID: PackageID,
        monitorSignals: StoreEventMonitorSignals,
        suppressInitialVersionOneEvent: Bool = true
    ) {
        self.channel = channel
        self.packageID = packageID
        self.monitorSignals = monitorSignals
        self.suppressInitialVersionOneEvent = suppressInitialVersionOneEvent
    }

    func withStoreAgent<T: Sendable>(
        _ operation: UUID,
        _ body: @Sendable (any StoreAgentChannel) async throws -> T
    ) async throws -> T {
        _ = operation
        return try await body(
            PackageEventObservedStoreChannel(
                channel,
                packageID: packageID,
                monitorSignals: monitorSignals,
                suppressInitialVersionOneEvent: suppressInitialVersionOneEvent
            )
        )
    }

    func userdataGeneration() async -> UUID? {
        nil
    }

    func close() async {
        await channel.close()
    }
}

private struct PackageEventObservedStoreChannel: StoreAgentChannel {
    private let channel: StoreAgentSupervisor
    private let packageID: PackageID
    private let monitorSignals: StoreEventMonitorSignals
    private let suppressInitialVersionOneEvent: Bool

    init(
        _ channel: StoreAgentSupervisor,
        packageID: PackageID,
        monitorSignals: StoreEventMonitorSignals,
        suppressInitialVersionOneEvent: Bool
    ) {
        self.channel = channel
        self.packageID = packageID
        self.monitorSignals = monitorSignals
        self.suppressInitialVersionOneEvent = suppressInitialVersionOneEvent
    }

    var capabilities: StoreCapabilities {
        channel.capabilities
    }

    var isConnected: Bool {
        channel.isConnected
    }

    var packageEvents: AsyncStream<StorePackageEvent> {
        let packageID = self.packageID
        let events = channel.packageEvents
        return AsyncStream(bufferingPolicy: .bufferingNewest(1_024)) { continuation in
            Task {
                await monitorSignals.markReady()
                for await event in events {
                    if event.packageID == packageID {
                        if event.versionCode == 1 {
                            await monitorSignals.markPackageChanged(event)
                            if suppressInitialVersionOneEvent {
                                continue
                            }
                        }
                        if event.versionCode == 2, event.kind == .replaced {
                            await monitorSignals.markPackageChanged(event)
                        }
                    }
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    func inspect(_ artifacts: [StoreArtifactSpec], files: [URL]) async throws -> StoreArchiveInfo {
        try await channel.inspect(artifacts, files: files)
    }

    func install(_ request: StoreInstallRequest, files: [URL]) async throws -> StorePackageInfo {
        try await channel.install(request, files: files)
    }

    func uninstall(_ package: PackageID, keepData: Bool) async throws {
        try await channel.uninstall(package, keepData: keepData)
    }

    func packageInfo(_ package: PackageID) async throws -> StorePackageInfo? {
        try await channel.packageInfo(package)
    }

    func listPackages(_ filter: StorePackageFilter) async throws -> [StorePackageSummary] {
        try await channel.listPackages(filter)
    }

    func listManagedPackages() async throws -> [StorePackageInfo] {
        try await channel.listManagedPackages()
    }

    func close() async {
        await channel.close()
    }
}
