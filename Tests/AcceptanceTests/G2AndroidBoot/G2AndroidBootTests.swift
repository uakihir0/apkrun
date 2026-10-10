import DiagnosticsCore
import Foundation
import ImageCore
import RuntimeCore
import RuntimeHost
import XCTest

/// Gate G2 (roadmap.md §2): the stock image reaches `sys.boot_completed=1` on VZ with
/// direct kernel boot, logs `BOOT_COMPLETED`, stays up for 10 minutes without a
/// `system_server` restart, Watchdog kill, or HAL crash loop, and does so for five cold
/// boots in a row after an instance reset.
final class G2AndroidBootTests: XCTestCase {
    /// Services that exit by design: one-shot setup and lazy AIDL services.
    private static let expectedExits: Set<String> = [
        "apexd", "artd", "gsid", "bugreportd", "vendor.dumpstate-default", "virtualizationservice",
        "media.codeclist.generator", "vendor.dlkm_loader", "usbd", "rename_eth0", "netd1shot",
        "system_aconfigd_platform_init", "system_aconfigd_socket_service", "rpmb_mock_init_test_system",
        "set_adb", "hidl_memory",
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["APKRUN_ACCEPTANCE_SUITE"] == "g2" else {
            throw XCTSkip("G2 checks run in the G2 test-plan configuration.")
        }
    }

    /// Removes a private home. An installed image is read-only, so the owner's write bits come back first.
    private static func removeHome(_ home: URL) {
        let manager = FileManager.default
        func restoreWrite(_ url: URL) {
            guard let attributes = try? manager.attributesOfItem(atPath: url.path),
                let mode = attributes[.posixPermissions] as? NSNumber
            else {
                return
            }
            try? manager.setAttributes(
                [.posixPermissions: NSNumber(value: mode.uint16Value | 0o200)], ofItemAtPath: url.path)
        }
        restoreWrite(home)
        if let walker = manager.enumerator(at: home, includingPropertiesForKeys: nil) {
            for case let url as URL in walker {
                restoreWrite(url)
            }
        }
        try? manager.removeItem(at: home)
    }

    func testFiveColdBootsReachBootCompletedAndStayStable() async throws {
        let bundle = try Self.bundleDirectory()
        // The run's own home and developer ADB port (test-strategy §3.10). Its console socket paths fit sockaddr_un.
        let run = try VMRunResources.new(environment: ProcessInfo.processInfo.environment)
        let home = run.home
        defer { Self.removeHome(home) }
        let paths = run.paths
        // The signed bundle goes through the install path of `apkrun dev image install`.
        let images = ImageStore(paths: paths, trust: .standard(), diagnostics: .live(paths: paths))
        let image = try await images.install(from: .directory(bundle))
        let store = InstanceStore(paths: paths, diagnostics: .live(paths: paths))
        _ = try await store.resetAndroid(image: image, sizing: .default)
        let dwell = Self.dwell()
        // XCTest's default allowance is 10 minutes; the plan's maximum (90 minutes) only caps this.
        executionTimeAllowance = TimeInterval(5 * (dwell.components.seconds + 300))

        for boot in 1...5 {
            let timeline = PerfTimeline()
            let live = DiagnosticsContext.live(paths: paths)
            let diagnostics = DiagnosticsContext(
                logSink: live.logSink,
                healthChecks: live.healthChecks,
                perfTimeline: timeline,
                paths: paths,
                clock: live.clock
            )
            let supervisor = RuntimeSupervisor(
                image: image,
                instanceStore: store,
                options: BootOptions(
                    gpuProfile: .headless,
                    developerMode: true,
                    captureLogcat: true,
                    adbHostPort: run.adbHostPort
                ),
                diagnostics: diagnostics
            )
            let capture = OutputCapture()
            let consoles = DevConsoleSocketServer(directory: paths.devConsoleDirectory)
            // Stops the socket on every exit from this boot, including a thrown boot failure.
            defer { consoles.stop() }
            let captureTask = Task {
                for await event in supervisor.events {
                    switch event {
                    case .console(let bytes): capture.appendConsole(bytes)
                    case .logcat(let bytes): capture.appendLogcat(bytes)
                    case .devConsole(let endpoint) where endpoint.name == "hvc1":
                        do throws(RuntimeFailure) {
                            try consoles.serve(endpoint)
                        } catch {
                            XCTFail("the developer console socket could not be created: \(error)")
                        }
                    default: break
                    }
                }
            }
            let started = ContinuousClock.now
            try await supervisor.ensureReady(.cli)
            let readyAfter = ContinuousClock.now - started
            let readyState = await supervisor.state
            XCTAssertEqual(readyState, .ready, "boot \(boot)")
            XCTAssertTrue(
                timeline.snapshot().contains { $0.marker == .bootCompleted },
                "boot \(boot) logs BOOT_COMPLETED"
            )
            let shellOrNil = await supervisor.shell
            let shell = try XCTUnwrap(shellOrNil)
            let completed = try await shell.run("getprop sys.boot_completed")
            XCTAssertEqual(completed.output.split(whereSeparator: \.isNewline).last, "1", "boot \(boot)")

            try await Task.sleep(for: dwell)

            let startCount = try await shell.run("getprop sys.system_server.start_count")
            XCTAssertEqual(startCount.output.split(whereSeparator: \.isNewline).last, "1", "boot \(boot)")
            let console = capture.console()
            let logcat = capture.logcat()
            XCTAssertFalse(logcat.contains("WATCHDOG KILLING SYSTEM PROCESS"), "boot \(boot)")
            XCTAssertFalse(console.contains("WATCHDOG KILLING SYSTEM PROCESS"), "boot \(boot)")
            let loops = Self.crashLoops(in: console)
            XCTAssertTrue(loops.isEmpty, "boot \(boot) crash loops: \(loops)")
            let attachment = XCTAttachment(
                string: "boot \(boot): ready after \(readyAfter), exits \(Self.serviceExits(in: console))"
            )
            attachment.lifetime = .keepAlways
            add(attachment)

            if boot == 5 {
                // The reference diff after the last boot (android-image.md §8.4): capture the boot over
                // the developer console and compare it with the launcher capture while Android is up.
                let comparison = try Self.compareWithReference(
                    socket: paths.devConsoleDirectory.appendingPathComponent("hvc1.sock"),
                    output: run.captureDirectory
                )
                let report = XCTAttachment(string: comparison.report)
                report.lifetime = .keepAlways
                add(report)
                XCTAssertEqual(comparison.status, 0, "the reference diff has no unexplained difference")
            }

            await supervisor.stop()
            consoles.stop()
            captureTask.cancel()
        }
        // The boot records of the run, for the gate evidence (diagnostics.md §4.3).
        let records = XCTAttachment(string: (try? String(contentsOf: paths.bootPerformanceFile, encoding: .utf8)) ?? "")
        records.lifetime = .keepAlways
        add(records)
    }

