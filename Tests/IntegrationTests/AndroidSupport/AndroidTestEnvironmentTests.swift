import XCTest

final class AndroidTestEnvironmentTests: XCTestCase {
    func testMissingADBIsFailureInCI() {
        XCTAssertThrowsError(
            try AndroidTestEnvironment.adbExecutable(
                environment: [
                    "APKRUN_CI": "1",
                    "PATH": "/apkrun-test-no-adb",
                ]
            )
        ) { error in
            guard case AndroidTestEnvironment.Failure.adbUnavailable = error else {
                XCTFail("Missing adb in CI should fail, but received \(error)")
                return
            }
        }
    }
}
