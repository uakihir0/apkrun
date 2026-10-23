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

    func testAndroidCustomRequiresCompositionProvenance() {
        XCTAssertTrue(
            AndroidTestBundleLocator.isComposedManifest([
                "kind": "apkrun",
                "provenance": ["composition": ["schemaVersion": 1]],
            ])
        )
        XCTAssertFalse(
            AndroidTestBundleLocator.isComposedManifest([
                "kind": "apkrun",
                "provenance": [:],
            ])
        )
        XCTAssertFalse(
            AndroidTestBundleLocator.isComposedManifest([
                "kind": "stock",
                "provenance": ["composition": ["schemaVersion": 1]],
            ])
        )
    }
}
