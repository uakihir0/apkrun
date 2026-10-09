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
