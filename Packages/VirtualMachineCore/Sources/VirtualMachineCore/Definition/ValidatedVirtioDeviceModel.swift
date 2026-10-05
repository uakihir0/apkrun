import VirtioDeviceCore

/// Freezes descriptor metadata while retaining its owning device model.
package final class ValidatedVirtioDeviceModel: VirtioDeviceModel, Sendable {
    package let descriptor: VirtioDeviceDescriptor
    package let underlying: any VirtioDeviceModel

    package init(underlying: any VirtioDeviceModel) {
        self.underlying = underlying
        descriptor = underlying.descriptor
    }

    package func deviceDidStart(context: VirtioDeviceContext, negotiatedFeatures: UInt64) {
        underlying.deviceDidStart(context: context, negotiatedFeatures: negotiatedFeatures)
    }

    package func queueNotified(index: Int, context: VirtioDeviceContext) {
        underlying.queueNotified(index: index, context: context)
    }

    package func deviceWillPause() {
        underlying.deviceWillPause()
    }

    package func deviceWillResume() {
        underlying.deviceWillResume()
    }

    package func deviceWillReset() {
        underlying.deviceWillReset()
    }

    package func deviceWillStop() {
        underlying.deviceWillStop()
    }
}
