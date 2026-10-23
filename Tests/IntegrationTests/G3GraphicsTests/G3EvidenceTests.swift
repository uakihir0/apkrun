import XCTest

/// The pure checks of gate G3 (G3Evidence). They run without a VM, and they pin the parsing of the evidence.
final class G3EvidenceTests: XCTestCase {
    func testAStatisticsLineWithoutTearingCountersParses() {
        let line = G3StatisticsLine(
            line: "APKRun display 0  60 fps  dropped 0  stalls 0  hostReadbacks 0  cpuPixelCopies 0")
        XCTAssertEqual(
            line,
            G3StatisticsLine(
                framesPerSecond: 60, hostReadbacks: 0, cpuPixelCopies: 0,
                framesSampled: nil, redFrames: nil, blueFrames: nil, mixedFrames: nil))
    }

    func testAStatisticsLineWithTearingCountersParses() {
        let line = G3StatisticsLine(
            line: "APKRun display 0  59 fps  dropped 2  stalls 1  hostReadbacks 0  cpuPixelCopies 0  "
                + "framesSampled 3600  redFrames 1800  blueFrames 1790  mixedFrames 0  unreadable 0")
        XCTAssertEqual(line?.framesPerSecond, 59)
        XCTAssertEqual(line?.hostReadbacks, 0)
        XCTAssertEqual(line?.cpuPixelCopies, 0)
        XCTAssertEqual(line?.framesSampled, 3600)
        XCTAssertEqual(line?.redFrames, 1800)
        XCTAssertEqual(line?.blueFrames, 1790)
        XCTAssertEqual(line?.mixedFrames, 0)
    }

    func testAStatisticsLineWithANonzeroReadbackParsesWithTheValue() {
        let line = G3StatisticsLine(
            line: "APKRun display 0  60 fps  dropped 0  stalls 0  hostReadbacks 3  cpuPixelCopies 0")
        XCTAssertEqual(line?.hostReadbacks, 3)
    }

    func testOtherLinesAreNotStatisticsLines() {
        XCTAssertNil(G3StatisticsLine(line: "state: ready"))
        XCTAssertNil(G3StatisticsLine(line: "APKRun display 0  fps but no numbers"))
        XCTAssertNil(G3StatisticsLine(line: "APKRun display 0  60 fps  dropped 0"))
    }

    func testTheFpsEventsAreReadFromHelloGLsLines() {
        let logcat = """
            10-12 01:48:04.000  7851  7860 I HelloGL : APKRUN-FIXTURE: renderer virgl
            10-12 01:48:14.000  7851  7860 I HelloGL : APKRUN-FIXTURE: fps 59.6
            10-12 01:48:24.000  7851  7860 I HelloGL : APKRUN-FIXTURE: fps 60.3
            """
        XCTAssertEqual(G3Evidence.fpsEvents(in: logcat), [59.6, 60.3])
    }

    func testTheRendererEventIsTheLineAfterThePrefix() {
        let logcat = "10-12 01:46:16.353  6072  6090 I HelloGL : APKRUN-FIXTURE: renderer virgl\n"
        XCTAssertEqual(G3Evidence.rendererEvent(in: logcat), "APKRUN-FIXTURE: renderer virgl")
        XCTAssertNil(G3Evidence.rendererEvent(in: "nothing here\n"))
    }

    func testARendererCrashNamesHelloGLOrSurfaceFlinger() {
        XCTAssertTrue(
            G3Evidence.isRendererCrash(
                "E AndroidRuntime: FATAL EXCEPTION main Process: io.apkrun.fixture.hellogl, PID: 1"))
        XCTAssertTrue(
            G3Evidence.isRendererCrash(
                "F libc    : Fatal signal 11 (SIGSEGV), code 1, in tid 9 (RenderThread), pid 812 (surfaceflinger)"))
        XCTAssertTrue(
            G3Evidence.isRendererCrash(
                "I ActivityManager: Process io.apkrun.fixture.hellogl (pid 7851) has died"))
    }

    func testACrashOfAnotherProcessIsNotARendererCrash() {
        let launcher =
            "F libc    : Fatal signal 6 (SIGABRT) in tid 2969 (RenderThread), pid 2951 (ndroid.settings)"
        XCTAssertFalse(G3Evidence.isRendererCrash(launcher))
        XCTAssertTrue(G3Evidence.isAnyCrash(launcher))
        XCTAssertFalse(G3Evidence.isRendererCrash("I HelloGL : APKRUN-FIXTURE: fps 60.0"))
    }

    /// A run that meets every condition.
    private func passingMeasurements() -> G3Measurements {
        var measurements = G3Measurements()
        measurements.rendererEvent = "APKRUN-FIXTURE: renderer virgl"
        measurements.surfaceFlingerGLES = "GLES: Mesa, virgl, OpenGL ES 3.0 Mesa 26.1.8"
        measurements.helloGLSELinuxDomain = "u:r:untrusted_app:s0:c123,c456"
        measurements.selinuxMode = "Enforcing"
        measurements.windowFound = true
        measurements.distinctColoursInWindow = 200
        measurements.statisticsDuringRun = Array(
            repeating: G3StatisticsLine(
                framesPerSecond: 60, hostReadbacks: 0, cpuPixelCopies: 0,
                framesSampled: nil, redFrames: nil, blueFrames: nil, mixedFrames: nil), count: 700)
        measurements.statisticsFirstSixtySeconds = Array(measurements.statisticsDuringRun.prefix(60))
        measurements.fpsEvents = Array(repeating: 59.9, count: 60)
        measurements.pidAtStart = "7851"
        measurements.pidAtMinute = Array(repeating: "7851", count: 10)
        measurements.alternatingRedFrames = 300
        measurements.alternatingBlueFrames = 300
        measurements.alternatingSampledFrames = 600
        measurements.alternatingMixedFrames = 0
        measurements.bootStop = .endedAfterInterrupt
        return measurements
    }

