import Foundation
import GraphicsCore
import VirtualMachineCore
import XCTest

/// T2 check of the headless virgl path: kmscube renders through Mesa's virgl driver on the
/// Linux test guest, and the host reads no pixels back (graphics.md §12 step 2, #022).
final class VirglTests: XCTestCase {
    func testKmscubeRendersHeadlesslyThroughVirglWithoutHostReadbacks() async throws {
        // The host runtime is the copy that scripts/tools/stage-hosted-test-inputs.sh stages beside the kernel. The
        // override also replaces any TEST_RUNNER_ value. Without it, the DEBUG lookup walks up from the test host to
        // the checkout under ~/Documents (GraphicsBridge.m), which the test process must not read (IR-600, IR-602).
        let library = try LinuxGuestHarness.stagedInput("virgl-runtime/libvirglrenderer.1.dylib")
        XCTAssertEqual(setenv("APKRUN_VIRGL_RUNTIME_PATH", library.deletingLastPathComponent().path, 1), 0)
        // The recorder is attached only when the environment names a file. It writes the renderer operations of the run
        // in the replay format, for the replay test of graphics.md §14 (M02-graphics.md #022 step 3). The file must be
        // under /tmp, so it stays out of the checkout and out of protected folders.
        // The path is standardized first, so a `..` segment cannot leave /tmp.
        let recordingURL = ProcessInfo.processInfo.environment["APKRUN_TEST_VIRGL_RECORDING"].map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
        if let recordingURL, !recordingURL.path.hasPrefix("/tmp/") {
            XCTFail("APKRUN_TEST_VIRGL_RECORDING must name a file under /tmp: \(recordingURL.path)")
            return
        }
        let recorder = recordingURL == nil ? nil : VirGLRecorder()
        let device = try VirtioGPUDevice.virgl(recorder: recorder)
        let result = try await LinuxGuestHarness.run(
            testCase: self,
            stopBehavior: .guestPowerOff,
            powerOff: true,
            tests: ["virgl"],
            customDevices: [device]
        )
        if let recordingURL, let recorder {
            try recorder.writeRecording(to: recordingURL)
        }

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
