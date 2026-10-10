/// The §5.4 limits that `ResourceTable` enforces before any renderer call.
struct ResourceTableLimits: Equatable, Sendable {
    /// The total host memory estimate of all live resources (2 GiB).
    var totalBytes: UInt64 = 2 * 1024 * 1024 * 1024
    /// The size of one resource (256 MiB).
    var singleResourceBytes: UInt64 = 256 * 1024 * 1024
    /// The largest width or height of a texture. Buffers are sized in bytes, not by this limit.
    var maximumDimension: UInt32 = VirtioGPUProtocol.Limits.maximumDimension
    /// The number of live resources.
    var liveResourceCount = 65_536
    /// The number of backing entries in one attach request.
    var maximumBackingEntries = VirtioGPUProtocol.Limits.maximumBackingEntries

    init() {}
}

/// The block layout of one pixel format: a block of `blockWidth` × `blockHeight` pixels
/// takes `bytesPerBlock` bytes. Uncompressed formats use 1 × 1 blocks.
struct PixelLayout: Equatable, Sendable {
    let blockWidth: UInt32
    let blockHeight: UInt32
    let bytesPerBlock: UInt32

    /// The bytes of one row of `pixels` pixels. A 32-bit pixel count cannot overflow `UInt64` here.
    func rowBytes(pixels: UInt32) -> UInt64 {
        let blocks = (UInt64(pixels) + UInt64(blockWidth) - 1) / UInt64(blockWidth)
        return blocks * UInt64(bytesPerBlock)
    }

    /// The bytes of `rows` rows of pixel blocks.
    func rowCount(_ rows: UInt32) -> UInt64 {
        (UInt64(rows) + UInt64(blockHeight) - 1) / UInt64(blockHeight)
    }
}

/// What kind of host resource a guest ID names (graphics.md §4.4).
enum GPUResourceKind: Equatable, Sendable {
    /// A 2D resource of the `guestSwiftshader` profile: host memory only.
    case host2D
    /// A resource created with `RESOURCE_CREATE_3D` (or `RESOURCE_CREATE_2D` under VirGL).
    case virgl(target: UInt32)
}

/// A live resource and its guest backing.
struct GPUResource: Equatable, Sendable {
    let id: UInt32
    let kind: GPUResourceKind
    let format: UInt32
    let width: UInt32
    let height: UInt32
    let depth: UInt32
    let arraySize: UInt32
    /// The highest mip level that transfers may address.
    let lastLevel: UInt32
    let layout: PixelLayout

    /// The PIPE target of the resource: 2 for a 2D resource.
    var target: UInt32 {
        switch kind {
        case .host2D:
            2
        case .virgl(let target):
            target
        }
    }

    /// True for the array and cube targets, whose layers are `arraySize`, not depth (graphics.md §4.4).
    var isArrayLike: Bool {
        [4, 5, 7, 8].contains(target)  // PIPE_TEXTURE_CUBE, 1D_ARRAY, 2D_ARRAY, and CUBE_ARRAY.
    }

    /// The guest ranges attached with `RESOURCE_ATTACH_BACKING`. Empty until attached.
    var backing: [VirtioGPUMemoryEntry]
    /// The host memory estimate of the resource: its level-0 bytes, times depth and layers.
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

/// The resource table: IDs, format and size limits, and backing validation.
///
/// The table is confined to the device queue. It never calls the renderer, so
/// host memory is only estimated here. The renderer owns the GPU side.
struct ResourceTable: Sendable {
    /// The virtio-gpu format codes of the 32-bit 2D formats the device accepts (graphics.md §6.2).
    static let supported2DFormats: Set<UInt32> = [
        1,  // B8G8R8A8_UNORM
        2,  // B8G8R8X8_UNORM
        3,  // A8R8G8B8_UNORM
        4,  // X8R8G8B8_UNORM
        67,  // R8G8B8A8_UNORM
        68,  // X8B8G8R8_UNORM
        121,  // A8B8G8R8_UNORM
        134,  // R8G8B8X8_UNORM
    ]

