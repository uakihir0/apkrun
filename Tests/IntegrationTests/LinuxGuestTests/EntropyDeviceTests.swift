import CryptoKit
import DiagnosticsCore
import Foundation
import VirtioDeviceCore
import VirtualMachineCore
import XCTest

final class EntropyDeviceTests: XCTestCase {
    private let seed: UInt64 = 0xA17E_5EED_0630_0001

    func testSeededReadResetAndConfigurationProbe() async throws {
        let logSink = EntropyDeviceLogSink()
        let device = EntropyTestDevice(
            seed: seed,
            logger: APKLogger(category: VMLogCategory.virtio, sink: logSink),
            probesGuestMemoryMapping: true
        )
        let result = try await LinuxGuestHarness.run(
            testCase: self,
            stopBehavior: .guestPowerOff,
            powerOff: true,
            tests: ["rng"],
            entropyTestDevice: device
        )

        XCTAssertEqual(result.records.first, .bootOK)
        XCTAssertEqual(result.records.last, .done)
        XCTAssertEqual(result.states, [.stopped, .starting, .running, .stopped])

        let samples = result.records.compactMap { record -> String? in
            guard case .check(name: "rng", result: .ok, detail: let detail) = record else {
                return nil
            }
            return detail
        }
        XCTAssertEqual(samples.count, 2)
        for detail in samples {
            assertGuestSample(detail, matchesStreamSeededWith: seed)
        }

        let requiredLogMessages = [
            "entropy-test DRIVER_OK generation=",
            "entropy-test notification summary generation=",
            "entropy-test same-size configuration update ok",
            "entropy-test serialized configuration updates ok",
            "entropy-test configuration size mismatch rejected",
            "entropy-test stale configuration updater rejected generation=",
            "entropy-test guest memory mapping ok",
            "entropy-test guest memory mapping invalidated on reset generation=",
            "entropy-test guest memory mapping rejected access during stop mappingGeneration=",
            "entropy-test stale context queue/features/memory rejected generation=",
            "entropy-test stale context reset ignored generation=",
            "entropy-test device stop generation=",
        ]
        let entries = logSink.waitForMessages(requiredLogMessages)
        let messages = entries.map(\.publicMessage)
        for phrase in requiredLogMessages {
            XCTAssertTrue(messages.contains(where: { $0.contains(phrase) }), "Missing host log: \(phrase)")
        }
        let driverPrefix = "entropy-test DRIVER_OK generation="
        let driverEvents = messages.enumerated().compactMap { index, message in
            generation(in: message, after: driverPrefix).map { (index, $0) }
        }
        guard let firstDriver = driverEvents.first,
            let secondDriver = driverEvents.dropFirst().first(where: { $0.1 != firstDriver.1 })
        else {
            XCTFail("The host did not report DRIVER_OK on two device generations.")
            attachHostLog(entries, name: "Virtio RNG host log")
            return
        }

        let firstGeneration = firstDriver.1
        let secondGeneration = secondDriver.1
        XCTAssertTrue(
            assertOrderedMessages(
                [
                    "entropy-test DRIVER_OK generation=\(firstGeneration)",
                    "entropy-test notification summary generation=\(firstGeneration) notifications=1",
                    "entropy-test guest memory mapping invalidated on reset generation=\(firstGeneration)",
                    "entropy-test device reset generation=\(secondGeneration)",
                    "entropy-test DRIVER_OK generation=\(secondGeneration)",
                    "entropy-test notification summary generation=\(secondGeneration) notifications=1",
                ],
                in: messages
            ),
            "Host lifecycle logs did not show the guest driver reset between the two RNG reads."
        )
        attachHostLog(entries, name: "Virtio RNG host log")
    }

