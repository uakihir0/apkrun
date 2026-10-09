import Foundation
import Testing

@testable import RuntimeCore

/// The readers of the launch replies (#017 T0). The replies are recorded from the Android 17 guest on 2026-10-09:
/// `am start -W`, `pidof`, and the resumed-activity section of `dumpsys activity activities`.
@Test
func startReplyOfAColdStartCarriesStatusOk() {
    let reply = """
        Starting: Intent { cmp=io.apkrun.fixture.hellotext/.MainActivity }
        Status: ok
        LaunchState: COLD
        Activity: io.apkrun.fixture.hellotext/.MainActivity
        TotalTime: 234
        WaitTime: 235
        Complete

        """
    #expect(reply.contains("Status: ok"))
}

@Test
func pidofReadsTheProcessIdentifier() {
    #expect(AdbOutputParser.processIdentifier("3456\n") == 3456)
    #expect(AdbOutputParser.processIdentifier("") == nil)
    #expect(AdbOutputParser.processIdentifier("not a pid\n") == nil)
}

@Test
func resumedComponentOfTheForegroundActivityIsItsPackageAndClass() {
    #expect(
        AdbOutputParser.resumedComponent(recordedForeground) == "io.apkrun.fixture.hellotext/.MainActivity"
    )
}

@Test
func resumedComponentAfterForceStopIsTheLauncher() {
    #expect(
        AdbOutputParser.resumedComponent(recordedAfterForceStop)
            == "com.android.launcher3/.uioverrides.QuickstepLauncher")
}

@Test
func resumedComponentOfTheOlderFormatIsReadToo() {
    // The `topResumedActivity=` form, recorded from the same guest before this change.
    let older = "    topResumedActivity=ActivityRecord{238233548 u0 io.apkrun.fixture.hellotext/.MainActivity t9}\n"
    #expect(AdbOutputParser.resumedComponent(older) == "io.apkrun.fixture.hellotext/.MainActivity")
}

@Test
func aDumpWithoutAResumedActivityHasNoComponent() {
    #expect(AdbOutputParser.resumedComponent("Activity stack:\n  (nothing resumed)\n") == nil)
}

/// Lines 127 to 133 of `dumpsys activity activities` while HelloText is in front.
private let recordedForeground = """

      Resumed activities in task display areas (from top to bottom):
        Resumed: ActivityRecord{247806208 u0 io.apkrun.fixture.hellotext/.MainActivity t12}

      ResumedActivity: ActivityRecord{247806208 u0 io.apkrun.fixture.hellotext/.MainActivity t12}

    ActivityTaskSupervisor state:
    """

/// The same section after `am force-stop`, when the launcher is resumed.
private let recordedAfterForceStop = """
      Resumed activities in task display areas (from top to bottom):
        Resumed: ActivityRecord{244065368 u0 com.android.launcher3/.uioverrides.QuickstepLauncher t11}

      ResumedActivity: ActivityRecord{244065368 u0 com.android.launcher3/.uioverrides.QuickstepLauncher t11}

    """
