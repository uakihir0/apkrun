import CryptoKit
import Darwin
import DiagnosticsCore
import Foundation
import XCTest

@testable import VirtualMachineCore

final class LinuxGuestVsockTests: XCTestCase {
    func testVsockGuestServicesReportReady() async throws {
        let result = try await LinuxGuestHarness.run(
            testCase: self,
            stopBehavior: .forced,
            powerOff: false,
            tests: ["vsock"],
            hostAction: { controller in
                for port: UInt32 in [7000, 7001] {
                    let connection = try await Self.connectWhenReady(
                        controller,
                        toPort: port
                    )
                    connection.close()
                }
            }
        )

        Self.assertGuestReportedVsockCheck(in: result)
    }

    func testVsockConnectionClosesWhenVMStops() async throws {
        let probe = VsockConnectionProbe()
        let result = try await LinuxGuestHarness.run(
            testCase: self,
            stopBehavior: .forced,
            powerOff: false,
            tests: ["vsock"],
            hostAction: { controller in
                let connection = try await Self.connectWhenReady(
                    controller,
                    toPort: 7000
                )
                let payload = Data("kept open through VM stop".utf8)
                try await connection.write(payload)
                let echoed = try await Self.readExactly(
                    payload.count,
                    from: connection,
                    timeout: .seconds(2)
                )
                XCTAssertEqual(echoed, payload)
                probe.retain(connection)
            }
        )

        Self.assertGuestReportedVsockCheck(in: result)
        guard let connection = probe.connection() else {
            XCTFail("The T2 host action did not retain its live vsock connection.")
            return
        }
        let closedWithinDeadline = await Self.connectionCloses(
            connection,
            within: .seconds(1)
        )
        XCTAssertTrue(
            closedWithinDeadline,
            "VMController.stop() did not close the live vsock connection within one second."
        )
    }

    func testVsockEchoReturnsOneMiB() async throws {
        let payload = Self.makePayload(byteCount: 1_048_576)
        let result = try await LinuxGuestHarness.run(
            testCase: self,
            stopBehavior: .forced,
            powerOff: false,
            tests: ["vsock"],
            hostAction: { controller in
                let connection = try await Self.connectWhenReady(
                    controller,
                    toPort: 7000
                )
                let writeTask = Task {
                    try await connection.write(payload)
                }

                do {
                    let echoed = try await Self.readExactly(
                        payload.count,
                        from: connection,
                        timeout: .seconds(15)
                    )
                    try await writeTask.value
                    XCTAssertEqual(echoed, payload)
                    XCTAssertEqual(
                        Data(SHA256.hash(data: echoed)),
                        Data(SHA256.hash(data: payload))
                    )
                } catch {
                    connection.close()
                    _ = await writeTask.result
                    await connection.closed.value
                    throw error
                }

                connection.close()
                await connection.closed.value
            }
        )

        Self.assertGuestReportedVsockCheck(in: result)
    }

