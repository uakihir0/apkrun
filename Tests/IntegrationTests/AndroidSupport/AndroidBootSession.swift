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

    static func start(developerMode: Bool) async throws -> AndroidBootSession {
        let bundle = try bundleDirectory()
        let image = try DevelopmentImage.load(directory: bundle)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-015-adb-\(UUID().uuidString)", isDirectory: true)
        let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": home.path])
        let store = InstanceStore(paths: paths, diagnostics: .live(paths: paths))
        _ = try await store.resetAndroid(image: image, sizing: .default)
        let diagnostics = DiagnosticsContext.live(paths: paths)
        let supervisor = RuntimeSupervisor(
            image: image,
            instanceStore: store,
            options: BootOptions(gpuProfile: .headless, developerMode: developerMode, captureLogcat: false),
            diagnostics: diagnostics,
            environment: AndroidTestEnvironment.current()
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

    func cleanUp() {
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
