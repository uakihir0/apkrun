import Dispatch

/// A privately created serial queue for all Virtualization.framework access.
package struct VMQueue: Sendable {
    /// The underlying serial queue.
    package let dispatchQueue: DispatchQueue

    /// Creates a serial queue with the label required by VirtualMachineCore.
    package init(label: String = "io.apkrun.vm.queue") {
        dispatchQueue = DispatchQueue(label: label)
    }
}
