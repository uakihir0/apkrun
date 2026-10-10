/// A failure of a context command, mapped to a virtio-gpu error response by the device.
enum ContextTableFailure: Error, Equatable, Sendable {
    /// The context ID is zero, already live, or unknown.
    case invalidContextID(UInt32)
    /// The §5.4 limit of live contexts is reached.
    case limitReached

    /// The virtio-gpu error response that this failure maps to (graphics.md §5.4).
    var errorCode: VirtioGPUErrorCode {
        switch self {
        case .invalidContextID:
            .invalidContextID
        case .limitReached:
            .unspec
        }
    }
}

/// The live rendering contexts of the guest (graphics.md §4.2, §5.4). Confined to the device queue.
struct ContextTable: Sendable {
    /// The most contexts that may be live at once (§5.4).
    static let maximumCount = 256

    private var ids: Set<UInt32> = []

    /// The number of live contexts.
    var count: Int {
        ids.count
    }

    /// True when `id` names a live context.
    func contains(_ id: UInt32) -> Bool {
        ids.contains(id)
    }

    /// Records a new context. ID 0 is the default context, which a guest cannot create.
    mutating func create(id: UInt32) throws(ContextTableFailure) {
        guard id != 0, !ids.contains(id) else {
            throw .invalidContextID(id)
        }
        guard ids.count < Self.maximumCount else {
            throw .limitReached
        }
        ids.insert(id)
    }

    /// Forgets a context.
    mutating func destroy(id: UInt32) throws(ContextTableFailure) {
        guard ids.remove(id) != nil else {
            throw .invalidContextID(id)
        }
    }

    /// Forgets every context, as a device reset does.
    mutating func reset() {
        ids.removeAll(keepingCapacity: false)
    }
}
