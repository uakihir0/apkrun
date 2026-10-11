import DiagnosticsCore
import Foundation
import ImageCore
import XCTest

@testable import RuntimeCore
@testable import VirtualMachineCore

/// The marker plan of #095 step 1 for the console ports of the Android dev boot (vm.md §6.2, android-image.md §7.1).
///
/// The host writes `APKRUN-PORT-<i>` into attachment port `i`, and a guest reader on `/dev/hvc<i>` must receive
/// exactly that line, so the guest numbers the ports as the host attaches them. This check marks the 17 ports that
/// the developer boot leaves unused: hvc2 to hvc17 and hvc19 (IR-899). hvc0 is the system console and hvc1 the
/// developer serial service, so neither is marked. hvc18 is the sensors port: it keeps its product role and its
/// responder, and it is never marked, because the responder would read a marker as HAL protocol (IR-871).
enum ConsolePortMarkerPlan {
    /// The console ports of the Android dev boot (android-image.md §7.1).
    static let portCount = 20

    /// The sensors port, which keeps its product role and its responder.
    static let sensorsPort = 18

    /// The product role of the sensors port. The responder serves this role (RuntimeSupervisor, `sensors_control`).
    static let sensorsRole: ConsoleRole = .service(name: "sensors_control")

    /// The ports that get a marker, in attachment order: hvc2 to hvc17 and hvc19.
    static let markedPorts: [Int] = (2..<portCount).filter { $0 != sensorsPort }

    /// How long a reader must be ready before its marker is written (IR-899, update 2). The first bytes sent to a port
    /// were lost in the 2026-10-12 run, so the host waits for this settle time after it sees `ready-<port>`.
    static let writeSettle: Duration = .seconds(2)

    /// The line the host writes into `port`, and the line that the guest reader of `port` must receive.
    static func marker(for port: Int) -> String {
        "APKRUN-PORT-\(port)"
    }

    /// The bytes the host writes into `port`: the marker line with its newline, so the guest reader gets one complete
    /// line.
    static func payload(for port: Int) -> String {
        marker(for: port) + "\n"
    }

    /// The guest device that the reader of `port` opens.
    static func device(for port: Int) -> String {
        "/dev/hvc\(port)"
    }

    /// The test-only role of a marked port. It exists only in this test target, and the product layout never names it.
    /// It is a service role, which permits host input.
    static func testRole(for port: Int) -> ConsoleRole {
        .service(name: "test-marker-\(port)")
    }

    /// The product port list with the marked ports given a test-only role. Every other port keeps its product role.
    static func testLayout(product: [ConsolePortDefinition]) -> [ConsolePortDefinition] {
        product.enumerated().map { index, definition in
            markedPorts.contains(index) ? ConsolePortDefinition(role: testRole(for: index)) : definition
        }
    }

    /// The guest directory that holds the reader files and the reader process ids.
    static let guestDirectory = "/data/local/tmp/apkrun-port-check"

    /// The guest command that starts one reader per marked port in the background, and returns at once.
    ///
    /// A reader opens its port on fd 3, sets it to raw mode on that descriptor (`raw-<port>` records whether that
    /// worked), and only then writes `ready-<port>`. The reader is `cat` under `timeout`, which copies what arrives
    /// into `out-<port>` and ends by itself. Its process id goes into `pid-<port>`, so `stopReadersCommand` can end it.
    static func readerCommand(timeoutSeconds: Int) -> String {
        let readers = markedPorts.map { port in
            "( exec 3<\(device(for: port)); "
                + "if stty raw -echo <&3 2>/dev/null; then echo raw > \(guestDirectory)/raw-\(port); "
                + "else echo unchanged > \(guestDirectory)/raw-\(port); fi; "
                + "echo ready > \(guestDirectory)/ready-\(port); "
                + "if command -v timeout >/dev/null 2>&1; then "
                + "exec timeout \(timeoutSeconds) cat <&3 > \(guestDirectory)/out-\(port); "
                + "else exec cat <&3 > \(guestDirectory)/out-\(port); fi ) </dev/null >/dev/null 2>&1 & "
                + "echo $! > \(guestDirectory)/pid-\(port);"
        }
        return ["rm -rf \(guestDirectory)", "mkdir -p \(guestDirectory)"].joined(separator: "; ")
            + "; " + readers.joined(separator: " ") + " echo started"
    }

