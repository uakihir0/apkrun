/// The transport RuntimeCore uses to open Guest Agent channels in development mode.
public enum GuestAgentTransportMode: Equatable, Sendable {
    /// Connect through an ADB forward to the guest's abstract sockets.
    case adb
    /// Connect directly to the Guest Agent's virtio-vsock ports.
    case vsock
}
