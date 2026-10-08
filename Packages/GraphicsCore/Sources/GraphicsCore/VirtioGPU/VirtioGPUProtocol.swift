/// Constants of the virtio-gpu control protocol (virtio 1.2 §5.7, Linux `virtio_gpu.h`).
///
/// The device identity, command codes, and limits follow
/// [graphics.md](../../../../../docs/02-design/graphics.md) §4.1, §4.2, and §5.4.
enum VirtioGPUProtocol {
    /// The virtio device type of a GPU device.
    static let deviceID: UInt16 = 16
    /// The PCI class code the device reports (`0x03`, display controller).
    static let pciClass: UInt8 = 0x03
    /// The PCI subclass code the device reports, as RiftVM does.
    static let pciSubclass: UInt8 = 0x80
    /// The index of the control queue (`controlq`).
    static let controlQueueIndex = 0
    /// The index of the cursor queue (`cursorq`).
    static let cursorQueueIndex = 1
    /// The number of virtqueues the device exposes.
    static let queueCount: UInt16 = 2
    /// The number of scanouts in the configuration space (the virtio-gpu maximum).
    static let scanoutCount = 16
    /// The size of the `virtio_gpu_ctrl_hdr` that starts every request and response.
    static let headerByteCount = 24
    /// The size of `virtio_gpu_config`.
    static let configurationByteCount = 16
    /// The size of one EDID base block.
    static let edidByteCount = 128
    /// The fixed EDID payload size of `virtio_gpu_resp_edid`.
    static let edidResponseCapacity = 1024
    /// The number of `virtio_gpu_display_one` entries in `OK_DISPLAY_INFO`.
    static let displayInfoEntryCount = scanoutCount

    /// Header flags.
    enum Flag {
        /// The response must not be returned before the fence completes.
        static let fence: UInt32 = 1 << 0
    }

    /// Bits of `events_read` and `events_clear`.
    enum Event {
        /// A display configuration change occurred.
        static let display: UInt32 = 1 << 0
    }

    /// Feature bits offered or negotiated by the device.
    enum Feature {
        /// `VIRTIO_GPU_F_VIRGL`, offered only with the renderer (#022).
        static let virgl: UInt64 = 1 << 0
        /// `VIRTIO_GPU_F_EDID`.
        static let edid: UInt64 = 1 << 1
        /// `VIRTIO_GPU_F_RESOURCE_UUID`, not offered in v1.
        static let resourceUUID: UInt64 = 1 << 2
        /// `VIRTIO_GPU_F_RESOURCE_BLOB`, not offered in v1.
        static let resourceBlob: UInt64 = 1 << 3
        /// `VIRTIO_GPU_F_CONTEXT_INIT`, not offered in v1.
        static let contextInit: UInt64 = 1 << 4
    }

    /// The limits that decoding enforces before any field is used (§5.4).
    enum Limits {
        /// The largest request, which is a 4 MiB `SUBMIT_3D` payload plus its header.
        static let maximumRequestByteCount = maximumSubmitByteCount + 32
        /// The largest `SUBMIT_3D` command stream.
        static let maximumSubmitByteCount = 4 * 1024 * 1024
        /// The largest number of backing entries in one attach or blob request.
        static let maximumBackingEntries = 16_384
        /// The largest width or height of a resource.
        static let maximumDimension: UInt32 = 8_192
        /// The longest context debug name.
        static let maximumDebugNameByteCount = 64
    }
}

/// A command code from the request side of the control or cursor queue.
enum VirtioGPUCommand: UInt32, Sendable, CaseIterable {
    case getDisplayInfo = 0x0100
    case resourceCreate2D = 0x0101
    case resourceUnref = 0x0102
    case setScanout = 0x0103
    case resourceFlush = 0x0104
    case transferToHost2D = 0x0105
    case resourceAttachBacking = 0x0106
    case resourceDetachBacking = 0x0107
    case getCapsetInfo = 0x0108
    case getCapset = 0x0109
    case getEDID = 0x010a
    case resourceAssignUUID = 0x010b
    case resourceCreateBlob = 0x010c
    case setScanoutBlob = 0x010d
    case ctxCreate = 0x0200
    case ctxDestroy = 0x0201
    case ctxAttachResource = 0x0202
    case ctxDetachResource = 0x0203
    case resourceCreate3D = 0x0204
    case transferToHost3D = 0x0205
    case transferFromHost3D = 0x0206
    case submit3D = 0x0207
    case resourceMapBlob = 0x0208
    case resourceUnmapBlob = 0x0209
    case updateCursor = 0x0300
    case moveCursor = 0x0301
}