    /// The guest command that ends every reader that `readerCommand` started.
    static let stopReadersCommand =
        "for f in \(guestDirectory)/pid-*; do kill $(cat $f) 2>/dev/null; done; echo stopped"

    /// The guest command that prints the raw-mode record of every reader.
    static let rawStateCommand = "for f in \(guestDirectory)/raw-*; do echo \"$f $(cat $f)\"; done"

    /// The guest command that prints each marked port's reader file, under a `PORT <n>` header.
    static func collectCommand() -> String {
        markedPorts.map { port in
            "echo PORT \(port); cat \(guestDirectory)/out-\(port) 2>/dev/null"
        }
        .joined(separator: "; ")
    }

    /// The guest command that lists the holder of every `/dev/hvc*` node, as the processes' open file descriptors.
    static let holdersCommand = "ls -l /proc/[0-9]*/fd/* 2>/dev/null | grep /dev/hvc"

    /// The received lines of each port, from the output of `collectCommand`.
    static func parseCollected(_ output: String) -> [Int: [String]] {
        var received: [Int: [String]] = [:]
        var current: Int?
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("PORT "), let port = Int(line.dropFirst(5)) {
                current = port
                received[port] = []
            } else if let port = current, !line.isEmpty {
                received[port, default: []].append(line)
            }
        }
        return received
    }

    /// The ports whose reader has announced itself, from the listing of `guestDirectory`.
    static func readyPorts(_ listing: String) -> Set<Int> {
        Set(
            listing.split(whereSeparator: \.isNewline).compactMap { entry -> Int? in
                let name = entry.trimmingCharacters(in: .whitespacesAndNewlines)
                guard name.hasPrefix("ready-") else { return nil }
                return Int(name.dropFirst("ready-".count))
            })
    }

    /// The marked ports to write now. A port is due once its `ready` file was first seen at least `settle` before
    /// `now`, and it has not been written yet. The host writes each port once.
    static func portsToWrite(
        seenAt: [Int: Duration],
        now: Duration,
        written: Set<Int>,
        settle: Duration
    ) -> [Int] {
        markedPorts.filter { port in
            guard !written.contains(port), let seen = seenAt[port] else {
                return false
            }
            return now - seen >= settle
        }
    }
}

/// The result of the marker check on one port.
struct ConsolePortMarkerResult: Equatable {
    let port: Int
    let readerReady: Bool
    let written: Bool
    let writeError: String?
    let received: [String]

    /// The port passed when its marker was written after its reader was ready, and its reader received exactly that
    /// marker line, and no other line.
    var passed: Bool {
        readerReady && written && writeError == nil && received == [ConsolePortMarkerPlan.marker(for: port)]
    }

    /// One line per port: the marker, the reader and write state, and the exact lines the reader received.
    var line: String {
        let verdict = passed ? "ok" : "missing"
        let lines = received.map { "\"\($0)\"" }.joined(separator: ",")
        let error = writeError.map { " write-error=\($0)" } ?? ""
        return
            "hvc\(port) marker=\(ConsolePortMarkerPlan.marker(for: port)) reader-ready=\(readerReady ? "yes" : "no") "
            + "written=\(written ? "yes" : "no") received=[\(lines)] \(verdict)\(error)"
    }
}

/// A failure of the marker check that is not a port result.
enum ConsolePortCheckFailure: Error, CustomStringConvertible {
    case instanceMissing
    case forwarderHasNoPort
    case guestNotReady(String)
    case controllerMissing
    case adbBridgeMissing

    var description: String {
        switch self {
        case .instanceMissing: "the instance was not provisioned for the marker check"
        case .forwarderHasNoPort: "the loopback forwarder did not bind a port"
        case .guestNotReady(let detail): "the Android guest did not answer over ADB: \(detail)"
        case .controllerMissing: "the VM controller is not running"
        case .adbBridgeMissing: "the ADB bridge is not running"
        }
    }
}

