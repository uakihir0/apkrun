/// A custom virtio device model that a virtual machine can attach.
public protocol VirtioDeviceModel: AnyObject, Sendable {
    /// The device's framework-facing configuration metadata.
    var descriptor: VirtioDeviceDescriptor { get }

    /// Called on the device queue after the guest sets `DRIVER_OK`.
    func deviceDidStart(context: VirtioDeviceContext, negotiatedFeatures: UInt64)

    /// Called on the device queue when the guest notifies a virtqueue.
    func queueNotified(index: Int, context: VirtioDeviceContext)

    /// Called on the device queue before the VM pauses.
    func deviceWillPause()

    /// Called on the device queue after the VM resumes.
    func deviceWillResume()

    /// Called on the device queue after a guest or host device reset.
    func deviceWillReset()

    /// Called on the device queue before the VM stops.
    func deviceWillStop()

    /// Called on the device queue before a reset, a stop, or a release invalidates the guest memory mappings.
    ///
    /// A model that gave host pointers into guest memory to another thread finishes that use here. The pointers are
    /// not valid after the mappings are invalidated, and the reset and stop callbacks run after that.
    func deviceWillInvalidateGuestMemory()
}

extension VirtioDeviceModel {
    /// Default no-op callback for models that do not need to observe driver readiness.
    public func deviceDidStart(context: VirtioDeviceContext, negotiatedFeatures: UInt64) {}

    /// Default no-op callback for models that do not process queue notifications.
    public func queueNotified(index: Int, context: VirtioDeviceContext) {}

    /// Default no-op callback for models that do not need pause handling.
    public func deviceWillPause() {}

    /// Default no-op callback for models that do not need resume handling.
    public func deviceWillResume() {}

    /// Default no-op callback for models that do not need reset handling.
    public func deviceWillReset() {}

    /// Default no-op callback for models that do not need stop handling.
    public func deviceWillStop() {}

    /// Default no-op callback for models that keep no host pointers into guest memory.
    public func deviceWillInvalidateGuestMemory() {}
}
