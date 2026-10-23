import CryptoKit
import DiagnosticsCore
import Foundation
import ImageCore
import RuntimeCore
import RuntimeHost
import XCTest

/// The environment and adb of the Android T2 suites (#16, #17, #18).
enum AndroidTestEnvironment {
    enum Failure: Error, CustomStringConvertible {
        case adbUnavailable(searchPath: String, reason: String)

        var description: String {
            switch self {
            case .adbUnavailable(let searchPath, let reason):
                "APKRUN_CI=1 requires adb, but none was found under \(searchPath): \(reason)"
            }
        }
    }

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
    static func adbExecutable(environment suppliedEnvironment: [String: String]? = nil) throws -> URL {
        let environment = suppliedEnvironment ?? current()
        do {
            return try AdbClient.resolveExecutable(environment: environment)
        } catch {
            if environment["APKRUN_CI"] == "1" {
                let searchPath = [
                    environment["ANDROID_HOME"].map { "\($0)/platform-tools" },
                    environment["PATH"],
                ]
                .compactMap { $0 }
                .joined(separator: ", ")
                throw Failure.adbUnavailable(
                    searchPath: searchPath.isEmpty ? "(no search path configured)" : searchPath,
                    reason: error.qualifiedCode
                )
            }
            throw XCTSkip("adb was not found under ANDROID_HOME or on PATH: \(error.qualifiedCode)")
        }
    }
}

/// Locates either the stock T2 bundle or the explicitly selected composed image (#36).
enum AndroidTestBundleLocator {
    enum Failure: Error, CustomStringConvertible {
        case composedBundleMissing(path: String)
        case invalidManifest(path: String)
        case testImageKeyMissing
        case testOverlayFixtureMissing(path: String)
        case notComposedTestImage(path: String, kind: String)

        var description: String {
            switch self {
            case .composedBundleMissing(let path):
                "The AndroidCustom suite requires a composed image bundle at \(path)."
            case .invalidManifest(let path):
                "The selected Android bundle has no readable manifest at \(path)."
            case .testImageKeyMissing:
                "The AndroidCustom test image public key is missing or invalid in the test bundle."
            case .testOverlayFixtureMissing(let path):
                "The AndroidCustom test overlay fixture is missing from the test bundle: \(path)."
            case .notComposedTestImage(let path, let kind):
                "AndroidCustom selected a \(kind) image at \(path); it requires kind: apkrun, composition provenance, and the fixed AndroidImageProduct test overlay."
            }
        }
    }

    private static let testOverlayFixtures: [(path: String, resource: String, fileExtension: String)] = [
        ("Tests/Fixtures/AndroidImageProduct/compose.json", "compose", "json"),
        ("Tests/Fixtures/AndroidImageProduct/init/apkrun-test.rc", "apkrun-test", "rc"),
    ]

    static func bundleDirectory() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let configured = configuredValue(
            "APKRUN_TEST_ANDROID_BUNDLE",
            environment: environment
        )

        let customSuite = environment["APKRUN_INTEGRATION_SUITE"] == "android-custom"
        let bundle: URL
        if let configured, !configured.isEmpty {
            bundle = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            let configuredRoot = configuredValue(
                "APKRUN_TEST_LINUX_DIR",
                environment: environment
            )
            let rootPath = configuredRoot.flatMap { $0.isEmpty ? nil : $0 } ?? "/tmp/apkrun-test-linux"
            bundle = URL(fileURLWithPath: rootPath)
                .appendingPathComponent("android-bundle", isDirectory: true)
        }

        guard FileManager.default.fileExists(atPath: bundle.appendingPathComponent("manifest.json").path) else {
            if customSuite {
                throw Failure.composedBundleMissing(path: bundle.path)
            }
            let source =
                configured == nil
                ? "Run scripts/build-test-android-bundle.sh."
                : "Set APKRUN_TEST_ANDROID_BUNDLE to a complete signed image bundle."
            let message = "The selected Android bundle is missing at \(bundle.path). \(source)"
            if environment["APKRUN_CI"] == "1"
                || Bundle.main.object(forInfoDictionaryKey: "APKRUN_CI") as? String == "1"
            {
                XCTFail(message)
            }
            throw XCTSkip(message)
        }

