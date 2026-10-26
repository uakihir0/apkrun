import DiagnosticsCore
import Foundation
import RuntimeAPI
import RuntimeCore
import RuntimeHost
import XCTest

/// APK package operations through RuntimeAPI on a booted guest (#17/#18/#28 T2).
///
/// The tests run in the `AndroidPackage` configuration of IntegrationTests.xctestplan and need the fixture APKs
/// plus the Guest Agent bundle staged outside the checkout. The headless #18 activity, force-stop, and split-file
/// observations still use ADB because this harness has no display-backed RuntimeAPI session and RuntimeAPI does not
/// expose Android's installed split paths.
final class AndroidPackageTests: XCTestCase {
    private static let packageName = "io.apkrun.fixture.hellotext"
    private static let mainActivity = "io.apkrun.fixture.hellotext/.MainActivity"
    private static let splitPackageName = "io.apkrun.fixture.hellosplit"
    private static let counterIncrementAction = "io.apkrun.fixture.hellotext.debug.INCREMENT"
    private static let counterReadAction = "io.apkrun.fixture.hellotext.debug.READ"
    private static let persistedCounterPrefix = "APKRUN-FIXTURE: debug read "

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

    /// RuntimeAPI imports and installs the complete HelloSplit APK set as one Android package.
    func testInstallHelloSplit() async throws {
        let apks = try Self.helloSplitAPKs()
        let guestAgentBundle = try Self.guestAgentBundle()
        try await AndroidBootSession.withBoot(developerMode: true, guestAgentBundle: guestAgentBundle) { session in
            let service = try await Self.packageService(for: session)
            let preview = try await Self.importPackage(apks, using: service)
            XCTAssertEqual(preview.packageID.rawValue, Self.splitPackageName)
            XCTAssertEqual(preview.versionCode, 1)
            XCTAssertEqual(preview.relation, .newPackage)
            XCTAssertEqual(preview.files.count, 5)
            XCTAssertEqual(preview.files.filter { $0.splitName != nil }.count, 4)

            let installed = try await service.installImported(
                RuntimeInstallImportedRequest(ticket: preview.ticket)
            )
            let packageID = try XCTUnwrap(RuntimePackageID(rawValue: Self.splitPackageName))
            XCTAssertEqual(installed.packageID, packageID)
            XCTAssertEqual(installed.versionCode, 1)

            let inventory = try await service.listPackages(RuntimeListPackagesRequest(filter: .all))
            XCTAssertEqual(inventory.source, .liveAndroid)
            let installedPackage = try XCTUnwrap(inventory.packages.first { $0.packageID == packageID })
            XCTAssertEqual(installedPackage.versionCode, 1)
            XCTAssertTrue(installedPackage.managed)

            let details = try await service.packageInfo(RuntimePackageRequest(packageID: packageID))
            XCTAssertEqual(details.summary.versionCode, 1)
            XCTAssertEqual(
                Set(details.files.map(\.name)),
                Set([
                    "base.apk",
                    "split_config.arm64_v8a.apk",
                    "split_config.xhdpi.apk",
                    "split_config.ja.apk",
                    "split_feature.apk",
                ])
            )

            let adb = try await Self.connectedClient(session)
            let packagePaths = try await adb.shell("pm path \(Self.splitPackageName)")
            XCTAssertEqual(packagePaths.status, 0, packagePaths.output)
            let installedAPKNames = packagePaths.output
                .split(whereSeparator: \.isNewline)
                .compactMap { line -> String? in
                    guard line.hasPrefix("package:") else { return nil }
                    return URL(fileURLWithPath: String(line.dropFirst("package:".count))).lastPathComponent
                }
            XCTAssertEqual(installedAPKNames.count, 5, "PackageManager did not report five unique base and split APKs.")
            XCTAssertEqual(
                Set(installedAPKNames),
                Set([
                    "base.apk",
                    "split_config.arm64_v8a.apk",
                    "split_config.xhdpi.apk",
                    "split_config.ja.apk",
                    "split_feature.apk",
                ])
            )
        }
    }

