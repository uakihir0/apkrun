import Foundation

/// Events reported asynchronously by a virtual machine and its attachments.
public enum VirtualMachineEvent: Equatable, Sendable {
    /// The guest shut itself down.
    case guestDidStop

    /// Virtualization.framework stopped the VM because of an error.
    case didStopWithError(VZErrorInfo)

    /// The network attachment was disconnected by the framework.
    case networkAttachmentDisconnected(VZErrorInfo)
}

/// The asynchronous lifecycle surface used by `VMController`.
public protocol VirtualMachineDriver: Sendable {
    /// Events from the VM delegate and its configured devices.
    var events: AsyncStream<VirtualMachineEvent> { get }

    /// Starts the guest.
    func start() async throws(VZErrorInfo)

    /// Force-stops a running or paused guest.
    func stop() async throws(VZErrorInfo)

    /// Requests that the guest shut itself down.
    func requestStop() async throws(VZErrorInfo)

    /// Pauses a running guest.
    func pause() async throws(VZErrorInfo)

    /// Resumes a paused guest.
    func resume() async throws(VZErrorInfo)

    /// Releases framework objects on the VM queue.
    func release() async
}

package protocol VirtualMachineDriverFactory: Sendable {
    func makeDriver(
        for definition: VMDefinition,
        consoleChannels: [ConsoleChannel]
    ) async throws(VZErrorInfo) -> any VirtualMachineDriver
}
