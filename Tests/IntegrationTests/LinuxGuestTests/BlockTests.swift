import Foundation
import XCTest

@testable import VirtualMachineCore

final class LinuxGuestBlockTests: XCTestCase {
    private let token = String(repeating: "deadbeef", count: 8)

    func testReadOnlyDiskAndReadWriteDiskPersistAcrossNewVM() async throws {
        let fixture = try makeBlockDiskFixture(for: self)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let format = try await runBlockPhase("format", fixture: fixture)
        assertBlockPhase("format", in: format)
        XCTAssertTrue(format.consoleOutput.contains("APKRUN-TEST: blk ok format"))

        let verify = try await runBlockPhase("verify", fixture: fixture)
        assertBlockPhase("verify", in: verify)
    }

    func testForcedStopDuringWritesCanRecoverTheExt4Disk() async throws {
        let fixture = try makeBlockDiskFixture(for: self)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let format = try await runBlockPhase("format", fixture: fixture)
        assertBlockPhase("format", in: format)

        let stress = try await LinuxGuestHarness.run(
            testCase: self,
            stopBehavior: .forcedAfterConsoleLineDelay(
                "APKRUN-BLK-STRESS-READY",
                .seconds(3)
            ),
            powerOff: false,
            tests: ["blk"],
            blockDisks: fixture.disks,
            extraCommandLine: blkArguments(
                phase: "stress",
                fixture: fixture
            )
        )
        XCTAssertTrue(stress.consoleOutput.contains("APKRUN-BLK-STRESS-READY"))
        XCTAssertFalse(stress.consoleOutput.contains("APKRUN-TEST: blk fail"))
        XCTAssertEqual(stress.states.last, .stopped)

        let recover = try await runBlockPhase("recover", fixture: fixture)
        assertBlockPhase("recover", in: recover)
        XCTAssertTrue(recover.consoleOutput.contains("APKRUN-BLK-RECOVERY journal replayed"))
    }

    func testBlockDeviceSerialOrderTracksBothAttachmentOrders() async throws {
        let fixture = try makeBlockDiskFixture(for: self)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let normal = try await runOrderCheck(
            fixture: fixture,
            order: .readOnlyThenReadWrite,
            expected: "apkrun-ro,apkrun-rw"
        )
        XCTAssertTrue(
            normal.records.contains(
                .check(name: "blk", result: .ok, detail: "order apkrun-ro,apkrun-rw")
            )
        )
        XCTAssertEqual(normal.records.last, .done)

        let reversed = try await runOrderCheck(
            fixture: fixture,
            order: .readWriteThenReadOnly,
            expected: "apkrun-rw,apkrun-ro"
        )
        XCTAssertTrue(
            reversed.records.contains(
                .check(name: "blk", result: .ok, detail: "order apkrun-rw,apkrun-ro")
            )
        )
        XCTAssertEqual(reversed.records.last, .done)
    }

    private func runBlockPhase(
        _ phase: String,
        fixture: BlockDiskFixture
    ) async throws -> LinuxGuestHarness.RunResult {
        try await LinuxGuestHarness.run(
            testCase: self,
            stopBehavior: .guestPowerOff,
            powerOff: true,
            tests: ["blk"],
            blockDisks: fixture.disks,
            extraCommandLine: blkArguments(phase: phase, fixture: fixture)
        )
    }

    private func runOrderCheck(
        fixture: BlockDiskFixture,
        order: LinuxTestGuest.BlockDiskOrder,
        expected: String
    ) async throws -> LinuxGuestHarness.RunResult {
        try await LinuxGuestHarness.run(
            testCase: self,
            stopBehavior: .guestPowerOff,
            powerOff: true,
            tests: ["blk"],
            blockDisks: fixture.disks,
            blockDiskOrder: order,
            extraCommandLine: blkArguments(
                phase: "order",
                fixture: fixture,
                order: expected
            )
        )
    }

    private func blkArguments(
        phase: String,
        fixture: BlockDiskFixture,
        order: String? = nil
    ) -> [String] {
        var arguments = [
            "apkrun.test.blk.phase=\(phase)",
            "apkrun.test.blk.token=\(token)",
        ]
        if phase == "format" {
            arguments.append("apkrun.test.blk.ro_sha256=\(fixture.readOnlySHA256)")
        }
        if let order {
            arguments.append("apkrun.test.blk.order=\(order)")
        }
        return arguments
    }

    private func assertBlockPhase(
        _ phase: String,
        in result: LinuxGuestHarness.RunResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(result.records.first, .bootOK, file: file, line: line)
        XCTAssertTrue(
            result.records.contains(
                .check(name: "blk", result: .ok, detail: phase)
            ),
            "Guest did not complete block phase \(phase): \(result.records)",
            file: file,
            line: line
        )
        XCTAssertEqual(result.records.last, .done, file: file, line: line)
        XCTAssertEqual(result.states, [.stopped, .starting, .running, .stopped], file: file, line: line)
    }
}

private struct BlockDiskFixture {
    let directory: URL
    let disks: LinuxTestGuest.BlockDisks
    let readOnlySHA256: String
}

private enum BlockDiskFixtureError: Error, CustomStringConvertible {
    case missingGenerator
    case generatorFailed(status: Int32, output: String)
    case invalidSHA256(String)

    var description: String {
        switch self {
        case .missingGenerator:
            "The test disk generator is missing from the IntegrationTests bundle."
        case .generatorFailed(let status, let output):
            "The test disk generator exited with status \(status): \(output)"
        case .invalidSHA256(let output):
            "The test disk generator returned an invalid SHA-256: \(output)"
        }
    }
}

private func makeBlockDiskFixture(for testCase: XCTestCase) throws -> BlockDiskFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-block-disks-\(UUID().uuidString)", isDirectory: true)

    do {
        guard
            let generator = Bundle(for: type(of: testCase))
                .url(forResource: "make-test-disks", withExtension: "sh")
        else {
            throw BlockDiskFixtureError.missingGenerator
        }

        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [generator.path, directory.path]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(decoding: outputData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw BlockDiskFixtureError.generatorFailed(
                status: process.terminationStatus,
                output: text
            )
        }
        guard
            text.utf8.count == 64,
            text.utf8.allSatisfy({
                (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
            })
        else {
            throw BlockDiskFixtureError.invalidSHA256(text)
        }

        return BlockDiskFixture(
            directory: directory,
            disks: LinuxTestGuest.BlockDisks(
                readOnly: directory.appendingPathComponent("ro.img"),
                readWrite: directory.appendingPathComponent("rw.img")
            ),
            readOnlySHA256: text
        )
    } catch {
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}

extension Data {
    fileprivate func contains(_ text: String) -> Bool {
        range(of: Data(text.utf8)) != nil
    }
}
