import DiagnosticsCore
import Foundation
import GuestProtocol
import ImageCore
import RuntimeCore
import RuntimeHost
import XCTest

/// The #36 T2 harness for a locally staged custom AOSP bundle.
///
/// The AndroidCustom test-plan configuration points APKRUN_TEST_ANDROID_CUSTOM_DIR at a directory
/// containing `android-bundle/manifest.json`. Each test gets a private APKRUN_HOME and installs
/// the bundle through ImageStore before starting the real RuntimeSupervisor.
final class AndroidCustomImageSession: @unchecked Sendable {
    let supervisor: RuntimeSupervisor
    let image: InstalledImage
    private let home: URL

    private init(supervisor: RuntimeSupervisor, image: InstalledImage, home: URL) {
        self.supervisor = supervisor
        self.image = image
        self.home = home
    }

    static func start(developerMode: Bool) async throws -> AndroidCustomImageSession {
        let bundle = try bundleDirectory()
        var environment = AndroidTestEnvironment.current()
        if environment[VMRunResources.adbPortVariable] == nil,
            let testRunnerPort = environment["TEST_RUNNER_\(VMRunResources.adbPortVariable)"]
        {
            environment[VMRunResources.adbPortVariable] = testRunnerPort
        }
        let run = try VMRunResources.new(environment: environment)
        do {
            let paths = run.paths
            let images = ImageStore(paths: paths, trust: .standard(), diagnostics: .live(paths: paths))
            let image = try await images.install(from: .directory(bundle))
            guard image.manifest.kind == .apkrun else {
                throw AndroidCustomTestFailure.wrongBundleKind(image.manifest.kind.rawValue)
            }
            let instanceStore = InstanceStore(paths: paths, diagnostics: .live(paths: paths))
            _ = try await instanceStore.resetAndroid(image: image, sizing: .default)
            let supervisor = RuntimeSupervisor(
                image: image,
                instanceStore: instanceStore,
                options: BootOptions(
                    gpuProfile: .headless,
                    developerMode: developerMode,
                    captureLogcat: false,
                    adbHostPort: run.adbHostPort
                ),
                diagnostics: .live(paths: paths),
                environment: environment,
                guestAgentTransportMode: .vsock
            )
            return AndroidCustomImageSession(supervisor: supervisor, image: image, home: run.home)
        } catch {
            VMRunResources.removeHomeOrReport(run.home)
            throw error
        }
    }

    /// Starts a fresh custom image and always stops it and removes its private home.
    static func withBoot(
        developerMode: Bool,
        _ body: (AndroidCustomImageSession) async throws -> Void
    ) async throws {
        let session = try await start(developerMode: developerMode)
        do {
            try await session.supervisor.ensureReady(.cli)
            try await body(session)
        } catch {
            await session.finish()
            throw error
        }
        await session.finish()
    }

    func finish() async {
        await supervisor.stop()
        VMRunResources.removeHomeOrReport(home)
    }

    /// Opens a Guest Agent control connection over the host-to-guest vsock path.
    static func openAgentConnection(
        _ session: AndroidCustomImageSession
    ) async throws -> (GuestConnection, GuestSessionInfo) {
        let transport = VsockGuestTransport { port, timeout in
            try await session.supervisor.connect(vsockPort: port, timeout: timeout)
        }
        let connection = GuestConnection(endpoint: .guestControl, transport: transport)
        do {
            let info = try await connection.open()
            return (connection, info)
        } catch {
            await connection.close()
            throw error
        }
    }

    static func connectedADB(_ session: AndroidCustomImageSession) async throws -> AdbClient {
        guard let port = await session.supervisor.developmentADBHostPort else {
            throw AndroidCustomTestFailure.adbForwarderUnavailable
        }
        let adb = AdbClient(
            executable: try AndroidTestEnvironment.adbExecutable(),
            endpoint: AdbClient.loopbackEndpoint(port: port)
        )
        try await adb.connect(timeout: .seconds(30))
        return adb
    }

    static func bundleDirectory() throws -> URL {
        let environment = AndroidTestEnvironment.current()
        let rootPath =
            environment["APKRUN_TEST_ANDROID_CUSTOM_DIR"]
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "/tmp/apkrun-test-android-custom"
        let bundle = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent("android-bundle", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundle.appendingPathComponent("manifest.json").path) else {
            let message =
                "The custom Android bundle is missing under \(rootPath). Stage the latest userdebug bundle there."
            if environment["APKRUN_CI"] == "1"
                || Bundle.main.object(forInfoDictionaryKey: "APKRUN_CI") as? String == "1"
            {
                XCTFail(message)
            }
            throw XCTSkip(message)
        }
        return bundle
    }

    static func helloProbeAPK() throws -> URL {
        let environment = AndroidTestEnvironment.current()
        guard let path = environment["APKRUN_FIXTURE_PROBE_APK"], !path.isEmpty,
            URL(fileURLWithPath: path).lastPathComponent == "HelloProbe.apk",
            FileManager.default.isReadableFile(atPath: path)
        else {
            let message = "APKRUN_FIXTURE_PROBE_APK must point to the built HelloProbe.apk fixture."
            if environment["APKRUN_CI"] == "1"
                || Bundle.main.object(forInfoDictionaryKey: "APKRUN_CI") as? String == "1"
            {
                XCTFail(message)
            }
            throw XCTSkip(message)
        }
        return URL(fileURLWithPath: path)
    }

    static func waitForProbeCompletion(using adb: AdbClient, timeout: Duration = .seconds(30)) async throws -> String {
        let deadline = ContinuousClock.now + timeout
        var latestLog = ""
        while ContinuousClock.now < deadline {
            latestLog = try await adb.shell("logcat -d -s APKRUN-FIXTURE").output
            if latestLog.contains("probe complete ok") {
                return latestLog
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw AndroidCustomTestFailure.probeDidNotComplete(latestLog)
    }

    static func requireAndroidCustomSuite() throws {
        guard AndroidTestEnvironment.current()["APKRUN_INTEGRATION_SUITE"] == "android-custom" else {
            throw XCTSkip("The #36 checks run in the AndroidCustom test-plan configuration.")
        }
    }
}

enum AndroidCustomTestFailure: Error, CustomStringConvertible {
    case adbForwarderUnavailable
    case probeDidNotComplete(String)
    case wrongBundleKind(String)

    var description: String {
        switch self {
        case .adbForwarderUnavailable:
            "the developer-mode ADB forwarder did not start"
        case .probeDidNotComplete(let log):
            "HelloProbe did not report completion; last logcat output:\n\(log)"
        case .wrongBundleKind(let kind):
            "AndroidCustom requires an `apkrun` image bundle, got kind `\(kind)`."
        }
    }
}