/// One Android developer boot that the marker check drives (#095 step 1).
///
/// The boot uses the product path up to the definition: the signed image, the instance, and the planner. The 17
/// unused ports then get a test-only role in the test's definition, so that the host can write to them (IR-899).
/// Every other port keeps its product role, including hvc18 with its sensors responder. The product layout and the
/// supervisor are not changed. The ADB bridge copies the supervisor's (RuntimeSupervisor.startADBBridge, which is
/// private). The responder is the one RuntimeCore runs for the supervisor, driven through the public byte stream.
private final class ConsolePortMarkerBoot {
    /// The guest's ADB port on vsock, as the supervisor uses it (RuntimeSupervisor.developmentADBGuestPort).
    private static let guestADBPort: UInt32 = 5555

    private let run: VMRunResources
    private var controller: VMController?
    private var forwarder: VsockLoopbackForwarder?
    private var adb: AdbClient?
    private var responder: Task<Void, Never>?

    init(run: VMRunResources) {
        self.run = run
    }

    /// Installs the image, provisions the instance, starts the VM with the test roles, starts the sensors responder,
    /// and starts the ADB bridge.
    func start(bundle: URL) async throws {
        let paths = run.paths
        let diagnostics = DiagnosticsContext.live(paths: paths)
        let images = ImageStore(paths: paths, trust: .standard(), diagnostics: diagnostics)
        let image = try await images.install(from: .directory(bundle))
        let store = InstanceStore(paths: paths, diagnostics: diagnostics)
        _ = try await store.resetAndroid(image: image, sizing: .default)
        guard let instance = try await store.load(image: image) else {
            throw ConsolePortCheckFailure.instanceMissing
        }
        let options = BootOptions(
            gpuProfile: .headless,
            developerMode: true,
            captureLogcat: false,
            adbHostPort: run.adbHostPort
        )
        let plan = try AndroidBootPlanner(paths: paths).prepareBoot(image: image, instance: instance, options: options)
        var definition = plan.definition
        definition.consolePorts = ConsolePortMarkerPlan.testLayout(product: definition.consolePorts)
        let validated = try VMDefinitionValidator().validate(definition)
        let controller = VMController(definition: validated, diagnostics: diagnostics)
        self.controller = controller
        try await controller.start()

        // The sensors responder answers the HAL on hvc18, as RuntimeSupervisor does for the sensors_control role.
        let sensors = controller.console(ConsolePortMarkerPlan.sensorsRole)
        let sensorsStream = sensors.makeByteStream()
        responder = Task { await Self.runSensorsResponder(channel: sensors, stream: sensorsStream) }

        let forwarder = VsockLoopbackForwarder(
            requestedPort: run.adbHostPort,
            guestPort: Self.guestADBPort,
            logSink: diagnostics.logSink,
            connectGuest: { port in
                try await controller.connect(vsockPort: port, timeout: .seconds(5))
            }
        )
        try forwarder.start()
        self.forwarder = forwarder
        guard let hostPort = forwarder.port else {
            throw ConsolePortCheckFailure.forwarderHasNoPort
        }
        self.adb = AdbClient(
            executable: try AndroidTestEnvironment.adbExecutable(),
            endpoint: AdbClient.loopbackEndpoint(port: hostPort),
            logSink: diagnostics.logSink
        )
    }

    /// Answers the sensors HAL with the responder's replies, as RuntimeSupervisor does. The stream is not acknowledged:
    /// the public `makeByteStream()` reserves no chunk capacity, so unacknowledged output is not dropped
    /// (ConsoleChannel.swift), and the acknowledgement calls are package-scoped (IR-894).
    private static func runSensorsResponder(channel: ConsoleChannel, stream: ConsoleByteStream) async {
        var responder = SensorsResponder()
        for await bytes in stream.stream {
            if bytes.isEmpty {
                continue
            }
            let reply = responder.consume(bytes)
            if reply.isEmpty {
                continue
            }
            try? channel.writeHostInput(reply)
        }
    }

    /// Waits for ADB to answer, takes root (the holder listing and the readers need it), and waits up to `bootBudget`
    /// for `sys.boot_completed`. The marker check needs ADB and root, not a finished boot, so a boot that does not
    /// finish is recorded and the check goes on (IR-894).
    func waitForGuest(connectBudget: Duration, bootBudget: Duration) async throws -> String {
        let adb = try requireADB()
        try await adb.connect(timeout: connectBudget)
        try await adb.restartAsRoot()
        let deadline = ContinuousClock.now + bootBudget
        var completed = ""
        while true {
            completed = try await adb.getprop("sys.boot_completed", timeout: .seconds(10))
            if completed == "1" || ContinuousClock.now >= deadline {
                break
            }
            try await Task.sleep(for: .seconds(5))
        }
        return "sys.boot_completed=\"\(completed)\""
    }