    /// The highest texture target: PIPE_TEXTURE_CUBE_ARRAY (8). Target 0 is PIPE_BUFFER.
    static let maximumTarget: UInt32 = 8
    /// The highest mip level of a texture no larger than 8192 pixels (levels 0 through 13).
    static let maximumLastLevel: UInt32 = 13
    /// The largest sample count the table accepts.
    static let maximumSampleCount: UInt32 = 16

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

    /// Creates a 2D host-memory resource, the `guestSwiftshader` profile's form of `RESOURCE_CREATE_2D`.
    mutating func createHost2D(
        id: UInt32,
        format: UInt32,
        width: UInt32,
        height: UInt32
    ) throws(ResourceTableFailure) {
        guard id != 0, resources[id] == nil else {
            throw .invalidResourceID(id)
        }
        guard Self.supported2DFormats.contains(format) else {
            throw .invalidParameter(field: "format")
        }
        try insert(
            id: id,
            kind: .host2D,
            format: format,
            target: 2,
            width: width,
            height: height,
            depth: 1,
            arraySize: 1,
            lastLevel: 0
        )
    }

    /// Creates a 2D resource that the renderer owns, the VirGL form of `RESOURCE_CREATE_2D`.
    mutating func createVirgl2D(
        id: UInt32,
        format: UInt32,
        width: UInt32,
        height: UInt32
    ) throws(ResourceTableFailure) {
        guard id != 0, resources[id] == nil else {
            throw .invalidResourceID(id)
        }
        guard Self.supported2DFormats.contains(format) else {
            throw .invalidParameter(field: "format")
        }
        try insert(
            id: id,
            kind: .virgl(target: 2),
            format: format,
            target: 2,
            width: width,
            height: height,
            depth: 1,
            arraySize: 1,
            lastLevel: 0
        )
    }

    /// Creates a resource from `RESOURCE_CREATE_3D`. Buffers (target 0) are sized in bytes.
    mutating func create3D(
        _ arguments: VirtioGPUResourceCreate3D
    ) throws(ResourceTableFailure) {
        let id = arguments.resourceID
        guard id != 0, resources[id] == nil else {
            throw .invalidResourceID(id)
        }
        guard arguments.target <= Self.maximumTarget else {
            throw .invalidParameter(field: "target")
        }
        if arguments.target != 0 {
            guard arguments.lastLevel <= Self.maximumLastLevel else {
                throw .invalidParameter(field: "lastLevel")
            }
            guard arguments.sampleCount <= Self.maximumSampleCount else {
                throw .invalidParameter(field: "nrSamples")
            }
        }
        try insert(
            id: id,
            kind: .virgl(target: arguments.target),
            format: arguments.format,
            target: arguments.target,
            width: arguments.width,
            height: arguments.height,
            depth: arguments.depth,
            arraySize: arguments.arraySize,
            lastLevel: arguments.lastLevel
        )
    }

    /// Validates a resource's size and format, then records it. Nothing changes on failure.
    private mutating func insert(
        id: UInt32,
        kind: GPUResourceKind,
        format: UInt32,
        target: UInt32,
        width: UInt32,
        height: UInt32,
        depth: UInt32,
        arraySize: UInt32,
        lastLevel: UInt32
    ) throws(ResourceTableFailure) {
        guard let layout = Self.layout(format: format) else {
            throw .invalidParameter(field: "format")
        }
        let byteEstimate: UInt64
        if target == 0 {
            // A buffer: width is its size in bytes, and the other dimensions are one.
            guard width >= 1, height == 1, depth == 1, arraySize == 1, lastLevel == 0 else {
                throw .invalidParameter(field: "size")
            }
            byteEstimate = UInt64(width) * UInt64(layout.bytesPerBlock)
        } else {
            for (field, value) in [("width", width), ("height", height), ("depth", depth), ("arraySize", arraySize)] {
                guard (1...limits.maximumDimension).contains(value) else {
                    throw .invalidParameter(field: field)
                }
            }
            byteEstimate = try Self.textureBytes(
                width: width, height: height, depth: depth, arraySize: arraySize, layout: layout)
        }
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
            kind: kind,
            format: format,
            width: width,
            height: height,
            depth: depth,
            arraySize: arraySize,
            lastLevel: lastLevel,
            layout: layout,
            backing: [],
            byteEstimate: byteEstimate
        )
        estimatedByteCount += byteEstimate
    }

