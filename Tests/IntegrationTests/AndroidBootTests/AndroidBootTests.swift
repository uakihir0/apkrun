import DiagnosticsCore
import Foundation
import ImageCore
import RuntimeCore
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
        defer { try? FileManager.default.removeItem(at: home) }
        let fixture = try AndroidBootFixture(home: home, bundle: AndroidBootFixture.bundleDirectory())
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
    /// A truncated ramdisk fails while the kernel unpacks it, before first-stage init has loaded
    /// `virtio_console`. The panic text cannot reach hvc0 at that point, so `.kernelPanic` never
    /// fires. The boot then produces no phase progress and ends with `.bootStalled(kernel)` once
    /// the stall limit passes. The `.kernelPanic` path itself is covered by the T0 detector tests
    /// over captured console logs (`BootPhaseDetectorTests`).
    func testKernelPanicDetected() async throws {
        let home = try AndroidBootFixture.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let bundle = try AndroidBootFixture.bundleDirectory()
        let truncated = try AndroidBootFixture.truncatedBundle(from: bundle, into: home)
        let fixture = try AndroidBootFixture(home: home, bundle: truncated)
        try await fixture.resetInstance()
        let timeouts = BootTimeouts(
            whole: .seconds(60),
            firstBoot: .seconds(60),
            stall: .seconds(30),
            firstBootStall: .seconds(30)
        )
        let supervisor = fixture.supervisor(developerMode: false, timeouts: timeouts)

        var failure: RuntimeBootFailure?
        do {
            try await supervisor.ensureReady(.cli)
            XCTFail("a truncated ramdisk must not boot")
        } catch {
            failure = error
        }
        XCTAssertEqual(failure, .bootStalled(phase: .kernel))
        let state = await supervisor.state
        XCTAssertEqual(state, .failed(.bootStalled(phase: .kernel)))
        let lines = try fixture.newestBootLog().components(separatedBy: "\n")
        XCTAssertFalse(lines.contains { $0.contains("] init: ") }, "the truncated boot never reaches init")
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
