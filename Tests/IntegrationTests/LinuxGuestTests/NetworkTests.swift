import DiagnosticsCore
import Foundation
import XCTest

@testable import VirtualMachineCore

final class LinuxGuestNetworkTests: XCTestCase {
    func testServerRejectsHeadersOverTheConfiguredLimit() {
        let requestLine = "GET /generate_204 HTTP/1.1\r\nX-Padding: "
        let terminatorLength = "\r\n\r\n".utf8.count
        let allowedValueLength =
            LinuxGuestHTTPServer.maximumHeaderLength
            - requestLine.utf8.count
            - terminatorLength
        let allowedRequest = Data(
            (requestLine + String(repeating: "a", count: allowedValueLength) + "\r\n\r\n")
                .utf8
        )
        XCTAssertEqual(LinuxGuestHTTPServer.completedRequestStatus(allowedRequest), 204)

        let oversizedRequest = Data(
            (requestLine + String(repeating: "a", count: allowedValueLength + 1) + "\r\n\r\n")
                .utf8
        )
        XCTAssertEqual(LinuxGuestHTTPServer.completedRequestStatus(oversizedRequest), 431)
    }

    func testNetworkFailureRecordIsNotMaskedByGuestDone() async throws {
        do {
            _ = try await LinuxGuestHarness.run(
                testCase: self,
                stopBehavior: .guestPowerOff,
                powerOff: true,
                tests: ["net"]
            )
            XCTFail("A failed guest check must fail the harness even when the guest prints done.")
        } catch let failure as LinuxGuestHarness.HarnessFailure {
            guard
                case .guestCheckFailed(
                    name: "net",
                    detail: "http apkrun.test.net.port must be a decimal port"
                ) = failure
            else {
                throw failure
            }
        }
    }

    func testGuestGetsNATLeaseAndReachesHostHTTPServer() async throws {
        let server = try LinuxGuestHTTPServer()
        let port = try await server.start()
        defer { server.stop() }

        let logSink = LinuxGuestRecordingLogSink()
        let result = try await LinuxGuestHarness.run(
            testCase: self,
            stopBehavior: .guestPowerOff,
            powerOff: true,
            tests: ["net"],
            extraCommandLine: ["apkrun.test.net.port=\(port)"],
            logSink: logSink
        )

        XCTAssertEqual(result.records.first, .bootOK)
        XCTAssertEqual(result.records.last, .done)
        guard
            case .check(name: "net", result: .ok, let detail) =
                result.records.first(where: {
                    if case .check(name: "net", result: .ok, detail: _) = $0 {
                        return true
                    }
                    return false
                })
        else {
            XCTFail("The guest did not report a successful network check.")
            return
        }
        guard
            let lease = Self.keyValues(in: detail),
            let ip = lease["ip"],
            let gateway = lease["gw"],
            let dns = lease["dns"]
        else {
            XCTFail("The guest did not report all DHCP lease fields.")
            return
        }
        XCTAssertEqual(lease["http"], "204")

        XCTAssertFalse(result.networkHealthStates.isEmpty)
        XCTAssertTrue(result.networkHealthStates.allSatisfy { $0 == .available })
        XCTAssertEqual(result.networkHealthResult?.state, .pass)

        let entries = logSink.snapshot()
        let configurationEntries = entries.filter {
            $0.subsystem == .vm
                && $0.category == VMLogCategory.config.rawValue
                && $0.publicMessage.hasPrefix("Configured VM NAT network with MAC ")
        }
        XCTAssertEqual(configurationEntries.count, 1)
        if let configurationEntry = configurationEntries.first {
            let macAddress = String(
                configurationEntry.publicMessage.dropFirst(
                    "Configured VM NAT network with MAC ".count
                )
            )
            let octets = macAddress.split(separator: ":")
            XCTAssertEqual(octets.count, 6)
            XCTAssertTrue(
                octets.allSatisfy { $0.count == 2 && UInt8($0, radix: 16) != nil }
            )
        }

        XCTAssertTrue(
            entries.contains {
                $0.subsystem == .vm
                    && $0.category == VMLogCategory.network.rawValue
                    && $0.publicMessage
                        == "lease interface=eth0 ip=\(ip) gw=\(gateway) dns=\(dns)"
            },
            "the VM network log should exactly match the lease reported by the guest"
        )
    }

    private static func keyValues(in detail: String) -> [String: String]? {
        var fields: [String: String] = [:]
        for token in detail.split(whereSeparator: \.isWhitespace) {
            let pair = token.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, fields[pair[0]] == nil else {
                return nil
            }
            fields[pair[0]] = pair[1]
        }
        return fields
    }
}

private final class LinuxGuestRecordingLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [LogEntry] = []

    func write(_ entry: LogEntry) {
        lock.withLock {
            entries.append(entry)
        }
    }

    func snapshot() -> [LogEntry] {
        lock.withLock { entries }
    }
}
