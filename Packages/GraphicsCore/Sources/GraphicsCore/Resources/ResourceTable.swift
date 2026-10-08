/// The §5.4 limits that `ResourceTable` enforces before any renderer call.
struct ResourceTableLimits: Equatable, Sendable {
    /// The total host memory estimate of all live resources (2 GiB).
    var totalBytes: UInt64 = 2 * 1024 * 1024 * 1024
    /// The size of one resource (256 MiB).
    var singleResourceBytes: UInt64 = 256 * 1024 * 1024
    /// The largest width or height of a resource.
    var maximumDimension: UInt32 = VirtioGPUProtocol.Limits.maximumDimension
    /// The number of live resources.
    var liveResourceCount = 65_536
    /// The number of backing entries in one attach request.
    var maximumBackingEntries = VirtioGPUProtocol.Limits.maximumBackingEntries

    init() {}
}

/// A 2D host-memory resource and its guest backing (graphics.md §4.4).
struct GPUResource: Equatable, Sendable {
    let id: UInt32
    let format: UInt32
    let width: UInt32
    let height: UInt32
    /// The guest ranges attached with `RESOURCE_ATTACH_BACKING`. Empty until attached.
    internal(set) var backing: [VirtioGPUMemoryEntry]
    /// The host memory estimate of the resource (`width × height × bytesPerPixel`).
    let byteEstimate: UInt64
}

/// The result of a validation failure, mapped to a virtio-gpu error response by the device.
enum ResourceTableFailure: Error, Equatable, Sendable {
    /// The ID is zero, duplicated, or unknown.
    case invalidResourceID(UInt32)
    /// A field is outside its valid range. `field` names it.
    case invalidParameter(field: String)
    /// A §5.4 memory or count limit would be exceeded. `limit` names it.
    case outOfMemory(limit: String)

    /// The virtio-gpu error response that this failure maps to.
    var errorCode: VirtioGPUErrorCode {
        switch self {
        case .invalidResourceID:
            .invalidResourceID
        case .invalidParameter:
            .invalidParameter
        case .outOfMemory:
            .outOfMemory
        }
    }
}

/// The 2D resource table: IDs, format and size limits, and backing validation.
///
/// The table is confined to the device queue. It has no renderer, so host
/// memory for resources is only estimated here. Commands that create or attach
/// resources get error responses until the renderer exists (#022).
struct ResourceTable: Sendable {
    /// The virtio-gpu format codes of the 32-bit 2D formats the device accepts (graphics.md §6.2).
    static let supportedFormats: Set<UInt32> = [
        1,  // B8G8R8A8_UNORM
        2,  // B8G8R8X8_UNORM
        3,  // A8R8G8B8_UNORM
        4,  // X8R8G8B8_UNORM
        67,  // R8G8B8A8_UNORM
        68,  // X8B8G8R8_UNORM
        121,  // A8B8G8R8_UNORM
        134,  // R8G8B8X8_UNORM
    ]

    /// The bytes per pixel of every supported format.
    static let bytesPerPixel: UInt64 = 4

    let limits: ResourceTableLimits
    private var resources: [UInt32: GPUResource] = [:]
    /// The host memory estimate of every live resource.
    private(set) var estimatedByteCount: UInt64 = 0

    /// Creates an empty table with the given limits.
    init(limits: ResourceTableLimits = ResourceTableLimits()) {
        self.limits = limits
    }

    /// The number of live resources.
    var count: Int {
        resources.count
    }

    /// The resource with `id`, or `nil`.
    func resource(id: UInt32) -> GPUResource? {
        resources[id]
    }

    /// Creates a 2D host-memory resource. Its size is checked with `UInt64` arithmetic.
    mutating func createHost2D(
        id: UInt32,
        format: UInt32,
        width: UInt32,
        height: UInt32
    ) throws(ResourceTableFailure) {
        guard id != 0, resources[id] == nil else {
            throw .invalidResourceID(id)
        }
        guard Self.supportedFormats.contains(format) else {
            throw .invalidParameter(field: "format")
        }
        guard (1...limits.maximumDimension).contains(width) else {
            throw .invalidParameter(field: "width")
        }
        guard (1...limits.maximumDimension).contains(height) else {
            throw .invalidParameter(field: "height")
        }
        let byteEstimate = UInt64(width) * UInt64(height) * Self.bytesPerPixel
        guard byteEstimate <= limits.singleResourceBytes else {
            throw .outOfMemory(limit: "singleResource")
        }
        guard resources.count < limits.liveResourceCount else {
            throw .outOfMemory(limit: "liveResources")
        }
        guard estimatedByteCount + byteEstimate <= limits.totalBytes else {
            throw .outOfMemory(limit: "totalBytes")
        }
        resources[id] = GPUResource(
            id: id,
            format: format,
            width: width,
            height: height,
            backing: [],
            byteEstimate: byteEstimate
        )
        estimatedByteCount += byteEstimate
    }

    /// Validates and records guest backing for `id`. Nothing changes when validation fails.
    ///
    /// Each entry must be non-empty, must not wrap the 64-bit address space, and
    /// must lie in guest memory as `isInGuestMemory` reports. The total length must cover the
    /// resource's bytes. Attaching backing to a resource that already has backing fails.
    mutating func attachBacking(
        id: UInt32,
        entries: [VirtioGPUMemoryEntry],
        isInGuestMemory: (VirtioGPUMemoryEntry) -> Bool
    ) throws(ResourceTableFailure) {
        guard let resource = resources[id] else {
            throw .invalidResourceID(id)
        }
        guard resource.backing.isEmpty else {
            throw .invalidParameter(field: "backing")
        }
        guard !entries.isEmpty, entries.count <= limits.maximumBackingEntries else {
            throw .invalidParameter(field: "entries")
        }
        var totalLength: UInt64 = 0
        for entry in entries {
            guard entry.length > 0 else {
                throw .invalidParameter(field: "entry.length")
            }
            guard !entry.address.addingReportingOverflow(UInt64(entry.length)).overflow else {
                throw .invalidParameter(field: "entry.address")
            }
            guard isInGuestMemory(entry) else {
                throw .invalidParameter(field: "entry.address")
            }
            totalLength += UInt64(entry.length)
        }
        guard totalLength >= resource.byteEstimate else {
            throw .invalidParameter(field: "entry.length")
        }
        resources[id]?.backing = entries
    }

    /// Removes the guest backing of `id`. The resource itself stays.
    mutating func detachBacking(id: UInt32) throws(ResourceTableFailure) {
        guard resources[id] != nil else {
            throw .invalidResourceID(id)
        }
        resources[id]?.backing = []
    }

    /// Destroys the resource with `id` and releases its host memory estimate.
    mutating func unref(id: UInt32) throws(ResourceTableFailure) {
        guard let resource = resources.removeValue(forKey: id) else {
            throw .invalidResourceID(id)
        }
        estimatedByteCount -= resource.byteEstimate
    }

    /// Clears every resource, as a device reset does.
    mutating func reset() {
        resources.removeAll(keepingCapacity: false)
        estimatedByteCount = 0
    }
}
