import CryptoKit
import Foundation
import GraphicsCore
import VirtualMachineCore
import XCTest

private final class TraceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [VirtioGPUDevice.TraceRecord] = []

    func append(_ record: VirtioGPUDevice.TraceRecord) {
        lock.withLock { stored.append(record) }
    }

    var records: [VirtioGPUDevice.TraceRecord] {
        lock.withLock { stored }
    }
}

/// T2 checks of the virtio-gpu device: the probe and EDID, and the R-01 hotplug spike
/// (graphics.md §12, #019).
final class GPUDeviceTests: XCTestCase {
    func testLinuxGuestDetectsTheVirtioGPUAndReadsTheGeneratedEDID() async throws {
        let trace = TraceRecorder()
        let result = try await LinuxGuestHarness.run(
            testCase: self,
            stopBehavior: .guestPowerOff,
            powerOff: true,
            tests: ["gpu"],
            customDevices: [VirtioGPUDevice(traceObserver: { trace.append($0) })]
        )
        // The exchanged bytes become the golden driver trace of graphics.md §12 (#019 step 1).
        try writeDriverTrace(trace.records)

        XCTAssertEqual(result.records.first, .bootOK)
        XCTAssertEqual(result.records.last, .done)
        let detail = try okDetail(named: "gpu", in: result.records)
        XCTAssertTrue(detail.contains("scanouts=16"), detail)
        XCTAssertTrue(detail.contains("connectors=16"), detail)
        XCTAssertTrue(detail.contains("virtual1=connected"), detail)

        // Scanout 0 is the test mode, so the guest's EDID must equal the golden block of that mode.
        let golden = try Data(contentsOf: goldenEDIDURL(named: "scanout-00-1024x768-60.edid"))
        let expectedSHA = SHA256.hash(data: golden).map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(detail.contains("edid_sha256=\(expectedSHA)"), detail)
    }

    func testHotplugSpikeShowsScanoutOneInTheGuestDRMConnector() async throws {
        do {
            let result = try await LinuxGuestHarness.run(
                testCase: self,
                stopBehavior: .guestPowerOff,
                powerOff: true,
                tests: ["gpu", "gpu-hotplug"],
                customDevices: [VirtioGPUDevice(hotplugSpikeDelay: .seconds(3))]
            )
            XCTAssertEqual(result.records.last, .done)
            // The guest's own timing shows when the DRM connector reported the change (R-01).
            let detail = try okDetail(named: "gpu-hotplug", in: result.records)
            let attachment = XCTAttachment(string: "R-01 gpu-hotplug: \(detail)")
            attachment.lifetime = .keepAlways
            add(attachment)
        } catch LinuxGuestHarness.HarnessFailure.guestCheckFailed(let name, let detail) where name == "gpu-hotplug" {
            // R-01 negative result: a config-space update did not raise a guest display event.
            XCTFail("R-01: scanout 1 did not reach the guest DRM connector: \(detail)")
        }
    }

    /// Writes the captured exchanges next to the guest artifacts, outside the repository.
    private func writeDriverTrace(_ records: [VirtioGPUDevice.TraceRecord]) throws {
        let directory = try LinuxGuestHarness.artifactURLs().kernel.deletingLastPathComponent()
        let entries: [[String: Any]] = records.map { record in
            [
                "queue": record.queueIndex == 0 ? "control" : "cursor",
                "request": hexString(record.request),
                "response": record.response.map(hexString) ?? NSNull(),
            ]
        }
        let document: [String: Any] = [
            "provenance": "Captured by GPUDeviceTests from the test Linux guest (gpu check) with virtio_gpu.",
            "records": entries,
        ]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("gpu-driver-trace.json"))
    }

    private func hexString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func okDetail(named name: String, in records: [TestGuestRecord]) throws -> String {
        let detail = records.lazy.compactMap { record -> String? in
            if case .check(name: name, result: .ok, detail: let detail) = record {
                return detail
            }
            return nil
        }.first
        return try XCTUnwrap(detail, "no ok record for \(name)")
    }

    /// The golden EDID block, which `scripts/build-test-initramfs.sh` copies beside the kernel. The test does not read
    /// `Tests/Fixtures/graphics/edid/` in the checkout: a test process that reads ~/Documents waits on the macOS
    /// approval prompt (IR-600).
    private func goldenEDIDURL(named name: String) throws -> URL {
        try LinuxGuestHarness.artifactURLs().kernel.deletingLastPathComponent().appendingPathComponent(name)
    }
}
