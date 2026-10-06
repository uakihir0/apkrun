/// A change that lets live health reporting re-evaluate `vm.network`.
public enum VMNetworkHealthState: Equatable, Sendable {
    /// No network attachment failure has been observed.
    case available

    /// Virtualization.framework reported that the NAT attachment disconnected.
    case disconnected(domain: String, code: Int)
}
