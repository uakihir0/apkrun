import CoreGraphics
import Foundation
import ImageIO

/// The inputs of the G3 run, which `scripts/run-gate.sh G3` passes as TEST_RUNNER_ environment variables.
struct G3Inputs {
    /// The embedded Debug CLI, built with the TestReadback trait (`apkrun dev boot`).
    let cli: URL
    /// The Android bundle with the ODM overlay (IR-1112). The gate records its path and SHA-256.
    let bundle: URL
    /// HelloGL's release APK, signed with the pinned fixture key.
    let helloGL: URL
    /// The Guest Agent bundle directory (APKRUN_GUEST_DIR of the CLI).
    let guestDirectory: URL
    /// The virgl runtime directory (APKRUN_VIRGL_RUNTIME_PATH of the CLI).
    let virglRuntime: URL
    /// The Android SDK that holds adb (ANDROID_HOME of the CLI).
    let androidHome: URL
    /// The directory the artifacts are written to. The gate copies it under build/gates/G3.
    let artifacts: URL

    /// The inputs from the process environment, and then from the test host's Info.plist, where the gate's build
    /// settings land (scripts/run-gate.sh G3, as APKRUN_TEST_LINUX_DIR does).
    static func fromEnvironment() throws -> G3Inputs {
        let environment = ProcessInfo.processInfo.environment
        func path(_ key: String) throws -> URL {
            let fromInfo = Bundle.main.object(forInfoDictionaryKey: key) as? String
            guard let value = environment[key] ?? fromInfo, !value.isEmpty, value.hasPrefix("/") else {
                throw G3Failure.missingInput(key)
            }
            return URL(fileURLWithPath: value)
        }
        return G3Inputs(
            cli: try path("APKRUN_G3_CLI"),
            bundle: try path("APKRUN_G3_BUNDLE"),
            helloGL: try path("APKRUN_G3_APK"),
            guestDirectory: try path("APKRUN_G3_GUEST_DIR"),
            virglRuntime: try path("APKRUN_G3_VIRGL_RUNTIME"),
            androidHome: try path("APKRUN_G3_ANDROID_HOME"),
            artifacts: try path("APKRUN_G3_ARTIFACTS")
        )
    }
}

/// A G3 step that could not produce its evidence. The message says what to fix.
enum G3Failure: Error, CustomStringConvertible {
    case missingInput(String)
    case commandFailed(String, Int32, String)
    case commandTimedOut(String)
    case bootEnded(String)
    case noWindow(Int32)
    case screenshotFailed(String)
    case screenRecordingDenied

    var description: String {
        switch self {
        case .missingInput(let key):
            "\(key) is not set to an absolute path. scripts/run-gate.sh G3 sets it."
        case .commandFailed(let command, let status, let output):
            "\(command) exited with \(status): \(output.suffix(400))"
        case .commandTimedOut(let command):
            "\(command) did not finish in time"
        case .bootEnded(let state):
            "the boot ended before it was ready: \(state)"
        case .noWindow(let pid):
            "no window titled APKRun display 0 belongs to process \(pid). Check that Screen Recording is allowed for the test host."
        case .screenshotFailed(let path):
            "screencapture did not write \(path)"
        case .screenRecordingDenied:
            "The test host has no Screen Recording access. Allow APKRunTestHost in System Settings, Privacy & Security, Screen Recording, then rerun scripts/run-gate.sh G3."
        }
    }
}

/// The lines that the boot writes to standard error, collected as they arrive.
final class G3LineCollector: @unchecked Sendable {
    // UNCHECKED-SENDABLE: the lines are appended by the pipe's reader and read under the lock.
    private let lock = NSLock()
    private var lines: [String] = []
    private var pending = Data()
    private let file: FileHandle

    init(file: FileHandle) {
        self.file = file
    }