/// A response code (`VIRTIO_GPU_RESP_*` successes).
enum VirtioGPUResponseType: UInt32, Sendable {
    case okNoData = 0x1100
    case okDisplayInfo = 0x1101
    case okCapsetInfo = 0x1102
    case okCapset = 0x1103
    case okEDID = 0x1104
}

/// An error response code (`VIRTIO_GPU_RESP_ERR_*`).
enum VirtioGPUErrorCode: UInt32, Sendable {
    case unspec = 0x1200
    case outOfMemory = 0x1201
    case invalidScanoutID = 0x1202
    case invalidResourceID = 0x1203
    case invalidContextID = 0x1204
    case invalidParameter = 0x1205
}

/// The `virtio_gpu_ctrl_hdr` that starts every request and response.
struct VirtioGPUControlHeader: Equatable, Sendable {
    /// The raw command or response code. Unknown codes are kept, not rejected.
    var type: UInt32
    /// Header flags such as ``VirtioGPUProtocol/Flag/fence``.
    var flags: UInt32
    /// The fence identifier, meaningful only with the fence flag.
    var fenceID: UInt64
    /// The rendering context, or zero.
    var contextID: UInt32
    /// The ring index, or zero.
    var ringIndex: UInt8

    /// Creates a header with explicit field values.
    init(
        type: UInt32,
        flags: UInt32 = 0,
        fenceID: UInt64 = 0,
        contextID: UInt32 = 0,
        ringIndex: UInt8 = 0
    ) {
        self.type = type
        self.flags = flags
        self.fenceID = fenceID
        self.contextID = contextID
        self.ringIndex = ringIndex
    }

    /// The known command for this header, or `nil` when the code is not in §4.2.
    var command: VirtioGPUCommand? {
        VirtioGPUCommand(rawValue: type)
    }

    /// Whether the request asks for its response to wait on a fence.
    var hasFence: Bool {
        flags & VirtioGPUProtocol.Flag.fence != 0
    }

    /// Decodes the first 24 bytes of `bytes`.
    init(decodingFrom bytes: [UInt8]) throws(VirtioGPUProtocolError) {
        guard bytes.count >= VirtioGPUProtocol.headerByteCount else {
            throw .headerTruncated(actualByteCount: bytes.count)
        }
        var reader = VirtioGPUWireReader(bytes)
        type = reader.readUInt32()
        flags = reader.readUInt32()
        fenceID = reader.readUInt64()
        contextID = reader.readUInt32()
        ringIndex = reader.readUInt8()
    }

    func encode(into writer: inout VirtioGPUWireWriter) {
        writer.writeUInt32(type)
        writer.writeUInt32(flags)
        writer.writeUInt64(fenceID)
        writer.writeUInt32(contextID)
        writer.writeUInt8(ringIndex)
        writer.writeZeros(count: 3)
    }
}

/// A structural failure while decoding a guest request or response.
///
/// These errors never leave the device as Swift errors. A malformed request
/// receives a virtio-gpu error response, and the device logs it with a rate limit.
enum VirtioGPUProtocolError: Error, Equatable, Sendable {
    /// The buffer is shorter than the 24-byte header.
    case headerTruncated(actualByteCount: Int)
    /// The request is shorter than its command requires.
    case truncated(command: UInt32, expectedByteCount: Int, actualByteCount: Int)
    /// The request is longer than its command allows, or exceeds a §5.4 limit.
    case oversized(command: UInt32, actualByteCount: Int, limitByteCount: Int)
    /// A field is outside its valid range. `field` names the field.
    case invalidField(command: UInt32, field: String)
}
