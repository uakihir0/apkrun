import Darwin
import DiagnosticsCore
import Foundation
import ImageCore
import RuntimeCore
import XCTest

/// The development ADB path against a real Android guest (#015 T2; cli.md §5, android-image.md §7.3,
/// security-model.md §4). Runs only in the `AndroidADB` configuration of IntegrationTests.xctestplan,
/// which needs the Android bundle of `scripts/build-test-android-bundle.sh` and adb under ANDROID_HOME.
final class AndroidADBTests: XCTestCase {
    private static let port: UInt16 = 6520

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["APKRUN_INTEGRATION_SUITE"] == "android-adb" else {
            throw XCTSkip("The Android ADB checks run in the AndroidADB test-plan configuration.")
        }
    }

    /// Developer mode: ADB answers through the forwarder, only on the loopback address, and `reboot -p`
    /// stops Android gracefully.
    func testDevelopmentBootServesADBOnLoopbackOnlyAndStopsGracefully() async throws {
        let session = try await BootSession.start(developerMode: true)
        defer { session.cleanUp() }
        let supervisor = session.supervisor
        try await supervisor.ensureReady(.cli)
        let readyState = await supervisor.state
        XCTAssertEqual(readyState, .ready)

        let adb = AdbClient(executable: try Self.adbExecutable())
        try await adb.connect(timeout: .seconds(30))
        let bootCompleted = try await adb.getprop("sys.boot_completed")
        XCTAssertEqual(bootCompleted, "1")
        let processes = try await adb.shell("ps -A")
        XCTAssertEqual(processes.status, 0)
        XCTAssertTrue(processes.output.contains("init"))
        let packages = try await adb.shell("pm list packages")
        XCTAssertEqual(packages.status, 0)
        XCTAssertTrue(packages.output.contains("package:"))
        let logcat = try await adb.logcatDump()
        XCTAssertFalse(logcat.isEmpty)
        let shellCount = await adb.shellInvocationCount
        XCTAssertEqual(shellCount, 4)

        XCTAssertEqual(try Self.listeningAddresses(port: Self.port), ["127.0.0.1:\(Self.port)"])
        for address in try Self.nonLoopbackIPv4Addresses() {
            XCTAssertFalse(
                Self.isAccepting(address: address, port: Self.port),
                "ADB must not accept connections on \(address)"
            )
        }

        let stopStarted = ContinuousClock.now
        await supervisor.stop()
        let stopped = ContinuousClock.now - stopStarted
        let stoppedState = await supervisor.state
        XCTAssertEqual(stoppedState, .stopped)
        XCTAssertLessThan(stopped, .seconds(20), "reboot -p must power Android off before the forced stop")
        XCTAssertTrue(try Self.listeningAddresses(port: Self.port).isEmpty)
        XCTAssertTrue(session.capture.console().contains("reboot: Power down"))
    }

    /// Without developer mode, nothing listens on the ADB port, and Android still boots.
    func testDeveloperModeOffListensOnNoPort() async throws {
        let session = try await BootSession.start(developerMode: false)
        defer { session.cleanUp() }
        try await session.supervisor.ensureReady(.cli)
        let readyState = await session.supervisor.state
        XCTAssertEqual(readyState, .ready)

        XCTAssertTrue(try Self.listeningAddresses(port: Self.port).isEmpty)
        XCTAssertFalse(Self.isAccepting(address: "127.0.0.1", port: Self.port))

        await session.supervisor.stop()
    }

    // MARK: - Helpers

    /// The adb of the SDK in `testEnvironment()`.
    private static func adbExecutable() throws -> URL {
        do {
            return try AdbClient.resolveExecutable(environment: testEnvironment())
        } catch {
            throw XCTSkip("adb was not found under ANDROID_HOME or on PATH: \(error.qualifiedCode)")
        }
    }

    /// The environment of the boot and of adb. xcodebuild does not pass ANDROID_HOME on, so the
    /// SDK comes from the `APKRUN_ANDROID_HOME` build setting that the host's Info.plist carries.
    static func testEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if environment["ANDROID_HOME"] == nil,
            let sdk = Bundle.main.object(forInfoDictionaryKey: "APKRUN_ANDROID_HOME") as? String,
            !sdk.isEmpty
        {
            environment["ANDROID_HOME"] = sdk
        }
        return environment
    }

    /// The addresses that `lsof` reports as listening on TCP `port`, as `host:port`.
    static func listeningAddresses(port: UInt16) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fn"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            line.hasPrefix("n") ? String(line.dropFirst()) : nil
        }
    }

    /// The IPv4 addresses of the Mac other than loopback.
    static func nonLoopbackIPv4Addresses() throws -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else {
            throw XCTSkip("The interface list is unavailable.")
        }
        defer { freeifaddrs(list) }
        var addresses: [String] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current?.pointee {
            defer { current = entry.ifa_next }
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0
            else {
                continue
            }
            var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var socketAddress = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            inet_ntop(AF_INET, &socketAddress.sin_addr, &host, socklen_t(INET_ADDRSTRLEN))
            let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            addresses.append(String(decoding: bytes, as: UTF8.self))
        }
        return addresses
    }

    /// Whether a TCP connection to `address:port` completes within one second.
    static func isAccepting(address: String, port: UInt16) -> Bool {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return false
        }
        defer { Darwin.close(descriptor) }
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = port.bigEndian
        _ = inet_pton(AF_INET, address, &target.sin_addr)
        let started = withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if started == 0 {
            return true
        }
        guard errno == EINPROGRESS else {
            return false
        }
        var pending = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard Darwin.poll(&pending, 1, 1_000) > 0 else {
            return false
        }
        var status: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        _ = getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &status, &length)
        return status == 0
    }
}

/// One supervised boot of the test Android image in a private APKRUN_HOME.
private final class BootSession: @unchecked Sendable {
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

    static func start(developerMode: Bool) async throws -> BootSession {
        let bundle = try bundleDirectory()
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-015-adb-\(UUID().uuidString)", isDirectory: true)
        let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": home.path])
        // The signed bundle goes through the install path of `apkrun dev image install`, as the G2 check does.
        let images = ImageStore(paths: paths, trust: .standard(), diagnostics: .live(paths: paths))
        let image = try await images.install(from: .directory(bundle))
        let store = InstanceStore(paths: paths, diagnostics: .live(paths: paths))
        _ = try await store.resetAndroid(image: image, sizing: .default)
        let diagnostics = DiagnosticsContext.live(paths: paths)
        let supervisor = RuntimeSupervisor(
            image: image,
            instanceStore: store,
            options: BootOptions(gpuProfile: .headless, developerMode: developerMode, captureLogcat: false),
            diagnostics: diagnostics,
            environment: AndroidADBTests.testEnvironment()
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
        return BootSession(supervisor: supervisor, capture: capture, home: home, captureTask: captureTask)
    }

    func cleanUp() {
        captureTask.cancel()
        try? FileManager.default.removeItem(at: home)
    }

    private static func bundleDirectory() throws -> URL {
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
private final class ConsoleCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    func append(_ data: Data) {
        lock.withLock { bytes.append(data) }
    }

    func console() -> String {
        lock.withLock { String(decoding: bytes, as: UTF8.self) }
    }
}
