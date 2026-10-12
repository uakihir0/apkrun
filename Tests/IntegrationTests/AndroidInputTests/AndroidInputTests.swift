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
/// The Xcode test host does not run adb (IR-438), so this suite is compiled there and not run there. The device checks
/// are run by the coordinator's scripted runs, which post the same gestures with the CGEvent helper in /tmp (decision
/// D14). The suite runs only with APKRUN_INPUT_T2=1, which the AndroidInput configuration of IntegrationTests.xctestplan
/// sets. It also needs APKRUN_GUEST_DIR (the Guest Agent bundle), APKRUN_FIXTURE_APK (HelloText), and
/// APKRUN_FIXTURE_COMPOSE_APK (HelloCompose). A missing input skips its test and names the variable.
///
/// The entry's `adb shell` counter is not in the code, because AdbClient has no shell counter, and none is added here.
/// The sequence samples the process list for `adb ... shell input` commands instead, and must find none (FR-IN-06).
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
            let pointer = try run.pointer()
            // The list fills the display below the text field, so these points lie inside it.
            try await pointer.drag(from: (x: 512, y: 600), to: (x: 512, y: 250), steps: 20)
            let dragged = try await Self.lastRow(run, above: 0)
            XCTAssertGreaterThan(dragged, 0, "the drag did not scroll the list")
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
