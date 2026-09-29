/// A custom virtio device model that a virtual machine can attach.
///
/// #063 adds the device lifecycle and queue callbacks. This initial contract
/// exposes only the descriptor needed by `VMDefinition` and validation.
public protocol VirtioDeviceModel: AnyObject, Sendable {
    /// The device's framework-facing configuration metadata.
    var descriptor: VirtioDeviceDescriptor { get }
}
