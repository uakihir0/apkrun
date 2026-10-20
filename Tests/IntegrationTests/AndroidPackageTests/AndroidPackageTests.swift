import DiagnosticsCore
import Foundation
import RuntimeAPI
import RuntimeCore
import RuntimeHost
import XCTest

/// HelloText package operations through RuntimeAPI on a booted guest (#17/#18 T2).
///
/// The tests run in the `AndroidPackage` configuration of IntegrationTests.xctestplan and need the HelloText APK
/// plus the Guest Agent bundle staged outside the checkout. The headless #18 activity and force-stop observations
/// still use ADB because this harness has no display-backed RuntimeAPI session.
final class AndroidPackageTests: XCTestCase {
    private static let packageName = "io.apkrun.fixture.hellotext"
    private static let mainActivity = "io.apkrun.fixture.hellotext/.MainActivity"

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["APKRUN_INTEGRATION_SUITE"] == "android-package" else {
            throw XCTSkip("The HelloText package checks run in the AndroidPackage test-plan configuration.")
        }
    }

    /// RuntimeAPI installs HelloText, and its live inventory and package details expose the installed version.
    func testInstallHelloText() async throws {
        let apk = try Self.fixtureAPK()
        let guestAgentBundle = try Self.guestAgentBundle()
        try await AndroidBootSession.withBoot(developerMode: true, guestAgentBundle: guestAgentBundle) { session in
            let service = try await Self.packageService(for: session)
            let installed = try await Self.install(apk, using: service)
            let packageID = try Self.runtimePackageID()

            XCTAssertEqual(installed.packageID, packageID)
            XCTAssertEqual(installed.versionCode, 1)

            let inventory = try await service.listPackages(RuntimeListPackagesRequest(filter: .all))
            XCTAssertEqual(inventory.source, .liveAndroid)
            let installedPackage = try XCTUnwrap(inventory.packages.first { $0.packageID == packageID })
            XCTAssertEqual(installedPackage.versionCode, 1)
            XCTAssertTrue(installedPackage.managed)

            let details = try await service.packageInfo(RuntimePackageRequest(packageID: packageID))
            XCTAssertEqual(details.summary.versionName, "1.0")
            XCTAssertEqual(details.summary.versionCode, 1)
            XCTAssertEqual(details.files.map(\.name), ["base.apk"])
        }
    }

    /// RuntimeAPI uninstall removes HelloText, and a later RuntimeAPI install succeeds.
    func testUninstallHelloText() async throws {
        let apk = try Self.fixtureAPK()
        let guestAgentBundle = try Self.guestAgentBundle()
        try await AndroidBootSession.withBoot(developerMode: true, guestAgentBundle: guestAgentBundle) { session in
            let service = try await Self.packageService(for: session)
            let packageID = try Self.runtimePackageID()
            _ = try await Self.install(apk, using: service)

            let uninstall = RuntimeUninstallPackageRequest(packageID: packageID)
            try await service.uninstallPackage(uninstall)

            let remaining = try await service.listPackages(RuntimeListPackagesRequest(filter: .all))
            XCTAssertEqual(remaining.source, .liveAndroid)
            XCTAssertFalse(
                remaining.packages.contains(where: { $0.packageID == packageID }),
                "PackageManager still lists \(Self.packageName)"
            )
            do {
                try await service.uninstallPackage(uninstall)
                XCTFail("A package that is not managed must not uninstall again.")
            } catch let failure as RuntimeWireError {
                XCTAssertEqual(failure.code, "store.packageNotFound")
            }

            let reinstalled = try await Self.install(apk, using: service)
            XCTAssertEqual(reinstalled.versionCode, 1)
            let inventory = try await service.listPackages(RuntimeListPackagesRequest(filter: .all))
            XCTAssertEqual(inventory.source, .liveAndroid)
            let installedPackage = try XCTUnwrap(inventory.packages.first { $0.packageID == packageID })
            XCTAssertEqual(installedPackage.versionCode, 1)
            XCTAssertTrue(installedPackage.managed)
        }
    }

    /// The #18 headless launch checks remain transport-level: package installation uses RuntimeAPI, while ADB
    /// observes the activity because RuntimeAPI.launch requires a window-backed session.
    func testLaunchHelloText() async throws {
        let apk = try Self.fixtureAPK()
        let guestAgentBundle = try Self.guestAgentBundle()
        try await AndroidBootSession.withBoot(developerMode: true, guestAgentBundle: guestAgentBundle) { session in
            let adb = try await Self.connectedClient(session)
            let service = try await Self.packageService(for: session)
            _ = try await Self.install(apk, using: service)

            try await adb.startActivity(component: Self.mainActivity)

            let pid = try await adb.pidof(Self.packageName)
            XCTAssertNotNil(pid, "pidof finds no process for \(Self.packageName)")
            let processes = try await adb.shell("ps -A")
            let listed = processes.output.split(whereSeparator: \.isNewline).contains {
                $0.trimmingCharacters(in: .whitespaces).hasSuffix(Self.packageName)
            }
            XCTAssertTrue(listed, "ps -A does not list \(Self.packageName)")
            let activities = try await adb.dumpsysActivities()
            XCTAssertEqual(activities.resumedComponent, Self.mainActivity)
        }
    }

    /// Uses RuntimeAPI for install, package termination, and uninstall around the #18 headless launch check.
    func testInstallLaunchStopUninstall() async throws {
        let apk = try Self.fixtureAPK()
        let guestAgentBundle = try Self.guestAgentBundle()
        try await AndroidBootSession.withBoot(developerMode: true, guestAgentBundle: guestAgentBundle) { session in
            let service = try await Self.packageService(for: session)
            let adb = try await Self.connectedClient(session)
            _ = try await Self.install(apk, using: service)
            try await adb.startActivity(component: Self.mainActivity)
            let launchedPid = try await adb.pidof(Self.packageName)
            XCTAssertNotNil(launchedPid)
            let launched = try await adb.dumpsysActivities()
            XCTAssertEqual(launched.resumedComponent, Self.mainActivity)

            let terminated = try await service.terminate(
                RuntimeTerminateRequest(packageID: try Self.runtimePackageID())
            )
            XCTAssertFalse(terminated.hadSession, "the headless test does not register a window-backed session")

            let stoppedPid = try await adb.pidof(Self.packageName)
            XCTAssertNil(stoppedPid, "the process survives RuntimeAPI termination")
            let stopped = try await adb.dumpsysActivities()
            XCTAssertNotNil(stopped.resumedComponent, "no activity is resumed after RuntimeAPI termination")
            XCTAssertNotEqual(stopped.resumedComponent, Self.mainActivity)

            try await service.uninstallPackage(
                RuntimeUninstallPackageRequest(packageID: try Self.runtimePackageID())
            )
            let remaining = try await service.listPackages(RuntimeListPackagesRequest(filter: .all))
            XCTAssertEqual(remaining.source, .liveAndroid)
            XCTAssertFalse(remaining.packages.contains(where: { $0.packageID.rawValue == Self.packageName }))
        }
    }

    private static func packageService(for session: AndroidBootSession) async throws -> EmbeddedPackageService {
        if ProcessInfo.processInfo.environment["ANDROID_HOME"] == nil,
            let sdk = AndroidTestEnvironment.current()["ANDROID_HOME"]
        {
            // APKInspector resolves aapt2 from ProcessInfo instead of AndroidTestEnvironment.current().
            setenv("ANDROID_HOME", sdk, 1)
        }
        let service = EmbeddedPackageService(paths: session.paths)
        try await service.attachRuntime(
            context: session.runtimeContext,
            environment: AndroidTestEnvironment.current()
        )
        return service
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

    private static func runtimePackageID() throws -> RuntimePackageID {
        try XCTUnwrap(RuntimePackageID(rawValue: packageName))
    }

    /// An ADB client connected to the development endpoint of `session`, which is the port the boot bound (IR-1255).
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

    /// The HelloText fixture APK of `APKRUN_FIXTURE_APK`, copied to /tmp before the run (environment-setup §4). The
    /// checkout is not read, because a read under ~/Documents waits for the privacy decision (IR-438, IR-1253).
    private static func fixtureAPK() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["APKRUN_FIXTURE_APK"], !path.isEmpty,
            FileManager.default.fileExists(atPath: path)
        else {
            let message = "APKRUN_FIXTURE_APK does not name the HelloText fixture (environment-setup §4)."
            if ProcessInfo.processInfo.environment["APKRUN_CI"] == "1" {
                XCTFail(message)
            }
            throw XCTSkip(message)
        }
        return URL(fileURLWithPath: path)
    }
}
