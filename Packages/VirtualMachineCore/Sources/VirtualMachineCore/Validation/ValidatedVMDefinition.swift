/// A VM definition that passed the host and Virtualization.framework checks.
///
/// Only the validator can create this value. Controllers should accept this
/// type instead of an unchecked `VMDefinition`.
public struct ValidatedVMDefinition: Sendable {
    /// The original value after successful validation.
    public let definition: VMDefinition

    package init(
        definition: VMDefinition,
        validationToken: VMDefinitionValidationToken
    ) {
        _ = validationToken
        self.definition = definition
    }
}