    /// Runs `compare_boot.py capture-vz` on the hvc1 socket, then compares the capture with the launcher's
    /// reference boot. Returns the comparison's exit status and its text report.
    static func compareWithReference(socket: URL, output: URL) throws -> (status: Int32, report: String) {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let python = root.appendingPathComponent("Images/tools/.venv/bin/python")
        let tool = root.appendingPathComponent("Images/tools/reference/compare_boot.py")
        let reference = root.appendingPathComponent(
            "Images/reference/16373615/incomplete/default-20261001T120904-49816")
        let commands = root.appendingPathComponent("Images/tools/reference/guest-capture-compare.txt")
        let capture = try run(
            python,
            [
                tool.path, "capture-vz", "--shell", socket.path, "--out", output.path,
                "--commands", commands.path, "--timeout", "300",
            ])
        guard capture.status == 0 else {
            throw G2Failure.captureFailed(capture.output)
        }
        // The explanations live beside the reference's `incomplete/` directory, not in it, so pass them explicitly.
        let expected = root.appendingPathComponent("Images/reference/16373615/expected-differences.yaml")
        let comparison = try run(
            python, [tool.path, reference.path, output.path, "--expected", expected.path])
        let report = (try? String(contentsOf: output.appendingPathComponent("report.txt"), encoding: .utf8)) ?? ""
        return (comparison.status, comparison.output + report)
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        return (process.terminationStatus, output)
    }

    /// Services that exited three or more times (the #095 crash-loop definition).
    static func crashLoops(in console: String) -> [String] {
        serviceExits(in: console).filter { $0.value >= 3 && !expectedExits.contains($0.key) }.keys.sorted()
    }

    static func serviceExits(in console: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for line in console.split(whereSeparator: \.isNewline) {
            guard let start = line.range(of: "init: Service '"),
                let end = line[start.upperBound...].firstIndex(of: "'"),
                line.contains("exited") || line.contains("received signal") || line.contains("killed")
            else {
                continue
            }
            counts[String(line[start.upperBound..<end]), default: 0] += 1
        }
        return counts
    }

    static func dwell() -> Duration {
        let value = ProcessInfo.processInfo.environment["APKRUN_G2_DWELL_SECONDS"].flatMap(Int.init) ?? 600
        return .seconds(value)
    }

    static func bundleDirectory() throws -> URL {
        let configured =
            ProcessInfo.processInfo.environment["APKRUN_TEST_LINUX_DIR"]
            ?? Bundle.main.object(forInfoDictionaryKey: "APKRUN_TEST_LINUX_DIR") as? String
        let rootPath = configured.flatMap { $0.isEmpty ? nil : $0 } ?? "/tmp/apkrun-test-linux"
        let root = URL(fileURLWithPath: rootPath)
        let bundle = root.appendingPathComponent("android-bundle", isDirectory: true)
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
}

/// A G2 step that could not produce its evidence.
enum G2Failure: Error, CustomStringConvertible {
    case captureFailed(String)

    var description: String {
        switch self {
        case .captureFailed(let output): "the VZ capture failed: \(output)"
        }
    }
}

/// Collects console and logcat output from the supervisor's event stream.
private final class OutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var consoleBytes = Data()
    private var logcatBytes = Data()

    func appendConsole(_ data: Data) {
        lock.withLock { consoleBytes.append(data) }
    }

    func appendLogcat(_ data: Data) {
        lock.withLock { logcatBytes.append(data) }
    }

    func console() -> String {
        lock.withLock { String(decoding: consoleBytes, as: UTF8.self) }
    }

    func logcat() -> String {
        lock.withLock { String(decoding: logcatBytes, as: UTF8.self) }
    }
}
