import AppKit
import Foundation
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
            let sampler = ShellInputSampler()
            sampler.start()
            try await Self.focusField(run)
            try await run.keyboard().type("Hello, APKRun 123!")
            let shellInput = await sampler.stop()
            XCTAssertEqual(shellInput, [], "adb shell input processes ran during the typing")
            let text = try await Self.fieldText(run)
            XCTAssertEqual(text, "Hello, APKRun 123!")
        }
    }

    /// Backspace removes the character before the cursor, the left arrow moves the cursor, and Enter is the editor action
    /// of the field, which logs `APKRUN-FIXTURE: editor action 6` (IME_ACTION_DONE, #025).
    func testBackspaceEnterAndArrowsEditTheField() async throws {
        let apk = try Self.fixture("APKRUN_FIXTURE_APK")
        try await AndroidInputRun.with(apk: apk, package: Self.helloText) { run in
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
            XCTAssertTrue(lines.contains { $0.contains(Self.editorActionLine) }, "Enter did not log the editor action")
        }
    }

    /// Esc and ⌘[ go back from the Details screen to the main screen, which logs `APKRUN-FIXTURE: screen main` (FR-IN-04).
    /// The Details button is opened with a pointer click, and the screen change is the log line the case checks.
    func testEscAndCommandBracketGoBackFromDetails() async throws {
        let apk = try Self.fixture("APKRUN_FIXTURE_APK")
        try await AndroidInputRun.with(apk: apk, package: Self.helloText) { run in
            let keys = try run.keyboard()
            try await Self.openDetails(run)
            _ = try await run.adb.shell("logcat -c")
            try await keys.tap(.escape)
            let back = try await run.fixtureLog { lines in lines.contains { $0.contains(Self.mainScreenLine) } }
            XCTAssertTrue(back.contains { $0.contains(Self.mainScreenLine) }, "Esc did not return to the main screen")
            try await Self.openDetails(run)
            _ = try await run.adb.shell("logcat -c")
            try await keys.commandShortcut(.leftBracket)
            let commandBack = try await run.fixtureLog { lines in lines.contains { $0.contains(Self.mainScreenLine) } }
            XCTAssertTrue(
                commandBack.contains { $0.contains(Self.mainScreenLine) }, "⌘[ did not return to the main screen")
        }
    }

    /// ⌘A, ⌘C, ⌘X, ⌘V, and ⌘Z act as the Ctrl combinations in the field (FR-IN-08, key mode). Each step is checked on the
    /// field's text: copy and paste append the copied text, cut empties the selection, and undo reverts the last paste.
    func testCommandShortcutsActOnTheField() async throws {
        let apk = try Self.fixture("APKRUN_FIXTURE_APK")
        try await AndroidInputRun.with(apk: apk, package: Self.helloText) { run in
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

    /// The APK that the environment variable `key` names. The test is skipped when the variable or the file is missing.
    private static func fixture(_ key: String) throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[key], FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("\(key) does not name a fixture APK. Copy the fixture of scripts/build-fixtures.sh to /tmp.")
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