    /// The level-0 bytes of a texture, with checked `UInt64` arithmetic.
    static func textureBytes(
        width: UInt32,
        height: UInt32,
        depth: UInt32,
        arraySize: UInt32,
        layout: PixelLayout
    ) throws(ResourceTableFailure) -> UInt64 {
        let rowBytes = layout.rowBytes(pixels: width)
        let rows = layout.rowCount(height)
        let (plane, planeOverflow) = rowBytes.multipliedReportingOverflow(by: rows)
        guard !planeOverflow else { throw .invalidParameter(field: "size") }
        let (volume, volumeOverflow) = plane.multipliedReportingOverflow(by: UInt64(depth))
        guard !volumeOverflow else { throw .invalidParameter(field: "size") }
        let (total, totalOverflow) = volume.multipliedReportingOverflow(by: UInt64(arraySize))
        guard !totalOverflow else { throw .invalidParameter(field: "size") }
        return total
    }

    /// The block layout of a format the table accepts, or `nil` for any other format.
    static func layout(format: UInt32) -> PixelLayout? {
        if let bytes = uncompressedBytesPerPixel[format] {
            return PixelLayout(blockWidth: 1, blockHeight: 1, bytesPerBlock: bytes)
        }
        if let bytes = compressedBytesPerBlock[format] {
            return PixelLayout(blockWidth: 4, blockHeight: 4, bytesPerBlock: bytes)
        }
        return nil
    }

    /// Uncompressed formats of the VirGL format list (`virgl_hw.h`), with their bytes per pixel.
    private static let uncompressedBytesPerPixel: [UInt32: UInt32] = [
        // The 32-bit 2D formats, then the other colour and depth formats of common use.
        1: 4, 2: 4, 3: 4, 4: 4, 5: 2, 6: 2, 7: 2, 8: 4,
        9: 1, 10: 1, 11: 1, 12: 2, 13: 2, 16: 2, 17: 4, 18: 4,
        19: 4, 20: 4, 21: 4, 22: 4, 23: 1, 24: 8, 25: 16, 26: 24, 27: 32,
        28: 4, 29: 8, 30: 12, 31: 16, 32: 4, 33: 8, 34: 12, 35: 16,
        40: 4, 41: 8, 42: 12, 43: 16,
        48: 2, 49: 4, 50: 6, 51: 8, 56: 2, 57: 4, 58: 6, 59: 8,
        64: 1, 65: 2, 66: 3, 67: 4, 68: 4,
        74: 1, 75: 2, 76: 3, 77: 4,
        91: 2, 92: 4, 93: 6, 94: 8,
        95: 1, 96: 2, 97: 3, 98: 4, 99: 4, 100: 4, 101: 4, 102: 4, 103: 4, 104: 4,
        121: 4, 122: 2, 124: 4, 125: 4, 130: 1, 131: 4, 134: 4, 135: 2,
        139: 1, 140: 4, 141: 2, 142: 2, 147: 1, 148: 1, 149: 2, 150: 1,
        151: 2, 152: 2, 153: 4, 154: 2, 155: 2, 156: 2, 157: 4, 158: 2,
        159: 4, 160: 4, 161: 8, 162: 4, 168: 1, 169: 1, 170: 2, 171: 2,
    ]

    /// Block-compressed formats (4 × 4 blocks), with their bytes per block.
    private static let compressedBytesPerBlock: [UInt32: UInt32] = [
        105: 8, 106: 8, 107: 16, 108: 16, 109: 8, 110: 8, 111: 16, 112: 16,
        113: 8, 114: 8, 115: 16, 116: 16, 143: 8, 144: 8, 145: 16, 146: 16,
    ]

    /// Destroys the resource with `id` and releases its host memory estimate.
    mutating func unref(id: UInt32) throws(ResourceTableFailure) {
        guard let resource = resources.removeValue(forKey: id) else {
            throw .invalidResourceID(id)
        }
        estimatedByteCount -= resource.byteEstimate
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

    /// Clears every resource, as a device reset does.
    mutating func reset() {
        resources.removeAll(keepingCapacity: false)
        estimatedByteCount = 0
    }
}