    /// Appends the bytes the pipe delivered, one line at a time.
    func append(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
        file.write(data)
        lock.withLock {
            pending.append(data)
            while let newline = pending.firstIndex(of: 0x0A) {
                let lineData = pending[pending.startIndex..<newline]
                lines.append(String(decoding: lineData, as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
    }

    var snapshot: [String] {
        lock.withLock { lines }
    }

    func count(containing text: String) -> Int {
        lock.withLock { lines.filter { $0.contains(text) }.count }
    }
}

/// One G3 run: the CLI and its boot, ADB through the CLI, and the window of display 0.
final class G3Session: @unchecked Sendable {
    static let package = "io.apkrun.fixture.hellogl"
    static let activity = "io.apkrun.fixture.hellogl/.MainActivity"

    let inputs: G3Inputs
    /// The APKRUN_HOME of the boot. It is a new directory, and the run removes it at the end.
    let home: URL
    private(set) var boot: Process?
    private(set) var collector: G3LineCollector?
    private var logFiles: [String: FileHandle] = [:]

    init(inputs: G3Inputs) throws {
        self.inputs = inputs
        // The console socket paths must fit sockaddr_un, so the home is a short directory under /tmp (as G2 does).
        home = URL(fileURLWithPath: "/tmp").appendingPathComponent(
            "apkrun-g3-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs.artifacts, withIntermediateDirectories: true)
    }

    /// The environment of every child process: the CLI's settings and the search path, and nothing the test host set.
    var childEnvironment: [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["PATH", "USER", "LANG", "TMPDIR"] {
            environment[key] = inherited[key]
        }
        environment["HOME"] = inherited["HOME"]
        environment["APKRUN_HOME"] = home.path
        environment["APKRUN_GUEST_DIR"] = inputs.guestDirectory.path
        environment["APKRUN_VIRGL_RUNTIME_PATH"] = inputs.virglRuntime.path
        environment["ANDROID_HOME"] = inputs.androidHome.path
        return environment
    }

    /// A text file in the artifact directory. Each name is written once, and later writes replace it.
    func writeArtifact(_ name: String, _ text: String) throws {
        try text.write(to: inputs.artifacts.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Installs the Android bundle into the run's home with `apkrun dev image install`.
    func installImage() throws {
        let result = try runCLI(["dev", "image", "install", inputs.bundle.path], timeout: 900)
        try writeArtifact("install-bundle.txt", result.output)
        guard result.status == 0 else {
            throw G3Failure.commandFailed("apkrun dev image install", result.status, result.output)
        }
    }

    /// Starts `apkrun dev boot --gpu virgl --window --stats --console`. Its standard output goes to `boot.out`, and
    /// its standard error is collected and written to `boot.err`.
    func startBoot() throws {
        let outURL = inputs.artifacts.appendingPathComponent("boot.out")
        let errURL = inputs.artifacts.appendingPathComponent("boot.err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let errFile = try FileHandle(forWritingTo: errURL)
        let collector = G3LineCollector(file: errFile)
        let process = Process()
        process.executableURL = inputs.cli
        process.arguments = ["dev", "boot", "--gpu", "virgl", "--window", "--stats", "--console"]
        process.environment = childEnvironment
        process.standardOutput = try FileHandle(forWritingTo: outURL)
        let errorPipe = Pipe()
        process.standardError = errorPipe
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collector.append(data)
            }
        }
        try process.run()
        self.boot = process
        self.collector = collector
    }

    /// The current state of the boot, from the last `state:` line of standard error.
    var lastState: String {
        collector?.snapshot.last { $0.hasPrefix("state: ") } ?? "none"
    }

    /// Waits until the boot reports `state: ready`. A boot that ends first fails the run with its last state.
    func waitForReady(timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if (collector?.count(containing: "state: ready") ?? 0) > 0 {
                return
            }
            if let boot, !boot.isRunning {
                throw G3Failure.bootEnded(lastState)
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw G3Failure.bootEnded("not ready after \(timeout): \(lastState)")
    }

    /// The number of lines logged so far. A mark is an index into the lines, so that a phase is the lines after it.
    var lineMark: Int {
        collector?.snapshot.count ?? 0
    }

    /// The statistics lines logged after `mark`.
    func statisticsLines(after mark: Int) -> [G3StatisticsLine] {
        (collector?.snapshot ?? []).dropFirst(mark).compactMap { G3StatisticsLine(line: $0) }
    }

    /// The statistics lines logged after `mark`, as they were written.
    func rawStatisticsLines(after mark: Int) -> String {
        (collector?.snapshot ?? []).dropFirst(mark).filter { $0.hasPrefix("APKRun display 0") }
            .joined(separator: "\n") + "\n"
    }

    /// The last statistics line logged before `mark`, which carries the cumulative tearing counters.
    func lastStatistics(before mark: Int) -> G3StatisticsLine? {
        (collector?.snapshot ?? []).prefix(mark).reversed().lazy.compactMap { G3StatisticsLine(line: $0) }.first
    }

    /// Appends a timestamped line to `session.log` in the artifact directory.
    func note(_ text: String) {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(text)\n"
        let url = inputs.artifacts.appendingPathComponent("session.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            handle.write(Data(line.utf8))
            try? handle.close()
        }
    }

    /// Stops the boot with SIGINT, waits 60 s, and then sends SIGKILL (the gate's stop rule). Returns whether the
    /// boot ended after SIGINT.
    func stopBoot() async -> Bool {
        guard let boot, boot.isRunning else {
            return true
        }
        boot.interrupt()
        let deadline = ContinuousClock.now + .seconds(60)
        while boot.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(500))
        }
        if boot.isRunning {
            kill(boot.processIdentifier, SIGKILL)
            while boot.isRunning {
                try? await Task.sleep(for: .milliseconds(200))
            }
            return false
        }
        return true
    }

    /// The pid of HelloGL, from `pidof`, or `nil` when it is not running.
    func helloGLPID() throws -> String? {
        let output = try adb(["shell", "pidof \(Self.package)"], timeout: 60).output
        let pid = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return pid.isEmpty ? nil : pid
    }

    /// Runs `apkrun dev adb <arguments>` with a 90 s limit, which talks to the developer ADB port of the boot.
    @discardableResult
    func adb(_ arguments: [String], timeout: TimeInterval = 90) throws -> (status: Int32, output: String) {
        try runCLI(["dev", "adb"] + arguments, timeout: timeout)
    }

    /// The guest log: every line of the persistent capture under APKRUN_HOME/Logs/guest.
    func guestLog() -> String {
        let directory = home.appendingPathComponent("Logs/guest", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "log" }.sorted { $0.path < $1.path }.compactMap {
            try? String(contentsOf: $0, encoding: .utf8)
        }.joined()
    }

    /// Captures the window of display 0 of the boot with `screencapture`, and returns its window number.
    func captureWindow(to name: String) throws -> Int {
        guard let boot else {
            throw G3Failure.noWindow(0)
        }
        let number = try windowNumber(owner: boot.processIdentifier)
        let destination = inputs.artifacts.appendingPathComponent("screenshots", isDirectory: true)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let result = try runProcess(
            URL(fileURLWithPath: "/usr/sbin/screencapture"),
            ["-x", "-o", "-l", String(number), destination.path],
            timeout: 30
        )
        guard result.status == 0, FileManager.default.fileExists(atPath: destination.path) else {
            throw G3Failure.screenshotFailed(destination.path)
        }
        return number
    }

    /// The number of the on-screen window of `owner` whose title starts with `APKRun display 0`.
    ///
    /// Without Screen Recording access, macOS hides the titles of other processes' windows. The request also adds the
    /// test host to the Screen Recording list of System Settings, which an app is not in until it asks.
    func windowNumber(owner: pid_t) throws -> Int {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw G3Failure.screenRecordingDenied
        }
        let windows =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for window in windows {
            let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            let title = window[kCGWindowName as String] as? String ?? ""
            if ownerPID == owner, title.hasPrefix("APKRun display 0"),
                let number = (window[kCGWindowNumber as String] as? NSNumber)?.intValue
            {
                return number
            }
        }
        throw G3Failure.noWindow(owner)
    }

    /// The number of distinct colours in the central part of a capture. A blank or missing display shows few.
    static func distinctColours(inPNG url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return 0
        }
        let width = image.width
        let height = image.height
        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: height * rowBytes)
        guard
            let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: rowBytes,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            return 0
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var colours = Set<UInt32>()
        for y in stride(from: height / 5, to: height * 4 / 5, by: 16) {
            for x in stride(from: width / 5, to: width * 4 / 5, by: 16) {
                let offset = y * rowBytes + x * 4
                let value =
                    UInt32(pixels[offset]) << 16 | UInt32(pixels[offset + 1]) << 8 | UInt32(pixels[offset + 2])
                colours.insert(value)
            }
        }
        return colours.count
    }

    /// Removes the run's home, restoring the write bits of an installed image first (VMRunResources.removeHome).
    func removeHome() {
        VMRunResources.removeHomeOrReport(home)
    }

    // MARK: - Processes

    private func runCLI(_ arguments: [String], timeout: TimeInterval) throws -> (status: Int32, output: String) {
        try runProcess(inputs.cli, arguments, timeout: timeout, environment: childEnvironment)
    }

    /// Runs a command, waits for it, and returns its status and its combined output. A command that runs past
    /// `timeout` is killed and fails the run.
    func runProcess(
        _ executable: URL,
        _ arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]? = nil
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment ?? ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        // The output goes to a file, not a pipe: adb may leave a server behind that holds a pipe open.
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apkrun-g3-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let outputFile = try FileHandle(forWritingTo: outputURL)
        process.standardOutput = outputFile
        process.standardError = outputFile
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = done.wait(timeout: .now() + 5)
            try? outputFile.close()
            throw G3Failure.commandTimedOut(
                executable.lastPathComponent + " " + arguments.prefix(2).joined(separator: " "))
        }
        try? outputFile.close()
        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        return (process.terminationStatus, output)
    }
}