    func testAPassingRunHasNoFailures() {
        XCTAssertEqual(G3Evidence.failures(passingMeasurements()), [])
    }

    func testAReadbackFailsCondition3() {
        var measurements = passingMeasurements()
        measurements.statisticsDuringRun[5] = G3StatisticsLine(
            framesPerSecond: 60, hostReadbacks: 1, cpuPixelCopies: 0,
            framesSampled: nil, redFrames: nil, blueFrames: nil, mixedFrames: nil)
        XCTAssertEqual(G3Evidence.failures(measurements).count, 1)
        XCTAssertTrue(G3Evidence.failures(measurements)[0].hasPrefix("3 "))
    }

    func testHelloGLMustRunInTheUntrustedAppDomain() {
        var measurements = passingMeasurements()
        measurements.helloGLSELinuxDomain = "u:r:system_app:s0"
        XCTAssertTrue(
            G3Evidence.failures(measurements).contains {
                $0.contains("HelloGL does not run in the untrusted_app SELinux domain")
            })
    }

    func testSelinuxMustBeEnforcing() {
        var measurements = passingMeasurements()
        measurements.selinuxMode = "Permissive"
        XCTAssertTrue(
            G3Evidence.failures(measurements).contains {
                $0 == "2 SELinux is not enforcing (Permissive)"
            })
    }

    func testAnAverageBelowFiftyFiveFailsCondition4() {
        var measurements = passingMeasurements()
        measurements.fpsEvents = Array(repeating: 54.0, count: 60)
        XCTAssertTrue(G3Evidence.failures(measurements).contains { $0.hasPrefix("4 HelloGL averages") })
    }

    func testAMixedFrameFailsTheTearingCondition() {
        var measurements = passingMeasurements()
        measurements.alternatingMixedFrames = 1
        XCTAssertTrue(G3Evidence.failures(measurements).contains { $0.contains("tearing") })
    }

    func testAnAlternationWithoutBothColoursFails() {
        var measurements = passingMeasurements()
        measurements.alternatingBlueFrames = 0
        XCTAssertTrue(G3Evidence.failures(measurements).contains { $0.contains("alternation was not observed") })
    }

    func testAChangedPidFailsCondition5() {
        var measurements = passingMeasurements()
        measurements.pidAtMinute[6] = "7999"
        XCTAssertTrue(G3Evidence.failures(measurements).contains { $0.hasPrefix("5 the HelloGL pid changed") })
    }

    func testARendererCrashFailsCondition5() {
        var measurements = passingMeasurements()
        measurements.rendererCrashLines = ["F libc : Fatal signal 11 (surfaceflinger)"]
        XCTAssertTrue(G3Evidence.failures(measurements).contains { $0.hasPrefix("5 1 renderer crash") })
    }

    func testANonVirglRendererFailsCondition2() {
        var measurements = passingMeasurements()
        measurements.surfaceFlingerGLES = "GLES: Google, Swiftshader"
        measurements.rendererEvent = "APKRUN-FIXTURE: renderer Google SwiftShader"
        XCTAssertEqual(G3Evidence.failures(measurements).filter { $0.hasPrefix("2 ") }.count, 2)
    }

    func testABlankWindowFailsCondition1() {
        var measurements = passingMeasurements()
        measurements.distinctColoursInWindow = 1
        XCTAssertTrue(G3Evidence.failures(measurements).contains { $0.hasPrefix("1 ") })
    }

    func testAnAdbErrorTextIsNotAProcessID() {
        var measurements = passingMeasurements()
        let error = "error: device offline"
        measurements.pidAtStart = error
        measurements.pidAtMinute = Array(repeating: error, count: 10)
        XCTAssertFalse(G3Evidence.isProcessID(error))
        XCTAssertTrue(G3Evidence.failures(measurements).contains { $0.hasPrefix("5 the HelloGL pid") })
    }

    func testAMissingPidFailsCondition5() {
        var measurements = passingMeasurements()
        measurements.pidAtMinute[3] = nil
        XCTAssertTrue(G3Evidence.failures(measurements).contains { $0.hasPrefix("5 the HelloGL pid") })
    }

    func testAnUnreadableTearingBufferFails() {
        var measurements = passingMeasurements()
        measurements.unreadableFrames = 2
        XCTAssertTrue(G3Evidence.failures(measurements).contains { $0.contains("could not read 2 buffers") })
    }

    func testABootThatWasKilledFailsTheStopRule() {
        var measurements = passingMeasurements()
        measurements.bootStop = .killedAfterInterrupt
        XCTAssertTrue(G3Evidence.failures(measurements).contains { $0.contains("did not end within 60 s of SIGINT") })
        measurements.bootStop = .endedBeforeStop
        XCTAssertFalse(G3Evidence.failures(measurements).isEmpty)
    }

    func testTheUnreadableCountIsParsedFromTheStatisticsLine() {
        let line = G3StatisticsLine(
            line: "APKRun display 0  60 fps  dropped 0  stalls 0  hostReadbacks 0  cpuPixelCopies 0  "
                + "framesSampled 9  redFrames 4  blueFrames 4  mixedFrames 0  otherFrames 1  unreadable 3")
        XCTAssertEqual(line?.unreadable, 3)
        XCTAssertEqual(line?.mixedFrames, 0)
    }
}
