import Testing
import VirtualMachineCore

@testable import RuntimeCore

private let ports = [
    ConsolePortDefinition(role: .systemConsole),
    ConsolePortDefinition(role: .service(name: "serial")),
    ConsolePortDefinition(role: .log(name: "logcat")),
]

@Test
func consolePortPlanKeepsTheOrderWhenTheGuestNumbersThePortsAsAttached() {
    let identity = [0: 0, 1: 1, 2: 2]

    #expect(ConsolePortPlan.reordered(ports, observedDevice: identity) == ports)
}

@Test
func consolePortPlanReordersToTheGuestNumberingForAPermutedMapping() {
    // The marker of attachment port 1 arrived on /dev/hvc2, and that of port 2 on /dev/hvc1.
    let permuted = [0: 0, 1: 2, 2: 1]

    #expect(
        ConsolePortPlan.reordered(ports, observedDevice: permuted)
            == [ports[0], ports[2], ports[1]]
    )
}

@Test
func consolePortPlanRejectsAMappingThatIsNotAPermutation() {
    #expect(ConsolePortPlan.reordered(ports, observedDevice: [0: 0, 1: 1]) == nil)
    #expect(ConsolePortPlan.reordered(ports, observedDevice: [0: 0, 1: 1, 2: 1]) == nil)
    #expect(ConsolePortPlan.reordered(ports, observedDevice: [0: 0, 1: 1, 2: 5]) == nil)
}
