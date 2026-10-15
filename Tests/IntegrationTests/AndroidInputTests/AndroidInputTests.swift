import AppKit
import Foundation
import XCTest

/// The pointer checks of #024 on a real Android guest (T2, test-strategy §6.4), through the path of `apkrun dev launch`.
///
/// Each test boots the test image with the embedded runtime (`DevBoot` and `DevInputRoute`) and shows the development
/// window. Pointer tests synthesize NSEvents; most call the view handlers directly, while the AppKit click case queues
/// events through `NSApplication`. Neither path uses WindowServer input. The suite needs no Accessibility permission.
/// Points are display pixels of display 0, mapped to the window by `CoordinateMapper`. The targets are the centres of
/// their `uiautomator` bounds, except the drag, which uses fixed points inside HelloCompose's list.
///
/// The suite runs in the Xcode test host (IR-438). Its boot needs a working guest renderer, which the odm7 overlay gives
/// (IR-1278), and the host dismisses the keyguard before it launches the app (IR-1285). The device checks of the
/// coordinator's scripted runs post the same gestures with the CGEvent helper in /tmp (decision D14). The suite runs only
/// with APKRUN_INPUT_T2=1, which the AndroidInput configuration of IntegrationTests.xctestplan sets. It also needs
/// APKRUN_GUEST_DIR (the Guest Agent bundle), APKRUN_FIXTURE_APK (HelloText, a debug build: its `TEXT` and `DETAILS`
/// broadcasts exist only there), and APKRUN_FIXTURE_COMPOSE_APK (HelloCompose). The separate ACK diagnostic test
/// requests one Guest Agent acknowledgement per routed batch. A missing input skips its test and names the variable.
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

    /// 100 of 100 clicks on HelloText's button are logged as `APKRUN-FIXTURE: click <n>` (#024 acceptance). Each click is
    /// a left-button press and release at the button's centre, with no `adb shell input` process during the sequence.
    func testOneHundredClicksOnTheButtonAreLogged() async throws {
        try await runOneHundredClickBatch(acknowledgeEveryBatch: false)
    }

    /// The opt-in diagnostic variant records every guest ACK without changing the ordinary click-test cadence.
    func testOneHundredClicksWithGuestAcknowledgementsAreLogged() async throws {
        guard ProcessInfo.processInfo.environment["APKRUN_INPUT_ACK_T2"] == "1" else {
            throw XCTSkip("The ACK diagnostic runs only with the AndroidInputAckDiagnostic test-plan configuration.")
        }
        try await runOneHundredClickBatch(acknowledgeEveryBatch: true)
    }

    private func runOneHundredClickBatch(acknowledgeEveryBatch: Bool) async throws {
        let apk = try Self.fixture("APKRUN_FIXTURE_APK")
        try await AndroidInputRun.with(
            apk: apk,
            package: Self.helloText,
            acknowledgeEveryBatch: acknowledgeEveryBatch
        ) { run in
            let target = try await run.centre(of: Self.buttonID)
            let traceAcknowledgements = acknowledgeEveryBatch
            let counterBefore = try await run.helloTextCounter().value
            let sampler = ShellInputSampler()
            sampler.start()
            _ = try await run.adb.shell("logcat -c")
            let countersBefore = await run.inputCountersAfterDraining()
            let bindingGenerationBefore = await run.inputBindingGeneration()
            if traceAcknowledgements {
                XCTAssertEqual(
                    countersBefore.batchesSent,
                    0,
                    "the ACK diagnostic requires a fresh route with no earlier batches")
            }
            let pointer = try run.pointer()
            for _ in 0..<100 {
                try await pointer.click(at: target)
                try await Task.sleep(for: .milliseconds(100))
            }
            let shellInput = await sampler.stop()
            XCTAssertEqual(shellInput, [], "adb shell input processes ran during the sequence")
            let acknowledgementTrace =
                traceAcknowledgements
                ? try await run.inputAcknowledgementTraceAfterDraining(throughSequence: 200)
                : []
            let lines = try await run.fixtureLog {
                $0.filter { $0.contains(Self.clickPrefix) }.count >= 100
            }
            let clickNumbers = AndroidInputRun.numbers(in: lines, after: Self.clickPrefix)
            let countersAfter = await run.inputCountersAfterDraining()
            let counterAfter = try await run.helloTextCounter().value
            let batchesSent = countersAfter.batchesSent - countersBefore.batchesSent
            XCTAssertEqual(
                clickNumbers, Array(1...100),
                "the direct-view click batch missed or reordered a callback; route counters: \(countersAfter)")
            XCTAssertEqual(countersAfter.droppedRate - countersBefore.droppedRate, 0, "\(countersAfter)")
            XCTAssertEqual(countersAfter.droppedNotRunning - countersBefore.droppedNotRunning, 0, "\(countersAfter)")
            XCTAssertEqual(countersAfter.droppedInvalid - countersBefore.droppedInvalid, 0, "\(countersAfter)")
            XCTAssertEqual(countersAfter.droppedChannel - countersBefore.droppedChannel, 0, "\(countersAfter)")
            XCTAssertEqual(countersAfter.coalesced - countersBefore.coalesced, 0, "\(countersAfter)")

            if traceAcknowledgements {
                let newAcknowledgements = acknowledgementTrace
                let expectedSequences = (1...200).map(UInt64.init)
                let bindingGenerationAfter = await run.inputBindingGeneration()
                let acknowledgementPairs =
                    newAcknowledgements
                    .map { "\($0.batchSequence):\($0.rejectedEvents)" }
                    .joined(separator: ",")
                let attachment = XCTAttachment(
                    string: """
                        host batches sent: \(batchesSent)
                        host events sent: \(countersAfter.eventsSent - countersBefore.eventsSent)
                        host route counters before: \(countersBefore)
                        host route counters after: \(countersAfter)
                        route generation: \(bindingGenerationBefore) -> \(bindingGenerationAfter)
                        acknowledgements (batch:rejected events): \(acknowledgementPairs)
                        HelloText click log: \(clickNumbers)
                        HelloText SharedPreferences counter: \(counterBefore) -> \(counterAfter)
                        adb shell input processes during clicks: \(shellInput.count)
                        """
                )
                attachment.name = "input-ack-diagnostic"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertEqual(
                    bindingGenerationAfter,
                    bindingGenerationBefore,
                    "the Guest Agent input route rebound during the batch-sequence diagnostic")
                XCTAssertEqual(batchesSent, 200, "the host route did not send 200 batches; \(countersAfter)")
                XCTAssertEqual(
                    countersAfter.eventsSent - countersBefore.eventsSent,
                    200,
                    "the host route did not send 200 click events; \(countersAfter)")
                XCTAssertEqual(
                    newAcknowledgements.map(\.batchSequence),
                    expectedSequences,
                    "missing or reordered Guest Agent acknowledgements: \(newAcknowledgements)")
                XCTAssertTrue(
                    newAcknowledgements.allSatisfy { $0.rejectedEvents == 0 },
                    "the Guest Agent rejected input events: \(newAcknowledgements)")
            }
            XCTAssertEqual(
                counterAfter - counterBefore,
                100,
                "the live guest app counter did not record all clicks; click log: \(clickNumbers)")
        }
    }

    /// Repeats the click acceptance check through AppKit's queue and the window's normal mouse dispatch.
    func testOneHundredAppKitQueuedClicksAreLogged() async throws {
        guard ProcessInfo.processInfo.environment["APKRUN_INPUT_APPKIT_T2"] == "1" else {
            throw XCTSkip(
                "Set APKRUN_INPUT_APPKIT_T2=1 only in an isolated active UI session that will remain untouched; "
                    + "the test activates its window.")
        }
        let apk = try Self.fixture("APKRUN_FIXTURE_APK")
        try await AndroidInputRun.with(
            apk: apk, package: Self.helloText, pointerDelivery: .appKitEventQueue
        ) { run in
            let target = try await run.centre(of: Self.buttonID)
            try await run.prepareForAppKitPointerDispatch()
            _ = try await run.adb.shell("logcat -c")
            let countersBefore = await run.inputCountersAfterDraining()
            let pointer = try run.pointer()
            let sampler = ShellInputSampler()
            sampler.start()
            do {
                for _ in 0..<100 {
                    try await pointer.click(at: target)
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch {
                _ = await sampler.stop()
                throw error
            }
            let shellInput = await sampler.stop()
            let lines = try await run.fixtureLog { $0.filter { $0.contains(Self.clickPrefix) }.count >= 100 }
            let clickNumbers = AndroidInputRun.numbers(in: lines, after: Self.clickPrefix)
            let countersAfter = await run.inputCountersAfterDraining()
            let sentDelta = countersAfter.eventsSent - countersBefore.eventsSent

            XCTAssertEqual(shellInput, [], "adb shell input processes ran during the sequence")
            XCTAssertEqual(clickNumbers, Array(1...100), "the AppKit queued click batch did not produce all callbacks")
            XCTAssertEqual(sentDelta, 200, "the host input route did not send exactly 200 click events")
            XCTAssertEqual(countersAfter.droppedRate - countersBefore.droppedRate, 0)
            XCTAssertEqual(countersAfter.droppedNotRunning - countersBefore.droppedNotRunning, 0)
            XCTAssertEqual(countersAfter.droppedInvalid - countersBefore.droppedInvalid, 0)
            XCTAssertEqual(countersAfter.droppedChannel - countersBefore.droppedChannel, 0)
            XCTAssertEqual(countersAfter.coalesced - countersBefore.coalesced, 0)
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
            // These direct-view drags end outside the content rectangle. The fixture logs settled list rows rather
            // than raw MotionEvents, so the row changes cannot prove which out-of-bounds samples or releases arrived.
            try await pointer.drag(from: (x: 512, y: 400), to: (x: 512, y: -100), steps: 20)
            let topEdge = try await Self.lastRow(run, above: dragged)
            XCTAssertGreaterThan(topEdge, dragged, "the drag that left the top display edge did not scroll the list")

            try await pointer.drag(from: (x: 512, y: 600), to: (x: -100, y: 250), steps: 20)
            let leftEdge = try await Self.lastRow(run, above: topEdge)
            XCTAssertGreaterThan(leftEdge, topEdge, "the drag that left the left display edge did not scroll the list")

            pointer.scroll(at: (x: 512, y: 400), deltaY: -120, precise: true)
            let trackpad = try await Self.lastRow(run, above: leftEdge)
            XCTAssertGreaterThan(trackpad, leftEdge, "the trackpad scroll did not move the list")
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
