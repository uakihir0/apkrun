import APKStoreCore
import DiagnosticsCore
import Foundation
import RuntimeAPI
import RuntimeCore
import RuntimeHost
import UpdateCore
import XCTest

/// Update ownership through a booted guest (#40 T2).
///
/// The tests run in the `AndroidStore` configuration of IntegrationTests.xctestplan on the custom
/// image with the Store Agent (op 109, `store.ownership.v1`). They need the HelloUpdate V1+V2 and
/// OtherInstaller fixture APKs plus the Guest Agent bundle staged outside the checkout. `APKRUN_*`
/// in the test plan names them under /tmp.
final class UpdateOwnershipTests: XCTestCase {
    private static let packageName = "io.apkrun.fixture.helloupdate"
    private static let otherInstallerName = "io.apkrun.fixture.otherinstaller"
    private static let otherInstallerActivity = "io.apkrun.fixture.otherinstaller/.MainActivity"
    private static let storeAgentPackage = "io.apkrun.store"

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["APKRUN_INTEGRATION_SUITE"] == "android-store" else {
            throw XCTSkip("The ownership checks run in the AndroidStore test-plan configuration.")
        }
    }

    /// package-store.md §6.3: an `apkrun`-authority install asks Android for update ownership, and
    /// the update keeps it: `android.updateOwner == io.apkrun.store` in the record after both.
    func testOwnerIsStoreAgentAfterInstallAndUpdate() async throws {
        let v1 = try Self.fixture("APKRUN_HELLOUPDATE_V1_APK", label: "HelloUpdate V1")
        let v2 = try Self.fixture("APKRUN_HELLOUPDATE_V2_APK", label: "HelloUpdate V2")
        let guestAgentBundle = try Self.guestAgentBundle()
        try await AndroidBootSession.withBoot(developerMode: true, guestAgentBundle: guestAgentBundle) { session in
            let service = try await Self.packageService(for: session)
            _ = try await Self.install(v1, using: service)
            let packageID = try Self.packageID()

            // Authority `apkrun` needs a provider: attach the local repo the
            // fixtures are staged from (update-system.md §2.1).
            let updates = await Self.updateService(for: service, paths: session.paths)
            try await updates.open()
            let repo = try Self.updateRepo()
            try await updates.setUpdatePolicy(
                packageID: packageID,
                policy: UpdatePolicy(
                    choice: .automatic,
                    provider: .set(
                        ProviderSpec(
                            spec: "local:\(repo.path)",
                            bookmark: try repo.bookmarkData(
                                options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                relativeTo: nil)))))
            var record = try Self.record(for: packageID, in: session.paths)
            XCTAssertEqual(record.updateAuthority, .apkrun)
            XCTAssertEqual(record.android.updateOwner?.rawValue, Self.storeAgentPackage)

            let outcome = try await Self.updateFromFile(v2, package: packageID, service: service, updates: updates)
            switch outcome {
            case .updated(_, let to):
                XCTAssertEqual(to, 2)
            default:
                XCTFail("HelloUpdate V2 did not install: \(String(describing: outcome))")
            }
            record = try Self.record(for: packageID, in: session.paths)
            XCTAssertEqual(record.android.updateOwner?.rawValue, Self.storeAgentPackage)
            XCTAssertEqual(record.versionCode, 2)
        }
    }

    /// test-strategy.md §4.2: on the custom image the Store Agent owns HelloUpdate, so
    /// OtherInstaller's USER_ACTION_NOT_REQUIRED session ends STATUS_PENDING_USER_ACTION and
    /// HelloUpdate stays on V1.
    func testOtherInstallerCannotUpdateHelloUpdate() async throws {
        let v1 = try Self.fixture("APKRUN_HELLOUPDATE_V1_APK", label: "HelloUpdate V1")
        let other = try Self.fixture("APKRUN_OTHERINSTALLER_APK", label: "OtherInstaller")
        let guestAgentBundle = try Self.guestAgentBundle()
        try await AndroidBootSession.withBoot(developerMode: true, guestAgentBundle: guestAgentBundle) { session in
            let service = try await Self.packageService(for: session)
            _ = try await Self.install(v1, using: service)
            let adb = try await Self.connectedClient(session)

            _ = try await adb.install(apk: other)
            try await adb.startActivity(component: Self.otherInstallerActivity)

            var status: String?
            for _ in 0..<30 {
                let log = try await adb.logcatDump()
                status = log.split(whereSeparator: \.isNewline)
                    .map(String.init)
                    .first { $0.contains("APKRUN-FIXTURE") && $0.contains("session ") }
                if status != nil { break }
                try await Task.sleep(for: .seconds(2))
            }
            let line = try XCTUnwrap(status, "OtherInstaller logged no session status")
            XCTAssertTrue(
                line.contains("PENDING_USER_ACTION"),
                "ownership enforcement should force user action, got: \(line)")

            let guest = try await adb.dumpsysPackage(Self.packageName)
            XCTAssertEqual(guest.versionCode, 1)
        }
    }

    /// package-store.md §6.3: moving to `external` relinquishes ownership first; Android and the
    /// record then report no update owner.
    func testExternalAuthorityClearsOwner() async throws {
        let v1 = try Self.fixture("APKRUN_HELLOUPDATE_V1_APK", label: "HelloUpdate V1")
        let guestAgentBundle = try Self.guestAgentBundle()
        try await AndroidBootSession.withBoot(developerMode: true, guestAgentBundle: guestAgentBundle) { session in
            let service = try await Self.packageService(for: session)
            _ = try await Self.install(v1, using: service)
            let packageID = try Self.packageID()

            let updates = await Self.updateService(for: service, paths: session.paths)
            try await updates.open()
            var record = try Self.record(for: packageID, in: session.paths)
            XCTAssertEqual(record.android.updateOwner?.rawValue, Self.storeAgentPackage)

            _ = try await updates.setUpdateAuthority(packageID: packageID, authority: .external)
            record = try Self.record(for: packageID, in: session.paths)
            XCTAssertEqual(record.updateAuthority, .external)
            XCTAssertNil(record.android.updateOwner)
        }
    }

    /// Step 7 / OQ-12 / R-18: an owner-less package (installed by `adb`, then adopted, then switched
    /// to `manual`) is updated from a file with `setRequestUpdateOwnership`; reading `updateOwner`
    /// afterwards records whether Android grants ownership on an owner-less update.
    func testOwnerlessPackageGainsOwnerOnManualFileUpdate() async throws {
        let v1 = try Self.fixture("APKRUN_HELLOUPDATE_V1_APK", label: "HelloUpdate V1")
        let v2 = try Self.fixture("APKRUN_HELLOUPDATE_V2_APK", label: "HelloUpdate V2")
        let guestAgentBundle = try Self.guestAgentBundle()
        try await AndroidBootSession.withBoot(developerMode: true, guestAgentBundle: guestAgentBundle) { session in
            let service = try await Self.packageService(for: session)
            let adb = try await Self.connectedClient(session)
            let packageID = try Self.packageID()
            let wireID = try XCTUnwrap(RuntimePackageID(rawValue: Self.packageName))

            // An ADB install lands owner-less and unmanaged (§9.3).
            _ = try await adb.install(apk: v1)
            _ = try await service.adoptPackage(RuntimeAdoptPackageRequest(packageID: wireID))

            let updates = await Self.updateService(for: service, paths: session.paths)
            try await updates.open()
            _ = try await updates.setUpdateAuthority(packageID: packageID, authority: .manual)
            var record = try Self.record(for: packageID, in: session.paths)
            XCTAssertEqual(record.updateAuthority, .manual)
            XCTAssertNil(record.android.updateOwner)

            _ = try await Self.updateFromFile(v2, package: packageID, service: service, updates: updates)

            // OQ-12 asks exactly this; the assertion records the answer on the custom image.
            record = try Self.record(for: packageID, in: session.paths)
            XCTAssertEqual(record.versionCode, 2)
            XCTAssertEqual(
                record.android.updateOwner?.rawValue, Self.storeAgentPackage,
                "OQ-12: Android did not grant update ownership on an owner-less manual update")
        }
    }

    // MARK: - Helpers

    private static func packageService(for session: AndroidBootSession) async throws -> EmbeddedPackageService {
        if ProcessInfo.processInfo.environment["ANDROID_HOME"] == nil,
            let sdk = AndroidTestEnvironment.current()["ANDROID_HOME"]
        {
            setenv("ANDROID_HOME", sdk, 1)
        }
        let service = EmbeddedPackageService(paths: session.paths)
        try await service.attachRuntime(
            context: session.runtimeContext,
            environment: AndroidTestEnvironment.current()
        )
        return service
    }

    /// An update service over the same store the package service already attached to the runtime.
    private static func updateService(
        for service: EmbeddedPackageService, paths: APKRunPaths
    ) async -> EmbeddedUpdateService {
        EmbeddedUpdateService(paths: paths, store: await service.store)
    }

    private static func install(_ apk: URL, using service: EmbeddedPackageService) async throws -> RuntimePackageSummary
    {
        let file = try FileHandle(forReadingFrom: apk)
        defer { try? file.close() }
        let preview = try await service.importPackage(
            RuntimeImportPackageRequest(
                files: [RuntimeImportSourceFile(fileIndex: 0, name: apk.lastPathComponent)],
                origin: .cli
            ),
            files: [file]
        )
        return try await service.installImported(RuntimeInstallImportedRequest(ticket: preview.ticket))
    }

    /// `apkrun update --file`: import the V2 set, then validate and install it in place.
    private static func updateFromFile(
        _ apk: URL,
        package packageID: PackageID,
        service: EmbeddedPackageService,
        updates: EmbeddedUpdateService
    ) async throws -> WireUpdateOutcome? {
        let file = try FileHandle(forReadingFrom: apk)
        defer { try? file.close() }
        let preview = try await service.importPackage(
            RuntimeImportPackageRequest(
                files: [RuntimeImportSourceFile(fileIndex: 0, name: apk.lastPathComponent)],
                origin: .cli
            ),
            files: [file]
        )
        let ticket = try XCTUnwrap(UUID(uuidString: preview.ticket.rawValue))
        return try await updates.updateFromFile(packageID, ticket: ticket, runtime: ReadyUpdateRuntime())
    }

    /// Reads the record's `metadata.json` directly, the way the T1 probes do.
    private static func record(for packageID: PackageID, in paths: APKRunPaths) throws -> PackageRecord {
        let metadata = paths.packagesDirectory
            .appendingPathComponent(packageID.rawValue, isDirectory: true)
            .appendingPathComponent("metadata.json")
        let data = try Data(contentsOf: metadata)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PackageRecord.self, from: data)
    }

    private static func packageID() throws -> PackageID {
        try XCTUnwrap(PackageID(rawValue: packageName))
    }

    private static func updateRepo() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["APKRUN_UPDATE_REPO"], !path.isEmpty else {
            throw XCTSkip("APKRUN_UPDATE_REPO does not name the staged local update repo.")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func connectedClient(_ session: AndroidBootSession) async throws -> AdbClient {
        let boundPort = await session.supervisor.developmentADBHostPort
        let port = try XCTUnwrap(boundPort, "the boot bound no development ADB port")
        let adb = AdbClient(
            executable: try AndroidTestEnvironment.adbExecutable(),
            endpoint: AdbClient.loopbackEndpoint(port: port)
        )
        try await adb.connect(timeout: .seconds(30))
        return adb
    }

    private static func guestAgentBundle() throws -> GuestAgentBundle {
        guard let path = AndroidTestEnvironment.current()["APKRUN_GUEST_DIR"], !path.isEmpty else {
            throw XCTSkip(
                "APKRUN_GUEST_DIR is not set. Build the Guest Agent bundle with scripts/build-guest.sh --out.")
        }
        do {
            return try GuestAgentBundle.load(directory: URL(fileURLWithPath: path, isDirectory: true))
        } catch {
            throw XCTSkip("The Guest Agent bundle in \(path) could not be read: \(error.qualifiedCode)")
        }
    }

    private static func fixture(_ environmentKey: String, label: String) throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[environmentKey], !path.isEmpty,
            FileManager.default.fileExists(atPath: path)
        else {
            let message = "\(environmentKey) does not name the \(label) fixture (environment-setup §4)."
            if ProcessInfo.processInfo.environment["APKRUN_CI"] == "1" {
                XCTFail(message)
            }
            throw XCTSkip(message)
        }
        return URL(fileURLWithPath: path)
    }
}

/// The boot is already ready in these tests; the update pipeline needs no further runtime control.
private struct ReadyUpdateRuntime: UpdateRuntimeAccess {
    var runtimeState: WireRuntimeState { .ready }
    func hasActiveUse(_ package: PackageID) async -> Bool { false }
    func ensureReadyForUpdate() async throws {}
}
