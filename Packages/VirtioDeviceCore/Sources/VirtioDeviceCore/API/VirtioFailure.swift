/// An internal failure while handling a custom virtio device.
///
/// Device models translate these failures into their own error domain before
/// presenting an error to a user.
public enum VirtioFailure: Error, Equatable, Sendable {
    /// The guest has not completed feature negotiation.
    case notReady

    /// The device does not expose this queue.
    case queueIndexInvalid(Int)

    /// A guest physical range has zero length, overflows, or cannot be mapped.
    case guestMemoryRangeInvalid

    /// A guest-memory view has been invalidated by reset or stop.
    case guestMemoryInvalidated

    /// An access falls outside the mapped guest-memory view.
    case guestMemoryAccessOutOfBounds(offset: Int, length: Int, capacity: Int)

    /// The framework rejected a same-sized configuration update.
    case configurationUpdateFailed(domain: String, code: Int)

    /// The framework rejected an operation on a virtqueue element.
    case queueElementAccessFailed(domain: String, code: Int)

    /// The requested device-specific configuration has a different byte count.
    case configSizeMismatch(expected: Int, actual: Int)

    /// The feature bit appears in both the mandatory and optional sets.
    case featureSetsOverlap
}
