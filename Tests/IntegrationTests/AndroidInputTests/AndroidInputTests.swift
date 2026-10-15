import AppKit
import CryptoKit
import Foundation
import RuntimeCore
import XCTest

private struct AndroidImageVariantReceipt: Decodable {
    let variantDiskSHA256: String
    let variantManifestSHA256: String
}

/// The pointer checks of #024 on a real Android guest (T2, test-strategy §6.4), through the path of `apkrun dev launch`.
///
/// Each test boots the test image with the embedded runtime (`DevBoot` and `DevInputRoute`), shows the development
/// window, and posts the pointer events into the window's content view. The existing tests synthesize `NSEvent`s
/// directly and need no Accessibility permission. The #103 interactive test opts into WindowServer `CGEvent`s and
/// requires permission only on its dedicated lab GUI session. Points are display pixels of display 0, mapped to the
/// window by `CoordinateMapper`. The targets are the centres of their `uiautomator` bounds, except the drag, which uses
/// fixed points inside HelloCompose's list.
///
/// The suite runs in the Xcode test host (IR-438). Its boot needs a working guest renderer, which the odm7 overlay gives
/// (IR-1278), and the host dismisses the keyguard before it launches the app (IR-1285). The device checks of the
/// coordinator's scripted runs post the same gestures with the CGEvent helper in /tmp (decision D14). The suite runs only
/// with APKRUN_INPUT_T2=1, which the AndroidInput configuration of IntegrationTests.xctestplan sets. It also needs
/// APKRUN_GUEST_DIR (the Guest Agent bundle), APKRUN_FIXTURE_APK (HelloText, a debug build: its `TEXT` and `DETAILS`
/// broadcasts exist only there), and APKRUN_FIXTURE_COMPOSE_APK (HelloCompose). A missing input skips its test and names
/// the variable.
///
/// The keyboard cases (#025) post AppKit key events into the window's view, as the pointer cases post pointer events. The
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

    /// 100 of 100 clicks on HelloText's button are logged as `APKRUN-FIXTURE: click <n>` (#024 acceptance). Each click is
    /// a left-button press and release at the button's centre, with no `adb shell input` process during the sequence.
    func testOneHundredClicksOnTheButtonAreLogged() async throws {
        let apk = try Self.fixture("APKRUN_FIXTURE_APK")
        try await AndroidInputRun.with(apk: apk, package: Self.helloText) { run in
            let target = try await run.centre(of: Self.buttonID)
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
            XCTAssertEqual(AndroidInputRun.numbers(in: lines, after: Self.clickPrefix), Array(1...100))
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
        let apk = try Self.fixture("APKRUN_FIXTURE_APK")
        try Self.attachEnvironmentIdentity(fixture: apk)
        try await AndroidInputRun.with(
            apk: apk, package: Self.helloText, pointerDelivery: .windowServer
        ) { run in
            let target = try await run.centre(of: Self.buttonID)
            try await run.prepareForWindowServerPointerDispatch()
            let captureStartCounters = try await run.startAcknowledgementHistoryCapture()
            let firstAcknowledgedSequenceAfterCaptureStart =
                UInt64(captureStartCounters.batchesSent / 32 + 1) * 32
            try await Self.assertNoShellInputDuring {
                guard var previousCount = try await Self.persistedClickCount(run) else {
                    throw AndroidInputRunFailure.timedOut("the fixture's initial persisted click counter")
                }
                XCTAssertEqual(previousCount, 0, "a new guest should start with an empty HelloText counter")
                var previousCounters = captureStartCounters
                let clickDeltas = [100, 100, 100]
                for (index, clickDelta) in clickDeltas.enumerated() {
                    var persistedCount: Int?
                    var counters: InputCounters?
                    var acknowledgements: InputAcknowledgementHistory?
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
                        let lastAcknowledgedSequence = UInt64(sentCounters.batchesSent / 32 * 32)
                        if lastAcknowledgedSequence == 0 {
                            acknowledgements = try await run.acknowledgementHistory()
                        } else {
                            acknowledgements = try await run.waitForAcknowledgement(
                                through: lastAcknowledgedSequence)
                        }
                        let finalCounters = try await run.inputCounters()
                        counters = finalCounters
                        XCTAssertGreaterThanOrEqual(
                            finalCounters.eventsSent - previousCounters.eventsSent,
                            clickDelta * 2,
                            "batch \(index + 1) did not send both touch edges for every click")
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
                            acknowledgements: acknowledgements,
                            failure: nil
                        )
                        previousCount = reachedCount
                        previousCounters = finalCounters
                    } catch {
                        if let currentCount = try? await Self.persistedClickCount(
                            run, timeout: .seconds(1))
                        {
                            persistedCount = currentCount
                        }
                        if let currentCounters = try? await run.inputCounters() {
                            counters = currentCounters
                        }
                        if let currentAcknowledgements = try? await run.acknowledgementHistory() {
                            acknowledgements = currentAcknowledgements
                        }
                        Self.attachBatchEvidence(
                            batch: index + 1,
                            before: previousCount,
                            after: persistedCount,
                            counters: counters,
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
        let apk = try Self.fixture("APKRUN_FIXTURE_APK")
        try Self.attachEnvironmentIdentity(fixture: apk)
        try await AndroidInputRun.with(
            apk: apk, package: Self.helloText, pointerDelivery: .windowServer
        ) { run in
            let target = try await run.centre(of: Self.buttonID)
            try await run.prepareForWindowServerPointerDispatch()
            guard let before = try await Self.persistedClickCount(run) else {
                throw AndroidInputRunFailure.timedOut("the fixture's initial persisted click counter")
            }
            XCTAssertEqual(before, 0, "a new guest should start with an empty HelloText counter")
            _ = try await run.adb.shell("logcat -c")
            let captureStart = try await run.startPerEventInputTraceCapture()
            _ = try await run.adb.shell(
                "am broadcast -n \(Self.helloText)/.DebugCounterReceiver -a \(Self.touchTraceStartAction)")

            var clickFailure: String?
            do {
                let pointer = try run.pointer()
                for _ in 0..<100 {
                    try await pointer.click(at: target, interClickGap: .milliseconds(50))
                }
                try await run.drainInput()
            } catch {
                clickFailure = String(describing: error)
            }

            let expectedCount = before + 100
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
            let evidence = InputTraceEvidence(
                schemaVersion: 1,
                path: "WindowServer → AppKit → IOSurfaceLayerView → InputRouter → Guest Agent → HelloText",
                captureMode: "one event per input batch; ACK requested for every batch",
                clockDomains: [
                    "hostTimeNanos": "NSEvent.timestamp and InputCore use Mac mach continuous time",
                    "lastEventTimeMillis": "Guest MotionEvent.eventTime in Android uptime milliseconds",
                    "fixtureEventTimeMs": "HelloText MotionEvent.eventTime; match only to the guest ACK timestamp",
                    "receiveToInjectMicros":
                        "Guest monotonic interval from batch receipt to input injection completion",
                ],
                limitations: [
                    "The debug touch listener and per-event ACK cadence can change timing; compare with the separate product-cadence test.",
                    "Host and guest clock values have different epochs and are never subtracted.",
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
                unattributedFixtureClickRecords: unattributedFixtureClickRecords,
                fixtureTraceLines: fixtureLines.filter {
                    $0.contains("touch-trace ") || $0.contains("debug touch trace drain")
                },
                fixtureTraceRecords: summary?.records,
                fixtureTraceDiscarded: summary?.discarded,
                persistedCounterBefore: before,
                persistedCounterAfter: after,
                persistedCounterDelta: after.map { $0 - before }
            )
            try Self.attachTraceEvidence(evidence, failure: clickFailure)

            XCTAssertNil(clickFailure, "the WindowServer click batch failed")
            XCTAssertEqual(after, expectedCount, "persisted counter after the diagnostic click batch")
            XCTAssertEqual(after.map { $0 - before }, 100)
            XCTAssertEqual(trace.host.discardedRawReceipts, 0)
            XCTAssertEqual(trace.host.discardedTranslatedEvents, 0)
            XCTAssertEqual(trace.routed.discardedRecords, 0)
            XCTAssertEqual(trace.acknowledgements.discardedRecords, 0)
            XCTAssertEqual(summary?.discarded, 0, "the fixture touch trace overflowed")

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

    /// Dragging scrolls HelloCompose's list, and trackpad and wheel scrolling move it the way macOS reports them (#024).
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
    /// (#024 acceptance). The right button is `SOURCE_MOUSE` with the secondary button (input.md §4.1).
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

    /// Typing `Hello, APKRun 123!` into HelloText's field gives exactly that text (#025 acceptance, T2). The field is
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
    /// of the field, which logs `APKRUN-FIXTURE: editor action 6` (IME_ACTION_DONE, #025).
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

    private static func joinTrace(
        host: InputTraceHostSnapshot,
        routedEvents: [InputSentEventHistory.Record],
        acknowledgements: [InputAcknowledgementHistory.Record],
        fixtureLines: [String]
    ) -> [InputTraceLink] {
        let traceLines = fixtureLines.filter { $0.contains("touch-trace ") }
        let touchLines = traceLines.filter { keyValues(in: $0)["kind"] == "touch" }
        let clickLines = traceLines.filter { keyValues(in: $0)["kind"] == "click" }
        let acksBySequence = Dictionary(uniqueKeysWithValues: acknowledgements.map { ($0.batchSequence, $0) })

        return routedEvents.map { routed in
            let eventType: Int?
            let fixtureAction: String?
            switch routed.kindAndPhase {
            case "touch.down":
                eventType = Int(NSEvent.EventType.leftMouseDown.rawValue)
                fixtureAction = "DOWN"
            case "touch.up":
                eventType = Int(NSEvent.EventType.leftMouseUp.rawValue)
                fixtureAction = "UP"
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
            let acknowledgement = acksBySequence[routed.batchSequence]
            let guestTime = acknowledgement?.lastEventTimeMillis ?? 0
            let fixtureTouches = touchLines.filter { line in
                let fields = keyValues(in: line)
                return fields["action"] == fixtureAction
                    && fields["eventTimeMs"].flatMap(UInt64.init) == (guestTime == 0 ? nil : guestTime)
            }
            let guestSequences = Set(fixtureTouches.compactMap { keyValues(in: $0)["sequence"] })
            let uniquelyCorrelatedClicks = clickLines.filter {
                guard let sequence = keyValues(in: $0)["correlatedUpSequence"] else {
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
                clickRecords = uniquelyCorrelatedClicks
                clickOutcome = "unique-up"
            } else if fixtureTouches.isEmpty {
                clickRecords = []
                clickOutcome = "no-matching-up"
            } else {
                clickRecords = []
                clickOutcome = "no-unique-up-correlation"
            }
            let dispatchOutcome: String
            if acknowledgement == nil {
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

    private static func attachEnvironmentIdentity(fixture: URL) throws {
        let bundle = try AndroidBootSession.bundleDirectory()
        guard let guestPath = ProcessInfo.processInfo.environment["APKRUN_GUEST_DIR"], !guestPath.isEmpty else {
            throw XCTSkip("APKRUN_GUEST_DIR is not set.")
        }
        let guestBundle = URL(fileURLWithPath: guestPath, isDirectory: true)
        let imageManifest = bundle.appendingPathComponent("manifest.json")
        let guestManifest = guestBundle.appendingPathComponent("apkrun-guest.json")
        let guestAPK = guestBundle.appendingPathComponent("apkrun-guest.apk")
        let identity: [String: Any] = [
            "delivery": "CGEvent.post(tap: .cghidEventTap)",
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
