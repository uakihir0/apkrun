import AppKit
import CryptoKit
import Foundation
import RuntimeAPI
import RuntimeCore
import XCTest

private struct AndroidImageVariantReceipt: Decodable {
    let variantDiskSHA256: String
    let variantManifestSHA256: String
}

/// The pointer checks of #25 on a real Android guest (T2), through the path of `apkrun dev launch`.
///
/// Each test boots the test image with the embedded runtime (`DevBoot` and `DevInputRoute`), shows the development
/// window, and posts the pointer events into the window's content view. The existing tests synthesize `NSEvent`s
/// directly and need no Accessibility permission. The #103 interactive test opts into WindowServer `CGEvent`s and
/// requires permission only on its dedicated lab GUI session. Points are display pixels of display 0, mapped to the
/// window by `CoordinateMapper`. The targets are the centres of their `uiautomator` bounds, except the drag, which uses
/// fixed points inside HelloCompose's list.
///
/// Showing the development window activates it. The edge-clamping and #103 cases therefore run only on a dedicated lab
/// GUI session. The edge-clamping case is enabled only by the `AndroidInputEdges` test-plan configuration.
///
/// The suite runs in the Xcode test host (IR-438). Its boot needs a working guest renderer, which the odm7 overlay gives
/// (IR-1278), and the host dismisses the keyguard before it launches the app (IR-1285). The device checks of the
/// coordinator's scripted runs post the same gestures with the CGEvent helper in /tmp (decision D14). The suite runs only
/// with APKRUN_INPUT_T2=1, which the AndroidInput configurations of IntegrationTests.xctestplan set. The
/// `AndroidInputEdges` configuration also sets APKRUN_INPUT_EDGE_T2=1. The suite needs
/// APKRUN_GUEST_DIR (the Guest Agent bundle), APKRUN_FIXTURE_APK (HelloText, a debug build: its `TEXT` and `DETAILS`
/// broadcasts exist only there), and APKRUN_FIXTURE_COMPOSE_APK (HelloCompose). The `AndroidInput` configuration also
/// enables the #101 Guest Agent restart test with APKRUN_INPUT_REBIND_T2=1. A missing input skips its test and names the
/// variable.
///
/// The keyboard cases (#26) post AppKit key events into the window's view, as the pointer cases post pointer events. The
/// field's text is read from the fixture's `text` line after a `TEXT` broadcast, and the screens and the editor action
/// from their log lines, so each case checks the state it needs and not only that a command ran.
///
/// For FR-IN-06 the sequence samples the process list for `adb ... shell input` commands, and must find none. The adb
/// shell count of the apkrun boot is printed by `apkrun dev boot` when the input binds and when it stops, and the device
/// checks record it (IR-1248). This suite cannot read that count, because the boot runs in another process.
@MainActor
final class AndroidInputTests: XCTestCase {
    private static let helloText = "io.apkrun.fixture.hellotext"
    private static let helloCompose = "io.apkrun.fixture.hellocompose"
    private static let buttonID = "io.apkrun.fixture.hellotext:id/increment_button"
    private static let contextTargetID = "io.apkrun.fixture.hellotext:id/context_target"
    private static let clickPrefix = "APKRUN-FIXTURE: click "
    private static let rowPrefix = "APKRUN-FIXTURE: scroll first="

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["APKRUN_INPUT_T2"] == "1" else {
            throw XCTSkip("The input checks run with APKRUN_INPUT_T2=1, in the AndroidInput test-plan configuration.")
        }
    }

    func testImageVariantIdentityIncludesReceiptAndDigests() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-image-variant-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let bundle = parent.appendingPathComponent("android-bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let receipt = parent.appendingPathComponent("android-bundle.variant.json")
        let receiptData = Data(
            #"{"variantDiskSHA256":"disk-digest","variantManifestSHA256":"manifest-digest"}"#.utf8)
        try receiptData.write(to: receipt)

        let identity = try Self.imageVariantIdentity(for: bundle)

        XCTAssertEqual(identity["receipt_path"] as? String, receipt.path)
        XCTAssertEqual(identity["receipt_sha256"] as? String, try Self.sha256(of: receipt))
        XCTAssertEqual(identity["variant_disk_sha256"] as? String, "disk-digest")
        XCTAssertEqual(identity["variant_manifest_sha256"] as? String, "manifest-digest")
    }

    func testImageVariantIdentityMarksMissingReceiptExplicitly() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-image-variant-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let bundle = parent.appendingPathComponent("android-bundle", isDirectory: true)

        let identity = try Self.imageVariantIdentity(for: bundle)

        XCTAssertTrue(identity["receipt_path"] is NSNull)
        XCTAssertTrue(identity["receipt_sha256"] is NSNull)
        XCTAssertTrue(identity["variant_disk_sha256"] is NSNull)
        XCTAssertTrue(identity["variant_manifest_sha256"] is NSNull)
    }

    /// A forced Guest Agent restart rebinds the same window's input route without rebooting Android (#101).
    func testWindowInputRebindsAfterGuestAgentRestartWithoutRebooting() async throws {
        guard ProcessInfo.processInfo.environment["APKRUN_INPUT_REBIND_T2"] == "1" else {
            throw XCTSkip("Run only with APKRUN_INPUT_REBIND_T2=1 in the AndroidInput test-plan configuration.")
        }
        let apk = try Self.fixture("APKRUN_FIXTURE_APK")
        try await AndroidInputRun.with(apk: apk, package: Self.helloText) { run in
            let target = try await run.centre(of: Self.buttonID)
            guard let initialCount = try await Self.persistedClickCount(run) else {
                throw AndroidInputRunFailure.timedOut("the fixture's initial persisted click counter")
            }
            XCTAssertEqual(initialCount, 0)

            let bootIDBefore = try await Self.androidBootID(run)
            let agentPIDBefore = try await Self.guestAgentPID(run)
            let rebindCountBefore = run.inputRouteRebindCount()
            let countersBefore = try await run.inputCounters()
            let killed = try await run.adb.shell("kill -9 \(agentPIDBefore)")
            guard killed.status == 0 else {
                throw AndroidInputRunFailure.timedOut("SIGKILL of Guest Agent PID \(agentPIDBefore)")
            }

            try await run.waitForInputRouteRebind(after: rebindCountBefore)
            let agentPIDAfter = try await Self.guestAgentPID(run)
            let bootIDAfter = try await Self.androidBootID(run)
            XCTAssertNotEqual(agentPIDAfter, agentPIDBefore, "the Guest Agent must have restarted")
            XCTAssertEqual(bootIDAfter, bootIDBefore, "Android must stay in the same boot")

            try await run.activateWindowForInput()
            try await run.drainInput()
            let countersBeforeClick = try await run.inputCounters()
            let touchPhasesBeforeClick = try await run.inputWireTouchPhaseCounts()
            try await run.pointer().click(at: target)
            try await run.drainInput()
            let countersAfter = try await run.inputCounters()
            let touchPhaseDelta = try await run.inputWireTouchPhaseCounts().delta(since: touchPhasesBeforeClick)
            let clickLines = try await run.fixtureLog(
                until: { lines in lines.contains { $0.contains(Self.clickPrefix) } },
                timeout: .seconds(10)
            )
            XCTAssertEqual(AndroidInputRun.numbers(in: clickLines, after: Self.clickPrefix), [1])

            XCTAssertEqual(touchPhaseDelta, InputWireTouchPhaseCounts(down: 1, up: 1))
            XCTAssertEqual(countersAfter.eventsSent - countersBeforeClick.eventsSent, 2, "\(countersAfter)")
            XCTAssertEqual(
                countersAfter.droppedNotFocused - countersBeforeClick.droppedNotFocused, 0, "\(countersAfter)")
            XCTAssertEqual(countersAfter.droppedChannel - countersBefore.droppedChannel, 0, "\(countersAfter)")
            XCTAssertEqual(
                countersAfter.droppedNotRunning - countersBefore.droppedNotRunning, 0, "\(countersAfter)")
        }
    }

    /// 100 of 100 clicks on HelloText's button are logged as `APKRUN-FIXTURE: click <n>` (#25 acceptance). Each click is
    /// a left-button press and release at the button's centre, with no `adb shell input` process during the sequence.
    func testOneHundredClicksOnTheButtonAreLogged() async throws {
        let apk = try Self.fixture("APKRUN_FIXTURE_APK")
        try await AndroidInputRun.with(apk: apk, package: Self.helloText) { run in
            let target = try await run.centre(of: Self.buttonID)
            guard let initialCount = try await Self.persistedClickCount(run) else {
                throw AndroidInputRunFailure.timedOut("the fixture's initial persisted click counter")
            }
            XCTAssertEqual(initialCount, 0)
            let countersBefore = try await run.inputCounters()
            let touchPhasesBefore = try await run.inputWireTouchPhaseCounts()
            let sampler = ShellInputSampler()
            sampler.start()
            _ = try await run.adb.shell("logcat -c")
            let pointer = try run.pointer()
            for _ in 0..<100 {
                try await pointer.click(at: target)
                try await Task.sleep(for: .milliseconds(100))
            }
            let shellInput = await sampler.stop()
            XCTAssertEqual(shellInput, [], "adb shell input processes ran during the sequence")
            let lines = try await run.fixtureLog { $0.filter { $0.contains(Self.clickPrefix) }.count >= 100 }
            let clickNumbers = AndroidInputRun.numbers(in: lines, after: Self.clickPrefix)
            let touchPhaseDelta = try await run.inputWireTouchPhaseCounts().delta(since: touchPhasesBefore)
            let countersAfter = try await run.inputCounters()
            guard let finalCount = try await Self.persistedClickCount(run) else {
                throw AndroidInputRunFailure.timedOut("the fixture's final persisted click counter")
            }
            XCTAssertEqual(clickNumbers, Array(1...100))
            XCTAssertEqual(finalCount - initialCount, 100, "the fixture must persist every click callback")
            XCTAssertEqual(
                touchPhaseDelta, InputWireTouchPhaseCounts(down: 100, up: 100),
                "wire conversion must produce exactly one touch DOWN and UP for each click"
            )
            XCTAssertEqual(countersAfter.droppedRate - countersBefore.droppedRate, 0, "\(countersAfter)")
            XCTAssertEqual(countersAfter.droppedNotRunning - countersBefore.droppedNotRunning, 0, "\(countersAfter)")
            XCTAssertEqual(countersAfter.droppedChannel - countersBefore.droppedChannel, 0, "\(countersAfter)")
            XCTAssertEqual(countersAfter.coalesced - countersBefore.coalesced, 0, "\(countersAfter)")
        }
    }

    /// Drags beyond the left and top edges clamp in the host and release the guest touch before a later click.
    func testDragsBeyondTopAndLeftEdgesCloseTheGuestTouch() async throws {
        guard ProcessInfo.processInfo.environment["APKRUN_INPUT_EDGE_T2"] == "1" else {
            throw XCTSkip("Select AndroidInputEdges on a dedicated lab GUI session.")
        }
        let apk = try Self.fixture("APKRUN_FIXTURE_APK")
        try await AndroidInputRun.with(apk: apk, package: Self.helloText) { run in
            let target = try await run.centre(of: Self.buttonID)
            let pointer = try run.pointer()
            let start = pointer.viewPoint(for: target)
            let leftEdge = NSPoint(x: pointer.view.bounds.minX - 24, y: start.y)
            let topEdge = NSPoint(x: start.x, y: pointer.view.bounds.maxY + 24)

            guard let initialCount = try await Self.persistedClickCount(run) else {
                throw AndroidInputRunFailure.timedOut("the fixture's initial persisted click counter")
            }
            XCTAssertEqual(initialCount, 0)

            let captureStart = try await run.startTouchEventCapture()
            try await pointer.drag(from: target, toViewPoint: leftEdge, steps: 4)
            let afterLeftDragCapture = try await run.touchEventCaptureSnapshot()
            guard let leftDragThrough = afterLeftDragCapture.sentEvents.records.last?.batchSequence else {
                throw AndroidInputRunFailure.timedOut("the routed left-edge drag")
            }
            Self.assertClampedEdgeDrag(
                afterLeftDragCapture, afterSequence: UInt64(captureStart.batchesSent),
                throughSequence: leftDragThrough, startingAt: target, edge: .left)
            let leftDragAcknowledgement = try await run.acknowledgeLatestInput(with: pointer, at: target)
            XCTAssertEqual(
                leftDragAcknowledgement.rejectedEvents,
                0,
                "periodic ACK batch \(leftDragAcknowledgement.batchSequence) reported rejected input"
            )
            let afterLeftDrag = try await Self.waitForStablePersistedClickCount(run, exactly: 0)
            XCTAssertEqual(afterLeftDrag, 0, "the drag outside the left edge must not click the button")

            try await pointer.click(at: target)
            let leftRecoveryAcknowledgement = try await run.acknowledgeLatestInput(with: pointer, at: target)
            XCTAssertEqual(
                leftRecoveryAcknowledgement.rejectedEvents,
                0,
                "periodic ACK batch \(leftRecoveryAcknowledgement.batchSequence) reported rejected input"
            )
            let afterLeftRecovery = try await Self.waitForStablePersistedClickCount(run, exactly: 1)
            XCTAssertEqual(afterLeftRecovery, 1, "the left-edge release must leave the guest ready for a new touch")

            let topDragStartSequence = try await run.inputCounters().batchesSent
            try await pointer.drag(from: target, toViewPoint: topEdge, steps: 4)
            let afterTopDragCapture = try await run.touchEventCaptureSnapshot()
            guard let topDragThrough = afterTopDragCapture.sentEvents.records.last?.batchSequence else {
                throw AndroidInputRunFailure.timedOut("the routed top-edge drag")
            }
            Self.assertClampedEdgeDrag(
                afterTopDragCapture, afterSequence: UInt64(topDragStartSequence),
                throughSequence: topDragThrough, startingAt: target, edge: .top)
            let topDragAcknowledgement = try await run.acknowledgeLatestInput(with: pointer, at: target)
            XCTAssertEqual(
                topDragAcknowledgement.rejectedEvents,
                0,
                "periodic ACK batch \(topDragAcknowledgement.batchSequence) reported rejected input"
            )
            let afterTopDrag = try await Self.waitForStablePersistedClickCount(run, exactly: 1)
            XCTAssertEqual(afterTopDrag, 1, "the drag outside the top edge must not click the button")

            try await pointer.click(at: target)
            let topRecoveryAcknowledgement = try await run.acknowledgeLatestInput(with: pointer, at: target)
            XCTAssertEqual(
                topRecoveryAcknowledgement.rejectedEvents,
                0,
                "periodic ACK batch \(topRecoveryAcknowledgement.batchSequence) reported rejected input"
            )
            let afterTopRecovery = try await Self.waitForStablePersistedClickCount(run, exactly: 2)
            XCTAssertEqual(afterTopRecovery, 2, "the top-edge release must leave the guest ready for a new touch")

            let capture = try await run.stopTouchEventCapture()
            XCTAssertEqual(capture.touches.discardedRecords, 0)
            XCTAssertEqual(capture.sentEvents.discardedRecords, 0)
            XCTAssertEqual(capture.acknowledgements?.discardedRecords, 0)
            let counters = capture.counters
            XCTAssertEqual(counters.droppedRate, 0)
            XCTAssertEqual(counters.droppedNotRunning, 0)
            XCTAssertEqual(counters.droppedInvalid, 0)
            XCTAssertEqual(counters.droppedChannel, 0)
            XCTAssertEqual(counters.coalesced, 0)
        }
    }

    private enum ClampedEdge {
        case left
        case top
    }

    private static func assertClampedEdgeDrag(
        _ capture: InputTouchCaptureSnapshot,
        afterSequence: UInt64,
        throughSequence: UInt64,
        startingAt start: InputPixel,
        edge: ClampedEdge,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let sentTouches = capture.sentEvents.records.filter {
            $0.batchSequence > afterSequence && $0.batchSequence <= throughSequence
                && $0.kindAndPhase.hasPrefix("touch.")
        }
        let sentTimes = Set(sentTouches.map(\.hostTimeNanos))
        let touches = capture.touches.records.filter { sentTimes.contains($0.time.hostNanos) }
        let sentPhases = sentTouches.map(\.kindAndPhase)
        let touchPhases = touches.map { touch -> String in
            switch touch.phase {
            case .down: "touch.down"
            case .move: "touch.move"
            case .up: "touch.up"
            case .cancel: "touch.cancel"
            }
        }
        let expectedPhases = ["touch.down", "touch.move", "touch.move", "touch.move", "touch.move", "touch.up"]
        XCTAssertEqual(
            sentPhases, expectedPhases, "the complete drag must be sent to the guest", file: file, line: line)
        XCTAssertEqual(
            touchPhases, expectedPhases, "the translated drag must match the sent phases", file: file, line: line)
        XCTAssertEqual(
            touches.map(\.time.hostNanos), sentTouches.map(\.hostTimeNanos),
            "each sent drag event must match one translated touch", file: file, line: line)
        guard touches.count == expectedPhases.count else {
            return
        }
        XCTAssertEqual(touches[0].position.x, start.x, accuracy: 1, file: file, line: line)
        XCTAssertEqual(touches[0].position.y, start.y, accuracy: 1, file: file, line: line)
        for touch in touches {
            XCTAssertTrue((0..<1024).contains(touch.position.x), file: file, line: line)
            XCTAssertTrue((0..<768).contains(touch.position.y), file: file, line: line)
        }
        switch edge {
        case .left:
            XCTAssertEqual(touches.suffix(2).map(\.position.x), [0, 0], file: file, line: line)
        case .top:
            XCTAssertEqual(touches.suffix(2).map(\.position.y), [0, 0], file: file, line: line)
        }
    }

    /// Three product-cadence click batches through WindowServer must each change the persisted counter by 100.
    ///
    /// This test activates the APKRun window and moves the system pointer. Run it only in a dedicated lab GUI session
    /// with `APKRUN_INPUT_INTERACTIVE_T2=1`; it is skipped by default and never requests Accessibility permission.
    func testThreeConsecutiveHundredClickBatchesThroughWindowServer() async throws {
        guard ProcessInfo.processInfo.environment["APKRUN_INPUT_INTERACTIVE_T2"] == "1" else {
            throw XCTSkip("Run only on a dedicated lab GUI session with APKRUN_INPUT_INTERACTIVE_T2=1.")
        }
        try await runThreeConsecutiveHundredClickBatches(pointerDelivery: .windowServer)
    }

    /// Diagnostic only: exercises the product 50 ms press/gap cadence through direct view dispatch.
    ///
    /// This activates the APKRun window but bypasses WindowServer and AppKit window dispatch. It can compare cadence
    /// behavior without Accessibility permission, but cannot satisfy #25 box 3 or #103's WindowServer requirement.
    func testThreeConsecutiveHundredClickBatchesThroughDirectView() async throws {
        guard ProcessInfo.processInfo.environment["APKRUN_INPUT_CADENCE_T2"] == "1" else {
            throw XCTSkip("Run only with the AndroidInputCadence test-plan configuration.")
        }
        try await runThreeConsecutiveHundredClickBatches(pointerDelivery: .directView)
    }

    private func runThreeConsecutiveHundredClickBatches(pointerDelivery: InputPointerDelivery) async throws {
        let apk = try Self.fixture("APKRUN_FIXTURE_APK")
        try Self.attachEnvironmentIdentity(fixture: apk, pointerDelivery: pointerDelivery)
        try await AndroidInputRun.with(apk: apk, package: Self.helloText, pointerDelivery: pointerDelivery) { run in
            let target = try await run.centre(of: Self.buttonID)
            if pointerDelivery == .windowServer {
                try await run.prepareForWindowServerPointerDispatch()
            }
            let captureStartCounters = try await run.startAcknowledgementHistoryCapture()
            let firstAcknowledgedSequenceAfterCaptureStart =
                UInt64(captureStartCounters.batchesSent / 32 + 1) * 32
            try await Self.assertNoShellInputDuring {
                guard var previousCount = try await Self.persistedClickCount(run) else {
                    throw AndroidInputRunFailure.timedOut("the fixture's initial persisted click counter")
                }
                XCTAssertEqual(previousCount, 0, "a new guest should start with an empty HelloText counter")
                var previousWireTouchPhases = try await run.inputWireTouchPhaseCounts()
                let clickDeltas = [100, 100, 100]
                for (index, clickDelta) in clickDeltas.enumerated() {
                    var persistedCount: Int?
                    var counters: InputCounters?
                    var acknowledgements: InputAcknowledgementHistory?
                    var touchPhaseDelta: InputWireTouchPhaseCounts?
                    do {
                        _ = try await run.adb.shell("logcat -c")
                        let pointer = try run.pointer()
                        for _ in 0..<clickDelta {
                            try await pointer.click(at: target, interClickGap: .milliseconds(50))
                        }

                        let expectedCount = previousCount + clickDelta
                        let reachedCount = try await Self.waitForPersistedClickCount(
                            run, atLeast: expectedCount)
                        persistedCount = reachedCount
                        XCTAssertEqual(
                            reachedCount, expectedCount,
                            "batch \(index + 1) persisted \(reachedCount - previousCount) of \(clickDelta) clicks")

                        let sentCounters = try await run.inputCounters()
                        let wireTouchPhases = try await run.inputWireTouchPhaseCounts()
                        touchPhaseDelta = wireTouchPhases.delta(since: previousWireTouchPhases)
                        let expectedTouchPhases = InputWireTouchPhaseCounts(down: clickDelta, up: clickDelta)
                        let touchPhaseFailure =
                            touchPhaseDelta == expectedTouchPhases
                            ? nil
                            : "expected \(expectedTouchPhases), got \(touchPhaseDelta.map { String(describing: $0) } ?? "unavailable")"
                        XCTAssertEqual(
                            touchPhaseDelta, expectedTouchPhases,
                            "batch \(index + 1) wire touch phase counts: \(touchPhaseFailure ?? "unexpected mismatch")")
                        let lastAcknowledgedSequence = UInt64(sentCounters.batchesSent / 32 * 32)
                        if lastAcknowledgedSequence == 0 {
                            acknowledgements = try await run.acknowledgementHistory()
                        } else {
                            acknowledgements = try await run.waitForAcknowledgement(
                                through: lastAcknowledgedSequence)
                        }
                        let finalCounters = try await run.inputCounters()
                        counters = finalCounters
                        XCTAssertEqual(finalCounters.droppedRate, 0, "batch \(index + 1)")
                        XCTAssertEqual(finalCounters.droppedNotRunning, 0, "batch \(index + 1)")
                        XCTAssertEqual(
                            finalCounters.droppedInvalid, 0,
                            "batch \(index + 1); this aggregate includes invalid host input and guest rejections in received ACKs"
                        )
                        XCTAssertEqual(finalCounters.droppedChannel, 0, "batch \(index + 1)")
                        XCTAssertEqual(finalCounters.coalesced, 0, "batch \(index + 1)")

                        let expectedSequences: [UInt64]
                        if firstAcknowledgedSequenceAfterCaptureStart <= lastAcknowledgedSequence {
                            expectedSequences = stride(
                                from: Int(firstAcknowledgedSequenceAfterCaptureStart),
                                through: Int(lastAcknowledgedSequence),
                                by: 32
                            ).map(UInt64.init)
                        } else {
                            expectedSequences = []
                        }
                        let capturedSequences = acknowledgements?.records
                            .map(\.batchSequence)
                            .filter {
                                $0 >= firstAcknowledgedSequenceAfterCaptureStart
                                    && $0 <= lastAcknowledgedSequence
                            }
                        XCTAssertEqual(acknowledgements?.discardedRecords, 0, "the bounded ACK history overflowed")
                        XCTAssertEqual(
                            capturedSequences, expectedSequences,
                            "the normal ACK coverage did not match the 32-batch cadence")
                        XCTAssertTrue(
                            acknowledgements?.records.allSatisfy { $0.rejectedEvents == 0 } == true,
                            "a normal periodic ACK reported rejected guest input")
                        Self.attachBatchEvidence(
                            batch: index + 1,
                            before: previousCount,
                            after: reachedCount,
                            counters: finalCounters,
                            touchPhaseDelta: touchPhaseDelta,
                            acknowledgements: acknowledgements,
                            failure: touchPhaseFailure
                        )
                        previousCount = reachedCount
                        previousWireTouchPhases = wireTouchPhases
                    } catch {
                        if let currentCount = try? await Self.persistedClickCount(
                            run, timeout: .seconds(1))
                        {
                            persistedCount = currentCount
                        }
                        if let currentCounters = try? await run.inputCounters() {
                            counters = currentCounters
                        }
                        if let currentWireTouchPhases = try? await run.inputWireTouchPhaseCounts() {
                            touchPhaseDelta = currentWireTouchPhases.delta(since: previousWireTouchPhases)
                        }
                        if let currentAcknowledgements = try? await run.acknowledgementHistory() {
                            acknowledgements = currentAcknowledgements
                        }
                        Self.attachBatchEvidence(
                            batch: index + 1,
                            before: previousCount,
                            after: persistedCount,
                            counters: counters,
                            touchPhaseDelta: touchPhaseDelta,
                            acknowledgements: acknowledgements,
                            failure: String(describing: error)
                        )
                        throw error
                    }
                }
            }
        }
    }

    /// Captures one diagnostic batch across AppKit, the route, guest injection, View dispatch, and the click callback.
    ///
    /// The per-event ACK mode and debug touch listener perturb timing, so this is separate from the product-cadence test.
    /// Run only on a dedicated lab GUI session with `APKRUN_INPUT_TRACE_T2=1`.
    func testOneHundredClickDiagnosticTraceJoinsHostGuestAndFixture() async throws {
        guard ProcessInfo.processInfo.environment["APKRUN_INPUT_TRACE_T2"] == "1" else {
            throw XCTSkip("Run only on a dedicated lab GUI session with APKRUN_INPUT_TRACE_T2=1.")
        }
        try await runOneHundredClickDiagnosticTrace(pointerDelivery: .windowServer, untracedWarmupBatches: 0)
    }

    /// Diagnostic only: traces the second 100-click batch after an untraced warm-up through direct view dispatch.
    ///
    /// Per-event ACKs and the debug fixture listener perturb timing. The test activates the APKRun window, bypasses
    /// WindowServer/AppKit dispatch, and cannot satisfy #25 box 3 or #103's WindowServer requirement.
    func testOneHundredClickDiagnosticTraceJoinsHostGuestAndFixtureThroughDirectView() async throws {
        guard ProcessInfo.processInfo.environment["APKRUN_INPUT_TRACE_CADENCE_T2"] == "1" else {
            throw XCTSkip("Run only with the AndroidInputCadence test-plan configuration.")
        }
        try await runOneHundredClickDiagnosticTrace(pointerDelivery: .directView, untracedWarmupBatches: 1)
    }

    private func runOneHundredClickDiagnosticTrace(
        pointerDelivery: InputPointerDelivery,
        untracedWarmupBatches: Int
    ) async throws {
        let apk = try Self.fixture("APKRUN_FIXTURE_APK")
        try Self.attachEnvironmentIdentity(fixture: apk, pointerDelivery: pointerDelivery)
        try await AndroidInputRun.with(apk: apk, package: Self.helloText, pointerDelivery: pointerDelivery) { run in
            let target = try await run.centre(of: Self.buttonID)
            if pointerDelivery == .windowServer {
                try await run.prepareForWindowServerPointerDispatch()
            }
            let warmupClickCount = untracedWarmupBatches * 100
            guard let initial = try await Self.persistedClickCount(run) else {
                throw AndroidInputRunFailure.timedOut("the fixture's initial persisted click counter")
            }
            XCTAssertEqual(initial, 0, "a new guest should start with an empty HelloText counter")
            if warmupClickCount > 0 {
                let pointer = try run.pointer()
                for _ in 0..<warmupClickCount {
                    try await pointer.click(at: target, interClickGap: .milliseconds(50))
                }
                let warmedCounter = try await Self.waitForPersistedClickCount(run, atLeast: warmupClickCount)
                guard warmedCounter == warmupClickCount else {
                    throw AndroidInputRunFailure.timedOut(
                        "the untraced warm-up reached \(warmedCounter) clicks; expected \(warmupClickCount)")
                }
            }
            guard let before = try await Self.persistedClickCount(run) else {
                throw AndroidInputRunFailure.timedOut("the fixture's persisted click counter before trace capture")
            }
            XCTAssertEqual(before, warmupClickCount, "the untraced warm-up must match its expected click count")
            let clickCount = 100
            _ = try await run.adb.shell("logcat -c")
            let captureStart = try await run.startPerEventInputTraceCapture()
            _ = try await run.adb.shell(
                "am broadcast -n \(Self.helloText)/.DebugCounterReceiver -a \(Self.touchTraceStartAction)")

            var clickFailure: String?
            do {
                let pointer = try run.pointer()
                for _ in 0..<clickCount {
                    try await pointer.click(at: target, interClickGap: .milliseconds(50))
                }
                try await run.drainInput()
            } catch {
                clickFailure = String(describing: error)
            }

            let expectedCount = before + clickCount
            let after = try? await Self.waitForPersistedClickCountPreservingTrace(
                run, atLeast: expectedCount, timeout: .seconds(30))
            try await Task.sleep(for: .milliseconds(60))
            let trace = try await run.stopPerEventInputTraceCapture()
            _ = try await run.adb.shell(
                "am broadcast -n \(Self.helloText)/.DebugCounterReceiver -a \(Self.touchTraceDrainAction)")
            let fixtureLines = try await run.fixtureLog { lines in
                guard let recordCount = Self.touchTraceRecordCount(in: lines) else {
                    return false
                }
                return lines.filter { $0.contains("touch-trace ") }.count >= recordCount
            }
            let summary = Self.touchTraceSummary(in: fixtureLines)
            let fixtureObservations = Self.fixtureObservations(in: fixtureLines)
            let unattributedFixtureClickRecords = fixtureLines.filter {
                $0.contains("touch-trace kind=click ") && Self.keyValues(in: $0)["correlation"] == "ambiguous"
            }
            let routed = trace.routed.records.map(InputTraceRoutedEvent.init)
            let acknowledgements = trace.acknowledgements.records.map(InputTraceAcknowledgement.init)
            let joins = Self.joinTrace(
                host: trace.host,
                routedEvents: trace.routed.records,
                acknowledgements: trace.acknowledgements.records,
                fixtureLines: fixtureLines
            )
            let stageDiscrepancies = Self.stageDiscrepancies(
                host: trace.host,
                routedEvents: trace.routed.records,
                expectedTouchCounts: [
                    "touch.down": clickCount,
                    "touch.move": 0,
                    "touch.up": clickCount,
                    "touch.cancel": 0,
                ],
                expectedCancelAllCount: 0
            )
            let evidence = InputTraceEvidence(
                schemaVersion: 3,
                path: pointerDelivery.tracePathDescription,
                captureMode:
                    "\(pointerDelivery.diagnosticDescription); one event per input batch; "
                    + "ACK requested for every batch; untraced warm-up clicks=\(warmupClickCount)",
                clockDomains: [
                    "hostTimeNanos": "NSEvent.timestamp and InputCore use Mac mach continuous time",
                    "lastEventTimeMillis": "Guest MotionEvent.eventTime in Android uptime milliseconds",
                    "fixtureEventTimeMs": "HelloText MotionEvent.eventTime; match only to the guest ACK timestamp",
                    "sampledAtElapsedRealtimeNanos":
                        "HelloText pressed-state transitions and counter writes use Android elapsed realtime",
                    "receiveToInjectMicros":
                        "Guest monotonic interval from batch receipt to input injection completion",
                ],
                limitations: [
                    "The debug touch listener and per-event ACK cadence can change timing; compare with the separate product-cadence test.",
                    "Direct-view delivery bypasses WindowServer and AppKit dispatch; this trace cannot satisfy #25 box 3 or #103's WindowServer requirement.",
                    "Host and guest clock values have different epochs and are never subtracted.",
                    "Fixture pressed transitions and counter timings are unjoined observations: they use elapsed realtime and have no gesture key, so they are not correlated with MotionEvent uptime or host events.",
                    "The route is M3 DevBoot/DevInputRoute and does not exercise the future wrapper-to-apkrund XPC path.",
                    "A click is linked to an UP only when the fixture reports a unique UP; ambiguous callbacks remain unattached in the global evidence.",
                ],
                captureStartCounters: String(describing: captureStart),
                finalCounters: String(describing: trace.counters),
                host: trace.host,
                routedEvents: routed,
                discardedRoutedEvents: trace.routed.discardedRecords,
                acknowledgements: acknowledgements,
                discardedAcknowledgements: trace.acknowledgements.discardedRecords,
                missingAcknowledgementSequences: trace.missingAcknowledgementSequences,
                joins: joins,
                stageDiscrepancies: stageDiscrepancies,
                ambiguousAcknowledgementSequences: Self.ambiguousAcknowledgementSequences(
                    trace.acknowledgements.records),
                unattributedFixtureClickRecords: unattributedFixtureClickRecords,
                fixtureTraceLines: fixtureLines.filter {
                    $0.contains("touch-trace ") || $0.contains("debug touch trace drain")
                },
                fixtureObservations: fixtureObservations,
                fixtureTraceRecords: summary?.records,
                fixtureTraceDiscarded: summary?.discarded,
                persistedCounterBefore: before,
                persistedCounterAfter: after,
                persistedCounterDelta: after.map { $0 - before }
            )
            try Self.attachTraceEvidence(evidence, failure: clickFailure)

            XCTAssertNil(clickFailure, "\(pointerDelivery.diagnosticDescription) click batch failed")
            XCTAssertEqual(after, expectedCount, "persisted counter after the diagnostic click batch")
            XCTAssertEqual(after.map { $0 - before }, 100)
            XCTAssertEqual(trace.host.discardedRawReceipts, 0)
            XCTAssertEqual(trace.host.discardedTranslatedEvents, 0)
            XCTAssertEqual(trace.routed.discardedRecords, 0)
            XCTAssertEqual(trace.acknowledgements.discardedRecords, 0)
            XCTAssertEqual(summary?.discarded, 0, "the fixture touch trace overflowed")
            XCTAssertTrue(
                stageDiscrepancies.isEmpty,
                "the diagnostic click sequence has host input stage discrepancies: \(stageDiscrepancies)")

            let hostTouchEvents = trace.host.translatedEvents.filter { $0.kindAndPhase.hasPrefix("touch.") }
            let routeTouchEvents = trace.routed.records.filter { $0.kindAndPhase.hasPrefix("touch.") }
            let touchJoins = joins.filter { $0.kindAndPhase.hasPrefix("touch.") }
            let touchUpJoins = touchJoins.filter { $0.kindAndPhase == "touch.up" }
            let incompleteTouchJoins = touchJoins.filter {
                $0.rawReceiptOrdinals.count != 1
                    || $0.translatedEventOrdinals.count != 1
                    || $0.acknowledgement == nil
                    || ($0.acknowledgement?.lastEventTimeMillis ?? 0) == 0
                    || $0.fixtureTouchRecords.count != 1
                    || $0.fixtureDispatch != "matched-view-touch"
            }
            XCTAssertEqual(hostTouchEvents.count, 200, "each click should produce a translated DOWN and UP")
            XCTAssertEqual(
                hostTouchEvents.map { "\($0.hostTimeNanos):\($0.kindAndPhase)" },
                routeTouchEvents.map { "\($0.hostTimeNanos):\($0.kindAndPhase)" },
                "the routed touch sequence should preserve the translated host events")
            XCTAssertEqual(
                trace.acknowledgements.records.map(\.batchSequence),
                trace.routed.records.map(\.batchSequence),
                "every per-event input batch should have a guest ACK")
            XCTAssertTrue(
                trace.missingAcknowledgementSequences.isEmpty,
                "ACK capture timed out for routed batches \(trace.missingAcknowledgementSequences)")
            XCTAssertTrue(trace.acknowledgements.records.allSatisfy { $0.rejectedEvents == 0 })
            XCTAssertEqual(touchJoins.count, 200, "all routed touch events should have a join record")
            XCTAssertTrue(
                incompleteTouchJoins.isEmpty,
                "touch events missing a unique host, guest ACK, or fixture match: "
                    + incompleteTouchJoins.map {
                        "\($0.batchSequence):\($0.kindAndPhase) ack=\($0.acknowledgement?.lastEventTimeMillis ?? 0) "
                            + "raw=\($0.rawReceiptOrdinals.count) translated=\($0.translatedEventOrdinals.count) "
                            + "fixture=\($0.fixtureTouchRecords.count) dispatch=\($0.fixtureDispatch)"
                    }.joined(separator: ", "))
            XCTAssertEqual(touchUpJoins.count, 100, "each click should produce one traced fixture UP")
            XCTAssertTrue(
                touchUpJoins.allSatisfy {
                    $0.clickOutcome == "unique-up" && $0.fixtureClickRecords.count == 1
                },
                "each fixture UP should have one unique click callback; ambiguous callbacks remain unattached "
                    + "and are recorded separately")
            let uniqueClickRecords = touchUpJoins.flatMap(\.fixtureClickRecords)
            XCTAssertEqual(uniqueClickRecords.count, 100)
            XCTAssertEqual(Set(uniqueClickRecords).count, 100, "a click callback must not be linked to two UP events")
            XCTAssertEqual(trace.counters.droppedRate - captureStart.droppedRate, 0)
            XCTAssertEqual(trace.counters.droppedNotRunning - captureStart.droppedNotRunning, 0)
            XCTAssertEqual(trace.counters.droppedInvalid - captureStart.droppedInvalid, 0)
            XCTAssertEqual(trace.counters.droppedChannel - captureStart.droppedChannel, 0)
            XCTAssertEqual(trace.counters.coalesced - captureStart.coalesced, 0)
            XCTAssertEqual(summary?.records, fixtureLines.filter { $0.contains("touch-trace ") }.count)
        }
    }

    /// Dragging scrolls HelloCompose's list, and trackpad and wheel scrolling move it the way macOS reports them (#25).
    /// The content moves up for a negative delta, and then the first visible row index grows.
    func testDragAndScrollMoveTheHelloComposeList() async throws {
        let apk = try Self.fixture("APKRUN_FIXTURE_COMPOSE_APK")
        try await AndroidInputRun.with(apk: apk, package: Self.helloCompose) { run in
            _ = try await run.adb.shell("logcat -c")
            // The first rows are on screen before the drag: the list is laid out after the launch (IR-1288).
            try await run.waitForText("Row 0")
            let pointer = try run.pointer()
            // The list fills the display below the text field, so these points lie inside it.
            try await pointer.drag(from: (x: 512, y: 600), to: (x: 512, y: 250), steps: 20)
            let dragged = try await Self.lastRow(run, above: 0)
            if dragged == 0 {
                XCTFail("the drag did not scroll the list: \(try await Self.diagnosis(run))")
                return
            }
            pointer.scroll(at: (x: 512, y: 400), deltaY: -120, precise: true)
            let trackpad = try await Self.lastRow(run, above: dragged)
            XCTAssertGreaterThan(trackpad, dragged, "the trackpad scroll did not move the list")
            pointer.scroll(at: (x: 512, y: 400), deltaY: -3, precise: false)
            let wheel = try await Self.lastRow(run, above: trackpad)
            XCTAssertGreaterThan(wheel, trackpad, "the wheel scroll did not move the list")
        }
    }

    /// A right-click on HelloText's context target opens its context menu, which logs `APKRUN-FIXTURE: contextmenu`
    /// (#25 acceptance). The right button is `SOURCE_MOUSE` with the secondary button (input.md §4.1).
    func testARightClickOpensTheContextMenu() async throws {
        let apk = try Self.fixture("APKRUN_FIXTURE_APK")
        try await AndroidInputRun.with(apk: apk, package: Self.helloText) { run in
            let target = try await run.centre(of: Self.contextTargetID)
            _ = try await run.adb.shell("logcat -c")
            try await run.pointer().rightClick(at: target)
            let lines = try await run.fixtureLog { lines in
                lines.contains { $0.contains("APKRUN-FIXTURE: contextmenu") }
            }
            XCTAssertTrue(lines.contains { $0.contains("APKRUN-FIXTURE: contextmenu") }, "no context menu was logged")
        }
    }

    /// Typing `Hello, APKRun 123!` into HelloText's field gives exactly that text (#26 acceptance, T2). The field is
    /// focused with Tab, because a pointer tap does not focus it reliably (IR-1270). The debug `TEXT` broadcast makes the
    /// fixture log the field's text, and that log line is what the case checks. The sequence samples for shell input too.
    func testTypingGivesExactTextInTheField() async throws {
        let apk = try Self.fixture("APKRUN_FIXTURE_APK")
        try await AndroidInputRun.with(apk: apk, package: Self.helloText) { run in
            try await Self.withoutShellInput {
                try await Self.focusField(run)
                try await run.keyboard().type("Hello, APKRun 123!")
            }
            let text = try await Self.fieldText(run)
            XCTAssertEqual(text, "Hello, APKRun 123!")
        }
    }

    /// Backspace removes the character before the cursor, the left arrow moves the cursor, and Enter is the editor action
    /// of the field, which logs `APKRUN-FIXTURE: editor action 6` (IME_ACTION_DONE, #26).
    func testBackspaceEnterAndArrowsEditTheField() async throws {
        let apk = try Self.fixture("APKRUN_FIXTURE_APK")
        try await AndroidInputRun.with(apk: apk, package: Self.helloText) { run in
            try await Self.withoutShellInput {
                try await Self.focusField(run)
                let keys = try run.keyboard()
                try await keys.type("abc")
                try await keys.tap(.delete)
                var text = try await Self.fieldText(run)
                XCTAssertEqual(text, "ab", "Backspace did not remove the last character")
                try await keys.type("cd")
                try await keys.tap(.leftArrow)
                try await keys.tap(.leftArrow)
                try await keys.type("X")
                text = try await Self.fieldText(run)
                XCTAssertEqual(text, "abXcd", "the left arrow did not move the cursor")
                _ = try await run.adb.shell("logcat -c")
                try await keys.tap(.returnKey)
                let lines = try await run.fixtureLog { lines in
                    lines.contains { $0.contains(Self.editorActionLine) }
                }
                XCTAssertTrue(
                    lines.contains { $0.contains(Self.editorActionLine) }, "Enter did not log the editor action")
            }
        }
    }

    /// Esc and ⌘[ go back from the Details screen to the main screen, which logs `APKRUN-FIXTURE: screen main` (FR-IN-04).
    /// The Details button is opened with a pointer click, and the screen change is the log line the case checks.
    func testEscAndCommandBracketGoBackFromDetails() async throws {
        let apk = try Self.fixture("APKRUN_FIXTURE_APK")
        try await AndroidInputRun.with(apk: apk, package: Self.helloText) { run in
            try await Self.withoutShellInput {
                let keys = try run.keyboard()
                try await Self.openDetails(run)
                _ = try await run.adb.shell("logcat -c")
                try await keys.tap(.escape)
                let back = try await run.fixtureLog { lines in lines.contains { $0.contains(Self.mainScreenLine) } }
                XCTAssertTrue(
                    back.contains { $0.contains(Self.mainScreenLine) }, "Esc did not return to the main screen")
                try await Self.openDetails(run)
                _ = try await run.adb.shell("logcat -c")
                try await keys.commandShortcut(.leftBracket)
                let commandBack = try await run.fixtureLog { lines in
                    lines.contains { $0.contains(Self.mainScreenLine) }
                }
                XCTAssertTrue(
                    commandBack.contains { $0.contains(Self.mainScreenLine) }, "⌘[ did not return to the main screen")
            }
        }
    }

    /// ⌘A, ⌘C, ⌘X, ⌘V, and ⌘Z act as the Ctrl combinations in the field (FR-IN-08, key mode). Each step is checked on the
    /// field's text: copy and paste append the copied text, cut empties the selection, and undo reverts the last paste.
    func testCommandShortcutsActOnTheField() async throws {
        let apk = try Self.fixture("APKRUN_FIXTURE_APK")
        try await AndroidInputRun.with(apk: apk, package: Self.helloText) { run in
            try await Self.withoutShellInput {
                try await Self.focusField(run)
                let keys = try run.keyboard()
                try await keys.type("Hello")
                try await keys.commandShortcut(.a)
                try await keys.commandShortcut(.c)
                try await keys.tap(.rightArrow)
                try await keys.commandShortcut(.v)
                var text = try await Self.fieldText(run)
                XCTAssertEqual(text, "HelloHello", "⌘C and ⌘V did not copy and paste the selection")
                try await keys.commandShortcut(.a)
                try await keys.commandShortcut(.x)
                text = try await Self.fieldText(run)
                XCTAssertEqual(text, "", "⌘X did not cut the selection")
                try await keys.commandShortcut(.v)
                text = try await Self.fieldText(run)
                XCTAssertEqual(text, "HelloHello", "⌘V did not paste the cut text")
                try await keys.commandShortcut(.z)
                text = try await Self.fieldText(run)
                XCTAssertEqual(text, "", "⌘Z did not undo the paste")
            }
        }
    }

    private static let fieldID = "io.apkrun.fixture.hellotext:id/input_text"
    private static let detailsID = "io.apkrun.fixture.hellotext:id/details_button"
    private static let textAction = "io.apkrun.fixture.hellotext.debug.TEXT"
    private static let textPrefix = "APKRUN-FIXTURE: text "
    private static let persistedCounterPrefix = "APKRUN-FIXTURE: debug read "
    private static let counterReadAction = "io.apkrun.fixture.hellotext.debug.READ"
    private static let touchTraceStartAction = "io.apkrun.fixture.hellotext.debug.TOUCH_TRACE_START"
    private static let touchTraceDrainAction = "io.apkrun.fixture.hellotext.debug.TOUCH_TRACE_DRAIN"
    private static let editorActionLine = "APKRUN-FIXTURE: editor action 6"
    private static let mainScreenLine = "APKRUN-FIXTURE: screen main"
    private static let detailsScreenLine = "APKRUN-FIXTURE: screen details"

    private static func persistedClickCount(
        _ run: AndroidInputRun,
        timeout: Duration = .seconds(30)
    ) async throws -> Int? {
        let deadline = ContinuousClock.now + timeout
        guard try await boundedShell(run, command: "logcat -c", until: deadline) != nil,
            try await boundedShell(
                run,
                command: "am broadcast -a \(counterReadAction) -p \(helloText)",
                until: deadline
            ) != nil
        else {
            return nil
        }
        while ContinuousClock.now < deadline {
            guard
                let reply = try await boundedShell(
                    run, command: "logcat -d -s APKRUN-FIXTURE", until: deadline)
            else {
                return nil
            }
            if let count = AndroidInputRun.numbers(
                in: reply.output.components(separatedBy: "\n"), after: persistedCounterPrefix
            ).last {
                return count
            }
            if ContinuousClock.now < deadline {
                try await Task.sleep(for: min(.milliseconds(100), deadline - .now))
            }
        }
        return nil
    }

    private static func guestAgentPID(_ run: AndroidInputRun) async throws -> Int {
        let reply = try await run.adb.shell("pidof apkrun_guestd")
        guard reply.status == 0,
            let pid = reply.output.split(whereSeparator: \.isWhitespace).compactMap({ Int($0) }).first
        else {
            throw AndroidInputRunFailure.timedOut("the running Guest Agent process ID")
        }
        return pid
    }

    private static func androidBootID(_ run: AndroidInputRun) async throws -> String {
        let reply = try await run.adb.shell("cat /proc/sys/kernel/random/boot_id")
        let bootID = reply.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reply.status == 0, !bootID.isEmpty else {
            throw AndroidInputRunFailure.timedOut("the Android kernel boot ID")
        }
        return bootID
    }

    /// Reads the fixture's persisted counter without clearing the diagnostic touch records from logcat.
    private static func waitForPersistedClickCountPreservingTrace(
        _ run: AndroidInputRun,
        atLeast expected: Int,
        timeout: Duration
    ) async throws -> Int? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            _ = try await run.adb.shell("am broadcast -a \(counterReadAction) -p \(helloText)")
            let lines = try await run.fixtureLog { lines in
                lines.contains { $0.contains(persistedCounterPrefix) }
            }
            if let count = AndroidInputRun.numbers(in: lines, after: persistedCounterPrefix).last,
                count >= expected
            {
                return count
            }
            try await Task.sleep(for: min(.milliseconds(100), deadline - .now))
        }
        let lines = try await run.fixtureLog { $0.contains { $0.contains(persistedCounterPrefix) } }
        return AndroidInputRun.numbers(in: lines, after: persistedCounterPrefix).last
    }

    private struct TouchTraceSummary {
        let records: Int
        let discarded: Int
    }

    private static func touchTraceSummary(in lines: [String]) -> TouchTraceSummary? {
        guard let line = lines.first(where: { $0.contains("debug touch trace drain ") }) else {
            return nil
        }
        let values = keyValues(in: line)
        guard let records = values["records"].flatMap(Int.init),
            let discarded = values["dropped"].flatMap(Int.init)
        else {
            return nil
        }
        return TouchTraceSummary(records: records, discarded: discarded)
    }

    private static func touchTraceRecordCount(in lines: [String]) -> Int? {
        touchTraceSummary(in: lines)?.records
    }

    fileprivate static func fixtureObservations(in lines: [String]) -> InputTraceFixtureObservations {
        var pressedTransitions: [InputTracePressedTransition] = []
        var clicks: [InputTraceFixtureClick] = []
        var malformedPressedTransitionCount = 0
        var malformedClickCount = 0

        for line in lines where line.contains("touch-trace ") {
            let fields = keyValues(in: line)
            switch fields["kind"] {
            case "pressed-transition":
                if let transition = pressedTransition(from: fields) {
                    pressedTransitions.append(transition)
                } else {
                    malformedPressedTransitionCount += 1
                }
            case "click":
                if let click = fixtureClick(from: fields) {
                    clicks.append(click)
                } else {
                    malformedClickCount += 1
                }
            default:
                break
            }
        }

        return InputTraceFixtureObservations(
            pressedTransitions: pressedTransitions,
            clicks: clicks,
            malformedPressedTransitionCount: malformedPressedTransitionCount,
            malformedClickCount: malformedClickCount
        )
    }

    private static func pressedTransition(from fields: [String: String]) -> InputTracePressedTransition? {
        guard
            let sequence = fields["sequence"].flatMap(UInt64.init),
            let sampledAtElapsedRealtimeNanos = fields["sampledAtElapsedRealtimeNanos"].flatMap(UInt64.init),
            let requestedPressed = fields["requestedPressed"].flatMap(Bool.init),
            let pressedBefore = fields["pressedBefore"].flatMap(Bool.init),
            let pressedAfter = fields["pressedAfter"].flatMap(Bool.init)
        else {
            return nil
        }
        return InputTracePressedTransition(
            sequence: sequence,
            sampledAtElapsedRealtimeNanos: sampledAtElapsedRealtimeNanos,
            requestedPressed: requestedPressed,
            pressedBefore: pressedBefore,
            pressedAfter: pressedAfter
        )
    }

    private static func fixtureClick(from fields: [String: String]) -> InputTraceFixtureClick? {
        guard
            let sequence = fields["sequence"].flatMap(UInt64.init),
            let clickOrdinal = fields["clickOrdinal"].flatMap(UInt64.init),
            validOptionalIntegerField("storedCounter", in: fields, as: Int.self),
            let saveSucceeded = fields["saveSucceeded"].flatMap(Bool.init),
            let correlation = fields["correlation"].flatMap(InputTraceFixtureClickCorrelation.init(rawValue:)),
            let pendingUpCount = fields["pendingUpCount"].flatMap(UInt64.init),
            validOptionalIntegerField("correlatedUpSequence", in: fields, as: UInt64.self),
            validOptionalIntegerField(
                "counterIncrementStartedAtElapsedRealtimeNanos", in: fields, as: UInt64.self),
            validOptionalIntegerField("counterIncrementDurationNanos", in: fields, as: UInt64.self)
        else {
            return nil
        }
        let storedCounter = optionalIntegerField("storedCounter", in: fields, as: Int.self)
        guard (storedCounter != nil) == saveSucceeded else {
            return nil
        }
        let correlatedUpSequence = optionalIntegerField("correlatedUpSequence", in: fields, as: UInt64.self)
        let counterIncrementStartedAtElapsedRealtimeNanos = optionalIntegerField(
            "counterIncrementStartedAtElapsedRealtimeNanos", in: fields, as: UInt64.self)
        let counterIncrementDurationNanos = optionalIntegerField(
            "counterIncrementDurationNanos", in: fields, as: UInt64.self)
        switch correlation {
        case .uniqueUp:
            guard pendingUpCount == 1, let correlatedUpSequence, correlatedUpSequence < sequence else {
                return nil
            }
        case .ambiguous:
            guard correlatedUpSequence == nil else {
                return nil
            }
        }
        guard
            (counterIncrementStartedAtElapsedRealtimeNanos == nil)
                == (counterIncrementDurationNanos == nil)
        else {
            return nil
        }
        return InputTraceFixtureClick(
            sequence: sequence,
            clickOrdinal: clickOrdinal,
            storedCounter: storedCounter,
            saveSucceeded: saveSucceeded,
            correlation: correlation,
            pendingUpCount: pendingUpCount,
            correlatedUpSequence: correlatedUpSequence,
            counterIncrementStartedAtElapsedRealtimeNanos: counterIncrementStartedAtElapsedRealtimeNanos,
            counterIncrementDurationNanos: counterIncrementDurationNanos
        )
    }

    private static func validOptionalIntegerField<Value: LosslessStringConvertible>(
        _ key: String,
        in fields: [String: String],
        as type: Value.Type
    ) -> Bool {
        guard let rawValue = fields[key] else {
            return false
        }
        if rawValue == "none" {
            return true
        }
        return type.init(rawValue) != nil
    }

    private static func optionalIntegerField<Value: LosslessStringConvertible>(
        _ key: String,
        in fields: [String: String],
        as type: Value.Type
    ) -> Value? {
        guard let rawValue = fields[key], rawValue != "none" else {
            return nil
        }
        return type.init(rawValue)
    }

    fileprivate static func joinTrace(
        host: InputTraceHostSnapshot,
        routedEvents: [InputSentEventHistory.Record],
        acknowledgements: [InputAcknowledgementHistory.Record],
        fixtureLines: [String]
    ) -> [InputTraceLink] {
        let traceLines = fixtureLines.filter { $0.contains("touch-trace ") }
        let touchLines = traceLines.filter { keyValues(in: $0)["kind"] == "touch" }
        let clickLines: [(line: String, record: InputTraceFixtureClick)] = traceLines.compactMap { line in
            let fields = keyValues(in: line)
            guard fields["kind"] == "click", let record = fixtureClick(from: fields) else {
                return nil
            }
            return (line: line, record: record)
        }
        let acknowledgementsBySequence = Dictionary(grouping: acknowledgements, by: \.batchSequence)

        return routedEvents.map { routed in
            let eventType: Int?
            let fixtureAction: String?
            switch routed.kindAndPhase {
            case "touch.down":
                eventType = Int(NSEvent.EventType.leftMouseDown.rawValue)
                fixtureAction = "DOWN"
            case "touch.move":
                eventType = Int(NSEvent.EventType.leftMouseDragged.rawValue)
                fixtureAction = "MOVE"
            case "touch.up":
                eventType = Int(NSEvent.EventType.leftMouseUp.rawValue)
                fixtureAction = "UP"
            case "touch.cancel":
                eventType = nil
                fixtureAction = "CANCEL"
            case "cancelAll":
                eventType = nil
                fixtureAction = "CANCEL"
            default:
                eventType = nil
                fixtureAction = nil
            }
            let rawReceipts = host.rawReceipts.filter {
                $0.hostTimeNanos == routed.hostTimeNanos && $0.eventType == eventType
            }
            let translated = host.translatedEvents.filter {
                $0.hostTimeNanos == routed.hostTimeNanos && $0.kindAndPhase == routed.kindAndPhase
            }
            let acknowledgementMatches = acknowledgementsBySequence[routed.batchSequence] ?? []
            let acknowledgement = acknowledgementMatches.count == 1 ? acknowledgementMatches[0] : nil
            let guestTime = acknowledgement?.lastEventTimeMillis ?? 0
            let fixtureTouches = touchLines.filter { line in
                let fields = keyValues(in: line)
                return fields["action"] == fixtureAction
                    && fields["eventTimeMs"].flatMap(UInt64.init) == (guestTime == 0 ? nil : guestTime)
            }
            let guestSequences = Set(fixtureTouches.compactMap { keyValues(in: $0)["sequence"].flatMap(UInt64.init) })
            let uniquelyCorrelatedClicks = clickLines.filter {
                guard $0.record.correlation == .uniqueUp, let sequence = $0.record.correlatedUpSequence else {
                    return false
                }
                return guestSequences.contains(sequence)
            }
            let clickRecords: [String]
            let clickOutcome: String
            if routed.kindAndPhase != "touch.up" {
                clickRecords = []
                clickOutcome = "not-an-up"
            } else if !uniquelyCorrelatedClicks.isEmpty {
                clickRecords = uniquelyCorrelatedClicks.map(\.line)
                clickOutcome = "unique-up"
            } else if fixtureTouches.isEmpty {
                clickRecords = []
                clickOutcome = "no-matching-up"
            } else {
                clickRecords = []
                clickOutcome = "no-unique-up-correlation"
            }
            let dispatchOutcome: String
            if acknowledgementMatches.count > 1 {
                dispatchOutcome = "ambiguous-ack"
            } else if acknowledgement == nil {
                dispatchOutcome = "no-ack"
            } else if guestTime == 0 {
                dispatchOutcome = "ack-without-accepted-motion-event"
            } else if fixtureTouches.isEmpty {
                dispatchOutcome = "no-matching-view-touch"
            } else if fixtureTouches.count == 1 {
                dispatchOutcome = "matched-view-touch"
            } else {
                dispatchOutcome = "multiple-view-touch-matches"
            }
            return InputTraceLink(
                batchSequence: routed.batchSequence,
                eventIndex: routed.eventIndex,
                kindAndPhase: routed.kindAndPhase,
                hostTimeNanos: routed.hostTimeNanos,
                rawReceiptOrdinals: rawReceipts.map(\.ordinal),
                translatedEventOrdinals: translated.map(\.ordinal),
                acknowledgement: acknowledgement.map(InputTraceAcknowledgement.init),
                fixtureTouchRecords: fixtureTouches,
                fixtureClickRecords: clickRecords,
                fixtureDispatch: dispatchOutcome,
                clickOutcome: clickOutcome
            )
        }
    }

    fileprivate static func stageDiscrepancies(
        host: InputTraceHostSnapshot,
        routedEvents: [InputSentEventHistory.Record],
        expectedTouchCounts: [String: Int],
        expectedCancelAllCount: Int = 0
    ) -> [InputTraceStageDiscrepancy] {
        let routedTouchEvents = routedEvents.filter { $0.kindAndPhase.hasPrefix("touch.") }
        let phases = Set(expectedTouchCounts.keys)
            .union(host.rawReceipts.compactMap { Self.touchPhase(for: $0.eventType) })
            .union(host.translatedEvents.filter { $0.kindAndPhase.hasPrefix("touch.") }.map(\.kindAndPhase))
            .union(routedTouchEvents.map(\.kindAndPhase))

        var discrepancies: [InputTraceStageDiscrepancy] = []
        for phase in phases.sorted() {
            let expectedCount = expectedTouchCounts[phase, default: 0]
            let rawReceipts = host.rawReceipts.filter { Self.touchPhase(for: $0.eventType) == phase }
            let translated = host.translatedEvents.filter { $0.kindAndPhase == phase }
            let routed = routedTouchEvents.filter { $0.kindAndPhase == phase }

            if expectedCount != rawReceipts.count {
                discrepancies.append(
                    InputTraceStageDiscrepancy(
                        stage: "expected-to-raw",
                        kindAndPhase: phase,
                        expectedCount: expectedCount,
                        observedCount: rawReceipts.count,
                        sourceOrdinals: [],
                        observedOrdinals: rawReceipts.map(\.ordinal),
                        observedBatchSequences: []
                    ))
            }
            if rawReceipts.count != translated.count {
                discrepancies.append(
                    InputTraceStageDiscrepancy(
                        stage: "raw-to-translated",
                        kindAndPhase: phase,
                        expectedCount: rawReceipts.count,
                        observedCount: translated.count,
                        sourceOrdinals: rawReceipts.map(\.ordinal),
                        observedOrdinals: translated.map(\.ordinal),
                        observedBatchSequences: []
                    ))
            }
            if translated.count != routed.count {
                discrepancies.append(
                    InputTraceStageDiscrepancy(
                        stage: "translated-to-routed",
                        kindAndPhase: phase,
                        expectedCount: translated.count,
                        observedCount: routed.count,
                        sourceOrdinals: translated.map(\.ordinal),
                        observedOrdinals: [],
                        observedBatchSequences: routed.map(\.batchSequence)
                    ))
            }
        }
        let translatedCancelAllEvents = host.translatedEvents.filter { $0.kindAndPhase == "cancelAll" }
        let routedCancelAllEvents = routedEvents.filter { $0.kindAndPhase == "cancelAll" }
        if expectedCancelAllCount != translatedCancelAllEvents.count {
            discrepancies.append(
                InputTraceStageDiscrepancy(
                    stage: "expected-to-translated",
                    kindAndPhase: "cancelAll",
                    expectedCount: expectedCancelAllCount,
                    observedCount: translatedCancelAllEvents.count,
                    sourceOrdinals: [],
                    observedOrdinals: translatedCancelAllEvents.map(\.ordinal),
                    observedBatchSequences: []
                ))
        }
        if translatedCancelAllEvents.count != routedCancelAllEvents.count {
            discrepancies.append(
                InputTraceStageDiscrepancy(
                    stage: "translated-to-routed",
                    kindAndPhase: "cancelAll",
                    expectedCount: translatedCancelAllEvents.count,
                    observedCount: routedCancelAllEvents.count,
                    sourceOrdinals: translatedCancelAllEvents.map(\.ordinal),
                    observedOrdinals: [],
                    observedBatchSequences: routedCancelAllEvents.map(\.batchSequence)
                ))
        }
        return discrepancies
    }

    fileprivate static func ambiguousAcknowledgementSequences(
        _ acknowledgements: [InputAcknowledgementHistory.Record]
    ) -> [UInt64] {
        Dictionary(grouping: acknowledgements, by: \.batchSequence)
            .filter { $0.value.count > 1 }
            .keys
            .sorted()
    }

    private static func touchPhase(for eventType: Int) -> String? {
        switch eventType {
        case Int(NSEvent.EventType.leftMouseDown.rawValue):
            "touch.down"
        case Int(NSEvent.EventType.leftMouseDragged.rawValue):
            "touch.move"
        case Int(NSEvent.EventType.leftMouseUp.rawValue):
            "touch.up"
        default:
            nil
        }
    }

    private static func keyValues(in line: String) -> [String: String] {
        let content: Substring
        if let marker = line.range(of: "touch-trace ") {
            content = line[marker.upperBound...]
        } else if let marker = line.range(of: "debug touch trace drain ") {
            content = line[marker.upperBound...]
        } else {
            content = line[...]
        }
        return Dictionary(
            content.split(whereSeparator: \.isWhitespace).compactMap { field in
                let pair = field.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else {
                    return nil
                }
                return (String(pair[0]), String(pair[1]))
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private static func attachTraceEvidence(_ evidence: InputTraceEvidence, failure: String?) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var object = try JSONSerialization.jsonObject(with: encoder.encode(evidence)) as? [String: Any] ?? [:]
        object["captureFailure"] = failure
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        XCTContext.runActivity(named: "Joined input trace evidence") { activity in
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "input-trace-evidence.json"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }

    private static func boundedShell(
        _ run: AndroidInputRun,
        command: String,
        until deadline: ContinuousClock.Instant
    ) async throws -> AdbShellReply? {
        let remaining = deadline - .now
        guard remaining > .zero else {
            return nil
        }
        do {
            return try await run.adb.shell(command, timeout: min(.seconds(10), remaining))
        } catch let failure {
            if case .commandTimedOut = failure {
                return nil
            }
            throw failure
        }
    }

    private static func waitForPersistedClickCount(_ run: AndroidInputRun, atLeast expected: Int) async throws -> Int {
        let deadline = ContinuousClock.now + .seconds(10)
        var lastCount = 0
        while ContinuousClock.now < deadline {
            let remaining = deadline - .now
            if let count = try await persistedClickCount(run, timeout: remaining) {
                lastCount = count
                if count >= expected {
                    return count
                }
            }
            if ContinuousClock.now < deadline {
                try await Task.sleep(for: min(.milliseconds(100), deadline - .now))
            }
        }
        throw AndroidInputRunFailure.timedOut(
            "the fixture's persisted click count to reach \(expected); last value was \(lastCount)")
    }

    /// Requires the fixture's click counter to stay at one exact value through the Android dispatch settling window.
    private static func waitForStablePersistedClickCount(
        _ run: AndroidInputRun,
        exactly expected: Int,
        stableFor: Duration = .seconds(1),
        timeout: Duration = .seconds(15)
    ) async throws -> Int {
        let deadline = ContinuousClock.now + timeout
        var stableSince: ContinuousClock.Instant?
        var lastCount: Int?
        while ContinuousClock.now < deadline {
            let remaining = deadline - .now
            if let count = try await persistedClickCount(run, timeout: remaining) {
                lastCount = count
                guard count <= expected else {
                    throw AndroidInputRunFailure.timedOut(
                        "the fixture's persisted click count to stay at \(expected); it reached \(count)")
                }
                if count == expected {
                    if let stableSince, stableSince.duration(to: .now) >= stableFor {
                        return count
                    }
                    stableSince = stableSince ?? .now
                } else {
                    stableSince = nil
                }
            } else {
                stableSince = nil
            }
            if ContinuousClock.now < deadline {
                try await Task.sleep(for: min(.milliseconds(100), deadline - .now))
            }
        }
        throw AndroidInputRunFailure.timedOut(
            "the fixture's persisted click count to stay at \(expected) for \(stableFor); last value was \(lastCount.map(String.init) ?? "unavailable")"
        )
    }

    private static func assertNoShellInputDuring(_ operation: () async throws -> Void) async throws {
        let sampler = ShellInputSampler()
        sampler.start()
        do {
            try await operation()
        } catch {
            _ = await sampler.stop()
            throw error
        }
        let shellInput = await sampler.stop()
        XCTAssertEqual(shellInput, [], "adb shell input processes ran during the sequence")
    }

    private static func attachEnvironmentIdentity(fixture: URL, pointerDelivery: InputPointerDelivery) throws {
        let bundle = try AndroidBootSession.bundleDirectory()
        guard let guestPath = ProcessInfo.processInfo.environment["APKRUN_GUEST_DIR"], !guestPath.isEmpty else {
            throw XCTSkip("APKRUN_GUEST_DIR is not set.")
        }
        let guestBundle = URL(fileURLWithPath: guestPath, isDirectory: true)
        let imageManifest = bundle.appendingPathComponent("manifest.json")
        let guestManifest = guestBundle.appendingPathComponent("apkrun-guest.json")
        let guestAPK = guestBundle.appendingPathComponent("apkrun-guest.apk")
        let identity: [String: Any] = [
            "delivery": pointerDelivery.diagnosticDescription,
            "image_bundle": bundle.path,
            "image_manifest_sha256": try sha256(of: imageManifest),
            "image_manifest": try JSONSerialization.jsonObject(with: Data(contentsOf: imageManifest)),
            "image_variant": try imageVariantIdentity(for: bundle),
            "guest_bundle": guestBundle.path,
            "guest_manifest_sha256": try sha256(of: guestManifest),
            "guest_manifest": try JSONSerialization.jsonObject(with: Data(contentsOf: guestManifest)),
            "guest_apk_sha256": try sha256(of: guestAPK),
            "fixture_apk": fixture.path,
            "fixture_apk_sha256": try sha256(of: fixture),
        ]
        let data = try JSONSerialization.data(withJSONObject: identity, options: [.prettyPrinted, .sortedKeys])
        XCTContext.runActivity(named: "Input test environment identity") { activity in
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "input-test-environment.json"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }

    private static func imageVariantIdentity(for bundle: URL) throws -> [String: Any] {
        let receipt = bundle.deletingLastPathComponent()
            .appendingPathComponent("\(bundle.lastPathComponent).variant.json")
        guard FileManager.default.fileExists(atPath: receipt.path) else {
            return [
                "receipt_path": NSNull(),
                "receipt_sha256": NSNull(),
                "variant_disk_sha256": NSNull(),
                "variant_manifest_sha256": NSNull(),
            ]
        }
        let receiptData = try Data(contentsOf: receipt)
        let variant = try JSONDecoder().decode(AndroidImageVariantReceipt.self, from: receiptData)
        return [
            "receipt_path": receipt.path,
            "receipt_sha256": SHA256.hash(data: receiptData).map { String(format: "%02x", $0) }.joined(),
            "variant_disk_sha256": variant.variantDiskSHA256,
            "variant_manifest_sha256": variant.variantManifestSHA256,
        ]
    }

    private static func sha256(of file: URL) throws -> String {
        let hash = SHA256.hash(data: try Data(contentsOf: file))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private static func attachBatchEvidence(
        batch: Int,
        before: Int,
        after: Int?,
        counters: InputCounters?,
        touchPhaseDelta: InputWireTouchPhaseCounts?,
        acknowledgements: InputAcknowledgementHistory?,
        failure: String?
    ) {
        let ackRows = acknowledgements?.records.map { "\($0.batchSequence):\($0.rejectedEvents)" } ?? []
        let text = """
            batch=\(batch)
            persisted_before=\(before)
            persisted_after=\(after.map(String.init) ?? "unavailable")
            persisted_delta=\(after.map { String($0 - before) } ?? "unavailable")
            host_input_counters=\(counters.map { String(describing: $0) } ?? "unavailable")
            wire_touch_phase_delta=\(touchPhaseDelta.map { String(describing: $0) } ?? "unavailable")
            normal_ack_sequence_and_rejections=\(ackRows)
            ack_history_discarded=\(acknowledgements.map { String($0.discardedRecords) } ?? "unavailable")
            failure=\(failure ?? "none")
            """
        XCTContext.runActivity(named: "Input batch \(batch) evidence") { activity in
            let attachment = XCTAttachment(data: Data(text.utf8), uniformTypeIdentifier: "public.utf8-plain-text")
            attachment.name = "input-batch-\(batch).txt"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }

    /// Moves the focus to HelloText's field with Tab, and reads the focus from a uiautomator dump before each Tab. A dump
    /// that fails is retried without a Tab, so a Tab never moves the focus twice.
    private static func focusField(_ run: AndroidInputRun) async throws {
        let keys = try run.keyboard()
        for _ in 0..<6 {
            let xml = try await run.uiDump()
            switch AndroidInputRun.isFocused(fieldID, in: xml) {
            case true?:
                return
            case false?:
                try await keys.tap(.tab)
                try await Task.sleep(for: .milliseconds(400))
            case nil:
                try await Task.sleep(for: .seconds(1))
            }
        }
        throw AndroidInputRunFailure.viewNotFound("the focus of \(fieldID)")
    }

    /// The text of HelloText's field, from the fixture's `text` line after the debug `TEXT` broadcast (a query, not input).
    private static func fieldText(_ run: AndroidInputRun) async throws -> String {
        _ = try await run.adb.shell("logcat -c")
        _ = try await run.adb.shell("am broadcast -a \(textAction) -p \(helloText)")
        let lines = try await run.fixtureLog { lines in lines.contains { $0.contains(textPrefix) } }
        guard let line = lines.last(where: { $0.contains(textPrefix) }), let range = line.range(of: textPrefix) else {
            throw AndroidInputRunFailure.timedOut("the fixture's text line")
        }
        // The fixture writes the text as a JSON string. The array wrapper lets JSONDecoder read a bare string.
        let json = String(line[range.upperBound...])
        return try JSONDecoder().decode([String].self, from: Data("[\(json)]".utf8)).first ?? ""
    }

    /// Opens the Details screen with a pointer click on its button, and waits for its `screen details` line.
    private static func openDetails(_ run: AndroidInputRun) async throws {
        let target = try await run.centre(of: detailsID)
        _ = try await run.adb.shell("logcat -c")
        try await run.pointer().click(at: target)
        let lines = try await run.fixtureLog { lines in lines.contains { $0.contains(detailsScreenLine) } }
        XCTAssertTrue(lines.contains { $0.contains(detailsScreenLine) }, "the Details screen did not open")
    }

    /// What the screen and the fixture log showed when a scroll had no effect (IR-1288): the packages of the dump, and the
    /// last fixture lines.
    private static func diagnosis(_ run: AndroidInputRun) async throws -> String {
        let dump = try await run.uiDump()
        let lines = try await run.adb.shell("logcat -d -s APKRUN-FIXTURE | tail -3").output
        return
            "the dump shows \(AndroidInputRun.packages(in: dump)); the fixture log ends with \(lines.replacingOccurrences(of: "\n", with: " | "))"
    }

    /// The last row index that HelloCompose logged, once it is above `previous`. The log is polled for 30 s.
    private static func lastRow(_ run: AndroidInputRun, above previous: Int) async throws -> Int {
        let lines = try await run.fixtureLog {
            (AndroidInputRun.numbers(in: $0, after: rowPrefix).last ?? 0) > previous
        }
        return AndroidInputRun.numbers(in: lines, after: rowPrefix).last ?? 0
    }

    /// Runs `body`, then fails when an `adb shell input` process ran during it (FR-IN-06). The sampler polls every 250 ms,
    /// so a command shorter than that can pass unseen.
    private static func withoutShellInput(_ body: () async throws -> Void) async throws {
        let sampler = ShellInputSampler()
        sampler.start()
        do {
            try await body()
        } catch {
            _ = await sampler.stop()
            throw error
        }
        let shellInput = await sampler.stop()
        XCTAssertEqual(shellInput, [], "adb shell input processes ran during the sequence")
    }

    /// The APK that the environment variable `key` names. The test is skipped when the variable or the file is missing.
    private static func fixture(_ key: String) throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[key], FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip(
                "\(key) does not name a fixture APK. Build the debug HelloText as environment-setup.md §4 says, and copy it to /tmp."
            )
        }
        return URL(fileURLWithPath: path)
    }
}

/// Samples the process list every 250 ms for `adb ... shell input` commands, and keeps the command lines it sees.
private final class ShellInputSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var found: [String] = []
    private var sampling: Task<Void, Never>?

    func start() {
        sampling = Task.detached { [self] in
            while !Task.isCancelled {
                let lines = Self.shellInputCommands()
                lock.withLock { found += lines }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Ends the sampling, and returns every matching command line that was seen.
    func stop() async -> [String] {
        sampling?.cancel()
        await sampling?.value
        return lock.withLock { found }
    }

    private static func shellInputCommands() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axww", "-o", "command="]
        let output = Pipe()
        process.standardOutput = output
        do {
            try process.run()
        } catch {
            return ["could not list the processes"]
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            .filter { $0.contains("adb") && $0.contains("shell input") }
    }
}

@MainActor
final class AndroidInputTraceJoinTests: XCTestCase {
    func testFixturePressedTransitionsAndCounterTimingsBecomeTypedUnjoinedObservations() throws {
        let lines = [
            "I APKRUN-FIXTURE: touch-trace kind=pressed-transition sequence=7 "
                + "sampledAtElapsedRealtimeNanos=123456 requestedPressed=true pressedBefore=false pressedAfter=true",
            "I APKRUN-FIXTURE: touch-trace kind=pressed-transition sequence=9 "
                + "sampledAtElapsedRealtimeNanos=234567 requestedPressed=false pressedBefore=true pressedAfter=false",
            "I APKRUN-FIXTURE: touch-trace kind=click sequence=11 clickOrdinal=1 storedCounter=1 "
                + "saveSucceeded=true correlation=unique_up pendingUpCount=1 correlatedUpSequence=10 "
                + "counterIncrementStartedAtElapsedRealtimeNanos=345678 counterIncrementDurationNanos=9012",
            "I APKRUN-FIXTURE: touch-trace kind=click sequence=13 clickOrdinal=2 storedCounter=none "
                + "saveSucceeded=false correlation=ambiguous pendingUpCount=2 correlatedUpSequence=none "
                + "counterIncrementStartedAtElapsedRealtimeNanos=none counterIncrementDurationNanos=none",
            "I APKRUN-FIXTURE: touch-trace kind=pressed-transition sequence=bad",
            "I APKRUN-FIXTURE: touch-trace kind=click sequence=15 clickOrdinal=3 storedCounter=2 "
                + "saveSucceeded=true correlation=unique_up pendingUpCount=1 correlatedUpSequence=14 "
                + "counterIncrementStartedAtElapsedRealtimeNanos=not-a-time counterIncrementDurationNanos=8",
            "I APKRUN-FIXTURE: touch-trace kind=click sequence=17 clickOrdinal=4 storedCounter=3 "
                + "saveSucceeded=true correlation=ambiguous pendingUpCount=1 correlatedUpSequence=16 "
                + "counterIncrementStartedAtElapsedRealtimeNanos=400 counterIncrementDurationNanos=8",
            "I APKRUN-FIXTURE: touch-trace kind=click sequence=19 clickOrdinal=5 storedCounter=4 "
                + "saveSucceeded=true correlation=unique_up pendingUpCount=2 correlatedUpSequence=18 "
                + "counterIncrementStartedAtElapsedRealtimeNanos=500 counterIncrementDurationNanos=9",
            "I APKRUN-FIXTURE: touch-trace kind=click sequence=21 clickOrdinal=6 storedCounter=5 "
                + "saveSucceeded=true correlation=unique_up pendingUpCount=1 correlatedUpSequence=20 "
                + "counterIncrementStartedAtElapsedRealtimeNanos=600",
            "I APKRUN-FIXTURE: touch-trace kind=click sequence=23 clickOrdinal=7 storedCounter=none "
                + "saveSucceeded=true correlation=unique_up pendingUpCount=1 correlatedUpSequence=22 "
                + "counterIncrementStartedAtElapsedRealtimeNanos=700 counterIncrementDurationNanos=10",
            "I APKRUN-FIXTURE: touch-trace kind=click sequence=25 clickOrdinal=8 storedCounter=6 "
                + "saveSucceeded=false correlation=unique_up pendingUpCount=1 correlatedUpSequence=24 "
                + "counterIncrementStartedAtElapsedRealtimeNanos=800 counterIncrementDurationNanos=11",
        ]

        let observations = AndroidInputTests.fixtureObservations(in: lines)

        XCTAssertEqual(
            observations.pressedTransitions,
            [
                InputTracePressedTransition(
                    sequence: 7,
                    sampledAtElapsedRealtimeNanos: 123_456,
                    requestedPressed: true,
                    pressedBefore: false,
                    pressedAfter: true
                ),
                InputTracePressedTransition(
                    sequence: 9,
                    sampledAtElapsedRealtimeNanos: 234_567,
                    requestedPressed: false,
                    pressedBefore: true,
                    pressedAfter: false
                ),
            ])
        XCTAssertEqual(
            observations.clicks,
            [
                InputTraceFixtureClick(
                    sequence: 11,
                    clickOrdinal: 1,
                    storedCounter: 1,
                    saveSucceeded: true,
                    correlation: .uniqueUp,
                    pendingUpCount: 1,
                    correlatedUpSequence: 10,
                    counterIncrementStartedAtElapsedRealtimeNanos: 345_678,
                    counterIncrementDurationNanos: 9_012
                ),
                InputTraceFixtureClick(
                    sequence: 13,
                    clickOrdinal: 2,
                    storedCounter: nil,
                    saveSucceeded: false,
                    correlation: .ambiguous,
                    pendingUpCount: 2,
                    correlatedUpSequence: nil,
                    counterIncrementStartedAtElapsedRealtimeNanos: nil,
                    counterIncrementDurationNanos: nil
                ),
            ])
        XCTAssertEqual(observations.malformedPressedTransitionCount, 1)
        XCTAssertEqual(observations.malformedClickCount, 6)
        XCTAssertEqual(
            try JSONDecoder().decode(InputTraceFixtureObservations.self, from: JSONEncoder().encode(observations)),
            observations)
    }

    func testAmbiguousFixtureClickCannotJoinAnUp() {
        let hostTime: UInt64 = 987_654_321
        let host = InputTraceHostSnapshot(
            rawReceipts: [
                InputTraceRawReceipt(
                    ordinal: 1,
                    eventType: Int(NSEvent.EventType.leftMouseUp.rawValue),
                    hostTimeNanos: hostTime
                )
            ],
            discardedRawReceipts: 0,
            translatedEvents: [
                InputTraceTranslatedEvent(ordinal: 2, hostTimeNanos: hostTime, kindAndPhase: "touch.up")
            ],
            discardedTranslatedEvents: 0
        )
        let routed = [
            InputSentEventHistory.Record(
                batchSequence: 14,
                eventIndex: 0,
                hostTimeNanos: hostTime,
                kindAndPhase: "touch.up"
            )
        ]
        let acknowledgements = [
            InputAcknowledgementHistory.Record(
                batchSequence: 14,
                rejectedEvents: 0,
                receiveToInjectMicros: 90,
                lastEventTimeMillis: 420
            )
        ]
        let fixtureLines = [
            "I APKRUN-FIXTURE: touch-trace kind=touch sequence=5 eventTimeMs=420 "
                + "downTimeMs=400 action=UP pressedBefore=true enabled=true focused=true inside=true shown=true",
            "I APKRUN-FIXTURE: touch-trace kind=click sequence=6 clickOrdinal=1 "
                + "storedCounter=1 saveSucceeded=true correlation=ambiguous pendingUpCount=1 "
                + "correlatedUpSequence=5 counterIncrementStartedAtElapsedRealtimeNanos=none "
                + "counterIncrementDurationNanos=none",
        ]

        let joins = AndroidInputTests.joinTrace(
            host: host,
            routedEvents: routed,
            acknowledgements: acknowledgements,
            fixtureLines: fixtureLines
        )

        XCTAssertEqual(joins.count, 1)
        XCTAssertEqual(joins[0].fixtureDispatch, "matched-view-touch")
        XCTAssertTrue(joins[0].fixtureClickRecords.isEmpty)
        XCTAssertEqual(joins[0].clickOutcome, "no-unique-up-correlation")
    }

    func testWireTouchPhaseCountsSeparateCancelAllFromTouchCancel() {
        let position = RuntimeAPI.DisplayPoint(x: 10, y: 20)
        let time = RuntimeAPI.InputTimestamp(hostNanos: 123)
        var counts = InputWireTouchPhaseCounts()

        counts.record([
            .touch(.init(phase: .down, pointerID: 0, position: position, time: time)),
            .mouse(.init(action: .hoverMove, position: position, buttons: 0, time: time)),
            .touch(.init(phase: .move, pointerID: 0, position: position, time: time)),
            .key(.init(action: .down, androidKeyCode: 29, metaState: 0, repeatCount: 0, time: time)),
            .touch(.init(phase: .up, pointerID: 0, position: position, time: time)),
            .cancelAll(time),
            .touch(.init(phase: .cancel, pointerID: 0, position: position, time: time)),
        ])

        XCTAssertEqual(counts, InputWireTouchPhaseCounts(down: 1, move: 1, up: 1, cancel: 1, cancelAll: 1))
    }

    func testWireTouchPhaseCountDeltaTracksOnlyEventsAfterBaseline() {
        let position = RuntimeAPI.DisplayPoint(x: 10, y: 20)
        let time = RuntimeAPI.InputTimestamp(hostNanos: 123)
        let before = InputWireTouchPhaseCounts(down: 4, move: 9, up: 4, cancel: 1, cancelAll: 2)
        var after = before

        after.record([
            .touch(.init(phase: .down, pointerID: 0, position: position, time: time)),
            .cancelAll(time),
        ])

        XCTAssertEqual(
            after.delta(since: before),
            InputWireTouchPhaseCounts(down: 1, cancelAll: 1)
        )
    }

    func testTouchMoveJoinsHostGuestAndFixtureWithoutBeingCountedAsAClick() {
        let hostTime: UInt64 = 987_654_321
        let host = InputTraceHostSnapshot(
            rawReceipts: [
                InputTraceRawReceipt(
                    ordinal: 1,
                    eventType: Int(NSEvent.EventType.leftMouseDragged.rawValue),
                    hostTimeNanos: hostTime
                )
            ],
            discardedRawReceipts: 0,
            translatedEvents: [
                InputTraceTranslatedEvent(
                    ordinal: 2,
                    hostTimeNanos: hostTime,
                    kindAndPhase: "touch.move"
                ),
                InputTraceTranslatedEvent(
                    ordinal: 3,
                    hostTimeNanos: hostTime + 1,
                    kindAndPhase: "cancelAll"
                ),
            ],
            discardedTranslatedEvents: 0
        )
        let routed = [
            InputSentEventHistory.Record(
                batchSequence: 14,
                eventIndex: 0,
                hostTimeNanos: hostTime,
                kindAndPhase: "touch.move"
            ),
            InputSentEventHistory.Record(
                batchSequence: 15,
                eventIndex: 0,
                hostTimeNanos: hostTime + 1,
                kindAndPhase: "cancelAll"
            ),
        ]
        let acknowledgements = [
            InputAcknowledgementHistory.Record(
                batchSequence: 14,
                rejectedEvents: 0,
                receiveToInjectMicros: 90,
                lastEventTimeMillis: 420
            ),
            InputAcknowledgementHistory.Record(
                batchSequence: 15,
                rejectedEvents: 0,
                receiveToInjectMicros: 95,
                lastEventTimeMillis: 421
            ),
        ]
        let moveLine =
            "I APKRUN-FIXTURE: touch-trace kind=touch sequence=3 eventTimeMs=420 "
            + "downTimeMs=400 action=MOVE pressedBefore=true enabled=true focused=true inside=true shown=true"
        let cancelLine =
            "I APKRUN-FIXTURE: touch-trace kind=touch sequence=4 eventTimeMs=421 "
            + "downTimeMs=400 action=CANCEL pressedBefore=true enabled=true focused=true inside=true shown=true"
        let fixtureLines = [
            moveLine,
            cancelLine,
            "I APKRUN-FIXTURE: touch-trace kind=touch sequence=5 eventTimeMs=430 "
                + "downTimeMs=400 action=UP pressedBefore=true enabled=true focused=true inside=true shown=true",
            "I APKRUN-FIXTURE: touch-trace kind=click sequence=6 clickOrdinal=1 "
                + "storedCounter=1 saveSucceeded=true correlation=unique_up pendingUpCount=1 "
                + "correlatedUpSequence=5 counterIncrementStartedAtElapsedRealtimeNanos=none "
                + "counterIncrementDurationNanos=none",
        ]

        let joins = AndroidInputTests.joinTrace(
            host: host,
            routedEvents: routed,
            acknowledgements: acknowledgements,
            fixtureLines: fixtureLines
        )

        XCTAssertEqual(joins.count, 2)
        XCTAssertEqual(joins[0].rawReceiptOrdinals, [1])
        XCTAssertEqual(joins[0].translatedEventOrdinals, [2])
        XCTAssertEqual(joins[0].acknowledgement?.lastEventTimeMillis, 420)
        XCTAssertEqual(joins[0].fixtureTouchRecords, [moveLine])
        XCTAssertEqual(joins[0].fixtureDispatch, "matched-view-touch")
        XCTAssertTrue(joins[0].fixtureClickRecords.isEmpty)
        XCTAssertEqual(joins[0].clickOutcome, "not-an-up")
        XCTAssertTrue(joins[1].rawReceiptOrdinals.isEmpty)
        XCTAssertEqual(joins[1].translatedEventOrdinals, [3])
        XCTAssertEqual(joins[1].fixtureTouchRecords, [cancelLine])
        XCTAssertEqual(joins[1].fixtureDispatch, "matched-view-touch")
        XCTAssertEqual(joins[1].clickOutcome, "not-an-up")
    }

    func testTraceStageDiscrepanciesAndDuplicateAcknowledgementsAreExplicit() {
        let host = InputTraceHostSnapshot(
            rawReceipts: [
                InputTraceRawReceipt(
                    ordinal: 1,
                    eventType: Int(NSEvent.EventType.leftMouseDown.rawValue),
                    hostTimeNanos: 100
                ),
                InputTraceRawReceipt(
                    ordinal: 2,
                    eventType: Int(NSEvent.EventType.leftMouseUp.rawValue),
                    hostTimeNanos: 200
                ),
            ],
            discardedRawReceipts: 0,
            translatedEvents: [
                InputTraceTranslatedEvent(
                    ordinal: 4,
                    hostTimeNanos: 200,
                    kindAndPhase: "touch.up"
                )
            ],
            discardedTranslatedEvents: 0
        )
        let routed = [
            InputSentEventHistory.Record(
                batchSequence: 21,
                eventIndex: 0,
                hostTimeNanos: 300,
                kindAndPhase: "key.down"
            )
        ]
        let acknowledgements = [
            InputAcknowledgementHistory.Record(
                batchSequence: 21,
                rejectedEvents: 0,
                receiveToInjectMicros: 90,
                lastEventTimeMillis: 420
            ),
            InputAcknowledgementHistory.Record(
                batchSequence: 21,
                rejectedEvents: 0,
                receiveToInjectMicros: 91,
                lastEventTimeMillis: 420
            ),
        ]

        let discrepancies = AndroidInputTests.stageDiscrepancies(
            host: host,
            routedEvents: routed,
            expectedTouchCounts: [
                "touch.down": 1,
                "touch.move": 1,
                "touch.up": 1,
            ]
        )
        let joins = AndroidInputTests.joinTrace(
            host: host,
            routedEvents: routed,
            acknowledgements: acknowledgements,
            fixtureLines: []
        )

        XCTAssertEqual(
            discrepancies,
            [
                InputTraceStageDiscrepancy(
                    stage: "raw-to-translated",
                    kindAndPhase: "touch.down",
                    expectedCount: 1,
                    observedCount: 0,
                    sourceOrdinals: [1],
                    observedOrdinals: [],
                    observedBatchSequences: []
                ),
                InputTraceStageDiscrepancy(
                    stage: "expected-to-raw",
                    kindAndPhase: "touch.move",
                    expectedCount: 1,
                    observedCount: 0,
                    sourceOrdinals: [],
                    observedOrdinals: [],
                    observedBatchSequences: []
                ),
                InputTraceStageDiscrepancy(
                    stage: "translated-to-routed",
                    kindAndPhase: "touch.up",
                    expectedCount: 1,
                    observedCount: 0,
                    sourceOrdinals: [4],
                    observedOrdinals: [],
                    observedBatchSequences: []
                ),
            ])
        XCTAssertEqual(AndroidInputTests.ambiguousAcknowledgementSequences(acknowledgements), [21])
        XCTAssertEqual(joins.count, 1)
        XCTAssertNil(joins[0].acknowledgement)
        XCTAssertEqual(joins[0].fixtureDispatch, "ambiguous-ack")
    }

    func testTraceStageDiscrepanciesIncludeUnexpectedCancelAll() {
        let host = InputTraceHostSnapshot(
            rawReceipts: [],
            discardedRawReceipts: 0,
            translatedEvents: [
                InputTraceTranslatedEvent(
                    ordinal: 8,
                    hostTimeNanos: 500,
                    kindAndPhase: "cancelAll"
                )
            ],
            discardedTranslatedEvents: 0
        )
        let routed = [
            InputSentEventHistory.Record(
                batchSequence: 22,
                eventIndex: 0,
                hostTimeNanos: 500,
                kindAndPhase: "cancelAll"
            )
        ]

        let discrepancies = AndroidInputTests.stageDiscrepancies(
            host: host,
            routedEvents: routed,
            expectedTouchCounts: [:],
            expectedCancelAllCount: 0
        )

        XCTAssertEqual(
            discrepancies,
            [
                InputTraceStageDiscrepancy(
                    stage: "expected-to-translated",
                    kindAndPhase: "cancelAll",
                    expectedCount: 0,
                    observedCount: 1,
                    sourceOrdinals: [],
                    observedOrdinals: [8],
                    observedBatchSequences: []
                )
            ])
    }

    func testTraceStageDiscrepanciesReportCancelAllNotRouted() {
        let host = InputTraceHostSnapshot(
            rawReceipts: [],
            discardedRawReceipts: 0,
            translatedEvents: [
                InputTraceTranslatedEvent(
                    ordinal: 9,
                    hostTimeNanos: 600,
                    kindAndPhase: "cancelAll"
                )
            ],
            discardedTranslatedEvents: 0
        )

        let discrepancies = AndroidInputTests.stageDiscrepancies(
            host: host,
            routedEvents: [],
            expectedTouchCounts: [:],
            expectedCancelAllCount: 0
        )

        XCTAssertEqual(
            discrepancies,
            [
                InputTraceStageDiscrepancy(
                    stage: "expected-to-translated",
                    kindAndPhase: "cancelAll",
                    expectedCount: 0,
                    observedCount: 1,
                    sourceOrdinals: [],
                    observedOrdinals: [9],
                    observedBatchSequences: []
                ),
                InputTraceStageDiscrepancy(
                    stage: "translated-to-routed",
                    kindAndPhase: "cancelAll",
                    expectedCount: 1,
                    observedCount: 0,
                    sourceOrdinals: [9],
                    observedOrdinals: [],
                    observedBatchSequences: []
                ),
            ])
    }

    func testTraceStageDiscrepanciesReportRouteOnlyCancelAll() {
        let host = InputTraceHostSnapshot(
            rawReceipts: [],
            discardedRawReceipts: 0,
            translatedEvents: [],
            discardedTranslatedEvents: 0
        )
        let routed = [
            InputSentEventHistory.Record(
                batchSequence: 25,
                eventIndex: 0,
                hostTimeNanos: 700,
                kindAndPhase: "cancelAll"
            )
        ]

        let discrepancies = AndroidInputTests.stageDiscrepancies(
            host: host,
            routedEvents: routed,
            expectedTouchCounts: [:],
            expectedCancelAllCount: 0
        )

        XCTAssertEqual(
            discrepancies,
            [
                InputTraceStageDiscrepancy(
                    stage: "translated-to-routed",
                    kindAndPhase: "cancelAll",
                    expectedCount: 0,
                    observedCount: 1,
                    sourceOrdinals: [],
                    observedOrdinals: [],
                    observedBatchSequences: [25]
                )
            ])
    }

    func testTraceStageDiscrepanciesAcceptExpectedClickWithoutCancelAll() {
        let host = InputTraceHostSnapshot(
            rawReceipts: [
                InputTraceRawReceipt(
                    ordinal: 1,
                    eventType: Int(NSEvent.EventType.leftMouseDown.rawValue),
                    hostTimeNanos: 100
                ),
                InputTraceRawReceipt(
                    ordinal: 2,
                    eventType: Int(NSEvent.EventType.leftMouseUp.rawValue),
                    hostTimeNanos: 200
                ),
            ],
            discardedRawReceipts: 0,
            translatedEvents: [
                InputTraceTranslatedEvent(
                    ordinal: 1,
                    hostTimeNanos: 100,
                    kindAndPhase: "touch.down"
                ),
                InputTraceTranslatedEvent(
                    ordinal: 2,
                    hostTimeNanos: 200,
                    kindAndPhase: "touch.up"
                ),
            ],
            discardedTranslatedEvents: 0
        )
        let routed = [
            InputSentEventHistory.Record(
                batchSequence: 23,
                eventIndex: 0,
                hostTimeNanos: 100,
                kindAndPhase: "touch.down"
            ),
            InputSentEventHistory.Record(
                batchSequence: 24,
                eventIndex: 0,
                hostTimeNanos: 200,
                kindAndPhase: "touch.up"
            ),
        ]

        let discrepancies = AndroidInputTests.stageDiscrepancies(
            host: host,
            routedEvents: routed,
            expectedTouchCounts: [
                "touch.down": 1,
                "touch.move": 0,
                "touch.up": 1,
                "touch.cancel": 0,
            ],
            expectedCancelAllCount: 0
        )

        XCTAssertTrue(discrepancies.isEmpty, "\(discrepancies)")
    }
}
