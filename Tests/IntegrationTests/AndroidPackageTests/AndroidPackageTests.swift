import DiagnosticsCore
import Foundation
import RuntimeCore
import XCTest

/// HelloText through ADB on a booted guest (#016 T2; package-store.md §6.1; FR-PKG-01).
///
/// The tests run in the `AndroidPackage` configuration of IntegrationTests.xctestplan. They need the
/// fixture APK of `scripts/build-fixtures.sh` at Tests/Fixtures/AndroidApps/out/HelloText.apk.
final class AndroidPackageTests: XCTestCase {
    private static let packageName = "io.apkrun.fixture.hellotext"
    private static let mainActivity = "io.apkrun.fixture.hellotext/.MainActivity"

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["APKRUN_INTEGRATION_SUITE"] == "android-package" else {
            throw XCTSkip("The HelloText package checks run in the AndroidPackage test-plan configuration.")
        }
    }

    /// `adb install -r` installs HelloText, and PackageManager reports its metadata (FR-PKG-01).
    func testInstallHelloText() async throws {
        let apk = try Self.fixtureAPK()
        try await AndroidBootSession.withBoot(developerMode: true) { _ in
            let adb = try await Self.connectedClient()
            try await adb.install(apk: apk)

            let listing = try await adb.listPackages(matching: Self.packageName)
            XCTAssertEqual(listing, [AdbPackageListing(name: Self.packageName, versionCode: 1)])
            let metadata = try await adb.dumpsysPackage(Self.packageName)
            XCTAssertEqual(metadata.versionCode, 1)
            XCTAssertEqual(metadata.versionName, "1.0")
            XCTAssertEqual(metadata.minSdk, 29)
            XCTAssertEqual(metadata.targetSdk, 37)
        }
    }

    /// `adb uninstall` removes HelloText, PackageManager no longer lists it, and a second install succeeds.
    func testUninstallHelloText() async throws {
        let apk = try Self.fixtureAPK()
        try await AndroidBootSession.withBoot(developerMode: true) { _ in
            let adb = try await Self.connectedClient()
            try await adb.install(apk: apk)

            try await adb.uninstall(packageName: Self.packageName)

            let remaining = try await adb.listPackages(matching: Self.packageName)
            XCTAssertTrue(remaining.isEmpty, "PackageManager still lists \(Self.packageName)")
            do {
                try await adb.uninstall(packageName: Self.packageName)
                XCTFail("A package that is not installed must not uninstall again.")
            } catch {
                XCTAssertEqual((error as? APKRunError)?.qualifiedCode, "runtime.adbPackageRejected")
            }
            try await adb.install(apk: apk)
            let reinstalled = try await adb.listPackages(matching: Self.packageName)
            XCTAssertEqual(reinstalled, [AdbPackageListing(name: Self.packageName, versionCode: 1)])
        }
    }

    /// `am start -W -n` starts MainActivity by its component name, and ADB then sees the process and the
    /// resumed activity (#017). The headless profile draws no window, so no rendering is needed.
    func testLaunchHelloText() async throws {
        let apk = try Self.fixtureAPK()
        try await AndroidBootSession.withBoot(developerMode: true) { _ in
            let adb = try await Self.connectedClient()
            try await adb.install(apk: apk)

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

    /// Install, launch, stop, and uninstall on one boot (#017 end to end).
    func testInstallLaunchStopUninstall() async throws {
        let apk = try Self.fixtureAPK()
        try await AndroidBootSession.withBoot(developerMode: true) { _ in
            let adb = try await Self.connectedClient()
            try await adb.install(apk: apk)
            try await adb.startActivity(component: Self.mainActivity)
            let launchedPid = try await adb.pidof(Self.packageName)
            XCTAssertNotNil(launchedPid)
            let launched = try await adb.dumpsysActivities()
            XCTAssertEqual(launched.resumedComponent, Self.mainActivity)

            try await adb.forceStop(Self.packageName)

            let stoppedPid = try await adb.pidof(Self.packageName)
            XCTAssertNil(stoppedPid, "the process survives am force-stop")
            let stopped = try await adb.dumpsysActivities()
            XCTAssertNotNil(stopped.resumedComponent, "no activity is resumed after am force-stop")
            XCTAssertNotEqual(stopped.resumedComponent, Self.mainActivity)

            try await adb.uninstall(packageName: Self.packageName)
            let remaining = try await adb.listPackages(matching: Self.packageName)
            XCTAssertTrue(remaining.isEmpty)
        }
    }

    private static func connectedClient() async throws -> AdbClient {
        let adb = AdbClient(executable: try AndroidTestEnvironment.adbExecutable())
        try await adb.connect(timeout: .seconds(30))
        return adb
    }

    /// The fixture APK, found from this source file's location in the checkout.
    private static func fixtureAPK() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let apk = root.appendingPathComponent("Tests/Fixtures/AndroidApps/out/HelloText.apk")
        guard FileManager.default.fileExists(atPath: apk.path) else {
            let message = "The HelloText fixture is missing. Run scripts/build-fixtures.sh."
            if ProcessInfo.processInfo.environment["APKRUN_CI"] == "1" {
                XCTFail(message)
            }
            throw XCTSkip(message)
        }
        return apk
    }
}
