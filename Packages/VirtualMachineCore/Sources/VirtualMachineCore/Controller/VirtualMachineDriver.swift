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

/// A vsock connect failure supplied by the driver.
public enum VirtualMachineDriverConnectFailure: Error, Equatable, Sendable {
    /// The VM does not expose its configured virtio-vsock device.
    case vsockDeviceUnavailable

    /// Virtualization.framework rejected the connection.
    case virtualization(VZErrorInfo)
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

    /// Opens a host-to-guest vsock connection.
    func connect(
        toPort port: UInt32,
        completion:
            @escaping @Sendable (
                Result<VsockConnection, VirtualMachineDriverConnectFailure>
            ) -> Void
    )

    /// Releases framework objects on the VM queue.
    func release() async
}

package protocol VirtualMachineDriverFactory: Sendable {
    func makeDriver(
        for definition: VMDefinition,
        consoleChannels: [ConsoleChannel]
    ) async throws(VZErrorInfo) -> any VirtualMachineDriver
}
