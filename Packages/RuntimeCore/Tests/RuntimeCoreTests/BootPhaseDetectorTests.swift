import DiagnosticsCore
import Foundation
import Testing

@testable import RuntimeCore

@Test
func bootPhaseDetectorFindsEveryPhaseInTheVZConsoleLogInOrder() throws {
    let log = try consoleFixture("vz-headless-cold-boot.log")
    var detector = BootPhaseDetector()
    var events: [BootPhaseDetector.Event] = []
    // Feed the log in uneven chunks, as the console pipe delivers it.
    var offset = 0
    while offset < log.count {
        let end = min(log.count, offset + 1 + (offset * 7919) % 4096)
        events += detector.consume(log.subdata(in: offset..<end))
        offset = end
    }

    #expect(
        events == [
            .entered(.kernel, marker: .kernelStart),
            .entered(.`init`, marker: .androidInit),
            .entered(.systemServer, marker: .systemServerReady),
            .entered(.bootCompleted, marker: .bootCompleted),
        ]
    )
    #expect(detector.phase == .bootCompleted)
}

@Test
func bootPhaseDetectorEndsTheBootOnAKernelPanic() {
    var detector = BootPhaseDetector()
    let events = detector.consume(
        Data("[    1.0][    T1] init: Loaded kernel module\n[    2.0] Kernel panic - not syncing: VFS\n".utf8)
    )
    #expect(events.last == .failed(.kernelPanic))
    #expect(detector.consume(Data("init: starting service 'zygote'\n".utf8)).isEmpty)
}

@Test
func bootPhaseDetectorReportsTheBootFailedDetail() {
    var detector = BootPhaseDetector()
    let events = detector.consume(
        Data(
            "[  149.5][ T3609] GceEventReporter: VIRTUAL_DEVICE_BOOT_FAILED: Dependencies not ready after 10 checks: Bluetooth\r\n"
                .utf8
        )
    )
    #expect(
        events.last
            == .failed(.androidBootFailed(detail: "Dependencies not ready after 10 checks: Bluetooth"))
    )
}

@Test
func bootPhaseDetectorNeverReentersOrSkipsBackwards() {
    var detector = BootPhaseDetector()
    _ = detector.consume(Data("GceEventReporter: VIRTUAL_DEVICE_BOOT_COMPLETED\n".utf8))
    #expect(detector.phase == .bootCompleted)
    #expect(detector.consume(Data("[ 9.0][ T1] init: starting service 'zygote'...\n".utf8)).isEmpty)
}

@Test
func sensorsResponderAnswersListSensorsWithTheEmptyMaskFrame() {
    var responder = SensorsResponder()
    let list = Data([0, 0, 0, 0, 12, 0, 0, 0]) + Data("list-sensors".utf8)
    let time = Data([0, 0, 0, 0, 16, 0, 0, 0]) + Data("time:36332343850".utf8)

    // Split inside the header and inside the payload.
    #expect(responder.consume(list.prefix(5)).isEmpty)
    let reply = responder.consume(list.dropFirst(5) + time.prefix(3))
    #expect(reply == Data([0x02, 0x00, 0x00, 0x80, 0x02, 0x00, 0x00, 0x00, 0x30, 0x0A]))
    #expect(responder.consume(time.dropFirst(3)).isEmpty)
    #expect(responder.commands == ["list-sensors", "time:36332343850"])
}

@Test
func sensorsResponderDropsAStreamThatIsNotThisProtocol() {
    var responder = SensorsResponder()
    #expect(responder.consume(Data([0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0x7F])).isEmpty)
    let list = Data([0, 0, 0, 0, 12, 0, 0, 0]) + Data("list-sensors".utf8)
    #expect(!responder.consume(list).isEmpty)
}

private func consoleFixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/console/\(name)")
    return try Data(contentsOf: url)
}
