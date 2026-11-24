import APKStoreCore
import DiagnosticsCore
import Foundation
import RuntimeAPI
import RuntimeCore
import RuntimeHost
import UpdateCore
import XCTest

/// Split-set install through a booted guest (#43 T2).
///
/// The tests run in the `AndroidStore` configuration of IntegrationTests.xctestplan. They need
/// the HelloSplit `.apks` container staged outside the checkout (`APKRUN_HELLOSPLIT_APKS`) and,
/// on the custom image, the Guest Agent bundle (`APKRUN_GUEST_DIR`). The macOS-Japanese check is
/// C05-9 in #86; here the guest locale is set directly in developer mode.
final class SplitInstallTests: XCTestCase {
    private static let packageName = "io.apkrun.fixture.hellosplit"
    private static let mainActivity = "io.apkrun.fixture.hellosplit/.MainActivity"
    private static let featureActivity =
        "io.apkrun.fixture.hellosplit/io.apkrun.fixture.hellosplit.feature.FeatureActivity"
    private static let storedSplits = [
        "config.arm64_v8a", "config.ja", "config.xhdpi", "feature",
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["APKRUN_INTEGRATION_SUITE"] == "android-store" else {
            throw XCTSkip("The split checks run in the AndroidStore test-plan configuration.")
        }
    }

    /// The `.apks` container imports, installs in one session, launches, loads its native
    /// library, resolves the xhdpi density resource, and Android lists every split.
    func testHelloSplitInstallsLaunchesAndListsSplits() async throws {
        let apks = try Self.fixture("APKRUN_HELLOSPLIT_APKS", label: "HelloSplit .apks")
        try await AndroidBootSession.withBoot(developerMode: true) { session in
            let service = try await Self.packageService(for: session)
            let adb = try await Self.connectedClient(session)

            let summary = try await Self.importContainer(apks, using: service)
            XCTAssertEqual(summary.packageID.rawValue, Self.packageName)

            try await adb.startActivity(component: Self.mainActivity)
            let native = try await Self.waitForLog("native ok", via: adb)
            XCTAssertTrue(native.contains("native ok"), "native library did not load: \(native)")

            // The density split SplitSelector kept must resolve at runtime (OQ-14).
            let dump = try await adb.shell("pm dump \(Self.packageName)")
            let splitLine = dump.output.split(whereSeparator: \.isNewline)
                .map(String.init)
                .first { $0.contains("splits=[") }
            let listed = try XCTUnwrap(splitLine, "PackageManager lists no splits")
            for split in Self.storedSplits {
                XCTAssertTrue(listed.contains(split), "missing split \(split) in \(listed)")
            }

            let packageID = try Self.packageID()
            let artifactSet = try await service.store.installedArtifactSet(for: packageID)
            XCTAssertEqual(
                artifactSet?.files.map(\.name).sorted(),
                [
                    "base.apk",
                    "split_config.arm64_v8a.apk",
                    "split_config.ja.apk",
                    "split_config.xhdpi.apk",
                    "split_feature.apk",
                ])
        }
    }

    /// At guest locale ja-JP the language split resolves and the feature split launches.
    func testJapaneseLocaleAndFeatureSplit() async throws {
        let apks = try Self.fixture("APKRUN_HELLOSPLIT_APKS", label: "HelloSplit .apks")
        try await AndroidBootSession.withBoot(developerMode: true) { session in
            let service = try await Self.packageService(for: session)
            let adb = try await Self.connectedClient(session)
            _ = try await Self.importContainer(apks, using: service)

            _ = try await adb.shell(
                "cmd locale set-app-locales \(Self.packageName) --locales ja-JP")
            try await adb.startActivity(component: Self.mainActivity)
            let localized = try await Self.waitForLog("string HelloSplit", via: adb)
            XCTAssertTrue(
                localized.contains("日本語"), "ja-JP resource did not resolve: \(localized)")

            try await adb.startActivity(component: Self.featureActivity)
            let feature = try await Self.waitForLog("feature loaded", via: adb)
            XCTAssertTrue(feature.contains("feature loaded"))
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

    /// Imports the `.apks` container and installs the ticket: one BeginInstall, one commit.
    private static func importContainer(
        _ container: URL, using service: EmbeddedPackageService
    ) async throws -> RuntimePackageSummary {
        let file = try FileHandle(forReadingFrom: container)
        defer { try? file.close() }
        let preview = try await service.importPackage(
            RuntimeImportPackageRequest(
                files: [RuntimeImportSourceFile(fileIndex: 0, name: container.lastPathComponent)],
                origin: .cli
            ),
            files: [file]
        )
        return try await service.installImported(RuntimeInstallImportedRequest(ticket: preview.ticket))
    }

    /// Polls `logcat -d` until a line contains `marker` or ~60 s pass.
    private static func waitForLog(_ marker: String, via adb: AdbClient) async throws -> String {
        for _ in 0..<30 {
            let log = try await adb.logcatDump()
            if let line = log.split(whereSeparator: \.isNewline)
                .map(String.init)
                .first(where: { $0.contains("APKRUN-FIXTURE") && $0.contains(marker) })
            {
                return line
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw XCTSkip("logcat never logged '\(marker)'")
    }

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
