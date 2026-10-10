import Foundation
import GraphicsCore
import VirtualMachineCore
import XCTest

/// T2 check of the headless virgl path: kmscube renders through Mesa's virgl driver on the
/// Linux test guest, and the host reads no pixels back (graphics.md §12 step 2, #022).
final class VirglTests: XCTestCase {
    func testKmscubeRendersHeadlesslyThroughVirglWithoutHostReadbacks() async throws {
        // The host runtime is the copy that scripts/build-test-initramfs.sh stages in the artifact directory. Without
        // the override, the DEBUG lookup walks up from the test host to the checkout under ~/Documents (GraphicsBridge.m),
        // and loading it there waits on the macOS approval prompt (IR-600).
        let runtime = try LinuxGuestHarness.artifactURLs().kernel
            .deletingLastPathComponent()
            .appendingPathComponent("virgl-runtime", isDirectory: true)
        XCTAssertEqual(setenv("APKRUN_VIRGL_RUNTIME_PATH", runtime.path, 1), 0)
        let device = try VirtioGPUDevice.virgl()
        let result = try await LinuxGuestHarness.run(
            testCase: self,
            stopBehavior: .guestPowerOff,
            powerOff: true,
            tests: ["virgl"],
            customDevices: [device]
        )

        XCTAssertEqual(result.records.first, .bootOK)
        XCTAssertEqual(result.records.last, .done)
        let detail = try okDetail(named: "virgl", in: result.records)
        XCTAssertTrue(detail.contains("renderer=virgl "), detail)
        XCTAssertTrue(detail.contains("requested=60 reported=59"), detail)
        XCTAssertEqual(device.statistics.hostReadbacks, 0)
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
}
