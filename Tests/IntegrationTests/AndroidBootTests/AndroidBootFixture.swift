import DiagnosticsCore
import Foundation
import ImageCore
import RuntimeCore
import XCTest

/// One development Android boot in a private `APKRUN_HOME`, shared by the T2 Android tests (#012-#014).
///
/// The fixture uses the product path: `DevelopmentImage`, `InstanceStore`, and `RuntimeSupervisor`.
/// The bundle is the one `scripts/build-test-android-bundle.sh` writes under `APKRUN_TEST_LINUX_DIR`.
struct AndroidBootFixture {
    let home: URL
    let paths: APKRunPaths
    let image: InstalledImage
    let store: InstanceStore

    /// The unsigned development bundle. It is skipped locally and fails on CI when it is missing.
    static func bundleDirectory() throws -> URL {
        let configured =
            ProcessInfo.processInfo.environment["APKRUN_TEST_LINUX_DIR"]
            ?? Bundle.main.object(forInfoDictionaryKey: "APKRUN_TEST_LINUX_DIR") as? String
        let rootPath = configured.flatMap { $0.isEmpty ? nil : $0 } ?? "/tmp/apkrun-test-linux"
        let bundle = URL(fileURLWithPath: rootPath).appendingPathComponent("android-bundle", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundle.appendingPathComponent("manifest.json").path) else {
            let message = "The Android bundle is missing. Run scripts/build-test-android-bundle.sh."
            if ProcessInfo.processInfo.environment["APKRUN_CI"] == "1"
                || Bundle.main.object(forInfoDictionaryKey: "APKRUN_CI") as? String == "1"
            {
                XCTFail(message)
            }
            throw XCTSkip(message)
        }
        return bundle
    }

    /// Creates a fixture with a fresh private home and the image in `bundle`.
    init(home: URL, bundle: URL) throws {
        self.home = home
        paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": home.path])
        image = try DevelopmentImage.load(directory: bundle)
        store = InstanceStore(paths: paths, diagnostics: .live(paths: paths))
    }

    /// A new private home under the temporary directory.
    static func makeHome() throws -> URL {
        // A short path under /tmp: the developer console socket path must fit in sockaddr_un.
        let home = URL(fileURLWithPath: "/tmp/apkrun-android-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// Provisions a fresh instance, as G2 does before its first boot.
    func resetInstance() async throws {
        _ = try await store.resetAndroid(image: image, sizing: .default)
    }

    /// A supervisor for one boot with the headless profile, as `apkrun dev boot --gpu none` uses.
    func supervisor(developerMode: Bool, timeouts: BootTimeouts = .standard) -> RuntimeSupervisor {
        RuntimeSupervisor(
            image: image,
            instanceStore: store,
            options: BootOptions(gpuProfile: .headless, developerMode: developerMode, captureLogcat: false),
            diagnostics: .live(paths: paths),
            timeouts: timeouts
        )
    }

    /// The newest per-boot console copy, `boot-<timestamp>.log` (diagnostics.md §3.1).
    func newestBootLog() throws -> String {
        let directory = paths.vmLogsDirectory
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("boot-") && $0.pathExtension == "log" }
        guard let newest = files.max(by: { $0.lastPathComponent < $1.lastPathComponent }) else {
            throw FixtureFailure.noBootLog(directory.path)
        }
        return String(decoding: try Data(contentsOf: newest), as: UTF8.self)
    }

    /// Copies `bundle` into `home/truncated-bundle` with `boot/ramdisk.img` cut to half its size.
    ///
    /// The manifest's size for the ramdisk is updated to match, because `DevelopmentImage.load`
    /// checks the listed sizes. Everything else is copied unchanged.
    static func truncatedBundle(from bundle: URL, into home: URL) throws -> URL {
        let destination = home.appendingPathComponent("truncated-bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let manifestURL = bundle.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any] ?? [:]
        var files = manifest["files"] as? [[String: Any]] ?? []
        let ramdiskPath = "boot/ramdisk.img"
        let ramdiskSource = bundle.appendingPathComponent(ramdiskPath)
        let ramdiskSize =
            (try FileManager.default.attributesOfItem(atPath: ramdiskSource.path)[.size] as? NSNumber)?
            .intValue ?? 0
        let truncatedSize = ramdiskSize / 2
        for index in files.indices where files[index]["path"] as? String == ramdiskPath {
            files[index]["size"] = truncatedSize
        }
        manifest["files"] = files
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: destination.appendingPathComponent("manifest.json"))

        for entry in files {
            guard let path = entry["path"] as? String, path != "manifest.json" else { continue }
            let target = destination.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if path == ramdiskPath {
                let handle = try FileHandle(forReadingFrom: ramdiskSource)
                defer { try? handle.close() }
                try handle.read(upToCount: truncatedSize)?.write(to: target)
            } else {
                try FileManager.default.copyItem(at: bundle.appendingPathComponent(path), to: target)
            }
        }
        return destination
    }

    /// Removes the private home.
    func remove() {
        try? FileManager.default.removeItem(at: home)
    }
}

/// A fixture step that could not produce its evidence. XCTest reports it as a test failure.
enum FixtureFailure: Error, CustomStringConvertible {
    case noBootLog(String)

    var description: String {
        switch self {
        case .noBootLog(let directory): "no boot log was written under \(directory)"
        }
    }
}

/// Collects console bytes from a supervisor's event stream for the T2 Android tests.
final class ConsoleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    /// Adds console bytes in arrival order.
    func append(_ data: Data) {
        lock.withLock { bytes.append(data) }
    }

    /// The console text so far.
    var text: String {
        lock.withLock { String(decoding: bytes, as: UTF8.self) }
    }

    /// Polls the text until `condition` holds or `budget` ends. Returns whether it held.
    func wait(within budget: Duration, until condition: (String) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + budget
        while true {
            if condition(text) {
                return true
            }
            if ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}

extension ConsoleBuffer {
    /// Runs `operation` and reports whether it returned within `budget`. The operation keeps running
    /// after a timeout, so a hung stop cannot hang the test process.
    static func completes(within budget: Duration, _ operation: @escaping @Sendable () async -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            let gate = OnceGate(continuation)
            Task {
                await operation()
                gate.resume(true)
            }
            Task {
                try? await Task.sleep(for: budget)
                gate.resume(false)
            }
        }
    }
}

/// Resumes a checked continuation exactly once.
private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool) {
        let pending = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
