import DiagnosticsCore
import VirtualMachineCore

/// Supplies deterministic framework validation results for VM definition tests.
package struct FakeFrameworkConfigurationValidator: FrameworkConfigurationValidator {
    package let rejection: UnderlyingError?
    package let customDeviceFailure: FrameworkConfigurationFailure?

    package init(
        rejection: UnderlyingError? = nil,
        customDeviceFailure: FrameworkConfigurationFailure? = nil
    ) {
        self.rejection = rejection
        self.customDeviceFailure = customDeviceFailure
    }

    package func validate(_ definition: VMDefinition) -> FrameworkConfigurationFailure? {
        _ = definition
        if let customDeviceFailure {
            return customDeviceFailure
        }
        return rejection.map(FrameworkConfigurationFailure.rejected)
    }
}