    /// RuntimeAPI refuses a lower-version import even when a client sets the legacy allowDowngrade flag.
    func testRejectsHelloTextDowngradeWhenAllowDowngradeIsSet() async throws {
        let versionOneAPK = try Self.fixtureAPK()
        let versionTwoAPK = try Self.fixtureAPKVersionTwo()
        let guestAgentBundle = try Self.guestAgentBundle()
        try await AndroidBootSession.withBoot(developerMode: true, guestAgentBundle: guestAgentBundle) { session in
            let service = try await Self.packageService(for: session)
            let installed = try await Self.install(versionTwoAPK, using: service)
            XCTAssertEqual(installed.versionCode, 2)

            let downgrade = try await Self.importPackage([versionOneAPK], using: service)
            XCTAssertEqual(downgrade.relation, .downgrade(from: 2))
            do {
                _ = try await service.installImported(
                    RuntimeInstallImportedRequest(
                        ticket: downgrade.ticket,
                        options: RuntimeInstallOptions(allowDowngrade: true)
                    )
                )
                XCTFail("RuntimeAPI must reject lower versions even when allowDowngrade is true.")
            } catch let failure as RuntimeWireError {
                XCTAssertEqual(failure.code, "store.downgradeRefused")
            }

            let packageID = try Self.runtimePackageID()
            let inventory = try await service.listPackages(RuntimeListPackagesRequest(filter: .all))
            XCTAssertEqual(inventory.source, .liveAndroid)
            let stillInstalled = try XCTUnwrap(inventory.packages.first { $0.packageID == packageID })
            XCTAssertEqual(stillInstalled.versionCode, 2)
            let details = try await service.packageInfo(RuntimePackageRequest(packageID: packageID))
            XCTAssertEqual(details.summary.versionCode, 2)
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

    /// RuntimeAPI retains app data on uninstall and restores it when reinstalled, checked with HelloText's debug counter.
    func testUninstallKeepingDataAndReinstallHelloText() async throws {
        let apk = try Self.fixtureAPK()
        let guestAgentBundle = try Self.guestAgentBundle()
        try await AndroidBootSession.withBoot(developerMode: true, guestAgentBundle: guestAgentBundle) { session in
            let service = try await Self.packageService(for: session)
            let adb = try await Self.connectedClient(session)
            let packageID = try Self.runtimePackageID()
            _ = try await Self.install(apk, using: service)
            let increment = try await adb.shell(
                "am broadcast -a \(Self.counterIncrementAction) -p \(Self.packageName)"
            )
            XCTAssertEqual(increment.status, 0, increment.output)
            let counterBeforeUninstall = try await Self.persistedCounter(using: adb)
            XCTAssertEqual(counterBeforeUninstall, 1)

            try await service.uninstallPackage(
                RuntimeUninstallPackageRequest(
                    packageID: packageID,
                    options: RuntimeUninstallOptions(keepData: true)
                )
            )
            let retained = try await service.listPackages(RuntimeListPackagesRequest(filter: .all))
            XCTAssertEqual(retained.source, .liveAndroid)
            let retainedPackage = try XCTUnwrap(retained.packages.first { $0.packageID == packageID })
            XCTAssertEqual(retainedPackage.state, .uninstalledKeepingData)

            let preview = try await Self.importPackage([apk], using: service)
            XCTAssertEqual(preview.relation, .uninstalledWithData(1))
            let reinstalled = try await service.installImported(
                RuntimeInstallImportedRequest(ticket: preview.ticket)
            )
            XCTAssertEqual(reinstalled.packageID, packageID)
            XCTAssertEqual(reinstalled.versionCode, 1)
            XCTAssertEqual(reinstalled.state, .installed)
            let counterAfterReinstall = try await Self.persistedCounter(using: adb)
            XCTAssertEqual(counterAfterReinstall, 1)

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
        let preview = try await importPackage([apk], using: service)
        return try await service.installImported(RuntimeInstallImportedRequest(ticket: preview.ticket))
    }

    private static func importPackage(
        _ apks: [URL],
        using service: EmbeddedPackageService
    ) async throws -> RuntimeImportPreview {
        let files = try apks.map { try FileHandle(forReadingFrom: $0) }
        defer {
            for file in files {
                try? file.close()
            }
        }
        return try await service.importPackage(
            RuntimeImportPackageRequest(
                files: apks.enumerated().map {
                    RuntimeImportSourceFile(fileIndex: $0.offset, name: $0.element.lastPathComponent)
                },
                origin: .cli
            ),
            files: files
        )
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

    private static func persistedCounter(
        using adb: AdbClient,
        timeout: Duration = .seconds(5)
    ) async throws -> Int {
        _ = try await adb.shell("logcat -c")
        let read = try await adb.shell("am broadcast -a \(counterReadAction) -p \(packageName)")
        guard read.status == 0 else {
            XCTFail("HelloText's debug counter read failed: \(read.output)")
            return -1
        }

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let logs = try await adb.shell("logcat -d -s APKRUN-FIXTURE")
            if let count = logs.output
                .split(whereSeparator: \.isNewline)
                .filter({ $0.contains(persistedCounterPrefix) })
                .compactMap({ line -> Int? in
                    guard let value = line.split(whereSeparator: \.isWhitespace).last else { return nil }
                    return Int(value)
                })
                .last
            {
                return count
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("HelloText did not report its persisted counter before the deadline.")
        return -1
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

    /// The debug HelloText fixture APK of `APKRUN_FIXTURE_APK`, copied to /tmp before the run (environment-setup §4).
    /// Its debug receiver lets the keep-data test observe persisted app state. The checkout is not read, because a read
    /// under ~/Documents waits for the privacy decision (IR-438, IR-1253).
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

    private static func fixtureAPKVersionTwo() throws -> URL {
        try stagedFixture(
            environmentKey: "APKRUN_FIXTURE_APK_V2",
            missingMessage:
                "APKRUN_FIXTURE_APK_V2 does not name the HelloText versionCode 2 fixture (environment-setup §4)."
        )
    }

    private static func helloSplitAPKs() throws -> [URL] {
        guard let path = ProcessInfo.processInfo.environment["APKRUN_FIXTURE_HELLOSPLIT_DIR"], !path.isEmpty else {
            let message =
                "APKRUN_FIXTURE_HELLOSPLIT_DIR does not name the staged HelloSplit APK set (environment-setup §4)."
            if ProcessInfo.processInfo.environment["APKRUN_CI"] == "1" {
                XCTFail(message)
            }
            throw XCTSkip(message)
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let names = [
            "base-master.apk",
            "base-arm64_v8a.apk",
            "base-xhdpi.apk",
            "base-ja.apk",
            "feature-master.apk",
        ]
        let apks = names.map { directory.appendingPathComponent($0) }
        guard apks.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            let message = "The staged HelloSplit directory is missing one or more verified split APKs."
            if ProcessInfo.processInfo.environment["APKRUN_CI"] == "1" {
                XCTFail(message)
            }
            throw XCTSkip(message)
        }
        return apks
    }

    private static func stagedFixture(environmentKey: String, missingMessage: String) throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[environmentKey], !path.isEmpty,
            FileManager.default.fileExists(atPath: path)
        else {
            if ProcessInfo.processInfo.environment["APKRUN_CI"] == "1" {
                XCTFail(missingMessage)
            }
            throw XCTSkip(missingMessage)
        }
        return URL(fileURLWithPath: path)
    }
}
