import DiagnosticsCore
import Foundation
import GraphicsCore
import VirtualMachineCore
import XCTest

/// T2 check that the Linux guest runs kmscube through VirGL without reported renderer failures.
/// A bounded resource 4 backing sample checks for nonzero guest memory before its first submission; this does not verify pixels.
/// `hostReadbacks` has no increment path: the product has no host readback, and scripts/check-readback.sh keeps it so
/// (graphics.md §7).
final class VirglTests: XCTestCase {
    func testKmscubeHasNonzeroResource4BackingWithoutRendererFailures() async throws {
        try installStagedVirGLRuntime()
        // The recorder is always attached for the bounded guest-backing sample. It writes renderer operations only when
        // the environment names a file, in the replay format for graphics.md §14 (M02-graphics.md #23 step 3). The
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

    func testGuestResetCompletesWithPausedKmscubeAndAttachedVirGLBacking() async throws {
        try installStagedVirGLRuntime()
        let recorder = VirGLRecorder(
            observingGuestResourceIDs: [4],
            recordsOperations: false
        )
        let logSink = VirglTestLogSink()
        let device = try lifecycleDevice(recorder: recorder, logSink: logSink)
        let bootCounter = VirglGuestBootCounter()
        let guestChecks = VirglGuestCheckObserver()
        let evidence = VirglLifecycleEvidence()
        let result = try await LinuxGuestHarness.run(
            testCase: self,
            stopBehavior: .observeGuestReboot(afterCheck: "virgl-reset"),
            powerOff: true,
            tests: ["virgl-lifecycle"],
            customDevices: [device],
            recordObserver: { record in
                bootCounter.record(record)
                guestChecks.record(record)
            },
            hostAction: { controller in
                try await Self.waitForGuestBoot(bootCounter, controller: controller)
                try controller.console(.systemConsole)
                    .writeHostInput(Data("APKRUN-VIRGL-RUN\n".utf8))
                try await Self.waitForGuestCheck(
                    "virgl-lifecycle-ready",
                    guestChecks: guestChecks,
                    controller: controller
                )
                _ = try await Self.waitForResource4Backing(
                    recorder,
                    controller: controller
                )
                try controller.console(.systemConsole)
                    .writeHostInput(Data("pause\n".utf8))
                try await Self.waitForGuestCheck(
                    "virgl-lifecycle-paused",
                    guestChecks: guestChecks,
                    controller: controller
                )
                try await Self.commitLifecycleOperation(
                    "reset",
                    recorder: recorder,
                    evidence: evidence,
                    guestChecks: guestChecks,
                    logSink: logSink,
                    controller: controller
                )
            },
            extraCommandLine: ["apkrun.test.virgl.lifecycle_gate=1"],
            logSink: logSink
        )

        assertLiveResource4Backing(try XCTUnwrap(evidence.observation))
        XCTAssertEqual(try okDetail(named: "virgl-lifecycle-ready", in: result.records), "kmscube process is running")
        XCTAssertEqual(try okDetail(named: "virgl-lifecycle-paused", in: result.records), "kmscube paused")
        XCTAssertEqual(
            try okDetail(named: "virgl-lifecycle-operation-ready", in: result.records),
            "reset requested; kmscube paused"
        )
        XCTAssertEqual(
            try okDetail(named: "virgl-reset", in: result.records),
            "reset committed with kmscube paused"
        )
        XCTAssertEqual(result.rebootObservation, .guestRestarted)
        assertGuestRebootWasObserved(result.records, markerName: "virgl-reset")
        XCTAssertTrue(result.states.contains(.running), "\(result.states)")
        XCTAssertEqual(result.states.last, .stopped)
        XCTAssertTrue(result.states.contains(.paused), "\(result.states)")
        XCTAssertFalse(result.states.contains { if case .failed = $0 { true } else { false } })
        XCTAssertEqual(device.statistics.rendererFailures, 0)

        let messages = logSink.messages
        let starts = messages.indices.filter { messages[$0].contains("virtio-gpu DRIVER_OK") }
        XCTAssertGreaterThanOrEqual(starts.count, 2)
        guard starts.count >= 2 else { return }
        let resetIndex = try XCTUnwrap(
            messages.indices.first {
                $0 > starts[0] && $0 < starts[1] && messages[$0].contains("virtio-gpu reset:")
            },
            "No virtio-gpu reset was logged between guest generations."
        )
        let stopIndex = try XCTUnwrap(
            messages.indices.first {
                $0 > starts[1] && messages[$0].contains("virtio-gpu stop")
            },
            "The VM stop was not logged after the second guest generation."
        )
        XCTAssertLessThan(starts[0], resetIndex)
        XCTAssertLessThan(resetIndex, starts[1])
        XCTAssertLessThan(starts[1], stopIndex)
    }

    func testForcedStopCompletesWithPausedKmscubeAndAttachedVirGLBacking() async throws {
        try installStagedVirGLRuntime()
        let recorder = VirGLRecorder(
            observingGuestResourceIDs: [4],
            recordsOperations: false
        )
        let logSink = VirglTestLogSink()
        let device = try lifecycleDevice(recorder: recorder, logSink: logSink)
        let bootCounter = VirglGuestBootCounter()
        let guestChecks = VirglGuestCheckObserver()
        let evidence = VirglLifecycleEvidence()
        let result = try await LinuxGuestHarness.run(
            testCase: self,
            stopBehavior: .forcedAfterConsoleLine("APKRUN-TEST: virgl-stop-ready"),
            powerOff: true,
            tests: ["virgl-lifecycle"],
            customDevices: [device],
            recordObserver: { record in
                bootCounter.record(record)
                guestChecks.record(record)
            },
            hostAction: { controller in
                try await Self.waitForGuestBoot(bootCounter, controller: controller)
                try controller.console(.systemConsole)
                    .writeHostInput(Data("APKRUN-VIRGL-RUN\n".utf8))
                try await Self.waitForGuestCheck(
                    "virgl-lifecycle-ready",
                    guestChecks: guestChecks,
                    controller: controller
                )
                _ = try await Self.waitForResource4Backing(
                    recorder,
                    controller: controller
                )
                try controller.console(.systemConsole)
                    .writeHostInput(Data("pause\n".utf8))
                try await Self.waitForGuestCheck(
                    "virgl-lifecycle-paused",
                    guestChecks: guestChecks,
                    controller: controller
                )
                try await Self.commitLifecycleOperation(
                    "stop",
                    recorder: recorder,
                    evidence: evidence,
                    guestChecks: guestChecks,
                    logSink: logSink,
                    controller: controller
                )
            },
            extraCommandLine: ["apkrun.test.virgl.lifecycle_gate=1"],
            logSink: logSink
        )

        assertLiveResource4Backing(try XCTUnwrap(evidence.observation))
        XCTAssertTrue(result.records.contains(.bootOK))
        XCTAssertEqual(try okDetail(named: "virgl-lifecycle-ready", in: result.records), "kmscube process is running")
        XCTAssertEqual(try okDetail(named: "virgl-lifecycle-paused", in: result.records), "kmscube paused")
        XCTAssertEqual(
            try okDetail(named: "virgl-lifecycle-operation-ready", in: result.records),
            "stop requested; kmscube paused"
        )
        XCTAssertEqual(try okDetail(named: "virgl-stop-ready", in: result.records), "kmscube paused")
        XCTAssertTrue(result.states.contains(.running), "\(result.states)")
        XCTAssertEqual(result.states.last, .stopped)
        XCTAssertTrue(result.states.contains(.paused), "\(result.states)")
        XCTAssertFalse(result.states.contains { if case .failed = $0 { true } else { false } })
        XCTAssertEqual(device.statistics.rendererFailures, 0)
        XCTAssertTrue(logSink.messages.contains("virtio-gpu stop"))
    }

    private func installStagedVirGLRuntime() throws {
        // The hosted test must load the staged library, not walk back into the checkout under ~/Documents (IR-600, IR-602).
        let library = try LinuxGuestHarness.stagedInput("virgl-runtime/libvirglrenderer.1.dylib")
        XCTAssertEqual(setenv("APKRUN_VIRGL_RUNTIME_PATH", library.deletingLastPathComponent().path, 1), 0)
    }

    private func lifecycleDevice(
        recorder: VirGLRecorder,
        logSink: VirglTestLogSink
    ) throws -> VirtioGPUDevice {
        try VirtioGPUDevice.virgl(
            logger: APKLogger(category: GraphicsLogCategory.device, sink: logSink),
            recorder: recorder
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

    private func assertLiveResource4Backing(_ observation: VirGLGuestBackingObservation) {
        XCTAssertEqual(observation.resourceID, 4)
        XCTAssertGreaterThan(observation.rangeCount, 0)
        XCTAssertGreaterThanOrEqual(observation.sampledByteCount, 864)
        XCTAssertGreaterThan(
            observation.nonzeroByteCount,
            0,
            "The sampled host pointer for resource 4 exposed only zero bytes."
        )
    }

    private func assertGuestRebootWasObserved(
        _ records: [TestGuestRecord],
        markerName: String
    ) {
        guard
            let markerIndex = records.firstIndex(where: {
                if case .check(name: let name, result: .ok, detail: _) = $0 {
                    return name == markerName
                }
                return false
            })
        else {
            XCTFail("The guest did not report the \(markerName) marker.")
            return
        }
        let bootIndices = records.indices.filter { records[$0] == .bootOK }
        XCTAssertEqual(bootIndices.count, 2)
        guard bootIndices.count == 2 else { return }
        XCTAssertLessThan(bootIndices[0], markerIndex)
        XCTAssertGreaterThan(bootIndices[1], markerIndex)
    }

    private static func waitForGuestBoot(
        _ bootCounter: VirglGuestBootCounter,
        controller: VMController
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while clock.now < deadline {
            if bootCounter.count > 0 { return }
            try await requireRunning(controller)
            try await Task.sleep(for: .milliseconds(10))
        }
        throw VirglLifecycleFailure.guestBootMarkerTimedOut
    }

    private static func waitForResource4Backing(
        _ recorder: VirGLRecorder,
        controller: VMController
    ) async throws -> VirGLGuestBackingObservation {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while clock.now < deadline {
            if let observation = recorder.guestBackingObservationIfAttachedForTest(resourceID: 4) {
                return observation
            }
            try await requireRunning(controller)
            try await Task.sleep(for: .milliseconds(10))
        }
        throw VirglLifecycleFailure.resource4BackingObservationTimedOut
    }

    private static func waitForGuestCheck(
        _ name: String,
        guestChecks: VirglGuestCheckObserver,
        controller: VMController
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while clock.now < deadline {
            if let record = guestChecks.record(named: name) {
                switch record {
                case .check(name: _, result: .ok, detail: _):
                    return
                case .check(name: _, result: .fail, let detail):
                    throw VirglLifecycleFailure.guestCheckFailed(name: name, detail: detail)
                default:
                    break
                }
            }
            try await requireRunning(controller)
            try await Task.sleep(for: .milliseconds(10))
        }
        throw VirglLifecycleFailure.guestCheckTimedOut(name)
    }

    private static func commitLifecycleOperation(
        _ operation: String,
        recorder: VirGLRecorder,
        evidence: VirglLifecycleEvidence,
        guestChecks: VirglGuestCheckObserver,
        logSink: VirglTestLogSink,
        controller: VMController
    ) async throws {
        try controller.console(.systemConsole)
            .writeHostInput(Data("\(operation)\n".utf8))
        try await waitForGuestCheck(
            "virgl-lifecycle-operation-ready",
            guestChecks: guestChecks,
            controller: controller
        )

        // Pausing serializes this barrier after prior virtio queue notifications; deviceWillPause drains the renderer
        // before the controller reports .paused. The guest stays blocked at the operation handshake until resumed.
        try await controller.pause()
        guard
            await controller.state == .paused,
            logSink.messages.contains("virtio-gpu pause: renderer work drained")
        else {
            throw VirglLifecycleFailure.vmPauseDidNotDrainRendererWork
        }
        guard
            let observation = recorder.guestBackingObservationIfAttachedForTest(
                resourceID: 4
            )
        else {
            throw VirglLifecycleFailure.resource4BackingDetachedBeforeLifecycleCommit
        }
        evidence.record(observation)
        try await controller.resume()
        try controller.console(.systemConsole)
            .writeHostInput(Data("commit-\(operation)\n".utf8))
    }

    private static func requireRunning(_ controller: VMController) async throws {
        let state = await controller.state
        guard state == .running else {
            throw VirglLifecycleFailure.vmStoppedBeforeLifecycleCheckCompleted
        }
    }
}

private enum VirglLifecycleFailure: Error {
    case guestBootMarkerTimedOut
    case guestCheckTimedOut(String)
    case guestCheckFailed(name: String, detail: String)
    case resource4BackingObservationTimedOut
    case resource4BackingDetachedBeforeLifecycleCommit
    case vmPauseDidNotDrainRendererWork
    case vmStoppedBeforeLifecycleCheckCompleted
}

private final class VirglGuestBootCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    var count: Int {
        lock.withLock { storedCount }
    }

    func record(_ record: TestGuestRecord) {
        guard record == .bootOK else { return }
        lock.withLock {
            storedCount += 1
        }
    }
}

private final class VirglGuestCheckObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var checks: [String: TestGuestRecord] = [:]

    func record(_ record: TestGuestRecord) {
        guard case .check(name: let name, result: _, detail: _) = record else { return }
        lock.withLock {
            checks[name] = record
        }
    }

    func record(named name: String) -> TestGuestRecord? {
        lock.withLock { checks[name] }
    }
}

private final class VirglLifecycleEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var storedObservation: VirGLGuestBackingObservation?

    var observation: VirGLGuestBackingObservation? {
        lock.withLock { storedObservation }
    }

    func record(_ observation: VirGLGuestBackingObservation) {
        lock.withLock {
            storedObservation = observation
        }
    }
}

private final class VirglTestLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storedMessages: [String] = []

    var messages: [String] {
        lock.withLock { storedMessages }
    }

    func write(_ entry: LogEntry) {
        lock.withLock {
            storedMessages.append(entry.publicMessage)
        }
    }

    func isEnabled(for level: LogLevel) -> Bool {
        level != .debug
    }
}
