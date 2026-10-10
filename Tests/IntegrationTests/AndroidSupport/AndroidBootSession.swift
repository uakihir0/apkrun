import DiagnosticsCore
import Foundation
import ImageCore
import RuntimeCore
import XCTest

/// The environment and adb of the Android T2 suites (#015, #016, #017).
enum AndroidTestEnvironment {
    /// The process environment, with ANDROID_HOME from the `APKRUN_ANDROID_HOME` build setting when it is not set.
    /// xcodebuild does not pass the SDK path on, so the host's Info.plist carries it (IR-324).
    static func current() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if environment["ANDROID_HOME"] == nil,
            let sdk = Bundle.main.object(forInfoDictionaryKey: "APKRUN_ANDROID_HOME") as? String,
            !sdk.isEmpty
        {
            environment["ANDROID_HOME"] = sdk
        }
        return environment
    }

    /// The adb of the SDK in `current()`. The suite is skipped when there is none.
    static func adbExecutable() throws -> URL {
        do {
            return try AdbClient.resolveExecutable(environment: current())
        } catch {
            throw XCTSkip("adb was not found under ANDROID_HOME or on PATH: \(error.qualifiedCode)")
        }
    }
}

/// One supervised boot of the test Android image in a private APKRUN_HOME (#015, #016, #017 T2).
final class AndroidBootSession: @unchecked Sendable {
    let supervisor: RuntimeSupervisor
    let capture: ConsoleCapture
    private let home: URL
    private let captureTask: Task<Void, Never>

    private init(supervisor: RuntimeSupervisor, capture: ConsoleCapture, home: URL, captureTask: Task<Void, Never>) {
        self.supervisor = supervisor
        self.capture = capture
        self.home = home
        self.captureTask = captureTask
    }

    /// Starts a boot whose supervisor installs and starts `guestAgentBundle` in developer mode (#072). Nil boots without the agent.
    static func start(developerMode: Bool, guestAgentBundle: GuestAgentBundle? = nil) async throws -> AndroidBootSession
    {
        let bundle = try bundleDirectory()
        // The run's own home and developer ADB port (test-strategy §3.10).
        let run = try VMRunResources.new(environment: ProcessInfo.processInfo.environment)
        let home = run.home
        let paths = run.paths
        // The signed bundle goes through the install path of `apkrun dev image install`, as the G2 check does.
        let images = ImageStore(paths: paths, trust: .standard(), diagnostics: .live(paths: paths))
        let image = try await images.install(from: .directory(bundle))
        let store = InstanceStore(paths: paths, diagnostics: .live(paths: paths))
        _ = try await store.resetAndroid(image: image, sizing: .default)
        let diagnostics = DiagnosticsContext.live(paths: paths)
        let supervisor = RuntimeSupervisor(
            image: image,
            instanceStore: store,
            options: BootOptions(
                gpuProfile: .headless,
                developerMode: developerMode,
                captureLogcat: false,
                adbHostPort: run.adbHostPort
            ),
            diagnostics: diagnostics,
            environment: AndroidTestEnvironment.current(),
            guestAgentBundle: guestAgentBundle
        )
        let capture = ConsoleCapture()
        let events = supervisor.events
        let captureTask = Task {
            for await event in events {
                if case .console(let bytes) = event {
                    capture.append(bytes)
                }
            }
        }
        return AndroidBootSession(supervisor: supervisor, capture: capture, home: home, captureTask: captureTask)
    }

    /// Runs `body` on a fresh boot, and stops Android and removes the instance afterwards, also when `body` throws.
    static func withBoot(
        developerMode: Bool,
        guestAgentBundle: GuestAgentBundle? = nil,
        _ body: (AndroidBootSession) async throws -> Void
    ) async throws {
        let session = try await start(developerMode: developerMode, guestAgentBundle: guestAgentBundle)
        do {
            try await session.supervisor.ensureReady(.cli)
            try await body(session)
        } catch {
            await session.finish()
            throw error
        }
        await session.finish()
    }

    /// Stops Android if it runs, then removes the instance. A stop that has already happened does nothing.
    func finish() async {
        await supervisor.stop()
        captureTask.cancel()
        try? FileManager.default.removeItem(at: home)
    }

    static func bundleDirectory() throws -> URL {
        let configured =
            ProcessInfo.processInfo.environment["APKRUN_TEST_LINUX_DIR"]
            ?? Bundle.main.object(forInfoDictionaryKey: "APKRUN_TEST_LINUX_DIR") as? String
        let rootPath = configured.flatMap { $0.isEmpty ? nil : $0 } ?? "/tmp/apkrun-test-linux"
        let bundle = URL(fileURLWithPath: rootPath).appendingPathComponent("android-bundle", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundle.appendingPathComponent("manifest.json").path) else {
            throw XCTSkip("The Android bundle is missing. Run scripts/build-test-android-bundle.sh.")
        }
        return bundle
    }
}

/// Collects the console bytes of one boot.
final class ConsoleCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    func append(_ data: Data) {
        lock.withLock { bytes.append(data) }
    }

    func console() -> String {
        lock.withLock { String(decoding: bytes, as: UTF8.self) }
    }
}
