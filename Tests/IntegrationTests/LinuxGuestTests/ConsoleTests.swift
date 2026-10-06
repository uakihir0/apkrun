import Foundation
import XCTest

@testable import VirtualMachineCore

final class LinuxGuestConsoleTests: XCTestCase {
    func testConsoleMarkersMatchLFAndCRLFLineEndings() {
        let marker = Data("APKRUN-PORT-READY-1\n".utf8)
        let lineFeed = Data("prefix APKRUN-PORT-READY-1\nsuffix".utf8)
        let carriageReturnLineFeed = Data("prefix APKRUN-PORT-READY-1\r\nsuffix".utf8)
        let firstChunk = Data("prefix APKRUN-PORT-READY-1\r".utf8)

        XCTAssertTrue(LinuxGuestHarness.consoleMarkerMatches(marker, in: lineFeed))
        XCTAssertTrue(
            LinuxGuestHarness.consoleMarkerMatches(marker, in: carriageReturnLineFeed)
        )
        var crossChunkBuffer = firstChunk
        XCTAssertFalse(LinuxGuestHarness.consoleMarkerMatches(marker, in: crossChunkBuffer))
        LinuxGuestHarness.retainConsoleMarkerSearchTail(
            &crossChunkBuffer,
            maximumMarkerLength: marker.count
        )
        crossChunkBuffer.append(0x0A)
        XCTAssertTrue(LinuxGuestHarness.consoleMarkerMatches(marker, in: crossChunkBuffer))
        XCTAssertFalse(
            LinuxGuestHarness.consoleMarkerMatches(
                marker,
                in: Data("prefix APKRUN-PORT-READY-2\r\n".utf8)
            )
        )
    }

    func testBootOutputIsLiveAndPersistedToCurrentAndPerBootLogs() async throws {
        let result = try await LinuxGuestHarness.run(
            testCase: self,
            stopBehavior: .guestPowerOff,
            powerOff: true
        )

        XCTAssertTrue(result.consoleOutput.range(of: Data("APKRUN-TEST: boot ok".utf8)) != nil)
        XCTAssertTrue(result.consoleLog.range(of: Data("APKRUN-TEST: boot ok".utf8)) != nil)
        XCTAssertTrue(result.bootLog.range(of: Data("APKRUN-TEST: boot ok".utf8)) != nil)
        XCTAssertEqual(result.consoleLog, result.bootLog)
    }

    func testServiceConsolePortsMatchLinuxHVCNumbering() async throws {
        let result = try await LinuxGuestHarness.run(
            testCase: self,
            stopBehavior: .guestPowerOff,
            powerOff: true,
            tests: ["ports"]
        )

        XCTAssertTrue(
            result.records.contains(
                .check(
                    name: "ports",
                    result: .ok,
                    detail: "hvc1=APKRUN-PORT-1 hvc2=APKRUN-PORT-2"
                )
            )
        )
        XCTAssertTrue(result.consoleLog.range(of: Data("APKRUN-TEST: ports ok".utf8)) != nil)
    }

    func testForcedStopDuringFloodLeavesCompletePersistedRecords() async throws {
        let result = try await LinuxGuestHarness.run(
            testCase: self,
            stopBehavior: .forcedAfterConsoleLine("APKRUN-FLOOD 100\n"),
            powerOff: false,
            tests: ["flood"],
            extraCommandLine: ["apkrun.test.flood=100000"]
        )

        let deliveredFloodRecords = floodRecords(in: result.consoleOutput)
        let persistedFloodRecords = floodRecords(in: result.consoleLog)

        XCTAssertFalse(deliveredFloodRecords.isEmpty)
        XCTAssertTrue(deliveredFloodRecords.contains("APKRUN-FLOOD 100"))
        XCTAssertEqual(persistedFloodRecords, deliveredFloodRecords)
        XCTAssertEqual(result.consoleOutputDroppedByteCount, 0)
        XCTAssertEqual(result.consoleLogDroppedByteCount, 0)
        XCTAssertEqual(result.consoleLog.last, 0x0A)
        XCTAssertEqual(result.bootLog, result.consoleLog)
        XCTAssertEqual(result.states.last, .stopped)
    }

    func testKernelPanicAndCallTraceArePersistedBeforeFailedOrStoppedState() async throws {
        let result = try await LinuxGuestHarness.run(
            testCase: self,
            stopBehavior: .observeGuestPanic,
            powerOff: false,
            tests: ["panic"],
            extraCommandLine: ["apkrun.test.panic=1"]
        )

        XCTAssertTrue(result.consoleLog.range(of: Data("Kernel panic".utf8)) != nil)
        XCTAssertTrue(result.consoleLog.range(of: Data("Call trace:".utf8)) != nil)
        XCTAssertTrue(
            result.states.contains { state in
                if case .failed = state {
                    return true
                }
                return state == .stopped
            })
        XCTAssertEqual(result.bootLog, result.consoleLog)
    }

    private func floodRecords(in data: Data) -> [String] {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                guard let range = line.range(of: "APKRUN-FLOOD ") else { return nil }
                return String(line[range.lowerBound...])
            }
    }
}