    /// Starts the readers, writes each marker once its reader has been ready for the settle time, and collects what
    /// each reader got.
    func checkMarkers() async throws -> [ConsolePortMarkerResult] {
        let adb = try requireADB()
        let controller = try requireController()

        let holdersBefore = try await adb.shell(ConsolePortMarkerPlan.holdersCommand, timeout: .seconds(20))
        print("port-check holders before the readers:\n\(holdersBefore.output)")

        let started = try await adb.shell(
            ConsolePortMarkerPlan.readerCommand(timeoutSeconds: 180),
            timeout: .seconds(30)
        )
        let startedOutput = started.output.trimmingCharacters(in: .whitespacesAndNewlines)
        print("port-check readers started: status \(started.status) \(startedOutput)")

        let start = ContinuousClock.now
        var seenAt: [Int: Duration] = [:]
        var written: Set<Int> = []
        var writeErrors: [Int: String] = [:]
        var ready: Set<Int> = []
        let writeDeadline = start + .seconds(90)
        while true {
            let listing = try await adb.shell("ls \(ConsolePortMarkerPlan.guestDirectory)", timeout: .seconds(20))
            ready = ConsolePortMarkerPlan.readyPorts(listing.output)
            let now = ContinuousClock.now - start
            for port in ready where seenAt[port] == nil {
                seenAt[port] = now
            }
            let due = ConsolePortMarkerPlan.portsToWrite(
                seenAt: seenAt,
                now: now,
                written: written,
                settle: ConsolePortMarkerPlan.writeSettle
            )
            for port in due {
                written.insert(port)
                do {
                    try controller.console(ConsolePortMarkerPlan.testRole(for: port))
                        .writeHostInput(Data(ConsolePortMarkerPlan.payload(for: port).utf8))
                } catch {
                    writeErrors[port] = String(describing: error)
                }
            }
            if written.count == ConsolePortMarkerPlan.markedPorts.count || ContinuousClock.now >= writeDeadline {
                break
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        let notReady = ConsolePortMarkerPlan.markedPorts.filter { !ready.contains($0) }
        let notWritten = ConsolePortMarkerPlan.markedPorts.filter { !written.contains($0) }
        print("port-check readers ready: \(ready.sorted()) not ready: \(notReady) not written: \(notWritten)")

        let holdersAfter = try await adb.shell(ConsolePortMarkerPlan.holdersCommand, timeout: .seconds(20))
        print("port-check holders with the readers running:\n\(holdersAfter.output)")

        var received: [Int: [String]] = [:]
        let markerDeadline = ContinuousClock.now + .seconds(60)
        while true {
            let collected = try await adb.shell(ConsolePortMarkerPlan.collectCommand(), timeout: .seconds(30))
            received = ConsolePortMarkerPlan.parseCollected(collected.output)
            let everyPortHasItsMarker = ConsolePortMarkerPlan.markedPorts.allSatisfy { port in
                received[port] == [ConsolePortMarkerPlan.marker(for: port)]
            }
            if everyPortHasItsMarker || ContinuousClock.now >= markerDeadline {
                break
            }
            try await Task.sleep(for: .seconds(2))
        }
        let rawState = try await adb.shell(ConsolePortMarkerPlan.rawStateCommand, timeout: .seconds(20))
        print("port-check raw mode per reader:\n\(rawState.output)")

        return ConsolePortMarkerPlan.markedPorts.map { port in
            ConsolePortMarkerResult(
                port: port,
                readerReady: ready.contains(port),
                written: written.contains(port),
                writeError: writeErrors[port],
                received: received[port] ?? []
            )
        }
    }

    /// Ends the readers, powers Android off, stops the VM, and stops the responder and the ADB bridge. The caller
    /// removes the run's home.
    func finish() async {
        if let adb {
            _ = try? await adb.shell(ConsolePortMarkerPlan.stopReadersCommand, timeout: .seconds(20))
            _ = try? await adb.rebootPowerOff()
        }
        if let controller {
            let deadline = ContinuousClock.now + .seconds(30)
            while await controller.state != .stopped, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .seconds(1))
            }
            if await controller.state != .stopped {
                try? await controller.stop()
            }
        }
        responder?.cancel()
        if let forwarder {
            await forwarder.stopAndWait()
        }
    }

