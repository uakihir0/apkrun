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

    func testAndroidCustomRequiresCompositionAndTestOverlayProvenance() {
        let composePath = "Tests/Fixtures/AndroidImageProduct/compose.json"
        let initPath = "Tests/Fixtures/AndroidImageProduct/init/apkrun-test.rc"
        let composeHash = String(repeating: "a", count: 64)
        let initHash = String(repeating: "b", count: 64)
        let expectedHashes = [composePath: composeHash, initPath: initHash]
        let validInputs: [[String: Any]] = [
            ["path": composePath, "sha256": composeHash],
            ["path": initPath, "sha256": initHash],
        ]
        let validManifest: [String: Any] = [
            "kind": "apkrun",
            "provenance": [
                "composition": [
                    "schemaVersion": 1,
                    "testOverlayInputs": validInputs,
                ]
            ],
        ]

        XCTAssertTrue(
            AndroidTestBundleLocator.isComposedTestManifest(
                validManifest,
                testOverlayHashes: expectedHashes
            )
        )
        XCTAssertFalse(
            AndroidTestBundleLocator.isComposedTestManifest(
                ["kind": "apkrun", "provenance": ["composition": ["schemaVersion": 1]]],
                testOverlayHashes: expectedHashes
            )
        )
        var stockManifest = validManifest
        stockManifest["kind"] = "stock"
        XCTAssertFalse(
            AndroidTestBundleLocator.isComposedTestManifest(
                stockManifest,
                testOverlayHashes: expectedHashes
            )
        )
        var missingHookManifest = validManifest
        missingHookManifest["provenance"] = [
            "composition": ["schemaVersion": 1, "testOverlayInputs": [validInputs[0]]]
        ]
        XCTAssertFalse(
            AndroidTestBundleLocator.isComposedTestManifest(
                missingHookManifest,
                testOverlayHashes: expectedHashes
            )
        )
        var staleHookManifest = validManifest
        staleHookManifest["provenance"] = [
            "composition": [
                "schemaVersion": 1,
                "testOverlayInputs": [
                    validInputs[0],
                    ["path": initPath, "sha256": String(repeating: "c", count: 64)],
                ],
            ]
        ]
        XCTAssertFalse(
            AndroidTestBundleLocator.isComposedTestManifest(
                staleHookManifest,
                testOverlayHashes: expectedHashes
            )
        )
        var unexpectedInputManifest = validManifest
        unexpectedInputManifest["provenance"] = [
            "composition": [
                "schemaVersion": 1,
                "testOverlayInputs": [
                    validInputs[0],
                    ["path": "Guest/product/init/apkrun.rc", "sha256": initHash],
                ],
            ]
        ]
        XCTAssertFalse(
            AndroidTestBundleLocator.isComposedTestManifest(
                unexpectedInputManifest,
                testOverlayHashes: expectedHashes
            )
        )
    }
}
