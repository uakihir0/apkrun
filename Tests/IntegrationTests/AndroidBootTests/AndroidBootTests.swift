import Darwin
import DiagnosticsCore
import Foundation
import ImageCore
import RuntimeCore
import RuntimeHost
import XCTest

/// T2 checks of the Android boot on the product path (android-image.md §6, §13; #012-#014).
///
/// They run in the `AndroidBoot` test-plan configuration of `IntegrationTests` and skip under
/// the `LinuxGuest` configuration.
final class AndroidBootTests: XCTestCase {
    /// The budget for the first init line and the block devices (#012 step 6).
    private static let kernelBudget = Duration.seconds(120)

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["APKRUN_INTEGRATION_SUITE"] == "android-boot" else {
            throw XCTSkip("Android boot checks run in the AndroidBoot test-plan configuration.")
        }
    }

    /// #012 step 6: the kernel gets past early init and detects the configured virtio devices.
    ///
    /// The boot runs without developer mode, so no serial shell is attached and the stop is a
    /// forced stop. The first-stage lines that come before `virtio_console` is loaded are not
    /// on hvc0 (IR-306), so the check does not look for them there. `Kernel command line:`,
    /// `Booting Linux on physical CPU`, and the other early lines are checked over the serial
    /// shell in #013.
    func testKernelBoot() async throws {
        let home = try AndroidBootFixture.makeHome()
        defer { removeTestHome(home) }
        let fixture = try await AndroidBootFixture(home: home, bundle: AndroidBootFixture.bundleDirectory())
        try await fixture.resetInstance()
        let supervisor = fixture.supervisor(developerMode: false)
        let console = ConsoleBuffer()
        let collector = Task {
            for await event in supervisor.events {
                if case .console(let bytes) = event {
                    console.append(bytes)
                }
            }
        }
        let boot = Task { try await supervisor.ensureReady(.cli) }

        let reachedInit = await console.wait(within: Self.kernelBudget) { text in
            text.contains("] init: ") && Self.partitionCount(of: "vdb", in: text.components(separatedBy: "\n")) != nil
        }
        let stopped = await ConsoleBuffer.completes(within: .seconds(60)) {
            await supervisor.stop()
            _ = await boot.result
        }
        collector.cancel()
        XCTAssertTrue(reachedInit, "the first init line and vdb appear on hvc0 within \(Self.kernelBudget)")
        XCTAssertTrue(stopped, "the forced stop returns within 60 s; console: \(console.text.suffix(400))")

        let lines = try fixture.newestBootLog().components(separatedBy: "\n")
        XCTAssertEqual(Self.partitionCount(of: "vda", in: lines), 9, "vda has nine partitions")
        XCTAssertEqual(Self.partitionCount(of: "vdb", in: lines), 4, "vdb has four partitions")
        XCTAssertTrue(
            lines.contains { $0.contains("virtio_blk") && $0.contains("[vda]") },
            "virtio_blk probes vda"
        )
        XCTAssertTrue(
            lines.contains { $0.contains("[drm] pci: virtio-gpu-pci detected") },
            "the headless profile's virtio-gpu is probed"
        )
        XCTAssertTrue(
            lines.contains { $0.contains("Loaded kernel module") && $0.contains("vmw_vsock_virtio_transport.ko") },
            "first-stage init loads the vsock transport"
        )
        XCTAssertFalse(lines.contains { $0.contains("Kernel panic - not syncing") }, "the kernel does not panic")
    }

    /// #012 step 6, with the observed outcome (IR-361).
    ///
    /// The test is named for what it checks: a truncated ramdisk stalls the boot in the kernel. It does not
    /// check panic detection. A truncated ramdisk fails while the kernel unpacks it, before first-stage init has
    /// loaded `virtio_console`. The panic text cannot reach hvc0 at that point, so `.kernelPanic` never fires. The
    /// boot then produces no phase progress and ends with `.bootStalled(kernel)` once the stall limit passes. The
    /// `.kernelPanic` path itself is covered by the T0 detector tests over captured console logs
    /// (`BootPhaseDetectorTests`); no T2 check produces a live panic.
    func testTruncatedRamdiskStallsBoot() async throws {
        let home = try AndroidBootFixture.makeHome()
        defer { removeTestHome(home) }
        let bundle = try AndroidBootFixture.bundleDirectory()
        // The truncated copy is not signed, so it is not installed: the test image is the installed image
        // with the truncated folder as its root (the planner reads only the files the manifest names).
        let installed = try await AndroidBootFixture(home: home, bundle: bundle).image
        let truncated = try AndroidBootFixture.truncatedBundle(from: bundle, into: home)
        let fixture = AndroidBootFixture(
            home: home,
            image: InstalledImage(version: installed.version, root: truncated, manifest: installed.manifest)
        )
        try await fixture.resetInstance()
        let timeouts = BootTimeouts(
            whole: .seconds(60),
            firstBoot: .seconds(60),
            stall: .seconds(30),
            firstBootStall: .seconds(30)
        )
        let supervisor = fixture.supervisor(developerMode: false, timeouts: timeouts)

        let returned = await ConsoleBuffer.completes(within: .seconds(120)) {
            _ = try? await supervisor.ensureReady(.cli)
        }
        XCTAssertTrue(returned, "the truncated boot ends within 120 s")
        let state = await supervisor.state
        XCTAssertEqual(state, .failed(.bootStalled(phase: .kernel)), "a truncated ramdisk must not boot")
        let lines = try fixture.newestBootLog().components(separatedBy: "\n")
        XCTAssertFalse(lines.contains { $0.contains("] init: ") }, "the truncated boot never reaches init")
    }

    /// A stop that arrives while the VM is starting ends the boot and returns. The VM controller refuses a stop
    /// while it is starting, so the boot must stop the VM itself once the start returns (`RuntimeSupervisor`).
    /// A second `ensureReady` during the boot is refused, and it does not cancel the stop.
    func testStopDuringStartReturnsAndStopsTheVM() async throws {
        let home = try AndroidBootFixture.makeHome()
        defer { removeTestHome(home) }
        let fixture = try await AndroidBootFixture(home: home, bundle: AndroidBootFixture.bundleDirectory())
        try await fixture.resetInstance()
        let supervisor = fixture.supervisor(developerMode: false)
        let collector = Task {
            for await _ in supervisor.events {}
        }
        let boot = Task { try await supervisor.ensureReady(.cli) }
        // The VM takes about 100 ms to reach running, so 40 ms after the boot starts it is usually still starting.
        // The log line `Rejected VM lifecycle operation from starting to stopping` shows the window was hit.
        try await Task.sleep(for: .milliseconds(40))
        do {
            try await supervisor.ensureReady(.cli)
            XCTFail("a second ensureReady must be refused while a boot is in progress")
        } catch {
            XCTAssertEqual(error.qualifiedCode, "runtime.androidBootFailed")
        }
        let stopped = await ConsoleBuffer.completes(within: .seconds(90)) {
            await supervisor.stop()
        }
        XCTAssertTrue(stopped, "stop() returns within 90 s while the VM is starting")
        switch await boot.result {
        case .failure:
            break
        case .success:
            XCTFail("the boot must end with a failure when it is stopped during start")
        }
        let state = await supervisor.state
        XCTAssertEqual(state, .stopped)
        collector.cancel()
    }

    /// #013 step 1-6: init runs, and the serial shell shows what hvc0 cannot (`AndroidShellConsole`).
    ///
    /// The boot runs in developer mode so that hvc1 answers. The expected bootconfig is the planner's
    /// merged block of the same instance, so the check compares the kernel with what was sent.
    func testReachesInit() async throws {
        let home = try AndroidBootFixture.makeHome()
        defer { removeTestHome(home) }
        let fixture = try await AndroidBootFixture(home: home, bundle: AndroidBootFixture.bundleDirectory())
        try await fixture.resetInstance()
        let expected = try await Self.plannedBootconfig(fixture)
        let supervisor = fixture.supervisor(developerMode: true)
        let console = ConsoleBuffer()
        let collector = Task {
            for await event in supervisor.events {
                if case .console(let bytes) = event {
                    console.append(bytes)
                }
            }
        }

        var failure: Error?
        var record = ""
        do {
            try await supervisor.ensureReady(.cli)
            record = try await Self.verifyInit(
                fixture,
                console: console,
                shell: await supervisor.shell,
                expectedBootconfig: expected
            )
        } catch {
            failure = error
        }
        let stopped = await ConsoleBuffer.completes(within: .seconds(90)) {
            await supervisor.stop()
        }
        collector.cancel()
        XCTAssertTrue(stopped, "the developer-mode stop returns within 90 s")
        let attachment = XCTAttachment(string: record)
        attachment.lifetime = .keepAlways
        add(attachment)
        if let failure {
            throw failure
        }
    }

    /// #095 step 3 and step 6: the in-guest KeyMint and Gatekeeper are running, `/data` is mounted, and
    /// LockSettings did not stall on Weaver (`logcat -s LockSettingsService`).
    func testHostServiceSubstitutes() async throws {
        let home = try AndroidBootFixture.makeHome()
        defer { removeTestHome(home) }
        let fixture = try await AndroidBootFixture(home: home, bundle: AndroidBootFixture.bundleDirectory())
        try await fixture.resetInstance()
        let supervisor = fixture.supervisor(developerMode: true)
        let collector = Task {
            for await _ in supervisor.events {}
        }
        var failure: Error?
        do {
            try await supervisor.ensureReady(.cli)
            let shellOrNil = await supervisor.shell
            let android = AndroidShellConsole(shell: try XCTUnwrap(shellOrNil))
            let keymint = try await android.value("service list | grep -c keymint")
            XCTAssertNotEqual(keymint, "0", "KeyMint is registered")
            let gatekeeper = try await android.value("service list | grep -c -i gatekeeper")
            XCTAssertNotEqual(gatekeeper, "0", "Gatekeeper is registered")
            let data = try await android.value("grep -c ' /data ' /proc/mounts")
            XCTAssertNotEqual(data, "0", "/data is mounted")
            let weaverStalls = try await android.value(
                "logcat -d -s LockSettingsService | grep -ci -e weaver -e timed -e fail")
            XCTAssertEqual(weaverStalls, "0", "LockSettings does not stall on Weaver")
        } catch {
            failure = error
        }
        let stopped = await ConsoleBuffer.completes(within: .seconds(90)) {
            await supervisor.stop()
        }
        collector.cancel()
        XCTAssertTrue(stopped, "the developer-mode stop returns within 90 s")
        if let failure {
            throw failure
        }
    }

    /// #014 step 1 and step 6: `sys.boot_completed` is 1 over the serial shell, and the boot wrote its
    /// record to `perf/boots.jsonl` with the markers in order from `VM_START`.
    func testBootCompleted() async throws {
        let home = try AndroidBootFixture.makeHome()
        defer { removeTestHome(home) }
        let fixture = try await AndroidBootFixture(home: home, bundle: AndroidBootFixture.bundleDirectory())
        try await fixture.resetInstance()
        let supervisor = fixture.supervisor(developerMode: true)
        let collector = Task {
            for await _ in supervisor.events {}
        }
        var failure: Error?
        do {
            try await supervisor.ensureReady(.cli)
            let state = await supervisor.state
            XCTAssertEqual(state, .ready)
            let shellOrNil = await supervisor.shell
            let shell = try XCTUnwrap(shellOrNil)
            let completed = try await AndroidShellConsole(shell: shell).output("getprop sys.boot_completed")
            XCTAssertEqual(completed.trimmingCharacters(in: .whitespacesAndNewlines), "1")
        } catch {
            failure = error
        }
        let stopped = await ConsoleBuffer.completes(within: .seconds(90)) {
            await supervisor.stop()
        }
        collector.cancel()
        XCTAssertTrue(stopped, "the developer-mode stop returns within 90 s")
        if let failure {
            throw failure
        }

        let records = try String(contentsOf: fixture.paths.bootPerformanceFile, encoding: .utf8)
            .split(separator: "\n")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(BootRecord.self, from: Data(try XCTUnwrap(records.last).utf8))
        XCTAssertEqual(record.outcome, "ready")
        XCTAssertEqual(record.markers["VM_START"], 0)
        let order = [
            "VM_START", "KERNEL_START", "ANDROID_INIT", "SYSTEM_SERVER_READY", "BOOT_COMPLETED", "RUNTIME_READY",
        ]
        let times = order.compactMap { record.markers[$0] }
        XCTAssertEqual(times.count, order.count, "every marker is recorded: \(record.markers.keys.sorted())")
        XCTAssertEqual(times, times.sorted(), "the markers are in boot order")
    }

    /// #014 step 6: the console and VM states pass through the phases in order, and the boot ends ready.
    func testPhasesInOrder() async throws {
        let home = try AndroidBootFixture.makeHome()
        defer { removeTestHome(home) }
        let fixture = try await AndroidBootFixture(home: home, bundle: AndroidBootFixture.bundleDirectory())
        try await fixture.resetInstance()
        let supervisor = fixture.supervisor(developerMode: false)
        let states = StateCollector()
        let collector = Task {
            for await event in supervisor.events {
                if case .state(let state) = event {
                    states.append(state)
                }
            }
        }
        var failure: Error?
        do {
            try await supervisor.ensureReady(.cli)
        } catch {
            failure = error
        }
        let stopped = await ConsoleBuffer.completes(within: .seconds(90)) {
            await supervisor.stop()
        }
        collector.cancel()
        XCTAssertTrue(stopped, "the stop returns within 90 s")
        if let failure {
            throw failure
        }
        let expected: [RuntimeState] = [
            .booting(.kernel), .booting(.`init`), .booting(.systemServer), .booting(.bootCompleted), .ready,
        ]
        let observed = states.values.filter { expected.contains($0) }
        XCTAssertEqual(observed, expected, "the boot enters each phase once, in order")
    }

    /// #014 step 4: the developer console socket relays the serial shell to a client.
    ///
    /// The socket server is the only consumer of the hvc1 output, so the test reads the answer from the
    /// client's end of the socket.
    func testDevConsoleShell() async throws {
        let home = try AndroidBootFixture.makeHome()
        defer { removeTestHome(home) }
        let fixture = try await AndroidBootFixture(home: home, bundle: AndroidBootFixture.bundleDirectory())
        try await fixture.resetInstance()
        let supervisor = fixture.supervisor(developerMode: true)
        let consoles = DevConsoleSocketServer(directory: fixture.paths.devConsoleDirectory)
        let relay = Task {
            for await event in supervisor.events {
                if case .devConsole(let endpoint) = event, endpoint.name == "hvc1" {
                    do throws(RuntimeFailure) {
                        try consoles.serve(endpoint)
                    } catch {
                        XCTFail("the developer console socket could not be created: \(error)")
                    }
                }
            }
        }
        var failure: Error?
        do {
            try await supervisor.ensureReady(.cli)
            let socket = try DevConsoleSocketClient.connect(
                console: "hvc1", directory: fixture.paths.devConsoleDirectory)
            defer { Darwin.close(socket) }
            let command = Data("getprop sys.boot_completed; echo SHELL_DONE\n".utf8)
            _ = command.withUnsafeBytes { Darwin.write(socket, $0.baseAddress, $0.count) }
            // The echo of the typed line ends in "echo SHELL_DONE", so only an output line starts with a newline.
            let reply = Self.readSocket(socket, until: "\nSHELL_DONE", seconds: 60)
            let lines = reply.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            XCTAssertTrue(lines.contains("1"), "sys.boot_completed reads 1 through the socket: \(reply.suffix(200))")
        } catch {
            failure = error
        }
        let stopped = await ConsoleBuffer.completes(within: .seconds(90)) {
            await supervisor.stop()
        }
        relay.cancel()
        consoles.stop()
        XCTAssertTrue(stopped, "the developer-mode stop returns within 90 s")
        if let failure {
            throw failure
        }
    }

    /// Reads from `descriptor` until `marker` appears or `seconds` pass.
    private static func readSocket(_ descriptor: Int32, until marker: String, seconds: Int) -> String {
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            var pending = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&pending, 1, 200) > 0 else { continue }
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { break }
            collected.append(contentsOf: buffer[0..<count])
            if String(decoding: collected, as: UTF8.self).contains(marker) { break }
        }
        return String(decoding: collected, as: UTF8.self)
    }

    /// The merged bootconfig and command line the planner gives this instance (android-image.md §6.1).
    static func plannedBootconfig(_ fixture: AndroidBootFixture) async throws -> [String: String] {
        let loaded = try await fixture.store.load(image: fixture.image)
        let instance = try XCTUnwrap(loaded)
        let plan = try AndroidBootPlanner(paths: fixture.paths).prepareBoot(
            image: fixture.image,
            instance: instance,
            options: BootOptions(gpuProfile: .headless, developerMode: true, captureLogcat: false)
        )
        return Dictionary(uniqueKeysWithValues: plan.bootconfig.map { ($0.key, $0.value) })
    }

    private static func verifyInit(
        _ fixture: AndroidBootFixture,
        console: ConsoleBuffer,
        shell: AndroidSerialShell?,
        expectedBootconfig: [String: String]
    ) async throws -> String {
        let text = console.text
        XCTAssertTrue(text.contains("] init: "), "init writes to hvc0")
        XCTAssertTrue(text.contains("init: starting service"), "init starts services")
        guard let shell else {
            throw AndroidShellConsole.CheckFailure(command: "serial shell", detail: "no shell in developer mode")
        }
        let android = AndroidShellConsole(shell: shell)

        // Long command lines are echoed with line-editing artifacts on hvc1, so the guest writes dmesg to a
        // file and each check greps it with a short command. Bracket classes (`[f]irst`) keep the echoed
        // command from matching its own pattern.
        _ = try await android.output("sh -c 'dmesg > /dev/apkrun-dmesg.txt'", root: true)
        let probe = try await android.output("wc -l /dev/apkrun-dmesg.txt", root: true)
        let firstStage = try await Self.grep(android, "init: init [f]irst stage")
        let secondStage = try await Self.grep(android, "init: init [s]econd stage")
        let booting = try await Self.grep(android, "Booting Linux on physical C[P]U")
        let kernelCommandLineLines = try await Self.grep(android, "Kernel command [l]ine")
        let avcLines = try await Self.grep(android, "avc: [d]enied")
        let logicalPartitions = try await Self.grep(android, "Created logical partition sy[s]tem_a")
        // The count comes from the probe. `wc -l < file` would open the root-only copy as the shell user,
        // before `su` runs, and fail with exit status 1 when the copy is not readable by that user.
        let counts = probe.split(whereSeparator: \.isNewline).compactMap { line in
            line.split(whereSeparator: \.isWhitespace).first.flatMap { Int($0) }
        }
        XCTAssertTrue((counts.last ?? 0) > 100, "the dmesg copy holds the boot: \(probe)")
        XCTAssertTrue(
            logicalPartitions.contains("Created logical partition system_a"),
            "first-stage init created the logical partitions of slot _a"
        )
        XCTAssertTrue(firstStage.contains("init: init first stage started!"), "first-stage init is in dmesg (\(probe))")
        XCTAssertTrue(secondStage.contains("init: init second stage started!"), "second-stage init is in dmesg")
        XCTAssertTrue(booting.contains("Booting Linux on physical CPU"), "the kernel booted on the CPU")
        let kernelLines = kernelCommandLineLines.components(separatedBy: "\n")
        let manifest = fixture.image.manifest
        let commandLine = try String(contentsOf: fixture.image.url(of: manifest.boot.cmdline.path), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let loggedCommandLine = kernelLines.first { $0.contains("Kernel command line: ") }?
            .components(separatedBy: "Kernel command line: ").last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(loggedCommandLine, Self.kernelCommandLine(commandLine), "dmesg shows the kernel command line")
        let procCommandLine = try await android.output("cat /proc/cmdline").trimmingCharacters(
            in: .whitespacesAndNewlines)
        XCTAssertEqual(procCommandLine, Self.kernelCommandLine(commandLine), "/proc/cmdline is the kernel command line")

        let listing = try await android.output("cat /proc/bootconfig", root: true)
        let kernelBootconfig = BootconfigListing.keyValues(in: listing)
        XCTAssertEqual(kernelBootconfig, expectedBootconfig, "/proc/bootconfig equals the merged block")

        _ = try await android.output("ls /dev/rtc0", root: true)
        // Each virtio device's id and the driver bound to it (the device directory's driver link).
        let devices = try await android.output(
            "sh -c 'for d in /sys/bus/virtio/devices/*; do echo $(cat $d/device) $(basename $(readlink $d/driver)); done'",
            root: true
        )
        let bound = Set(devices.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        for expected in [
            "0x0001 virtio_net", "0x0002 virtio_blk", "0x0003 virtio_console", "0x0004 virtio_rng",
            "0x0013 vmw_vsock_virtio_transport",
        ] {
            XCTAssertTrue(bound.contains(expected), "\(expected) is bound")
        }

        let enforce = try await android.output("getenforce").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(enforce, "Enforcing", "SELinux runs as the reference")
        XCTAssertEqual(
            avcLines.components(separatedBy: "\n").filter { $0.contains("avc: denied") }.count, 0, "no AVC denials")

        let byName = try await android.output("ls -l /dev/block/by-name", root: true)
        let names = byName.components(separatedBy: "\n").compactMap { line -> String? in
            guard let arrow = line.range(of: " -> ") else { return nil }
            return line[..<arrow.lowerBound].split(separator: " ").last.map(String.init)
        }
        let labels = manifest.disks.flatMap { $0.partitions.map(\.label) }
        let missingLabels = labels.filter { !names.contains($0) }
        XCTAssertEqual(missingLabels, [], "every GPT label of the disk plan is in /dev/block/by-name")

        let fstab = try await android.output("ls /vendor/etc/", root: true)
        XCTAssertTrue(fstab.contains("fstab.cf.f2fs.hctr2"), "the fstab_suffix selects the fstab")
        let mounts = try await android.output("cat /proc/mounts", root: true)
        XCTAssertTrue(
            mounts.contains("/dev/block/dm-") && mounts.contains(" / erofs "), "the root is a dm-verity erofs")
        XCTAssertTrue(mounts.contains(" /data f2fs "), "/data is mounted as f2fs")
        XCTAssertTrue(mounts.contains(" /metadata ext4 "), "/metadata is mounted as ext4")

        for (property, expectedValue) in [
            ("ro.boot.verifiedbootstate", "orange"),
            ("ro.boot.slot_suffix", "_a"),
            ("ro.debuggable", "1"),
        ] {
            let value = try await android.output("getprop \(property)").trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(value, expectedValue, "\(property)")
        }
        let fingerprint = try await android.output("getprop ro.build.fingerprint")
        XCTAssertFalse(
            fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "the build fingerprint is set")

        // AVB lines come from first-stage init on hvc0, so the console text has them.
        let avbLines = text.components(separatedBy: "\n").filter { $0.contains("libfs_avb") }
        XCTAssertFalse(avbLines.isEmpty, "first-stage init verified the AVB chain")
        let avbErrors = avbLines.filter { line in
            line.range(of: "rror|fail", options: [.regularExpression, .caseInsensitive]) != nil
                && !Self.unsignedImageAVBMessages.contains { line.contains($0) }
        }
        XCTAssertEqual(avbErrors, [], "the only libfs_avb errors are the unsigned development vbmeta messages")

        let record = [
            "planned bootconfig:\n\(expectedBootconfig.sorted { $0.key < $1.key }.map { "\($0.key) = \"\($0.value)\"" }.joined(separator: "\n"))",
            "kernel bootconfig:\n\(listing)",
            "dmesg lines: \(probe)",
            "dmesg head:\n\(try await android.output("head -n 4 /dev/apkrun-dmesg.txt | cut -c1-160", root: true))",
            "devices (id driver):\n\(devices)",
            "by-name:\n\(byName)",
            "mounts:\n\(try await android.output("cat /proc/mounts", root: true))",
            "lsmod:\n\(try await android.output("lsmod", root: true))",
        ].joined(separator: "\n")
        return record
    }

    /// The AVB messages a development bundle produces: its vbmeta is unsigned, so AVB reports
    /// `OK_NOT_SIGNED` and an unknown key for `/system` and `/system_dlkm`, and the boot continues
    /// with `verifiedbootstate=orange` (IR-364, android-image.md §13 CF-16).
    private static let unsignedImageAVBMessages = [
        "Error verifying vbmeta image: OK_NOT_SIGNED",
        "public key data shouldn't be empty",
        "Found unknown public key used to sign",
        "status: VerificationError",
    ]

    /// The lines of the guest's dmesg copy that match `pattern`.
    private static func grep(_ android: AndroidShellConsole, _ pattern: String) async throws -> String {
        try await android.run("grep '\(pattern)' /dev/apkrun-dmesg.txt", root: true).output
    }

    /// What `/proc/cmdline` and the kernel's log show: the bootconfig `kernel.*` key is appended first,
    /// then the kernel's built-in command line (`CONFIG_CMDLINE`, visible in the boot/kernel image), and
    /// then `cmdline.txt` unchanged (IR-365). The reference kernel prints the same order.
    static func kernelCommandLine(_ commandLine: String) -> String {
        "vmw_vsock_virtio_transport_common.virtio_transport_max_vsock_pkt_buf_size=16384 console=ttynull "
            + "stack_depot_disable=on cgroup_disable=pressure kasan.stacktrace=off kvm-arm.mode=protected bootconfig "
            + commandLine
    }

    /// The number of partitions the kernel listed for `disk` (`vda: vda1 … vda9`).
    static func partitionCount(of disk: String, in lines: [String]) -> Int? {
        for line in lines {
            guard let range = line.range(of: "\(disk): \(disk)1") else { continue }
            let listing = line[range.lowerBound...].dropFirst(disk.count + 2)
            return listing.split(separator: " ").filter { $0.hasPrefix(disk) }.count
        }
        return nil
    }
}

/// Collects runtime states from a supervisor's event stream.
final class StateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [RuntimeState] = []

    func append(_ state: RuntimeState) {
        lock.withLock { states.append(state) }
    }

    var values: [RuntimeState] {
        lock.withLock { states }
    }
}