    private func requireADB() throws -> AdbClient {
        guard let adb else {
            throw ConsolePortCheckFailure.adbBridgeMissing
        }
        return adb
    }

    private func requireController() throws -> VMController {
        guard let controller else {
            throw ConsolePortCheckFailure.controllerMissing
        }
        return controller
    }
}

/// The T0 checks of the marker plan. They need no VM and run in every configuration.
final class ConsolePortMarkerPlanTests: XCTestCase {
    /// Whether the reader command opens `/dev/hvc<port>`. The device name is matched as a whole word, so hvc1 does not
    /// match hvc18 or hvc19.
    private func opens(_ command: String, device port: Int) -> Bool {
        command.contains("/dev/hvc\(port) ") || command.contains("/dev/hvc\(port);")
    }

    func testMarkedPortsAreTheUnusedPortsWithoutTheSensorsPort() {
        XCTAssertEqual(ConsolePortMarkerPlan.portCount, 20)
        XCTAssertEqual(ConsolePortMarkerPlan.markedPorts, Array(2...17) + [19])
        XCTAssertEqual(ConsolePortMarkerPlan.markedPorts.count, 17)
        XCTAssertFalse(ConsolePortMarkerPlan.markedPorts.contains(ConsolePortMarkerPlan.sensorsPort))
        XCTAssertFalse(ConsolePortMarkerPlan.markedPorts.contains(0), "hvc0 is the system console")
        XCTAssertFalse(ConsolePortMarkerPlan.markedPorts.contains(1), "hvc1 is the developer serial service")
    }

    func testMarkersAndReaderDevicesAreExactAndUnique() {
        XCTAssertEqual(ConsolePortMarkerPlan.marker(for: 2), "APKRUN-PORT-2")
        XCTAssertEqual(ConsolePortMarkerPlan.marker(for: 19), "APKRUN-PORT-19")
        XCTAssertEqual(ConsolePortMarkerPlan.device(for: 5), "/dev/hvc5")
        let markers = ConsolePortMarkerPlan.markedPorts.map(ConsolePortMarkerPlan.marker(for:))
        XCTAssertEqual(Set(markers).count, markers.count)
    }

    /// The developer boot's product layout as the planner gives it: hvc1 is the serial service, hvc2 to hvc17 and hvc19
    /// are silent, and hvc18 is the sensors service.
    private var developerBootLayout: [ConsolePortDefinition] {
        [ConsolePortDefinition(role: .systemConsole), ConsolePortDefinition(role: .service(name: "serial"))]
            + (2..<18).map { ConsolePortDefinition(role: .silent(name: "port-\($0)")) }
            + [
                ConsolePortDefinition(role: .service(name: "sensors_control")),
                ConsolePortDefinition(role: .silent(name: "sensors_data")),
            ]
    }

    func testTestLayoutGivesHostInputToEveryMarkedPortAndKeepsEveryOtherRole() {
        let product = developerBootLayout
        let layout = ConsolePortMarkerPlan.testLayout(product: product)

        XCTAssertEqual(layout.count, 20)
        for port in ConsolePortMarkerPlan.markedPorts {
            XCTAssertEqual(layout[port].role, ConsolePortMarkerPlan.testRole(for: port))
            if case .service = layout[port].role {
                continue
            }
            XCTFail("port \(port) must accept host input in the test layout")
        }
        for port in [0, 1, ConsolePortMarkerPlan.sensorsPort] {
            XCTAssertEqual(layout[port], product[port], "hvc\(port) keeps its product role")
        }
    }

    func testSensorsPortKeepsItsResponderRole() {
        XCTAssertEqual(ConsolePortMarkerPlan.sensorsPort, 18)
        XCTAssertEqual(ConsolePortMarkerPlan.sensorsRole, .service(name: "sensors_control"))
        XCTAssertFalse(ConsolePortMarkerPlan.markedPorts.contains(18))
        let layout = ConsolePortMarkerPlan.testLayout(product: developerBootLayout)
        XCTAssertEqual(layout[18].role, ConsolePortMarkerPlan.sensorsRole)
    }