        if customSuite {
            let manifestURL = bundle.appendingPathComponent("manifest.json")
            guard
                let manifestData = try? Data(contentsOf: manifestURL),
                let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
                let kind = manifest["kind"] as? String
            else {
                throw Failure.invalidManifest(path: manifestURL.path)
            }
            let testOverlayHashes = try Self.expectedTestOverlayHashes()
            guard Self.isComposedTestManifest(manifest, testOverlayHashes: testOverlayHashes) else {
                throw Failure.notComposedTestImage(path: bundle.path, kind: kind)
            }
        }
        return bundle
    }

    static func expectedTestOverlayHashes() throws -> [String: String] {
        let bundle = Bundle(for: IntegrationTestsBundleMarker.self)
        var hashes: [String: String] = [:]
        for fixture in testOverlayFixtures {
            guard
                let url = bundle.url(
                    forResource: fixture.resource,
                    withExtension: fixture.fileExtension
                ),
                let data = try? Data(contentsOf: url)
            else {
                throw Failure.testOverlayFixtureMissing(path: fixture.path)
            }
            hashes[fixture.path] = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        }
        return hashes
    }

    static func isComposedTestManifest(
        _ manifest: [String: Any],
        testOverlayHashes: [String: String]
    ) -> Bool {
        guard manifest["kind"] as? String == "apkrun",
            let provenance = manifest["provenance"] as? [String: Any],
            let composition = provenance["composition"] as? [String: Any],
            let inputs = composition["testOverlayInputs"] as? [[String: Any]],
            testOverlayHashes.count == testOverlayFixtures.count,
            Set(testOverlayHashes.keys) == Set(testOverlayFixtures.map(\.path))
        else {
            return false
        }
        var observedHashes: [String: String] = [:]
        for input in inputs {
            guard let path = input["path"] as? String,
                let hash = input["sha256"] as? String,
                observedHashes.updateValue(hash, forKey: path) == nil
            else {
                return false
            }
        }
        return observedHashes == testOverlayHashes
    }

    /// Adds the fixture signer only to the AndroidCustom test process trust list.
    static func imageTrustStore() throws -> ImageTrustStore {
        let standard = ImageTrustStore.standard()
        guard ProcessInfo.processInfo.environment["APKRUN_INTEGRATION_SUITE"] == "android-custom" else {
            return standard
        }
        guard
            let keyURL = Bundle(for: IntegrationTestsBundleMarker.self)
                .url(forResource: "test-image-ed25519", withExtension: "pub"),
            let text = try? String(contentsOf: keyURL, encoding: .utf8),
            let publicKey = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            publicKey.count == 32
        else {
            throw Failure.testImageKeyMissing
        }
        let fixtureKey = ImageTrustStore.Key(publicKey: publicKey)
        return ImageTrustStore(keys: standard.keys + [fixtureKey])
    }

    private static func configuredValue(
        _ key: String,
        environment: [String: String]
    ) -> String? {
        let value =
            environment[key]
            ?? Bundle.main.object(forInfoDictionaryKey: key) as? String
        guard let value, !value.isEmpty, !value.contains("$(") else {
            return nil
        }
        return value
    }
}

private final class IntegrationTestsBundleMarker: NSObject {}

/// One supervised boot of the test Android image in a private APKRUN_HOME (#16, #17, #18 T2).
final class AndroidBootSession: @unchecked Sendable {
    let supervisor: RuntimeSupervisor
    let capture: ConsoleCapture
    let paths: APKRunPaths
    let runtimeContext: DevelopmentRuntimeContext
    private let home: URL
    private let captureTask: Task<Void, Never>

    private init(
        supervisor: RuntimeSupervisor,
        capture: ConsoleCapture,
        paths: APKRunPaths,
        runtimeContext: DevelopmentRuntimeContext,
        home: URL,
        captureTask: Task<Void, Never>
    ) {
        self.supervisor = supervisor
        self.capture = capture
        self.paths = paths
        self.runtimeContext = runtimeContext
        self.home = home
        self.captureTask = captureTask
    }

    /// Starts a boot whose supervisor installs and starts `guestAgentBundle` in developer mode (#73). Nil boots without the agent.
    static func start(
        developerMode: Bool,
        guestAgentBundle: GuestAgentBundle? = nil,
        gpuProfile: GPUProfileID = .headless
    ) async throws -> AndroidBootSession {
        let bundle = try bundleDirectory()
        // The run's own home and developer ADB port (test-strategy §3.10).
        let run = try VMRunResources.new(environment: ProcessInfo.processInfo.environment)
        let home = run.home
        let paths = run.paths
        // The signed bundle goes through the install path of `apkrun dev image install`, as the G2 check does.
        let trust = try AndroidTestBundleLocator.imageTrustStore()
        let images = ImageStore(paths: paths, trust: trust, diagnostics: .live(paths: paths))
        let image = try await images.install(from: .directory(bundle))
        let store = InstanceStore(paths: paths, diagnostics: .live(paths: paths))
        _ = try await store.resetAndroid(image: image, sizing: .default)
        let diagnostics = DiagnosticsContext.live(paths: paths)
        let supervisor = RuntimeSupervisor(
            image: image,
            instanceStore: store,
            options: BootOptions(
                gpuProfile: gpuProfile,
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
        return AndroidBootSession(
            supervisor: supervisor,
            capture: capture,
            paths: paths,
            runtimeContext: DevelopmentRuntimeContext(
                image: image,
                instanceStore: store,
                supervisor: supervisor,
                diagnostics: diagnostics
            ),
            home: home,
            captureTask: captureTask
        )
    }

    /// Runs `body` on a fresh boot, and stops Android and removes the instance afterwards, also when `body` throws.
    static func withBoot(
        developerMode: Bool,
        guestAgentBundle: GuestAgentBundle? = nil,
        gpuProfile: GPUProfileID = .headless,
        _ body: (AndroidBootSession) async throws -> Void
    ) async throws {
        let session: AndroidBootSession
        do {
            session = try await start(
                developerMode: developerMode,
                guestAgentBundle: guestAgentBundle,
                gpuProfile: gpuProfile
            )
        } catch {
            reportImageFailure(error)
            throw error
        }
        do {
            try await session.supervisor.ensureReady(.cli)
            try await body(session)
        } catch {
            await session.finish()
            reportImageFailure(error)
            throw error
        }
        await session.finish()
    }

    private static func reportImageFailure(
        _ error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let failure = error as? ImageFailure else {
            return
        }
        XCTFail(
            "Android image operation failed with \(failure.qualifiedCode): \(failure.parameters)",
            file: file,
            line: line
        )
    }

    /// Stops Android if it runs, then removes the run's home. A stop that has already happened does nothing. The
    /// home is removed with its read-only image restored to writable first, and a failure is reported in the test
    /// output with its path (VMRunResources.removeHome).
    func finish() async {
        await supervisor.stop()
        captureTask.cancel()
        VMRunResources.removeHomeOrReport(home)
    }

    static func bundleDirectory() throws -> URL {
        try AndroidTestBundleLocator.bundleDirectory()
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

    func wait(for marker: String, within budget: Duration) async -> Bool {
        let deadline = ContinuousClock.now + budget
        while true {
            if console().contains(marker) {
                return true
            }
            if ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}