    func testGuestRebootBehaviorIsObservable() async throws {
        let logSink = EntropyDeviceLogSink()
        let rebootTimeline = VirtioDeviceEventTimeline()
        let result = try await LinuxGuestHarness.run(
            testCase: self,
            stopBehavior: .observeGuestReboot,
            powerOff: false,
            tests: ["rng"],
            entropyTestDevice: EntropyTestDevice(
                seed: seed,
                logger: APKLogger(category: VMLogCategory.virtio, sink: logSink),
                resetObserver: { generation in
                    rebootTimeline.recordDeviceReset(generation)
                },
                startObserver: { generation in
                    rebootTimeline.recordDeviceStart(generation)
                }
            ),
            recordObserver: { record in
                rebootTimeline.recordGuestRecord(record)
            },
            extraCommandLine: ["apkrun.test.rng.reboot=1"]
        )

        XCTAssertTrue(result.records.contains(.bootOK))
        XCTAssertTrue(
            result.records.contains(
                .check(
                    name: "rng-reboot",
                    result: .ok,
                    detail: "reboot requested after first read"
                )
            )
        )
        switch result.rebootObservation {
        case .guestRestarted:
            guard
                let markerIndex = result.records.firstIndex(where: {
                    if case .check(name: "rng-reboot", result: .ok, detail: _) = $0 {
                        return true
                    }
                    return false
                })
            else {
                XCTFail("The guest reboot marker was not recorded.")
                break
            }
            let bootIndices = result.records.indices.filter { result.records[$0] == .bootOK }
            guard let firstBoot = bootIndices.first,
                let secondBoot = bootIndices.first(where: { $0 > markerIndex })
            else {
                XCTFail("The guest console did not record a second boot after the reboot marker.")
                break
            }
            XCTAssertLessThan(firstBoot, markerIndex)
            XCTAssertGreaterThan(secondBoot, markerIndex)

            guard let deviceSequence = rebootTimeline.resetGenerationsBetweenDeviceStarts() else {
                XCTFail("The VZ callback stream did not show WillReset between device starts.")
                break
            }
            XCTAssertTrue(
                result.records[secondBoot] == .bootOK,
                "The guest console did not record the second boot after its reboot marker."
            )
            XCTAssertTrue(
                deviceSequence.resetGenerations.allSatisfy { resetGeneration in
                    logSink.entries.contains {
                        $0.publicMessage
                            .contains("entropy-test device reset generation=\(resetGeneration)")
                    }
                },
                "The VZ callback stream contained an unlogged reset generation."
            )
            XCTAssertTrue(
                logSink.entries.contains {
                    $0.publicMessage
                        .contains(
                            "entropy-test DRIVER_OK generation=\(deviceSequence.secondStartGeneration)"
                        )
                },
                "The VZ callback stream's second device start was not logged."
            )
        case .guestDidStop:
            break
        case .noRestartObserved, .none:
            XCTFail(
                "The guest reboot ended in an unexpected state: \(String(describing: result.rebootObservation))"
            )
        }
        let observation = XCTAttachment(
            string: """
                VZ guest reboot observation: \(String(describing: result.rebootObservation))
                Guest console order: \(rebootTimeline.guestRecordDescriptions.joined(separator: " -> "))
                VZ device callback order: \(rebootTimeline.deviceCallbackDescriptions.joined(separator: " -> "))
                """
        )
        observation.name = "VZ guest reboot observation"
        observation.lifetime = .keepAlways
        add(observation)
        attachHostLog(logSink.entries, name: "Virtio RNG reboot probe host log")
    }

    func testForcedStopInvalidatesLiveMappingAndDeferredVZElement() async throws {
        let logSink = EntropyDeviceLogSink()
        let stopTimeline = VirtioDeviceEventTimeline()
        let result = try await LinuxGuestHarness.run(
            testCase: self,
            stopBehavior: .forced,
            powerOff: false,
            tests: ["rng-pending"],
            entropyTestDevice: EntropyTestDevice(
                seed: seed,
                logger: APKLogger(category: VMLogCategory.virtio, sink: logSink),
                resetObserver: { generation in
                    stopTimeline.recordDeviceReset(generation)
                },
                startObserver: { generation in
                    stopTimeline.recordDeviceStart(generation)
                },
                mappingObserver: { generation in
                    stopTimeline.recordMappingCreated(generation)
                },
                stopObserver: { generation in
                    stopTimeline.recordDeviceStop(generation)
                },
                performsConfigurationProbe: false,
                probesGuestMemoryMapping: true,
                probesPendingElementInvalidation: true
            )
        )

        XCTAssertTrue(
            result.records.contains(
                .check(
                    name: "rng-pending",
                    result: .ok,
                    detail: "background read submitted"
                )
            )
        )
        XCTAssertEqual(result.records.last, .done)
        XCTAssertEqual(result.states.last, .stopped)
        XCTAssertEqual(
            stopTimeline.resetGenerationsBetweenMappingAndStop(),
            [],
            "The forced-stop probe must reach WillStop without an intervening WillReset."
        )

        let requiredMessages = [
            "entropy-test guest memory mapping ok",
            "entropy-test pending element deferred generation=",
            "entropy-test pending element probe armed",
            "entropy-test guest memory mapping rejected access during stop mappingGeneration=",
            "entropy-test pending completion attempted after stop callback",
        ]
        let entries = logSink.waitForMessages(requiredMessages, timeout: 10)
        let messages = entries.map(\.publicMessage)
        for phrase in requiredMessages {
            XCTAssertTrue(
                messages.contains(where: { $0.contains(phrase) }),
                "Missing host log: \(phrase)"
            )
        }

        XCTAssertFalse(
            messages.contains {
                $0.contains("entropy-test pending completion preceded stop callback")
            }
        )
        let callbackObservation = XCTAttachment(
            string: """
                Forced-stop VZ device callback order:
                \(stopTimeline.deviceCallbackDescriptions.joined(separator: " -> "))
                """
        )
        callbackObservation.name = "VZ forced-stop device callback order"
        callbackObservation.lifetime = .keepAlways
        add(callbackObservation)
        attachHostLog(entries, name: "Virtio RNG forced-stop pending-element host log")
    }