    func testProductBootLayoutNamesNoTestRoleAndKeepsTheSensorsResponder() throws {
        // The layout is the one in the bundle that the product boots. The bundle is outside the repository, so the test
        // host reads it without a file-access prompt (the repository is under ~/Documents).
        let bundle = try AndroidBootSession.bundleDirectory()
        let data = try Data(contentsOf: bundle.appendingPathComponent("manifest.json"))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("test-marker-"), "the product layout names no test role")

        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let ports = try XCTUnwrap(manifest["consolePorts"] as? [[String: Any]])
        XCTAssertEqual(ports.count, 20)
        for port in ports {
            let index = try XCTUnwrap(port["index"] as? Int)
            let role = port["role"] as? String
            if index == ConsolePortMarkerPlan.sensorsPort {
                XCTAssertEqual(role, "service")
                XCTAssertEqual(port["name"] as? String, "sensors_control")
            } else if ConsolePortMarkerPlan.markedPorts.contains(index) {
                XCTAssertEqual(role, "silent", "the product leaves hvc\(index) unused")
            }
        }
    }

    func testReaderCommandStartsOneReaderPerMarkedPortAndOpensNoOtherPort() {
        let command = ConsolePortMarkerPlan.readerCommand(timeoutSeconds: 180)
        for port in ConsolePortMarkerPlan.markedPorts {
            XCTAssertTrue(command.contains("exec 3</dev/hvc\(port);"), "port \(port) has a reader")
            XCTAssertTrue(command.contains("echo $! > /data/local/tmp/apkrun-port-check/pid-\(port);"))
        }
        for port in [0, 1, ConsolePortMarkerPlan.sensorsPort] {
            XCTAssertFalse(opens(command, device: port), "the reader command never opens hvc\(port)")
        }
        XCTAssertTrue(command.contains("exec timeout 180 cat <&3"))
        XCTAssertTrue(command.hasSuffix("echo started"))
    }

    /// Raw mode is set on the port before the reader writes its ready file, so the host never writes before the port is
    /// in raw mode, and the record of raw mode is written where the host can read it.
    func testReaderSetsRawModeBeforeItsReadyFile() throws {
        let command = ConsolePortMarkerPlan.readerCommand(timeoutSeconds: 180)
        let raw = try XCTUnwrap(command.range(of: "stty raw -echo <&3"))
        let ready = try XCTUnwrap(command.range(of: "echo ready > /data/local/tmp/apkrun-port-check/ready-2;"))
        let open = try XCTUnwrap(command.range(of: "exec 3</dev/hvc2;"))
        XCTAssertLessThan(open.lowerBound, raw.lowerBound, "the port is opened before raw mode is set")
        XCTAssertLessThan(raw.lowerBound, ready.lowerBound, "raw mode is set before ready-2 is written")
        XCTAssertTrue(command.contains("echo raw > /data/local/tmp/apkrun-port-check/raw-2;"))
        XCTAssertFalse(command.contains("stty -F"), "stty acts on the open descriptor, not on a device path")
    }

    func testStopCommandEndsTheRecordedReaders() {
        XCTAssertTrue(ConsolePortMarkerPlan.stopReadersCommand.contains("pid-*"))
        XCTAssertTrue(ConsolePortMarkerPlan.stopReadersCommand.contains("kill $(cat $f)"))
    }

    /// A port is written only after its ready file has been seen for the settle time, and only once.
    func testPortsAreWrittenOnlyAfterReadyAndSettleAndOnlyOnce() {
        let settle = ConsolePortMarkerPlan.writeSettle
        let seenAt: [Int: Duration] = [2: .seconds(1), 3: .seconds(5)]

        XCTAssertEqual(
            ConsolePortMarkerPlan.portsToWrite(seenAt: [:], now: .seconds(100), written: [], settle: settle),
            [],
            "no port is written before its ready file is seen"
        )
        XCTAssertEqual(
            ConsolePortMarkerPlan.portsToWrite(seenAt: seenAt, now: .seconds(3), written: [], settle: settle),
            [2],
            "port 2 waited its settle time (seen at 1 s, due at 3 s), and port 3 has not yet been ready that long"
        )
        XCTAssertEqual(
            ConsolePortMarkerPlan.portsToWrite(seenAt: seenAt, now: .seconds(10), written: [2], settle: settle),
            [3],
            "a port written once is not written again"
        )
        XCTAssertEqual(
            ConsolePortMarkerPlan.portsToWrite(
                seenAt: [18: .seconds(1)], now: .seconds(10), written: [], settle: settle
            ),
            [],
            "the sensors port is never a marked port"
        )
    }

    /// A marker written after its ready file is seen is the complete line `APKRUN-PORT-<i>` with its newline, and a
    /// port passes only when that line, and no other, is what the reader received.
    func testMarkerWrittenAfterReadyIsCompleteAndPassesOnlyWhenWhole() {
        XCTAssertEqual(ConsolePortMarkerPlan.payload(for: 5), "APKRUN-PORT-5\n")
        let complete = ConsolePortMarkerResult(
            port: 5, readerReady: true, written: true, writeError: nil, received: ["APKRUN-PORT-5"]
        )
        XCTAssertTrue(complete.passed)
        let truncated = ConsolePortMarkerResult(
            port: 5, readerReady: true, written: true, writeError: nil, received: ["PKRUN-PORT-5"]
        )
        XCTAssertFalse(truncated.passed, "a line that lost its first characters is not the marker")
        let notWritten = ConsolePortMarkerResult(
            port: 5, readerReady: true, written: false, writeError: nil, received: ["APKRUN-PORT-5"]
        )
        XCTAssertFalse(notWritten.passed, "a marker that was never written is not a pass")
    }

    func testCollectedLinesAreParsedPerPort() {
        let output = "PORT 0\nAPKRUN-PORT-0\nPORT 1\r\nAPKRUN-PORT-2\nPORT 2\n"
        let parsed = ConsolePortMarkerPlan.parseCollected(output)
        XCTAssertEqual(parsed[0], ["APKRUN-PORT-0"])
        XCTAssertEqual(parsed[1], ["APKRUN-PORT-2"])
        XCTAssertEqual(parsed[2], [])
    }

    func testReadyPortsComeFromTheReaderListing() {
        let listing = "out-3\nready-3\nready-19\nready-18\npid-3\nraw-3\n"
        XCTAssertEqual(ConsolePortMarkerPlan.readyPorts(listing), [3, 19, 18])
    }
}

