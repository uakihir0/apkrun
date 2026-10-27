import DiagnosticsCore
import Foundation
import RuntimeAPI
import XCTest

final class LauncherProcessTimingTests: XCTestCase {
    func testRecoveryRequestPreservesSessionFieldsAndClearsLaunchTiming() throws {
        let packageID = try XCTUnwrap(RuntimePackageID(rawValue: "io.apkrun.example"))
        let header = APIRequestHeader(clientKind: .wrapper)
        let geometry = DisplayGeometry(
            pointSize: DisplayPointSize(width: 480, height: 850),
            backingScale: 2,
            zoom: 1
        )
        let screenSize = DisplayPointSize(width: 1_440, height: 900)
        let launchTiming = LaunchTiming(processStart: 123, requestSent: 456)
        let request = OpenSessionRequest(
            header: header,
            packageID: packageID,
            geometry: geometry,
            screenSize: screenSize,
            launchTiming: launchTiming
        )

        let recoveryRequest = LauncherProcessTiming.recoveryRequest(from: request)

        XCTAssertEqual(recoveryRequest.header, request.header)
        XCTAssertEqual(recoveryRequest.packageID, request.packageID)
        XCTAssertEqual(recoveryRequest.geometry, request.geometry)
        XCTAssertEqual(recoveryRequest.screenSize, request.screenSize)
        XCTAssertNil(recoveryRequest.launchTiming)
        XCTAssertEqual(request.launchTiming, launchTiming)
    }

    func testLauncherProcessTimingMapsKernelStartToContinuousNanoseconds() {
        let processStartUnixNanoseconds: UInt64 = 1_000_000_000_000
        let wallNowUnixNanoseconds: UInt64 = 1_005_000_000_000
        let continuousNowNanoseconds: UInt64 = 10_000_000_000

        XCTAssertEqual(
            LauncherProcessTiming.continuousStartNanoseconds(
                processStartUnixNanoseconds: processStartUnixNanoseconds,
                wallNowUnixNanoseconds: wallNowUnixNanoseconds,
                continuousNowNanoseconds: continuousNowNanoseconds
            ),
            5_000_000_000
        )
        XCTAssertNil(
            LauncherProcessTiming.continuousStartNanoseconds(
                processStartUnixNanoseconds: wallNowUnixNanoseconds + 1,
                wallNowUnixNanoseconds: wallNowUnixNanoseconds,
                continuousNowNanoseconds: continuousNowNanoseconds
            )
        )
    }

    func testLauncherReadsKernelProcessStartAsAContinuousTimestamp() throws {
        let processStart = try XCTUnwrap(LauncherProcessTiming.processStartContinuousNanoseconds())
        let now = try XCTUnwrap(ContinuousClockTimestamp.nowNanoseconds())

        XCTAssertLessThanOrEqual(processStart, now)
    }
}
