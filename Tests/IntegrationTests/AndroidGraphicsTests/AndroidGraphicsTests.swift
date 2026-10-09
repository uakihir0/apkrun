import Foundation
import ImageCore
import RuntimeCore
import XCTest

/// T2 checks of the virtio-gpu device on the Android boot (#021; graphics.md §12, android-image.md §7).
///
/// They run in the `AndroidGraphics` configuration of IntegrationTests.xctestplan, with the `guestSwiftshader`
/// profile. They need the Android bundle of `scripts/build-test-android-bundle.sh` and adb under ANDROID_HOME.
/// Android does not reach `boot_completed` with this profile before #022 (graphics.md §12). So the check does not
/// wait for readiness: it waits for adb, reads the guest, saves the capture, and stops Android.
final class AndroidGraphicsTests: XCTestCase {
    /// The wait for the guest's adbd. A first boot has 900 s for the whole boot (BootTimeouts.standard).
    private static let adbBudget = Duration.seconds(600)
    /// The virtio device ID of virtio-gpu (virtio_gpu_ids: VIRTIO_ID_GPU), as the `device` attribute prints it.
    private static let virtioGPUDeviceID: UInt32 = 16
    /// The connectors that `virtio_gpu` creates: one per scanout, named `card0-Virtual-N`.
    private static let connectorNames = (1...16).map { "card0-Virtual-\($0)" }

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["APKRUN_INTEGRATION_SUITE"] == "android-graphics" else {
            throw XCTSkip("The Android graphics checks run in the AndroidGraphics test-plan configuration.")
        }
    }

    /// #021 acceptance: Android binds `virtio_gpu` to APKRun's device, `card0` has 16 `Virtual-N` connectors, and
    /// only `Virtual-1` (scanout 0) is connected.
    func testVirtioGPUBinds() async throws {
        // The adb lookup skips the test when there is no SDK. It runs before the boot, so a skip never stops a VM.
        let adbExecutable = try AndroidTestEnvironment.adbExecutable()
        let home = try AndroidBootFixture.makeHome()
        defer { removeTestHome(home) }
        let bundle = try AndroidBootFixture.bundleDirectory()
        let fixture = try await AndroidBootFixture(home: home, bundle: bundle)
        try await fixture.resetInstance()
        let supervisor = fixture.supervisor(developerMode: true, gpuProfile: .guestSwiftshader)
        let console = ConsoleBuffer()
        let collector = Task {
            for await event in supervisor.events {
                if case .console(let bytes) = event {
                    console.append(bytes)
                }
            }
        }
        // The check reads the guest while Android runs, and stops Android after the capture. The boot wait is not
        // awaited on its own terms, so a boot that stalls before `ready` still gets its capture.
        let boot = Task { try? await supervisor.ensureReady(.cli) }

        let captured: Result<GraphicsCapture, Error>
        do {
            let adb = AdbClient(executable: adbExecutable)
            try await adb.connect(timeout: Self.adbBudget)
            // SELinux keeps the shell from reading the DRM connector status, so the capture runs as root (#021).
            try await adb.restartAsRoot()
            captured = .success(try await Self.capture(adb: adb, consoleText: console.text))
        } catch {
            captured = .failure(error)
        }
        await supervisor.stop()
        _ = await boot.value
        collector.cancel()

        let directory = bundle.deletingLastPathComponent().appendingPathComponent("android-graphics", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try console.text.write(
            to: directory.appendingPathComponent("hvc0-console.log"),
            atomically: true,
            encoding: .utf8
        )

        let capture: GraphicsCapture
        switch captured {
        case .success(let value):
            capture = value
        case .failure(let error):
            XCTFail("the guest capture did not complete: \(error). Console tail: \(console.text.suffix(400))")
            return
        }
        try capture.save(to: directory, attach: { add($0) })

        let gpu = capture.virtioDevices.first { $0.deviceID == Self.virtioGPUDeviceID }
        XCTAssertEqual(gpu?.driver, "virtio_gpu", "device 16 is bound to virtio_gpu: \(capture.virtioDevices)")
        XCTAssertEqual(
            capture.connectors.map(\.name).sorted(),
            Self.connectorNames.sorted(),
            "card0 has exactly the 16 Virtual-N connectors"
        )
        XCTAssertEqual(
            capture.connectors.filter { $0.status == .connected }.map(\.name),
            ["card0-Virtual-1"],
            "only Virtual-1 (scanout 0) is connected"
        )
        XCTAssertTrue(
            capture.connectors.filter { $0.name != "card0-Virtual-1" }.allSatisfy { $0.status == .disconnected },
            "every other connector is disconnected: \(capture.connectors)"
        )
        XCTAssertTrue(capture.drmListing.contains("card0"), "/sys/class/drm lists card0")
    }

    /// Reads the guest. The kernel log comes from `dmesg` over adb, and from the hvc0 console when adb refuses it.
    private static func capture(adb: AdbClient, consoleText: String) async throws -> GraphicsCapture {
        let kernelLog: String
        let kernelLogSource: String
        do {
            kernelLog = try await adb.dmesg()
            kernelLogSource = "dmesg over adb"
        } catch {
            // A user build may restrict dmesg. The kernel console carries the same messages from boot (android-image.md §7.1).
            kernelLog = consoleText
            kernelLogSource = "hvc0 console, because dmesg over adb failed: \(error.qualifiedCode)"
        }
        return GraphicsCapture(
            kernelLog: kernelLog,
            kernelLogSource: kernelLogSource,
            connectors: try await adb.drmConnectors(),
            virtioDevices: try await adb.virtioDevices(),
            drmListing: try await adb.shell("ls -l /sys/class/drm /dev/dri").output,
            bootCompleted: try await adb.getprop("sys.boot_completed")
        )
    }
}

/// The guest state that the #021 check reads, saved next to the bundle as its artifact.
private struct GraphicsCapture {
    let kernelLog: String
    let kernelLogSource: String
    let connectors: [AdbDRMConnector]
    let virtioDevices: [AdbVirtioDevice]
    let drmListing: String
    /// `sys.boot_completed` when the capture was taken. Android need not be complete for the #021 check.
    let bootCompleted: String

    /// Writes the capture into `directory` and attaches each file to the test report.
    func save(to directory: URL, attach: (XCTAttachment) -> Void) throws {
        let files: [(String, String)] = [
            (
                "summary.txt",
                "sys.boot_completed=\(bootCompleted)\nkernel-log source: \(kernelLogSource)\n"
            ),
            (
                "kernel-log.txt",
                "source: \(kernelLogSource)\n\n\(kernelLog)"
            ),
            (
                "drm-connectors.txt",
                connectors.map { "\($0.name) \($0.status.rawValue)" }.joined(separator: "\n")
                    + "\n\n# ls -l /sys/class/drm /dev/dri\n" + drmListing
            ),
            (
                "virtio-devices.txt",
                virtioDevices.map { device in
                    let id = device.deviceID.map { String(format: "0x%04x", $0) } ?? ""
                    return "\(device.name) device=\(id) driver=\(device.driver ?? "")"
                }.joined(separator: "\n")
            ),
        ]
        for (name, text) in files {
            try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
            let attachment = XCTAttachment(string: text)
            attachment.name = name
            attachment.lifetime = .keepAlways
            attach(attachment)
        }
    }
}