/// The T2 check of #095 step 1, criterion (a): the markers reach their own ports on the Android dev boot.
///
/// Run it with `-test-timeouts-enabled NO`. The connect, boot-state, reader, and marker budgets together can pass
/// xcodebuild's default 10-minute allowance (IR-895).
final class AndroidConsolePortTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["APKRUN_INTEGRATION_SUITE"] == "android-adb" else {
            throw XCTSkip("The console port marker check runs in the AndroidADB test-plan configuration.")
        }
    }

    /// Every marked port of the dev boot passes its own marker through to its reader. hvc18 is excluded by design
    /// (ConsolePortMarkerPlan.sensorsPort).
    func testMarkersReachTheirReadersOnEveryMarkedPort() async throws {
        let bundle = try AndroidBootSession.bundleDirectory()
        print("port-check adb \(try AndroidTestEnvironment.adbExecutable().path)")
        let run = try VMRunResources.new(environment: ProcessInfo.processInfo.environment)
        let boot = ConsolePortMarkerBoot(run: run)
        let results: [ConsolePortMarkerResult]
        do {
            try await boot.start(bundle: bundle)
            let bootState = try await boot.waitForGuest(connectBudget: .seconds(300), bootBudget: .seconds(120))
            print("port-check guest \(bootState)")
            results = try await boot.checkMarkers()
        } catch {
            await boot.finish()
            VMRunResources.removeHomeOrReport(run.home)
            throw error
        }
        await boot.finish()
        VMRunResources.removeHomeOrReport(run.home)

        for result in results {
            print("port-check \(result.line)")
        }
        let missing = results.filter { !$0.passed }
        XCTAssertEqual(
            missing.map(\.port),
            [],
            "the marker did not reach its own reader whole on: \(missing.map(\.line).joined(separator: "; "))"
        )
    }
}