    private func assertGuestSample(
        _ detail: String,
        matchesStreamSeededWith seed: UInt64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let fields = Dictionary(
            detail.split(whereSeparator: \.isWhitespace).compactMap { field -> (String, String)? in
                let parts = field.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return (String(parts[0]), String(parts[1]))
            },
            uniquingKeysWith: { first, _ in first }
        )
        guard let digest = fields["sha256"], let headHex = fields["head"] else {
            XCTFail("Malformed guest RNG result: \(detail)", file: file, line: line)
            return
        }
        guard let head = Self.bytes(fromHex: headHex), head.count == 16 else {
            XCTFail("Malformed guest RNG sample prefix: \(headHex)", file: file, line: line)
            return
        }

        let stream = Self.byteStream(seed: seed, count: 1 * 1_024 * 1_024)
        guard
            let offset = stream.indices.dropLast(head.count).first(where: { start in
                stream[start..<(start + head.count)].elementsEqual(head)
            }),
            offset + 64 * 1_024 <= stream.count
        else {
            XCTFail("Guest RNG prefix was not found in the seeded host stream.", file: file, line: line)
            return
        }

        let expected = Data(stream[offset..<(offset + 64 * 1_024)])
        let expectedDigest = SHA256.hash(data: expected)
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(digest, expectedDigest, file: file, line: line)
    }

    private func generation(in message: String, after prefix: String) -> UInt64? {
        guard message.hasPrefix(prefix) else { return nil }
        let digits = message.dropFirst(prefix.count).prefix(while: \.isNumber)
        return UInt64(digits)
    }

    private func assertOrderedMessages(_ phrases: [String], in messages: [String]) -> Bool {
        var nextSearchIndex = 0
        for phrase in phrases {
            guard
                let index = messages.indices.dropFirst(nextSearchIndex).first(where: {
                    messages[$0].contains(phrase)
                })
            else {
                XCTFail("Missing host log in expected order: \(phrase)")
                return false
            }
            nextSearchIndex = index + 1
        }
        return true
    }

    private func attachHostLog(_ entries: [LogEntry], name: String) {
        let text = entries.map(\.formattedPublicMessage).joined(separator: "\n")
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static func bytes(fromHex hex: String) -> [UInt8]? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<end], radix: 16) else { return nil }
            bytes.append(byte)
            index = end
        }
        return bytes
    }

    private static func byteStream(seed: UInt64, count: Int) -> [UInt8] {
        var generator = TestSplitMix64Generator(seed: seed)
        return (0..<count).map { _ in generator.nextByte() }
    }
}

private final class VirtioDeviceEventTimeline: @unchecked Sendable {
    private enum GuestEvent: Equatable {
        case rebootMarker
        case bootOK
    }

    private enum DeviceEvent: Equatable {
        case mappingCreated(UInt64)
        case reset(UInt64)
        case started(UInt64)
        case stopped(UInt64)
    }

    private let lock = NSLock()
    private var storedGuestEvents: [GuestEvent] = []
    private var storedDeviceEvents: [DeviceEvent] = []

    func recordDeviceReset(_ generation: UInt64) {
        lock.withLock {
            storedDeviceEvents.append(.reset(generation))
        }
    }

