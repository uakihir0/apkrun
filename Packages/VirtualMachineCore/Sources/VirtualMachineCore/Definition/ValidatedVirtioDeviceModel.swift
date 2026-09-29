import VirtioDeviceCore

/// Freezes descriptor metadata while retaining its owning device model.
///
/// When #063 adds device lifecycle operations to `VirtioDeviceModel`, this
/// wrapper must forward those operations to `underlying`.
package final class ValidatedVirtioDeviceModel: VirtioDeviceModel, Sendable {
    package let descriptor: VirtioDeviceDescriptor
    package let underlying: any VirtioDeviceModel

    package init(underlying: any VirtioDeviceModel) {
        self.underlying = underlying
        descriptor = underlying.descriptor
    }
}
