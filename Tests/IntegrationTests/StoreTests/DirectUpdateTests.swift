import APKStoreCore
import DiagnosticsCore
import Foundation
import RuntimeAPI
import RuntimeCore
import RuntimeHost
import UpdateCore
import XCTest

/// DirectProvider end to end through `update-server.py` (#51 T2).
///
/// The tests run in the `AndroidStore` configuration of IntegrationTests.xctestplan on the custom
/// image with the Store Agent. They need the HelloUpdate V1+V2 fixture APKs and the Guest Agent
/// bundle staged outside the checkout (`APKRUN_*` in the test plan).
final class DirectUpdateTests: XCTestCase {
    private static let packageName = "io.apkrun.fixture.helloupdate"

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["APKRUN_INTEGRATION_SUITE"] == "android-store"
        else {
            throw XCTSkip("The Direct provider checks run in the AndroidStore configuration.")
        }
    }

    /// update-system.md §4.4, §12: HelloUpdate V1 → V2 through a `direct:` provider on
    /// `update-server.py`; the relaunched V2 still reads V1's `data HELLO`.
    func testV1ToV2ThroughDirectProviderKeepsData() async throws {
        let v1 = try Self.fixture("APKRUN_HELLOUPDATE_V1_APK", label: "HelloUpdate V1")
        let v2 = try Self.fixture("APKRUN_HELLOUPDATE_V2_APK", label: "HelloUpdate V2")
        let guestAgentBundle = try Self.guestAgentBundle()
        let server = try Self.UpdateServer(rootPackage: Self.packageName)
        defer { server.stop() }
        try server.stage(version: 1, apk: v1)
        try server.stage(version: 2, apk: v2)

        try await AndroidBootSession.withBoot(
            developerMode: true, guestAgentBundle: guestAgentBundle
        ) { session in
            let service = try await Self.packageService(for: session)
            _ = try await Self.install(v1, using: service)
            let packageID = try Self.packageID()
            let adb = try await Self.connectedClient(session)

            // Launch V1 so it writes `data HELLO` into its private storage.
            try await adb.startActivity(
                component: "\(Self.packageName)/.MainActivity")

            let updates = await Self.updateService(for: service, paths: session.paths)
            try await updates.open()
            try await updates.setUpdatePolicy(
                packageID: packageID,
                policy: UpdatePolicy(
                    choice: .automatic,
                    provider: .set(
                        ProviderSpec(spec: "direct:\(server.manifestURL(version: 2))"))))
            let outcome = await updates.updatePackageNow(
                packageID,
                context: await updates.providerContext(userInitiated: true),
                runtime: ReadyDirectRuntime(), closeRunningApp: true)
            guard case .updated(_, let to) = outcome else {
                XCTFail("HelloUpdate V2 did not install: \(String(describing: outcome))")
                return
            }
            XCTAssertEqual(to, 2)

            // Relaunch V2: the fixture logs `data HELLO` + `version 2` when the
            // data V1 wrote survives (fixture contract, test-strategy.md §4.3).
            try await adb.startActivity(
                component: "\(Self.packageName)/.MainActivity")
            let deadline = Date().addingTimeInterval(120)
            var marker = false
            while !marker, Date() < deadline {
                let log = try await adb.logcatDump()
                if log.contains("data HELLO"), log.contains("version 2") { marker = true }
                try await Task.sleep(for: .seconds(5))
            }
            XCTAssertTrue(marker, "the updated V2 never logged `data HELLO`/`version 2`")
        }
    }

    /// FR-UPD-14 / V5: a manifest whose versionCode disagrees with the staged APK
    /// refuses with `providerMetadataMismatch`, and nothing installs.
    func testVersionCodeMismatchRefused() async throws {
        let v1 = try Self.fixture("APKRUN_HELLOUPDATE_V1_APK", label: "HelloUpdate V1")
        let v2 = try Self.fixture("APKRUN_HELLOUPDATE_V2_APK", label: "HelloUpdate V2")
        let guestAgentBundle = try Self.guestAgentBundle()
        let server = try Self.UpdateServer(rootPackage: Self.packageName)
        defer { server.stop() }
        // The manifest claims 3 while the served APK is versionCode 2.
        try server.stage(version: 3, apk: v2)

        try await AndroidBootSession.withBoot(
            developerMode: true, guestAgentBundle: guestAgentBundle
        ) { session in
            let service = try await Self.packageService(for: session)
            _ = try await Self.install(v1, using: service)
            let packageID = try Self.packageID()
            let updates = await Self.updateService(for: service, paths: session.paths)
            try await updates.open()
            try await updates.setUpdatePolicy(
                packageID: packageID,
                policy: UpdatePolicy(
                    choice: .automatic,
                    provider: .set(
                        ProviderSpec(spec: "direct:\(server.manifestURL(version: 3))"))))
            let outcome = await updates.updatePackageNow(
                packageID,
                context: await updates.providerContext(userInitiated: true),
                runtime: ReadyDirectRuntime(), closeRunningApp: true)
            guard case .skipped(_, let mismatch) = outcome,
                "\(String(describing: mismatch))".contains("providerMetadataMismatch")
            else {
                XCTFail("a versionCode mismatch must refuse, got \(String(describing: outcome))")
                return
            }
            XCTAssertEqual(try Self.record(for: packageID, in: session.paths).versionCode, 1)
        }
    }

    /// §5.3 / V4: a wrong manifest `sha256` fails the download with `hashMismatch`
    /// after one retry; the package keeps V1.
    func testWrongSha256RefusedWhileDownloading() async throws {
        let v1 = try Self.fixture("APKRUN_HELLOUPDATE_V1_APK", label: "HelloUpdate V1")
        let v2 = try Self.fixture("APKRUN_HELLOUPDATE_V2_APK", label: "HelloUpdate V2")
        let guestAgentBundle = try Self.guestAgentBundle()
        let server = try Self.UpdateServer(rootPackage: Self.packageName)
        defer { server.stop() }
        try server.stage(version: 2, apk: v2)
        try server.corruptSha256(version: 2)

        try await AndroidBootSession.withBoot(
            developerMode: true, guestAgentBundle: guestAgentBundle
        ) { session in
            let service = try await Self.packageService(for: session)
            _ = try await Self.install(v1, using: service)
            let packageID = try Self.packageID()
            let updates = await Self.updateService(for: service, paths: session.paths)
            try await updates.open()
            try await updates.setUpdatePolicy(
                packageID: packageID,
                policy: UpdatePolicy(
                    choice: .automatic,
                    provider: .set(
                        ProviderSpec(spec: "direct:\(server.corruptManifestURL)"))))
            let outcome = await updates.updatePackageNow(
                packageID,
                context: await updates.providerContext(userInitiated: true),
                runtime: ReadyDirectRuntime(), closeRunningApp: true)
            guard case .skipped(_, let mismatch) = outcome,
                "\(String(describing: mismatch))".contains("hashMismatch")
            else {
                XCTFail("a wrong sha256 must refuse, got \(String(describing: outcome))")
                return
            }
            XCTAssertEqual(try Self.record(for: packageID, in: session.paths).versionCode, 1)
        }
    }

    // MARK: - update-server.py

    /// A `scripts/dev/update-server.py` serving a per-test root on a random
    /// loopback port; `local/<package>/<version>/<file>` entries are staged by
    /// `stage(version:apk:)`.
    final class UpdateServer: @unchecked Sendable {
        private final class Banner: @unchecked Sendable {
            var data = Data()
        }

        let baseURL: URL
        let root: URL
        private let process: Process
        private let packageName: String

        init(rootPackage: String) throws {
            packageName = rootPackage
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("apkrun-direct-server-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("local"), withIntermediateDirectories: true)
            let repoRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            let script = repoRoot.appendingPathComponent("scripts/dev/update-server.py")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", script.path, "--root", root.path, "--port", "0"]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            let banner = Banner()
            let ready = DispatchSemaphore(value: 0)
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                banner.data.append(chunk)
                if chunk.contains(0x0A) { ready.signal() }
            }
            try process.run()
            if ready.wait(timeout: .now() + 15) == .timedOut {
                process.terminate()
                throw XCTSkip("update-server.py did not print its base URL")
            }
            stdout.fileHandleForReading.readabilityHandler = nil
            guard let line = String(data: banner.data, encoding: .utf8)?.split(separator: "\n").first,
                let base = line.split(separator: " ").dropFirst().first,
                let url = URL(string: String(base))
            else {
                process.terminate()
                throw XCTSkip("update-server.py did not print its base URL")
            }
            baseURL = url
            self.process = process
        }

        func stop() {
            process.terminate()
        }

        /// Stages `apk` as `local/<package>/<version>/base.apk`; the manifest
        /// is synthesized by the server with the real hash and size.
        func stage(version: Int, apk: URL) throws {
            let directory = root.appendingPathComponent("local/\(packageName)/\(version)")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: apk, to: directory.appendingPathComponent("base.apk"))
        }

        /// Replaces the synthesized manifest's `sha256` with a wrong value so
        /// the download verification fails.
        /// Writes `direct/bad.json`: a manifest for `version` whose `sha256` is
        /// wrong on purpose; `corruptManifestURL` serves it.
        func corruptSha256(version: Int) throws {
            let directory = root.appendingPathComponent("direct")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let manifest = """
                {"schemaVersion":1,"packageId":"\(packageName)","versionCode":\(version),\
                "versionName":"\(version).0","artifacts":[{"type":"apk","url":\
                "\(baseURL.absoluteString)local/\(packageName)/\(version)/base.apk",\
                "sha256":"0000000000000000000000000000000000000000000000000000000000000000"}]}
                """
            try manifest.write(
                to: directory.appendingPathComponent("bad.json"),
                atomically: true, encoding: .utf8)
        }

        var corruptManifestURL: String {
            "\(baseURL.absoluteString)direct/bad.json"
        }

        func manifestURL(version: Int) -> String {
            "\(baseURL.absoluteString)/local/\(packageName)/\(version)/manifest.json"
        }
    }

    // MARK: - helpers (mirror UpdateOwnershipTests)

    private static func packageService(for session: AndroidBootSession) async throws
        -> EmbeddedPackageService
    {
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

    private static func updateService(
        for service: EmbeddedPackageService, paths: APKRunPaths
    ) async -> EmbeddedUpdateService {
        EmbeddedUpdateService(paths: paths, store: await service.store)
    }

    private static func install(_ apk: URL, using service: EmbeddedPackageService) async throws
        -> RuntimePackageSummary
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
        return try await service.installImported(
            RuntimeInstallImportedRequest(ticket: preview.ticket))
    }

    private static func record(for packageID: PackageID, in paths: APKRunPaths) throws
        -> PackageRecord
    {
        let metadata = paths.packagesDirectory
            .appendingPathComponent(packageID.rawValue, isDirectory: true)
            .appendingPathComponent("metadata.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            PackageRecord.self, from: Data(contentsOf: metadata))
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

    private static func guestAgentBundle() throws -> GuestAgentBundle {
        guard let path = AndroidTestEnvironment.current()["APKRUN_GUEST_DIR"], !path.isEmpty else {
            throw XCTSkip(
                "APKRUN_GUEST_DIR is not set. Build the Guest Agent bundle with scripts/build-guest.sh --out.")
        }
        do {
            return try GuestAgentBundle.load(
                directory: URL(fileURLWithPath: path, isDirectory: true))
        } catch {
            throw XCTSkip(
                "The Guest Agent bundle in \(path) could not be read: \(error.qualifiedCode)")
        }
    }

    private static func fixture(_ environmentKey: String, label: String) throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[environmentKey], !path.isEmpty,
            FileManager.default.fileExists(atPath: path)
        else {
            let message =
                "\(environmentKey) does not name the \(label) fixture (environment-setup §4)."
            if ProcessInfo.processInfo.environment["APKRUN_CI"] == "1" {
                XCTFail(message)
            }
            throw XCTSkip(message)
        }
        return URL(fileURLWithPath: path)
    }
}

/// The boot is already ready in these tests; the update pipeline needs no further runtime control.
private struct ReadyDirectRuntime: UpdateRuntimeAccess {
    var runtimeState: WireRuntimeState { .ready }
    func hasActiveUse(_ package: PackageID) async -> Bool { false }
    func ensureReady(_: UpdateStartReason) async throws {}
}