    func recordDeviceStart(_ generation: UInt64) {
        lock.withLock {
            storedDeviceEvents.append(.started(generation))
        }
    }

    func recordMappingCreated(_ generation: UInt64) {
        lock.withLock {
            storedDeviceEvents.append(.mappingCreated(generation))
        }
    }

    func recordDeviceStop(_ generation: UInt64) {
        lock.withLock {
            storedDeviceEvents.append(.stopped(generation))
        }
    }

    func recordGuestRecord(_ record: TestGuestRecord) {
        let event: GuestEvent?
        switch record {
        case .bootOK:
            event = .bootOK
        case .check(name: "rng-reboot", result: .ok, detail: _):
            event = .rebootMarker
        case .check, .done:
            event = nil
        }
        guard let event else { return }
        lock.withLock {
            storedGuestEvents.append(event)
        }
    }

    func resetGenerationsBetweenDeviceStarts() -> (
        resetGenerations: [UInt64],
        secondStartGeneration: UInt64
    )? {
        lock.withLock {
            let startIndices = storedDeviceEvents.indices.filter {
                if case .started = storedDeviceEvents[$0] {
                    return true
                }
                return false
            }
            guard startIndices.count >= 2,
                case .started(let secondStartGeneration) = storedDeviceEvents[startIndices[1]]
            else {
                return nil
            }
            let resetGenerations = storedDeviceEvents[
                (startIndices[0] + 1)..<startIndices[1]
            ].compactMap { event -> UInt64? in
                guard case .reset(let generation) = event else { return nil }
                return generation
            }
            guard !resetGenerations.isEmpty else { return nil }
            return (resetGenerations, secondStartGeneration)
        }
    }

    func resetGenerationsBetweenMappingAndStop() -> [UInt64]? {
        lock.withLock {
            guard
                let mappingIndex = storedDeviceEvents.firstIndex(where: {
                    if case .mappingCreated = $0 { return true }
                    return false
                }),
                let stopIndex = storedDeviceEvents.firstIndex(where: {
                    if case .stopped = $0 { return true }
                    return false
                }),
                mappingIndex < stopIndex
            else {
                return nil
            }
            return storedDeviceEvents[(mappingIndex + 1)..<stopIndex].compactMap { event in
                guard case .reset(let generation) = event else { return nil }
                return generation
            }
        }
    }

    var guestRecordDescriptions: [String] {
        lock.withLock {
            storedGuestEvents.map { event in
                switch event {
                case .rebootMarker:
                    "guest reboot marker"
                case .bootOK:
                    "guest bootOK"
                }
            }
        }
    }

    var deviceCallbackDescriptions: [String] {
        lock.withLock {
            storedDeviceEvents.map { event in
                switch event {
                case .mappingCreated(let generation):
                    "guest memory mapping created generation=\(generation)"
                case .reset(let generation):
                    "WillReset generation=\(generation)"
                case .started(let generation):
                    "DRIVER_OK generation=\(generation)"
                case .stopped(let generation):
                    "WillStop generation=\(generation)"
                }
            }
        }
    }
}

private final class EntropyDeviceLogSink: LogSink, @unchecked Sendable {
    private let condition = NSCondition()
    private var storedEntries: [LogEntry] = []

    var entries: [LogEntry] {
        condition.lock()
        defer { condition.unlock() }
        return storedEntries
    }

    func write(_ entry: LogEntry) {
        condition.lock()
        storedEntries.append(entry)
        condition.broadcast()
        condition.unlock()
    }

    func isEnabled(for level: LogLevel) -> Bool {
        level != .debug
    }

    func waitForMessages(
        _ phrases: [String],
        timeout: TimeInterval = 10
    ) -> [LogEntry] {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !phrases.allSatisfy({ phrase in
            storedEntries.contains(where: { $0.publicMessage.contains(phrase) })
        }) {
            guard condition.wait(until: deadline) else { break }
        }
        return storedEntries
    }
}

private struct TestSplitMix64Generator {
    private var state: UInt64
    private var currentWord: UInt64 = 0
    private var remainingBytes = 0

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextByte() -> UInt8 {
        if remainingBytes == 0 {
            currentWord = nextWord()
            remainingBytes = MemoryLayout<UInt64>.size
        }
        let byte = UInt8(truncatingIfNeeded: currentWord)
        currentWord >>= 8
        remainingBytes -= 1
        return byte
    }

    private mutating func nextWord() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