    func testVsockUnusedPortReturnsTypedFailureWithinDeadline() async throws {
        let logSink = VsockTestLogSink()
        let probe = VsockPortFailureProbe()
        let clock = ContinuousClock()
        let result = try await LinuxGuestHarness.run(
            testCase: self,
            stopBehavior: .forced,
            powerOff: false,
            tests: ["vsock"],
            hostAction: { controller in
                let listener = try await Self.connectWhenReady(
                    controller,
                    toPort: 7000
                )
                listener.close()
                await listener.closed.value

                let started = clock.now
                do {
                    let unexpected = try await controller.connect(
                        vsockPort: 7999,
                        timeout: .seconds(2)
                    )
                    unexpected.close()
                    await unexpected.closed.value
                    probe.record("unexpectedly connected")
                    XCTFail("A connection to unused guest port 7999 unexpectedly succeeded.")
                } catch let failure as VMFailure {
                    probe.record(Self.describe(failure))
                    let hostVersion = ProcessInfo.processInfo.operatingSystemVersion
                    let isReferenceHost =
                        hostVersion.majorVersion == 27 && hostVersion.minorVersion == 0
                    switch failure {
                    case .vsockConnectFailed(
                        port: 7999,
                        underlying: let error
                    ):
                        if isReferenceHost {
                            XCTAssertEqual(error.domain, NSPOSIXErrorDomain)
                            XCTAssertEqual(error.code, Int(ECONNRESET))
                        }
                    case .vsockPortNotListening(port: 7999),
                        .vsockConnectTimedOut(port: 7999):
                        XCTAssertFalse(
                            isReferenceHost,
                            "macOS 27.0 is expected to return NSPOSIXErrorDomain/ECONNRESET."
                        )
                    default:
                        XCTFail("Unused port returned unexpected failure \(failure.code).")
                    }
                }
                XCTAssertLessThanOrEqual(
                    started.duration(to: clock.now),
                    .milliseconds(2_500)
                )
            },
            logSink: logSink
        )

        Self.assertGuestReportedVsockCheck(in: result)
        let vsockMessages = logSink.snapshot()
            .filter {
                $0.subsystem == .vm && $0.category == VMLogCategory.vsock.rawValue
            }
            .map(\.publicMessage)
        let attachment = XCTAttachment(
            string: """
                unused-port-7999: \(probe.snapshot())
                vsock-log:
                \(vsockMessages.joined(separator: "\n"))
                """
        )
        attachment.name = "Unused vsock port diagnostic"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testVsockGuestClosureCompletesClosedWithinOneSecond() async throws {
        let payload = Data(0..<32)
        let result = try await LinuxGuestHarness.run(
            testCase: self,
            stopBehavior: .forced,
            powerOff: false,
            tests: ["vsock"],
            hostAction: { controller in
                let connection = try await Self.connectWhenReady(
                    controller,
                    toPort: 7001
                )
                try await connection.write(payload)
                let received = try await Self.readExactly(
                    16,
                    from: connection,
                    timeout: .seconds(2)
                )
                XCTAssertEqual(received, Data(payload.prefix(16)))
                let closedWithinDeadline = await Self.connectionCloses(
                    connection,
                    within: .seconds(1)
                )
                XCTAssertTrue(
                    closedWithinDeadline,
                    "The guest did not close the vsock connection within one second."
                )
            }
        )

        Self.assertGuestReportedVsockCheck(in: result)
    }

    private static func assertGuestReportedVsockCheck(
        in result: LinuxGuestHarness.RunResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(result.records.first, .bootOK, file: file, line: line)
        XCTAssertTrue(
            result.records.contains(
                .check(
                    name: "vsock",
                    result: .ok,
                    detail: "listening 7000,7001"
                )
            ),
            "The guest did not report both vsock listeners ready: \(result.records)",
            file: file,
            line: line
        )
        XCTAssertEqual(result.records.last, .done, file: file, line: line)
        XCTAssertEqual(
            result.states,
            [.stopped, .starting, .running, .stopping, .stopped],
            file: file,
            line: line
        )
    }

    private static func connectWhenReady(
        _ controller: VMController,
        toPort port: UInt32
    ) async throws -> VsockConnection {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var backoff = Duration.milliseconds(100)

        while clock.now < deadline {
            let remaining = clock.now.duration(to: deadline)
            do {
                return try await controller.connect(
                    vsockPort: port,
                    timeout: min(remaining, .milliseconds(500))
                )
            } catch let failure as VMFailure {
                switch failure {
                case .vsockPortNotListening(port: port),
                    .vsockConnectTimedOut(port: port):
                    break
                case .vsockConnectFailed(port: port, underlying: let error)
                where error.domain == NSPOSIXErrorDomain
                    && error.code == ECONNRESET:
                    break
                default:
                    throw failure
                }
            }

            let remainingAfterAttempt = clock.now.duration(to: deadline)
            guard remainingAfterAttempt > .zero else { break }
            try await Task.sleep(for: min(backoff, remainingAfterAttempt))
            backoff = min(backoff * 2, .seconds(2))
        }

        throw VMFailure.vsockConnectTimedOut(port: port)
    }

    private static func readExactly(
        _ byteCount: Int,
        from connection: VsockConnection,
        timeout: Duration
    ) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                var received = Data()
                received.reserveCapacity(byteCount)
                while received.count < byteCount {
                    let bytes = try await connection.read(
                        upTo: min(64 * 1_024, byteCount - received.count)
                    )
                    guard !bytes.isEmpty else {
                        throw VsockGuestTestFailure.peerClosedEarly(
                            expected: byteCount,
                            received: received.count
                        )
                    }
                    received.append(bytes)
                }
                return received
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                connection.close()
                throw VsockGuestTestFailure.timedOut
            }

            guard let result = try await group.next() else {
                throw VsockGuestTestFailure.timedOut
            }
            group.cancelAll()
            return result
        }
    }

    private static func connectionCloses(
        _ connection: VsockConnection,
        within timeout: Duration
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let race = VsockCloseRace(continuation)
            let closed = connection.closed
            Task.detached {
                await closed.value
                race.resolve(true)
            }
            Task.detached {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                guard race.resolve(false) else { return }
                connection.close()
            }
        }
    }

    private static func makePayload(byteCount: Int) -> Data {
        var state: UInt32 = 0x9e37_79b9
        return Data(
            (0..<byteCount).map { _ in
                state = state &* 1_664_525 &+ 1_013_904_223
                return UInt8(truncatingIfNeeded: state >> 16)
            }
        )
    }

    private static func describe(_ failure: VMFailure) -> String {
        switch failure {
        case .vsockPortNotListening(let port):
            "vsockPortNotListening port=\(port)"
        case .vsockConnectTimedOut(let port):
            "vsockConnectTimedOut port=\(port)"
        case .vsockConnectFailed(let port, let underlying):
            "vsockConnectFailed port=\(port) domain=\(underlying.domain) code=\(underlying.code)"
        default:
            failure.code
        }
    }
}

private final class VsockCloseRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func resolve(_ didClose: Bool) -> Bool {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        guard let continuation else { return false }
        continuation.resume(returning: didClose)
        return true
    }
}

private enum VsockGuestTestFailure: Error {
    case peerClosedEarly(expected: Int, received: Int)
    case timedOut
}

private final class VsockPortFailureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var failure = "not observed"

    func record(_ failure: String) {
        lock.withLock {
            self.failure = failure
        }
    }

    func snapshot() -> String {
        lock.withLock { failure }
    }
}

private final class VsockConnectionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var retainedConnection: VsockConnection?

    func retain(_ connection: VsockConnection) {
        lock.withLock {
            retainedConnection = connection
        }
    }

    func connection() -> VsockConnection? {
        lock.withLock { retainedConnection }
    }
}

private final class VsockTestLogSink: LogSink, @unchecked Sendable {
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
