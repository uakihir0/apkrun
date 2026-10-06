import Foundation
import XCTest

@testable import VirtualMachineCore

final class LinuxGuestNetworkAcceptanceTests: XCTestCase {
    func testExternalClassificationIsLimitedToDNSAndRecognizedNetworkFailures() {
        XCTAssertEqual(
            Self.externalFailureDetail(
                .guestCheckFailed(name: "net", detail: "dns lookup failed")
            ),
            "dns lookup failed"
        )
        XCTAssertEqual(
            Self.externalFailureDetail(
                .guestCheckFailed(name: "net", detail: "ext socket connection unavailable")
            ),
            "ext socket connection unavailable"
        )
        XCTAssertEqual(
            Self.externalFailureDetail(
                .guestCheckFailed(name: "net", detail: "ext download timed out")
            ),
            "ext download timed out"
        )
        XCTAssertNil(
            Self.externalFailureDetail(
                .guestCheckFailed(
                    name: "net",
                    detail: "ext client failed without HTTP response (exit=127)"
                )
            )
        )
        XCTAssertNil(
            Self.externalFailureDetail(
                .guestCheckFailed(name: "net", detail: "ext TLS handshake failed")
            )
        )
        XCTAssertNil(
            Self.externalFailureDetail(
                .guestCheckFailed(name: "net", detail: "ext HTTP status=503 expected 204")
            )
        )
        XCTAssertNil(
            Self.externalFailureDetail(
                .guestCheckFailed(name: "net", detail: "ext HTTP response did not include a status line")
            )
        )
        XCTAssertNil(
            Self.externalFailureDetail(
                .guestCheckFailed(
                    name: "net",
                    detail: "ext client exited 1 after HTTP 204"
                )
            )
        )
        XCTAssertNil(Self.externalFailureDetail(.cleanupFailed))
    }

    func testExternalSkipRequiresTheSameFailureOnBothAttempts() {
        XCTAssertEqual(
            Self.repeatedExternalFailure(
                first: .guestCheckFailed(name: "net", detail: "dns lookup failed"),
                retry: .guestCheckFailed(name: "net", detail: "dns lookup failed")
            ),
            "dns lookup failed"
        )
        XCTAssertEqual(
            Self.repeatedExternalFailure(
                first: .guestCheckFailed(name: "net", detail: "ext socket connection unavailable"),
                retry: .guestCheckFailed(name: "net", detail: "ext socket connection unavailable")
            ),
            "ext socket connection unavailable"
        )
        XCTAssertEqual(
            Self.repeatedExternalFailure(
                first: .guestCheckFailed(name: "net", detail: "ext download timed out"),
                retry: .guestCheckFailed(name: "net", detail: "ext download timed out")
            ),
            "ext download timed out"
        )
        XCTAssertNil(
            Self.repeatedExternalFailure(
                first: .guestCheckFailed(name: "net", detail: "dns lookup failed"),
                retry: .guestCheckFailed(
                    name: "net",
                    detail: "ext socket connection unavailable"
                )
            )
        )
        XCTAssertNil(
            Self.repeatedExternalFailure(
                first: .guestCheckFailed(
                    name: "net",
                    detail: "ext socket connection unavailable"
                ),
                retry: .guestCheckFailed(name: "net", detail: "ext download timed out")
            )
        )
        XCTAssertNil(
            Self.repeatedExternalFailure(
                first: .guestCheckFailed(name: "net", detail: "dns lookup failed"),
                retry: .guestCheckFailed(name: "net", detail: "ext TLS handshake failed")
            )
        )
    }

    func testGuestResolvesDNSAndReachesExternalHTTPSProbe() async throws {
        guard ProcessInfo.processInfo.environment["APKRUN_ACCEPTANCE_SUITE"] == "network" else {
            throw XCTSkip("This acceptance check runs in the Network test-plan configuration.")
        }

        let server = try LinuxGuestHTTPServer()
        let port = try await server.start()
        defer { server.stop() }

        let result: LinuxGuestHarness.RunResult
        do {
            result = try await runExternalProbe(on: port)
        } catch let failure as LinuxGuestHarness.HarnessFailure {
            guard Self.externalFailureDetail(failure) != nil else {
                throw failure
            }
            do {
                result = try await runExternalProbe(on: port)
            } catch let retryFailure as LinuxGuestHarness.HarnessFailure {
                guard
                    let repeatedFailure = Self.repeatedExternalFailure(
                        first: failure,
                        retry: retryFailure
                    )
                else {
                    throw retryFailure
                }
                throw XCTSkip("external: \(repeatedFailure) repeated on retry")
            }
        }

        guard
            case .check(name: "net", result: .ok, let detail) =
                result.records.first(where: {
                    if case .check(name: "net", result: .ok, detail: _) = $0 {
                        return true
                    }
                    return false
                })
        else {
            XCTFail("The guest did not report a successful external network check.")
            return
        }
        XCTAssertTrue(detail.contains("http=204"))
        XCTAssertTrue(detail.contains("ext=204"))
        XCTAssertEqual(result.networkHealthResult?.state, .pass)
    }

    private func runExternalProbe(on port: UInt16) async throws -> LinuxGuestHarness.RunResult {
        try await LinuxGuestHarness.run(
            testCase: self,
            stopBehavior: .guestPowerOff,
            powerOff: true,
            tests: ["net"],
            extraCommandLine: [
                "apkrun.test.net.port=\(port)",
                "apkrun.test.net.external=1",
            ]
        )
    }

    private static func externalFailureDetail(
        _ failure: LinuxGuestHarness.HarnessFailure
    ) -> String? {
        guard case .guestCheckFailed(name: "net", detail: let detail) = failure,
            detail.hasPrefix("dns ")
                || detail == "ext socket connection unavailable"
                || detail == "ext download timed out"
        else {
            return nil
        }
        return detail
    }

    private static func repeatedExternalFailure(
        first: LinuxGuestHarness.HarnessFailure,
        retry: LinuxGuestHarness.HarnessFailure
    ) -> String? {
        guard
            let firstDetail = externalFailureDetail(first),
            let retryDetail = externalFailureDetail(retry),
            firstDetail == retryDetail
        else {
            return nil
        }
        return retryDetail
    }
}
