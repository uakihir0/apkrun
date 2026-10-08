import Dispatch

/// A privately created serial queue for all Virtualization.framework access.
package struct VMQueue: Sendable {
    private static let membershipKey = DispatchSpecificKey<Bool>()

    /// The underlying serial queue.
    package let dispatchQueue: DispatchQueue

    /// Creates a serial queue with the label required by VirtualMachineCore.
    package init(label: String = "io.apkrun.vm.queue") {
        dispatchQueue = DispatchQueue(label: label)
        dispatchQueue.setSpecific(key: Self.membershipKey, value: true)
    }

    /// Returns whether the caller is already running on this queue.
    package func isCurrent() -> Bool {
        DispatchQueue.getSpecific(key: Self.membershipKey) == true
    }

    /// Runs work on this queue and waits for its result.
    ///
    /// Framework objects that no controller owns yet, such as validation
    /// configurations and identifiers, are created through a fresh queue with
    /// this label, so they still never run on the caller's thread.
    package func performSynchronously<T>(_ work: () -> T) -> T {
        dispatchQueue.sync(execute: work)
    }
}
