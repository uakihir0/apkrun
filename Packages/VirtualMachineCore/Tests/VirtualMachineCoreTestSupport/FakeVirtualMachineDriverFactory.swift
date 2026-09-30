import Foundation
import VirtualMachineCore

/// Supplies scripted fake drivers to VMController lifecycle tests.
public actor FakeVirtualMachineDriverFactory: VirtualMachineDriverFactory {
    private var drivers: [FakeVirtualMachineDriver]
    private let failure: VZErrorInfo?

    /// Console roles passed to each driver creation request.
    public private(set) var requestedConsoleRoles: [[ConsoleRole]] = []

    /// Creates a factory with the drivers to return in creation order.
    public init(
        drivers: [FakeVirtualMachineDriver],
        failure: VZErrorInfo? = nil
    ) {
        self.drivers = drivers
        self.failure = failure
    }

    package func makeDriver(
        for definition: VMDefinition,
        consoleChannels: [ConsoleChannel]
    ) async throws(VZErrorInfo) -> any VirtualMachineDriver {
        _ = definition
        requestedConsoleRoles.append(consoleChannels.map(\.role))
        if let failure {
            throw failure
        }
        guard !drivers.isEmpty else {
            throw VZErrorInfo(
                domain: "FakeVirtualMachineDriverFactory",
                code: 1,
                description: "No fake driver was configured."
            )
        }
        return drivers.removeFirst()
    }
}
