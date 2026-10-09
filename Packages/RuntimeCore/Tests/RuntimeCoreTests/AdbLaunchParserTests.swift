import Foundation
import Testing

@testable import RuntimeCore

/// The readers of the launch replies (#017 T0). The replies in Fixtures/adb are verbatim copies of replies
/// that the Android 17 guest printed on 2026-10-09: `am start -W`, the resumed-activity section of
/// `dumpsys activity activities` before and after `am force-stop`, and `dumpsys package`.
@Test
func amStartReplyOfAColdStartIsOk() throws {
    #expect(AdbOutputParser.startReplyIsOk(try fixture("am-start-cold.txt")))
}

@Test
func amStartErrorTextIsNotOk() {
    // A class that does not exist: am prints this and must not be read as a started activity.
    let error =
        "Error type 3\nError: Activity class {io.apkrun.fixture.hellotext/io.apkrun.fixture.hellotext.Missing} does not exist.\n"
    #expect(!AdbOutputParser.startReplyIsOk(error))
}

@Test
func pidReadsTheFirstProcessIdentifierOfThePidofReply() {
    #expect(AdbOutputParser.processIdentifier("3456\n") == 3456)
    #expect(AdbOutputParser.processIdentifier("3456 3457\n") == 3456)
}

@Test
func pidRefusesWhatIsNotAPositiveNumber() {
    #expect(AdbOutputParser.processIdentifier("") == nil)
    #expect(AdbOutputParser.processIdentifier("-1\n") == nil)
    #expect(AdbOutputParser.processIdentifier("+3\n") == nil)
    #expect(AdbOutputParser.processIdentifier("0\n") == nil)
    #expect(AdbOutputParser.processIdentifier("error: closed\n") == nil)
}

@Test
func resumedComponentOfTheForegroundActivityIsItsPackageAndClass() throws {
    #expect(
        AdbOutputParser.resumedComponent(try fixture("activities-foreground.txt"))
            == "io.apkrun.fixture.hellotext/.MainActivity"
    )
}

@Test
func resumedComponentAfterForceStopIsTheLauncher() throws {
    #expect(
        AdbOutputParser.resumedComponent(try fixture("activities-after-force-stop.txt"))
            == "com.android.launcher3/.uioverrides.QuickstepLauncher"
    )
}

@Test
func topResumedActivityOutranksAnotherResumedLine() {
    // The older builds name the top activity with topResumedActivity=. A different Resumed line must lose.
    let dump = """
        Resumed: ActivityRecord{1 u0 com.android.launcher3/.Launcher t2}
        topResumedActivity=ActivityRecord{3 u0 io.apkrun.fixture.hellotext/.MainActivity t9}
        """
    #expect(AdbOutputParser.resumedComponent(dump) == "io.apkrun.fixture.hellotext/.MainActivity")
}

@Test
func resumedComponentOfTheOlderFormatIsReadToo() {
    let older = "    topResumedActivity=ActivityRecord{238233548 u0 io.apkrun.fixture.hellotext/.MainActivity t9}\n"
    #expect(AdbOutputParser.resumedComponent(older) == "io.apkrun.fixture.hellotext/.MainActivity")
}

@Test
func aDumpWithoutAResumedRecordHasNoComponentAndNoMarker() {
    let dump = "Activity stack:\n  (nothing resumed)\n"
    #expect(AdbOutputParser.resumedComponent(dump) == nil)
    #expect(!AdbOutputParser.hasResumedMarker(dump))
}

@Test
func aRecordWithoutAClosingBraceIsSkipped() {
    #expect(
        AdbOutputParser.resumedComponent("  Resumed: ActivityRecord{1 u0 io.apkrun.fixture.hellotext/.MainActivity t2")
            == nil)
}

/// Reads a recorded reply from Fixtures/adb, next to this file.
private func fixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/adb/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}
