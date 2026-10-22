import Foundation
import RuntimeCore
import XCTest

/// T2 negative capability test for an ordinary untrusted app (#36; guest-components.md §4.2, §10).
final class AgentSocketIsolationTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try AndroidCustomImageSession.requireAndroidCustomSuite()
    }

    /// HelloProbe cannot connect to the three live Guest Agent sockets or create an AF_VSOCK
    /// socket. The kernel log must show enforcing-mode denials for both socket classes.
    func testUntrustedHelloProbeCannotReachAgentSocketsOrCreateVsock() async throws {
        let apk = try AndroidCustomImageSession.helloProbeAPK()
        try await AndroidCustomImageSession.withBoot(developerMode: true) { session in
            let adb = try await AndroidCustomImageSession.connectedADB(session)
            try await adb.install(apk: apk)
            let start = try await adb.shell(
                "am start -W -n io.apkrun.fixture.helloprobe/.ProbeActivity"
            )
            XCTAssertEqual(start.status, 0, start.output)
            XCTAssertTrue(start.output.contains("Status: ok"), start.output)
            let optionalProbePID = try await adb.pidof("io.apkrun.fixture.helloprobe")
            XCTAssertNotNil(optionalProbePID, "HelloProbe must remain running while its denials are checked")
            guard let probePID = optionalProbePID else {
                return
            }

            let log = try await AndroidCustomImageSession.waitForProbeCompletion(using: adb)
            XCTAssertTrue(log.contains("probe context u:r:untrusted_app"), log)
            for socket in [
                "apkrun-guestd-control",
                "apkrun-guestd-input",
                "apkrun-guestd-bulk",
            ] {
                XCTAssertTrue(Self.hasPermissionDeniedResult(for: "socket:\(socket)", in: log), log)
            }
            XCTAssertTrue(Self.hasPermissionDeniedResult(for: "vsock", in: log), log)

            try await adb.restartAsRoot()
            let denials = try await adb.dmesg()
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter {
                    $0.contains("avc: denied")
                        && $0.contains("scontext=u:r:untrusted_app")
                        && ($0.contains("tclass=unix_stream_socket") || $0.contains("tclass=vsock_socket"))
                }
            let probeDenials = denials.filter { $0.contains("pid=\(probePID)") }
            XCTAssertTrue(
                probeDenials.contains {
                    $0.contains("tclass=unix_stream_socket") && $0.contains("permissive=0")
                },
                "the kernel did not record an enforcing Unix-socket denial from HelloProbe PID \(probePID): \(denials)"
            )
            XCTAssertTrue(
                probeDenials.contains {
                    $0.contains("tclass=vsock_socket") && $0.contains("permissive=0")
                },
                "the kernel did not record an enforcing AF_VSOCK denial from HelloProbe PID \(probePID): \(denials)"
            )
        }
    }

    private static func hasPermissionDeniedResult(for target: String, in log: String) -> Bool {
        log.split(whereSeparator: \.isNewline).contains { line in
            line.contains("probe \(target) denied errno=1") || line.contains("probe \(target) denied errno=13")
        }
    }
}
