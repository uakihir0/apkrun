import AppKit
import Foundation
import InputCore
import RuntimeCore
import XCTest

/// The pointer checks of #024 on a real Android guest (T2, test-strategy §6.4), through the path of `apkrun dev launch`.
///
/// Each test boots the test image with the embedded runtime (`DevBoot` and `DevInputRoute`), shows the development
/// window, and posts the pointer events into the window's content view as `NSEvent`s. The suite needs no Accessibility
/// permission. Points are display pixels of display 0, mapped to the window by `CoordinateMapper`. The targets are the
/// centres of their `uiautomator` bounds, except the drag, which uses fixed points inside HelloCompose's list.
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
    private static let debugReadPrefix = "APKRUN-FIXTURE: debug read "
    private static let rowPrefix = "APKRUN-FIXTURE: scroll first="

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["APKRUN_INPUT_T2"] == "1" else {
            throw XCTSkip("The input checks run with APKRUN_INPUT_T2=1, in the AndroidInput test-plan configuration.")
        }
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

    /// One click must reach HelloText through the AppKit event queue, NSWindow dispatch, and the ordinary view handler.
    func testOneAppKitQueuedClickReachesHelloText() async throws {
        let apk = try Self.fixture("APKRUN_FIXTURE_APK")
        try await AndroidInputRun.with(
            apk: apk, package: Self.helloText, pointerDelivery: .appKitEventQueue, recordPointerTrace: true
        ) { run in
            let target = try await run.centre(of: Self.buttonID)
            _ = try await run.adb.shell("logcat -c")
            try await run.prepareForAppKitPointerDispatch()
            let countersBeforeClick = await run.inputCounters()
            let pointer = try run.pointer()
            try await pointer.click(at: target)
            let lines = try await run.fixtureLog(
                until: { lines in lines.contains { $0.contains(Self.clickPrefix) } },
                settleFor: .seconds(2)
            )
            XCTAssertEqual(AndroidInputRun.numbers(in: lines, after: Self.clickPrefix), [1])

            let fence = try await run.acknowledgementFence()
            let receipt = try await run.waitForAcknowledgement(fence)
            let pointerTrace = run.pointerEventTrace()
            let touchEvents = pointerTrace.entries.compactMap {
                entry -> (
                    sequence: UInt64,
                    receivedAtHostUptimeNanos: UInt64,
                    phase: InputCore.TouchEvent.Phase
                )? in
                guard case .touch(let touch) = entry.event, touch.pointerID == 0 else {
                    return nil
                }
                return (entry.sequence, entry.receivedAtHostUptimeNanos, touch.phase)
            }
            XCTAssertEqual(pointerTrace.droppedEntryCount, 0, "the bounded test input trace overflowed")
            XCTAssertEqual(
                touchEvents.map(\.phase), [.down, .up],
                "the AppKit queued click did not reach the test WireSink as one ordered touch gesture: \(pointerTrace)"
            )
            if touchEvents.count == 2 {
                XCTAssertLessThan(touchEvents[0].sequence, touchEvents[1].sequence)
                XCTAssertLessThan(
                    touchEvents[0].receivedAtHostUptimeNanos, touchEvents[1].receivedAtHostUptimeNanos,
                    "the WireSink host receive timestamps did not increase from down to up"
                )
            }
            XCTAssertGreaterThanOrEqual(receipt.counters.eventsSent - countersBeforeClick.eventsSent, 2)
            XCTAssertEqual(receipt.counters.droppedRate, 0)
            XCTAssertEqual(receipt.counters.droppedNotRunning, 0)
            XCTAssertEqual(receipt.counters.droppedInvalid, 0)
            XCTAssertEqual(receipt.counters.droppedChannel, 0)
            XCTAssertEqual(receipt.counters.coalesced, 0)
        }
    }

    /// Captures the Button's UI state around two 100-click AppKit batches, comparing queued and synchronous fixture writes.
    /// This is diagnostic evidence only: AppKit posts synthetic application events, not WindowServer or hardware input.
    func testHundredAppKitClicksCaptureGuestButtonStateForBothWriteModes() async throws {
        let apk = try Self.fixture("APKRUN_FIXTURE_APK")
        try await AndroidInputRun.with(
            apk: apk,
            package: Self.helloText,
            acknowledgeEveryBatch: true,
            pointerDelivery: .appKitEventQueue,
            recordPointerTrace: true
        ) { run in
            let target = try await run.centre(of: Self.buttonID)
            try await run.prepareForAppKitPointerDispatch()
            let baselineFence = try await run.acknowledgementFence()
            _ = try await run.waitForAcknowledgement(baselineFence)
            let pointer = try run.pointer()

            for mode in ["queue", "synchronous"] {
                let countersBeforeMode = await run.inputCounters()
                _ = try await run.adb.shell("logcat -c")
                let start = try await run.adb.shell(
                    "am broadcast -a io.apkrun.fixture.hellotext.debug.TRACE_START "
                        + "--es mode \(mode) -p \(Self.helloText)")
                XCTAssertFalse(start.output.contains("Permission Denial"), start.output)
                XCTAssertTrue(start.output.contains("Broadcast completed"), start.output)
                let startLines = try await run.fixtureLog(
                    until: { $0.contains { $0.contains("debug trace started") } })
                guard startLines.contains(where: { $0.contains("debug trace started") }) else {
                    XCTFail("the \(mode) guest trace did not start: \(startLines)")
                    return
                }

                for _ in 0..<100 {
                    try await pointer.click(at: target)
                    try await Task.sleep(for: .milliseconds(100))
                }

                let clickLines = try await run.fixtureLog(
                    until: { $0.filter { $0.contains(Self.clickPrefix) }.count >= 100 })
                let clickNumbers = AndroidInputRun.numbers(in: clickLines, after: Self.clickPrefix)
                let expectedClickNumbers = mode == "queue" ? Array(1...100) : Array(101...200)
                XCTAssertEqual(clickNumbers, expectedClickNumbers, "the \(mode) batch click logs were \(clickNumbers)")

                let fence = try await run.acknowledgementFence()
                let receipt = try await run.waitForAcknowledgement(fence)
                XCTAssertGreaterThanOrEqual(receipt.counters.eventsSent - countersBeforeMode.eventsSent, 200)
                let sentBatchCount = receipt.counters.batchesSent - countersBeforeMode.batchesSent
                let acknowledgedBatchCount =
                    receipt.counters.acknowledgementsReceived - countersBeforeMode.acknowledgementsReceived
                XCTAssertGreaterThan(sentBatchCount, 0)
                XCTAssertEqual(acknowledgedBatchCount, sentBatchCount)
                XCTAssertEqual(receipt.counters.droppedRate, 0)
                XCTAssertEqual(receipt.counters.droppedNotRunning, 0)
                XCTAssertEqual(receipt.counters.droppedInvalid, 0)
                XCTAssertEqual(receipt.counters.droppedChannel, 0)
                XCTAssertEqual(receipt.counters.coalesced, 0)

                let read = try await run.adb.shell(
                    "am broadcast -a io.apkrun.fixture.hellotext.debug.TRACE_READ -p \(Self.helloText)")
                XCTAssertFalse(read.output.contains("Permission Denial"), read.output)
                let traceLines = try await run.fixtureLog(until: { Self.reassembledGuestTrace(in: $0) != nil })
                let traceJSON = try XCTUnwrap(
                    Self.reassembledGuestTrace(in: traceLines),
                    "the \(mode) guest trace was missing or had a dropped chunk: \(traceLines)")
                let attachment = XCTAttachment(string: traceJSON)
                attachment.name = "hellotext-\(mode)-button-trace.json"
                attachment.lifetime = .keepAlways
                add(attachment)

                let trace = try XCTUnwrap(
                    try JSONSerialization.jsonObject(with: Data(traceJSON.utf8)) as? [String: Any])
                XCTAssertEqual(trace["mode"] as? String, mode)
                XCTAssertEqual((trace["dropped_events"] as? NSNumber)?.intValue, 0)
                let events = try XCTUnwrap(trace["events"] as? [[String: Any]])
                XCTAssertEqual(
                    events.filter { $0["kind"] as? String == "touch" && $0["action"] as? String == "down" }.count,
                    100)
                XCTAssertEqual(
                    events.filter { $0["kind"] as? String == "touch" && $0["action"] as? String == "up" }.count,
                    100)
                XCTAssertEqual(events.filter { $0["kind"] as? String == "click_callback" }.count, 100)
                XCTAssertEqual(events.filter { $0["kind"] as? String == "counter_write" }.count, 100)
                XCTAssertEqual(
                    events.compactMap { ($0["seq"] as? NSNumber)?.intValue },
                    Array(1..<(events.count + 1)),
                    "the \(mode) guest trace sequence was incomplete or out of order")

                let pointerTrace = run.pointerEventTrace()
                XCTAssertEqual(pointerTrace.droppedEntryCount, 0)
                let expectedTouchEventCount = mode == "queue" ? 200 : 400
                XCTAssertEqual(
                    pointerTrace.entries.filter {
                        if case .touch = $0.event { return true }
                        return false
                    }.count,
                    expectedTouchEventCount,
                    "the host-side pointer trace did not retain both 100-click batches: \(pointerTrace)")
            }
        }
    }

    /// Diagnostic only: checks route counters, then checks persistence after all 100 ordered click logs are present.
    func testOneHundredCommittedClicksSurviveForceStopAndRelaunch() async throws {
        let apk = try Self.fixture("APKRUN_FIXTURE_APK")
        try await AndroidInputRun.with(
            apk: apk, package: Self.helloText, acknowledgeEveryBatch: true
        ) { run in
            var observation = "phase: preparing click sequence\n"
            defer {
                let attachment = XCTAttachment(string: observation)
                attachment.name = "click-ack-fence.txt"
                attachment.lifetime = .keepAlways
                add(attachment)
            }

            let target = try await run.centre(of: Self.buttonID)
            _ = try await run.adb.shell("logcat -c")
            let pointer = try run.pointer()
            observation = "phase: submitting clicks\n"
            var submittedClicks = 0
            do {
                for _ in 0..<100 {
                    try await pointer.click(at: target)
                    submittedClicks += 1
                    observation = "phase: submitting clicks; submitted \(submittedClicks) of 100\n"
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch {
                let counters = await run.inputCounters()
                let acknowledgementHistory = await run.acknowledgementHistory()
                observation += "click submission failed: \(error)\n"
                observation += "counters at click failure: \(counters)\n"
                observation += "acknowledged sequences: \(acknowledgementHistory.batchSequences)\n"
                observation += "acknowledgement history truncated: \(acknowledgementHistory.truncated)\n"
                throw error
            }
            observation = "phase: click sequence submitted\n"

            let fenceSequence: UInt64
            do {
                fenceSequence = try await run.acknowledgementFence()
            } catch {
                let acknowledgementHistory = await run.acknowledgementHistory()
                observation += "fence enqueue failed: \(error)\n"
                observation += "counters before fence failure: \(await run.inputCounters())\n"
                observation += "acknowledged sequences: \(acknowledgementHistory.batchSequences)\n"
                observation += "acknowledgement history truncated: \(acknowledgementHistory.truncated)\n"
                throw error
            }
            observation += "fence sequence: \(fenceSequence)\nphase: waiting for guest acknowledgements\n"

            let receipt: (counters: InputCounters, lastAcknowledgedBatchSequence: UInt64)
            do {
                receipt = try await run.waitForAcknowledgement(fenceSequence)
            } catch {
                let counters = await run.inputCounters()
                let acknowledgementHistory = await run.acknowledgementHistory()
                let lastAcknowledgedBatchSequence = await run.lastAcknowledgedBatchSequence()
                observation += "acknowledgement wait failed: \(error)\n"
                observation += "last acknowledged sequence: \(String(describing: lastAcknowledgedBatchSequence))\n"
                observation += "counters at timeout: \(counters)\n"
                observation += "acknowledged sequences: \(acknowledgementHistory.batchSequences)\n"
                observation += "acknowledgement history truncated: \(acknowledgementHistory.truncated)\n"
                throw error
            }
            let counters = receipt.counters
            let acknowledgementHistory = await run.acknowledgementHistory()
            let expectedAcknowledgementSequences = Array(1...fenceSequence)
            observation += """
                last acknowledged sequence: \(receipt.lastAcknowledgedBatchSequence)
                sent events: \(counters.eventsSent)
                sent batches: \(counters.batchesSent)
                received acknowledgements: \(counters.acknowledgementsReceived)
                acknowledged sequences: \(acknowledgementHistory.batchSequences)
                acknowledgement history truncated: \(acknowledgementHistory.truncated)
                rejected events: \(counters.droppedInvalid)
                host drops: rate=\(counters.droppedRate), not-running=\(counters.droppedNotRunning), channel=\(counters.droppedChannel)
                coalesced events: \(counters.coalesced)
                phase: collecting ordered click callbacks
                """
            let clickLines = try await run.fixtureLog(
                until: { $0.filter { $0.contains(Self.clickPrefix) }.count >= 100 },
                settleFor: .seconds(2))
            let clickNumbers = AndroidInputRun.numbers(in: clickLines, after: Self.clickPrefix)
            observation += "\nordered click callbacks before force-stop: \(clickNumbers)\n"
            XCTAssertEqual(receipt.lastAcknowledgedBatchSequence, fenceSequence)
            XCTAssertGreaterThanOrEqual(
                counters.eventsSent, 200, "input counters after 100 committed clicks: \(counters)")
            XCTAssertEqual(
                counters.batchesSent, Int(fenceSequence),
                "the batch sequence did not match the sent batch count through the fence: \(counters)")
            XCTAssertEqual(
                counters.acknowledgementsReceived,
                counters.batchesSent,
                "the guest did not acknowledge every test input batch through fence \(fenceSequence): \(counters)")
            XCTAssertFalse(
                acknowledgementHistory.truncated,
                "the acknowledgement sequence history was truncated at fence \(fenceSequence)")
            XCTAssertEqual(
                acknowledgementHistory.batchSequences, expectedAcknowledgementSequences,
                "the guest acknowledgements did not match each batch sequence through fence \(fenceSequence)")
            XCTAssertEqual(counters.droppedRate, 0, "input counters after 100 committed clicks: \(counters)")
            XCTAssertEqual(counters.droppedNotRunning, 0, "input counters after 100 committed clicks: \(counters)")
            XCTAssertEqual(counters.droppedInvalid, 0, "input counters after 100 committed clicks: \(counters)")
            XCTAssertEqual(counters.droppedChannel, 0, "input counters after 100 committed clicks: \(counters)")
            XCTAssertEqual(counters.coalesced, 0, "input counters after 100 committed clicks: \(counters)")
            guard counters.eventsSent >= 200 else {
                XCTFail("the host input stream did not send 200 events; restart check skipped")
                return
            }
            guard counters.acknowledgementsReceived == counters.batchesSent, counters.droppedInvalid == 0 else {
                XCTFail(
                    "guest input acknowledgements were incomplete or reported rejected events; "
                        + "restart check skipped")
                return
            }
            guard
                !acknowledgementHistory.truncated,
                acknowledgementHistory.batchSequences == expectedAcknowledgementSequences,
                receipt.lastAcknowledgedBatchSequence == fenceSequence
            else {
                XCTFail("guest acknowledgement sequences were incomplete; restart check skipped")
                return
            }
            guard clickNumbers == Array(1...100) else {
                XCTFail(
                    "expected ordered click logs 1 through 100 before the persistence check, got \(clickNumbers); "
                        + "restart check skipped")
                return
            }

            observation += "phase: force-stopping and relaunching the fixture\n"
            try await run.adb.forceStop(Self.helloText)
            let stoppedProcess = try await run.adb.pidof(Self.helloText)
            XCTAssertNil(stoppedProcess, "force-stop left the fixture process running")
            try await run.adb.startActivity(component: "\(Self.helloText)/.MainActivity")
            _ = try await run.adb.shell("logcat -c")
            _ = try await run.adb.shell(
                "am broadcast -a io.apkrun.fixture.hellotext.debug.READ -p \(Self.helloText)")

            let readLines = try await run.fixtureLog(until: { lines in
                lines.contains { $0.contains(Self.debugReadPrefix) }
            })
            let persistedClickNumbers = AndroidInputRun.numbers(in: readLines, after: Self.debugReadPrefix)
            XCTAssertEqual(
                persistedClickNumbers, [100],
                "the reopened store did not report the 100 saved clicks")
            observation +=
                "persisted click count after relaunch: \(persistedClickNumbers)\nphase: complete\n"
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
    private static let editorActionLine = "APKRUN-FIXTURE: editor action 6"
    private static let mainScreenLine = "APKRUN-FIXTURE: screen main"
    private static let detailsScreenLine = "APKRUN-FIXTURE: screen details"

    /// Reassembles numbered guest logcat chunks only when every piece is present exactly once.
    private static func reassembledGuestTrace(in lines: [String]) -> String? {
        let prefix = "debug trace chunk "
        var total: Int?
        var chunks: [Int: String] = [:]
        for line in lines {
            guard let range = line.range(of: prefix) else {
                continue
            }
            let suffix = line[range.upperBound...]
            guard let separator = suffix.firstIndex(of: " ") else {
                return nil
            }
            let indexAndTotal = suffix[..<separator].split(separator: "/")
            guard
                indexAndTotal.count == 2,
                let index = Int(indexAndTotal[0]),
                let lineTotal = Int(indexAndTotal[1]),
                index > 0,
                lineTotal > 0,
                index <= lineTotal,
                total == nil || total == lineTotal,
                chunks[index] == nil
            else {
                return nil
            }
            total = lineTotal
            chunks[index] = String(suffix[suffix.index(after: separator)...])
        }
        guard let total, chunks.count == total else {
            return nil
        }
        return (1...total).compactMap { chunks[$0] }.joined()
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
