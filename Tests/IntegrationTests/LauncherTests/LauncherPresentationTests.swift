import RuntimeAPI
import XCTest

final class LauncherPresentationTests: XCTestCase {
    func testRuntimeAndLauncherAPICompatibilityMatrix() {
        let cases: [(APIVersion, APIVersion, LauncherCompatibility)] = [
            (APIVersion(major: 1, minor: 13), APIVersion(major: 1, minor: 14), .compatible),
            (APIVersion(major: 1, minor: 15), APIVersion(major: 1, minor: 14), .runtimeAPITooOld),
            (APIVersion(major: 1, minor: 14), APIVersion(major: 2, minor: 0), .compatible),
            (APIVersion(major: 1, minor: 14), APIVersion(major: 3, minor: 0), .launcherTooOld),
            (APIVersion(major: 2, minor: 0), APIVersion(major: 1, minor: 14), .runtimeAPITooOld),
        ]

        for (launcherAPI, serverAPI, expected) in cases {
            XCTAssertEqual(
                LauncherCompatibility.evaluate(
                    runtimeVersion: "1.2.3",
                    serverAPI: serverAPI,
                    minimumRuntimeVersion: minimumRuntimeVersion,
                    launcherAPI: launcherAPI
                ),
                expected,
                "launcher API \(launcherAPI.major).\(launcherAPI.minor), server API \(serverAPI.major).\(serverAPI.minor)"
            )
        }
    }

    func testRuntimeMinimumVersionCompatibility() {
        XCTAssertEqual(
            LauncherCompatibility.evaluate(
                runtimeVersion: "1.2.3",
                serverAPI: APIVersion(major: 1, minor: 14),
                minimumRuntimeVersion: minimumRuntimeVersion,
                launcherAPI: APIVersion(major: 1, minor: 14)
            ),
            .compatible
        )
        XCTAssertEqual(
            LauncherCompatibility.evaluate(
                runtimeVersion: "1.2.2",
                serverAPI: APIVersion(major: 1, minor: 14),
                minimumRuntimeVersion: minimumRuntimeVersion,
                launcherAPI: APIVersion(major: 1, minor: 14)
            ),
            .runtimeTooOld
        )
    }

    func testEveryLauncherScreenHasItsSpecifiedPrimaryAction() {
        let cases: [(LauncherScreen, LauncherAction?)] = [
            (.starting(appName: "HelloText"), nil),
            (.required(appName: "HelloText"), .getAPKRun),
            (.setup(appName: "HelloText"), .openAPKRun),
            (.minimumRuntime(appName: "HelloText", version: "1.0.0"), .checkForUpdates),
            (.launcherTooOld(appName: "HelloText"), .updateMacApp),
            (.approvalPending(appName: "HelloText"), .openAPKRun),
            (.approvalDenied(appName: "HelloText"), .openAPKRun),
            (.notInstalled(appName: "HelloText"), .openAPKRun),
            (.damaged(appName: "HelloText"), .openAPKRun),
            (.translocated(appName: "HelloText"), nil),
            (.runtimeError(appName: "HelloText", message: "Runtime failed.", remediation: "Try again."), .tryAgain),
        ]

        for (screen, expectedAction) in cases {
            XCTAssertEqual(screen.presentation.primaryAction, expectedAction)
            XCTAssertFalse(screen.presentation.message.isEmpty)
            XCTAssertEqual(screen.appName, "HelloText")
        }
    }

    private var minimumRuntimeVersion: WrapperMinimumRuntimeVersion {
        // This valid schema value is shared by the table-driven compatibility cases.
        WrapperMinimumRuntimeVersion(rawValue: "1.2.3")!
    }
}
