import Foundation
import Testing

@testable import VirtualMachineCore

/// The port test's plan for the 20 console ports of #095 step 1.
private let twentyPortPlan = LinuxTestGuest.consolePorts(tests: ["ports"], consolePortCount: 20)

/// The `ok` record that the guest prints when port `index` receives its own marker.
private func passingRecord(forPort index: Int) -> TestGuestRecord {
    .check(
        name: ConsolePortMarkerCheck.checkName(forPort: index),
        result: .ok,
        detail: ConsolePortMarkerCheck.marker(forPort: index)
    )
}

@Test
func portTestPlanHasOneSystemConsoleAndTheTestPortsInAttachmentOrder() {
    #expect(
        twentyPortPlan
            == [ConsolePortDefinition(role: .systemConsole)]
            + (1..<20).map { ConsolePortDefinition(role: .service(name: "test-\($0)")) }
    )
    #expect(
        LinuxTestGuest.consolePorts(tests: [], consolePortCount: 20)
            == [ConsolePortDefinition(role: .systemConsole)]
    )
    #expect(LinuxTestGuest.consolePorts(tests: ["ports"], consolePortCount: 1).count == 3)
}

@Test
func portMarkerCheckRequiresAMarkerOnEveryPortOfTheTwentyPortPlan() {
    #expect(ConsolePortMarkerCheck.markedPorts(in: twentyPortPlan) == Array(1..<20))
    #expect(ConsolePortMarkerCheck.markedPorts(in: [ConsolePortDefinition(role: .systemConsole)]).isEmpty)

    let records = (1..<20).map(passingRecord(forPort:)) + [.bootOK, .done]
    #expect(ConsolePortMarkerCheck.failures(in: records, plan: twentyPortPlan).isEmpty)
}

@Test
func portMarkerCheckFailsWhenAPortHasNoMarkerRecord() {
    var records = (1..<20).map(passingRecord(forPort:))
    records.removeAll { $0 == passingRecord(forPort: 7) }

    #expect(ConsolePortMarkerCheck.failures(in: records, plan: twentyPortPlan) == [.missing(port: 7)])
}

@Test
func portMarkerCheckFailsWhenAPortReportsAnotherPortsMarker() {
    // Port 9 printed the marker that was sent to port 8: the guest numbers the ports differently.
    var records = (1..<20).map(passingRecord(forPort:))
    records = records.map { record in
        record == passingRecord(forPort: 9)
            ? .check(name: "port-9", result: .ok, detail: "APKRUN-PORT-8")
            : record
    }

    #expect(
        ConsolePortMarkerCheck.failures(in: records, plan: twentyPortPlan)
            == [.wrongMarker(port: 9, detail: "APKRUN-PORT-8")]
    )
}

@Test
func portMarkerCheckFailsForAFailedOrRepeatedRecord() {
    var records = (1..<20).map(passingRecord(forPort:))
    records[3] = .check(name: "port-4", result: .fail, detail: "no host marker arrived on /dev/hvc4")
    records.append(passingRecord(forPort: 5))

    #expect(
        ConsolePortMarkerCheck.failures(in: records, plan: twentyPortPlan)
            == [
                .failed(port: 4, detail: "no host marker arrived on /dev/hvc4"),
                .repeated(port: 5, count: 2),
            ]
    )
}

@Test
func portMarkerCheckIsOverTheGuestOutputAsParsed() {
    // The guest's output for a four-port plan, with port 2 failing and port 3 silent.
    var parser = TestGuestLineParser()
    let text = """
        APKRUN-TEST: hvc-devices ok hvc0 hvc1 hvc2 hvc3
        APKRUN-TEST: port-1 ok APKRUN-PORT-1
        APKRUN-TEST: port-2 fail no host marker arrived on /dev/hvc2
        APKRUN-TEST: done
        """
    let records = parser.consume(Data((text + "\n").utf8)) + parser.finish()
    let plan = LinuxTestGuest.consolePorts(tests: ["ports"], consolePortCount: 4)

    #expect(
        ConsolePortMarkerCheck.failures(in: records, plan: plan)
            == [
                .failed(port: 2, detail: "no host marker arrived on /dev/hvc2"),
                .missing(port: 3),
            ]
    )
    #expect(
        ConsolePortMarkerCheck.failures(in: records, plan: plan).map(\.description)
            == [
                "port-2 failed: no host marker arrived on /dev/hvc2",
                "port-3 was not reported",
            ]
    )
}
