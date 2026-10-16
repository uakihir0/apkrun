import Foundation
import GraphicsCore
import VirtualMachineCore
import XCTest

/// T2 check that the Linux guest runs kmscube through VirGL without reported renderer failures.
/// A bounded resource 4 backing sample checks for nonzero guest memory before its first submission; this does not verify pixels.
/// `hostReadbacks` is not instrumented yet (IR-816).
final class VirglTests: XCTestCase {
    func testKmscubeHasNonzeroResource4BackingWithoutRendererFailures() async throws {
        // The host runtime is the copy that scripts/tools/stage-hosted-test-inputs.sh stages beside the kernel. The
        // override also replaces any TEST_RUNNER_ value. Without it, the DEBUG lookup walks up from the test host to
        // the checkout under ~/Documents (GraphicsBridge.m), which the test process must not read (IR-600, IR-602).
        let library = try LinuxGuestHarness.stagedInput("virgl-runtime/libvirglrenderer.1.dylib")
        XCTAssertEqual(setenv("APKRUN_VIRGL_RUNTIME_PATH", library.deletingLastPathComponent().path, 1), 0)
        // The recorder is always attached for the bounded guest-backing sample. It writes renderer operations only when
        // the environment names a file, in the replay format for graphics.md §14 (M02-graphics.md #022 step 3). The
        // file must be under /tmp, so it stays out of the checkout and out of protected folders.
        // The path is standardized first, so a `..` segment cannot leave /tmp.
        let recordingURL = ProcessInfo.processInfo.environment["APKRUN_TEST_VIRGL_RECORDING"].map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
        if let recordingURL, !recordingURL.path.hasPrefix("/tmp/") {
            XCTFail("APKRUN_TEST_VIRGL_RECORDING must name a file under /tmp: \(recordingURL.path)")
            return
        }
        let recorder = VirGLRecorder(
            observingGuestResourceIDs: [4],
            recordsOperations: recordingURL != nil
        )
        let device = try VirtioGPUDevice.virgl(recorder: recorder)
        let result = try await LinuxGuestHarness.run(
            testCase: self,
            stopBehavior: .guestPowerOff,
            powerOff: true,
            tests: ["virgl"],
            customDevices: [device]
        )
        if let recordingURL {
            try recorder.writeRecording(to: recordingURL)
        }

        XCTAssertEqual(result.records.first, .bootOK)
        XCTAssertEqual(result.records.last, .done)
        let detail = try okDetail(named: "virgl", in: result.records)
        XCTAssertTrue(detail.contains("renderer=virgl "), detail)
        XCTAssertTrue(detail.contains("requested=60 reported=59"), detail)
        let statistics = device.statistics
        XCTAssertEqual(statistics.hostReadbacks, 0)
        XCTAssertEqual(
            statistics.rendererFailures,
            0,
            "VirGL recorded \(statistics.rendererFailures) renderer failure(s)."
        )
        let resource4Backing = try XCTUnwrap(
            recorder.guestBackingObservationsForTest().first { $0.resourceID == 4 },
            "kmscube never submitted resource 4 with guest backing attached."
        )
        XCTAssertGreaterThan(resource4Backing.rangeCount, 0)
        XCTAssertGreaterThanOrEqual(resource4Backing.sampledByteCount, 864)
        XCTAssertGreaterThan(
            resource4Backing.nonzeroByteCount,
            0,
            "The sampled host pointer for resource 4 exposed only zero bytes before its first submission."
        )
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
