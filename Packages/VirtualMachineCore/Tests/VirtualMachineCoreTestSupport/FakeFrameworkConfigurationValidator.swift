import DiagnosticsCore
import VirtualMachineCore

/// Supplies deterministic framework validation results for VM definition tests.
package struct FakeFrameworkConfigurationValidator: FrameworkConfigurationValidator {
    package let rejection: UnderlyingError?

    package init(rejection: UnderlyingError? = nil) {
        self.rejection = rejection
    }

    package func validate(_ definition: VMDefinition) -> UnderlyingError? {
        _ = definition
        return rejection
    }
}
