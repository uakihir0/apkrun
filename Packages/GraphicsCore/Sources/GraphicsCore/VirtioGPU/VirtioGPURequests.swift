/// A decoded control or cursor request: its header and typed body.
struct VirtioGPURequest: Equatable, Sendable {
    /// The `virtio_gpu_ctrl_hdr` of the request.
    var header: VirtioGPUControlHeader
    /// The command-specific fields.
    var body: VirtioGPURequestBody

    /// Creates a request from its parts.
}

/// The command-specific fields of a request, one case per command in §4.2.
///
/// `unsupported` carries a command code that is not in §4.2. It has no fields.
enum VirtioGPURequestBody: Equatable, Sendable {
    case getDisplayInfo
    case getEDID(scanout: UInt32)
    case resourceCreate2D(resourceID: UInt32, format: UInt32, width: UInt32, height: UInt32)
    case resourceUnref(resourceID: UInt32)
    case setScanout(rect: VirtioGPURect, scanoutID: UInt32, resourceID: UInt32)
    case resourceFlush(rect: VirtioGPURect, resourceID: UInt32)
    case transferToHost2D(rect: VirtioGPURect, offset: UInt64, resourceID: UInt32)
    case resourceAttachBacking(resourceID: UInt32, entries: [VirtioGPUMemoryEntry])
    case resourceDetachBacking(resourceID: UInt32)
    case getCapsetInfo(index: UInt32)
    case getCapset(id: UInt32, version: UInt32)
    case resourceAssignUUID(resourceID: UInt32)
    case resourceCreateBlob(VirtioGPUResourceCreateBlob)
    case setScanoutBlob(VirtioGPUSetScanoutBlob)
    case ctxCreate(contextInit: UInt32, debugName: [UInt8])
    case ctxDestroy
    case ctxAttachResource(resourceID: UInt32)
    case ctxDetachResource(resourceID: UInt32)
    case resourceCreate3D(VirtioGPUResourceCreate3D)
    case transferToHost3D(VirtioGPUTransfer3D)
    case transferFromHost3D(VirtioGPUTransfer3D)
    case submit3D(commandStream: [UInt8])
    case resourceMapBlob(resourceID: UInt32, offset: UInt64)
    case resourceUnmapBlob(resourceID: UInt32)
    case updateCursor(VirtioGPUCursorUpdate)
    case moveCursor(VirtioGPUCursorUpdate)
    case unsupported
}

/// One `virtio_gpu_mem_entry`: a guest-physical range that backs a resource.
struct VirtioGPUMemoryEntry: Equatable, Sendable {
    var address: UInt64
    var length: UInt32

}

/// A three-dimensional box (`virtio_gpu_box`).
struct VirtioGPUBox: Equatable, Sendable {
    var x: UInt32
    var y: UInt32
    var z: UInt32
    var width: UInt32
    var height: UInt32
    var depth: UInt32

}

/// `virtio_gpu_resource_create_3d`.
struct VirtioGPUResourceCreate3D: Equatable, Sendable {
    var resourceID: UInt32
    var target: UInt32
    var format: UInt32
    var bind: UInt32
    var width: UInt32
    var height: UInt32
    var depth: UInt32
    var arraySize: UInt32
    var lastLevel: UInt32
    var sampleCount: UInt32
    var flags: UInt32

}

/// `virtio_gpu_transfer_host_3d`, used by both transfer directions.
struct VirtioGPUTransfer3D: Equatable, Sendable {
    var box: VirtioGPUBox
    var offset: UInt64
    var resourceID: UInt32
    var level: UInt32
    var stride: UInt32
    var layerStride: UInt32

}

/// `virtio_gpu_resource_create_blob` with its memory entries.
struct VirtioGPUResourceCreateBlob: Equatable, Sendable {
    var resourceID: UInt32
    var blobMemory: UInt32
    var blobFlags: UInt32
    var blobID: UInt64
    var size: UInt64
    var entries: [VirtioGPUMemoryEntry]

}

/// `virtio_gpu_set_scanout_blob`. The four strides and offsets are per plane.
struct VirtioGPUSetScanoutBlob: Equatable, Sendable {
    var rect: VirtioGPURect
    var scanoutID: UInt32
    var resourceID: UInt32
    var width: UInt32
    var height: UInt32
    var format: UInt32
    var strides: [UInt32]
    var offsets: [UInt32]

}

/// `virtio_gpu_update_cursor`, which `MOVE_CURSOR` also uses.
struct VirtioGPUCursorUpdate: Equatable, Sendable {
    var scanoutID: UInt32
    var x: UInt32
    var y: UInt32
    var resourceID: UInt32
    var hotX: UInt32
    var hotY: UInt32

}

// Wire sizes of the fixed-length requests, in bytes, including the 24-byte header.
private enum RequestSize {
    static let getDisplayInfo = 24
    static let resourceCreate2D = 40
    static let resourceUnref = 32
    static let setScanout = 48
    static let resourceFlush = 48
    static let transferToHost2D = 56
    static let attachBackingFixed = 32
    static let memoryEntry = 16
    static let detachBacking = 32
    static let getCapsetInfo = 32
    static let getCapset = 32
    static let getEDID = 32
    static let assignUUID = 32
    static let createBlobFixed = 56
    static let setScanoutBlob = 96
    static let ctxCreate = 96
    static let ctxDestroy = 24
    static let ctxResource = 32
    static let createResource3D = 72
    static let transfer3D = 72
    static let submit3DFixed = 32
    static let mapBlob = 40
    static let unmapBlob = 32
    static let cursor = 56
}

extension VirtioGPUProtocol {
    /// Decodes one request, checking its length and the §5.4 limits before any field is used.
    ///
    /// Fixed-length commands must match their length exactly. Unknown command
    /// codes decode to `unsupported` so the device can answer them.
    static func decodeRequest(_ bytes: [UInt8]) throws(VirtioGPUProtocolError) -> VirtioGPURequest {
        let header = try VirtioGPUControlHeader(decodingFrom: bytes)
        guard bytes.count <= Limits.maximumRequestByteCount else {
            throw .oversized(
                command: header.type,
                actualByteCount: bytes.count,
                limitByteCount: Limits.maximumRequestByteCount
            )
        }
        guard let command = header.command else {
            return VirtioGPURequest(header: header, body: .unsupported)
        }

        var reader = VirtioGPUWireReader(bytes)
        reader.skip(byteCount: VirtioGPUProtocol.headerByteCount)
        let body: VirtioGPURequestBody
        switch command {
        case .getDisplayInfo:
            try requireLength(bytes, RequestSize.getDisplayInfo, command: header.type)
            body = .getDisplayInfo
        case .getEDID:
            try requireLength(bytes, RequestSize.getEDID, command: header.type)
            body = .getEDID(scanout: reader.readUInt32())
        case .resourceCreate2D:
            try requireLength(bytes, RequestSize.resourceCreate2D, command: header.type)
            let resourceID = reader.readUInt32()
            let format = reader.readUInt32()
            let width = reader.readUInt32()
            let height = reader.readUInt32()
            try requireDimension(width, field: "width", command: header.type)
            try requireDimension(height, field: "height", command: header.type)
            body = .resourceCreate2D(resourceID: resourceID, format: format, width: width, height: height)
        case .resourceUnref:
            try requireLength(bytes, RequestSize.resourceUnref, command: header.type)
            body = .resourceUnref(resourceID: reader.readUInt32())
        case .setScanout:
            try requireLength(bytes, RequestSize.setScanout, command: header.type)
            let rect = reader.readRect()
            let scanoutID = reader.readUInt32()
            body = .setScanout(rect: rect, scanoutID: scanoutID, resourceID: reader.readUInt32())
        case .resourceFlush:
            try requireLength(bytes, RequestSize.resourceFlush, command: header.type)
            let rect = reader.readRect()
            body = .resourceFlush(rect: rect, resourceID: reader.readUInt32())
        case .transferToHost2D:
            try requireLength(bytes, RequestSize.transferToHost2D, command: header.type)
            let rect = reader.readRect()
            let offset = reader.readUInt64()
            body = .transferToHost2D(rect: rect, offset: offset, resourceID: reader.readUInt32())
        case .resourceAttachBacking:
            let entries = try decodeCountedEntries(
                &reader,
                bytes: bytes,
                fixedLength: RequestSize.attachBackingFixed,
                command: header.type
            )
            body = .resourceAttachBacking(resourceID: entries.resourceID, entries: entries.entries)
        case .resourceDetachBacking:
            try requireLength(bytes, RequestSize.detachBacking, command: header.type)
            body = .resourceDetachBacking(resourceID: reader.readUInt32())
        case .getCapsetInfo:
            try requireLength(bytes, RequestSize.getCapsetInfo, command: header.type)
            body = .getCapsetInfo(index: reader.readUInt32())
        case .getCapset:
            try requireLength(bytes, RequestSize.getCapset, command: header.type)
            let id = reader.readUInt32()
            body = .getCapset(id: id, version: reader.readUInt32())
        case .resourceAssignUUID:
            try requireLength(bytes, RequestSize.assignUUID, command: header.type)
            body = .resourceAssignUUID(resourceID: reader.readUInt32())
        case .resourceCreateBlob:
            body = .resourceCreateBlob(try decodeCreateBlob(&reader, bytes: bytes, command: header.type))
        case .setScanoutBlob:
            try requireLength(bytes, RequestSize.setScanoutBlob, command: header.type)
            let rect = reader.readRect()
            let scanoutID = reader.readUInt32()
            let resourceID = reader.readUInt32()
            let width = reader.readUInt32()
            let height = reader.readUInt32()
            let format = reader.readUInt32()
            reader.skip(byteCount: 4)
            let strides = (0..<4).map { _ in reader.readUInt32() }
            let offsets = (0..<4).map { _ in reader.readUInt32() }
            body = .setScanoutBlob(
                VirtioGPUSetScanoutBlob(
                    rect: rect,
                    scanoutID: scanoutID,
                    resourceID: resourceID,
                    width: width,
                    height: height,
                    format: format,
                    strides: strides,
                    offsets: offsets
                )
            )
        case .ctxCreate:
            try requireLength(bytes, RequestSize.ctxCreate, command: header.type)
            let nameLength = reader.readUInt32()
            guard nameLength <= UInt32(Limits.maximumDebugNameByteCount) else {
                throw .invalidField(command: header.type, field: "nlen")
            }
            let contextInit = reader.readUInt32()
            let name = reader.readBytes(count: Limits.maximumDebugNameByteCount)
            body = .ctxCreate(contextInit: contextInit, debugName: Array(name.prefix(Int(nameLength))))
        case .ctxDestroy:
            try requireLength(bytes, RequestSize.ctxDestroy, command: header.type)
            body = .ctxDestroy
        case .ctxAttachResource:
            try requireLength(bytes, RequestSize.ctxResource, command: header.type)
            body = .ctxAttachResource(resourceID: reader.readUInt32())
        case .ctxDetachResource:
            try requireLength(bytes, RequestSize.ctxResource, command: header.type)
            body = .ctxDetachResource(resourceID: reader.readUInt32())
        case .resourceCreate3D:
            try requireLength(bytes, RequestSize.createResource3D, command: header.type)
            let resource = VirtioGPUResourceCreate3D(
                resourceID: reader.readUInt32(),
                target: reader.readUInt32(),
                format: reader.readUInt32(),
                bind: reader.readUInt32(),
                width: reader.readUInt32(),
                height: reader.readUInt32(),
                depth: reader.readUInt32(),
                arraySize: reader.readUInt32(),
                lastLevel: reader.readUInt32(),
                sampleCount: reader.readUInt32(),
                flags: reader.readUInt32()
            )
            reader.skip(byteCount: 4)
            // The size limits depend on the target (buffers are sized in bytes), so
            // ResourceTable checks them, not the decoder.
            body = .resourceCreate3D(resource)
        case .transferToHost3D:
            try requireLength(bytes, RequestSize.transfer3D, command: header.type)
            body = .transferToHost3D(readTransfer3D(&reader))
        case .transferFromHost3D:
            try requireLength(bytes, RequestSize.transfer3D, command: header.type)
            body = .transferFromHost3D(readTransfer3D(&reader))
        case .submit3D:
            let stream = try decodeSubmit(&reader, bytes: bytes, command: header.type)
            body = .submit3D(commandStream: stream)
        case .resourceMapBlob:
            try requireLength(bytes, RequestSize.mapBlob, command: header.type)
            let resourceID = reader.readUInt32()
            reader.skip(byteCount: 4)
            body = .resourceMapBlob(resourceID: resourceID, offset: reader.readUInt64())
        case .resourceUnmapBlob:
            try requireLength(bytes, RequestSize.unmapBlob, command: header.type)
            body = .resourceUnmapBlob(resourceID: reader.readUInt32())
        case .updateCursor:
            try requireLength(bytes, RequestSize.cursor, command: header.type)
            body = .updateCursor(readCursor(&reader))
        case .moveCursor:
            try requireLength(bytes, RequestSize.cursor, command: header.type)
            body = .moveCursor(readCursor(&reader))
        }
        return VirtioGPURequest(header: header, body: body)
    }

    /// Encodes a request with zero padding. Round-tripping a decoded request
    /// reproduces its bytes when its padding was zero.
    static func encodeRequest(_ request: VirtioGPURequest) -> [UInt8] {
        var writer = VirtioGPUWireWriter(capacity: headerByteCount)
        request.header.encode(into: &writer)
        switch request.body {
        case .getDisplayInfo, .ctxDestroy, .unsupported:
            break
        case .getEDID(let scanout):
            writer.writeUInt32(scanout)
            writer.writeZeros(count: 4)
        case .resourceCreate2D(let resourceID, let format, let width, let height):
            writer.writeUInt32(resourceID)
            writer.writeUInt32(format)
            writer.writeUInt32(width)
            writer.writeUInt32(height)
        case .resourceUnref(let resourceID):
            writer.writeUInt32(resourceID)
            writer.writeZeros(count: 4)
        case .setScanout(let rect, let scanoutID, let resourceID):
            writer.writeRect(rect)
            writer.writeUInt32(scanoutID)
            writer.writeUInt32(resourceID)
        case .resourceFlush(let rect, let resourceID):
            writer.writeRect(rect)
            writer.writeUInt32(resourceID)
            writer.writeZeros(count: 4)
        case .transferToHost2D(let rect, let offset, let resourceID):
            writer.writeRect(rect)
            writer.writeUInt64(offset)
            writer.writeUInt32(resourceID)
            writer.writeZeros(count: 4)
        case .resourceAttachBacking(let resourceID, let entries):
            writer.writeUInt32(resourceID)
            writer.writeUInt32(UInt32(entries.count))
            writeEntries(entries, into: &writer)
        case .resourceDetachBacking(let resourceID), .resourceAssignUUID(let resourceID):
            writer.writeUInt32(resourceID)
            writer.writeZeros(count: 4)
        case .getCapsetInfo(let index):
            writer.writeUInt32(index)
            writer.writeZeros(count: 4)
        case .getCapset(let id, let version):
            writer.writeUInt32(id)
            writer.writeUInt32(version)
        case .resourceCreateBlob(let blob):
            writer.writeUInt32(blob.resourceID)
            writer.writeUInt32(blob.blobMemory)
            writer.writeUInt32(blob.blobFlags)
            writer.writeUInt32(UInt32(blob.entries.count))
            writer.writeUInt64(blob.blobID)
            writer.writeUInt64(blob.size)
            writeEntries(blob.entries, into: &writer)
        case .setScanoutBlob(let blob):
            writer.writeRect(blob.rect)
            writer.writeUInt32(blob.scanoutID)
            writer.writeUInt32(blob.resourceID)
            writer.writeUInt32(blob.width)
            writer.writeUInt32(blob.height)
            writer.writeUInt32(blob.format)
            writer.writeZeros(count: 4)
            writeFixedPlanes(blob.strides, into: &writer)
            writeFixedPlanes(blob.offsets, into: &writer)
        case .ctxCreate(let contextInit, let debugName):
            writer.writeUInt32(UInt32(debugName.count))
            writer.writeUInt32(contextInit)
            writer.writeBytes(debugName)
            writer.writeZeros(count: Limits.maximumDebugNameByteCount - debugName.count)
        case .ctxAttachResource(let resourceID), .ctxDetachResource(let resourceID):
            writer.writeUInt32(resourceID)
            writer.writeZeros(count: 4)
        case .resourceCreate3D(let resource):
            writer.writeUInt32(resource.resourceID)
            writer.writeUInt32(resource.target)
            writer.writeUInt32(resource.format)
            writer.writeUInt32(resource.bind)
            writer.writeUInt32(resource.width)
            writer.writeUInt32(resource.height)
            writer.writeUInt32(resource.depth)
            writer.writeUInt32(resource.arraySize)
            writer.writeUInt32(resource.lastLevel)
            writer.writeUInt32(resource.sampleCount)
            writer.writeUInt32(resource.flags)
            writer.writeZeros(count: 4)
        case .transferToHost3D(let transfer), .transferFromHost3D(let transfer):
            writeTransfer3D(transfer, into: &writer)
        case .submit3D(let commandStream):
            writer.writeUInt32(UInt32(commandStream.count))
            writer.writeZeros(count: 4)
            writer.writeBytes(commandStream)
        case .resourceMapBlob(let resourceID, let offset):
            writer.writeUInt32(resourceID)
            writer.writeZeros(count: 4)
            writer.writeUInt64(offset)
        case .resourceUnmapBlob(let resourceID):
            writer.writeUInt32(resourceID)
            writer.writeZeros(count: 4)
        case .updateCursor(let cursor), .moveCursor(let cursor):
            writer.writeUInt32(cursor.scanoutID)
            writer.writeUInt32(cursor.x)
            writer.writeUInt32(cursor.y)
            writer.writeZeros(count: 4)
            writer.writeUInt32(cursor.resourceID)
            writer.writeUInt32(cursor.hotX)
            writer.writeUInt32(cursor.hotY)
            writer.writeZeros(count: 4)
        }
        return writer.bytes
    }
}

private func requireLength(
    _ bytes: [UInt8],
    _ expected: Int,
    command: UInt32
) throws(VirtioGPUProtocolError) {
    if bytes.count < expected {
        throw .truncated(command: command, expectedByteCount: expected, actualByteCount: bytes.count)
    }
    if bytes.count > expected {
        throw .oversized(command: command, actualByteCount: bytes.count, limitByteCount: expected)
    }
}

private func requireDimension(
    _ value: UInt32,
    field: String,
    command: UInt32
) throws(VirtioGPUProtocolError) {
    guard value >= 1, value <= VirtioGPUProtocol.Limits.maximumDimension else {
        throw .invalidField(command: command, field: field)
    }
}

/// Decodes `resource_id` and `nr_entries`, then the entry list, with the exact total length.
private func decodeCountedEntries(
    _ reader: inout VirtioGPUWireReader,
    bytes: [UInt8],
    fixedLength: Int,
    command: UInt32
) throws(VirtioGPUProtocolError) -> (resourceID: UInt32, entries: [VirtioGPUMemoryEntry]) {
    guard bytes.count >= fixedLength else {
        throw .truncated(command: command, expectedByteCount: fixedLength, actualByteCount: bytes.count)
    }
    let resourceID = reader.readUInt32()
    let count = reader.readUInt32()
    guard count <= UInt32(VirtioGPUProtocol.Limits.maximumBackingEntries) else {
        throw .invalidField(command: command, field: "nr_entries")
    }
    let expected = fixedLength + Int(count) * RequestSize.memoryEntry
    try requireLength(bytes, expected, command: command)
    let entries = (0..<Int(count)).map { _ in
        VirtioGPUMemoryEntry(address: reader.readUInt64(), length: readEntryLength(&reader))
    }
    return (resourceID, entries)
}

/// Decodes `resource_create_blob`: its fixed blob fields, then `nr_entries` memory entries.
private func decodeCreateBlob(
    _ reader: inout VirtioGPUWireReader,
    bytes: [UInt8],
    command: UInt32
) throws(VirtioGPUProtocolError) -> VirtioGPUResourceCreateBlob {
    guard bytes.count >= RequestSize.createBlobFixed else {
        throw .truncated(
            command: command,
            expectedByteCount: RequestSize.createBlobFixed,
            actualByteCount: bytes.count
        )
    }
    let resourceID = reader.readUInt32()
    let blobMemory = reader.readUInt32()
    let blobFlags = reader.readUInt32()
    let count = reader.readUInt32()
    guard count <= UInt32(VirtioGPUProtocol.Limits.maximumBackingEntries) else {
        throw .invalidField(command: command, field: "nr_entries")
    }
    let blobID = reader.readUInt64()
    let size = reader.readUInt64()
    try requireLength(
        bytes,
        RequestSize.createBlobFixed + Int(count) * RequestSize.memoryEntry,
        command: command
    )
    let entries = (0..<Int(count)).map { _ in
        VirtioGPUMemoryEntry(address: reader.readUInt64(), length: readEntryLength(&reader))
    }
    return VirtioGPUResourceCreateBlob(
        resourceID: resourceID,
        blobMemory: blobMemory,
        blobFlags: blobFlags,
        blobID: blobID,
        size: size,
        entries: entries
    )
}

/// Reads the length field of a memory entry and skips its padding.
private func readEntryLength(_ reader: inout VirtioGPUWireReader) -> UInt32 {
    let length = reader.readUInt32()
    reader.skip(byteCount: 4)
    return length
}

private func decodeSubmit(
    _ reader: inout VirtioGPUWireReader,
    bytes: [UInt8],
    command: UInt32
) throws(VirtioGPUProtocolError) -> [UInt8] {
    guard bytes.count >= RequestSize.submit3DFixed else {
        throw .truncated(
            command: command,
            expectedByteCount: RequestSize.submit3DFixed,
            actualByteCount: bytes.count
        )
    }
    let size = Int(reader.readUInt32())
    reader.skip(byteCount: 4)
    guard size <= VirtioGPUProtocol.Limits.maximumSubmitByteCount else {
        throw .oversized(
            command: command,
            actualByteCount: size,
            limitByteCount: VirtioGPUProtocol.Limits.maximumSubmitByteCount
        )
    }
    try requireLength(bytes, RequestSize.submit3DFixed + size, command: command)
    return reader.readBytes(count: size)
}

private func readTransfer3D(_ reader: inout VirtioGPUWireReader) -> VirtioGPUTransfer3D {
    let box = VirtioGPUBox(
        x: reader.readUInt32(),
        y: reader.readUInt32(),
        z: reader.readUInt32(),
        width: reader.readUInt32(),
        height: reader.readUInt32(),
        depth: reader.readUInt32()
    )
    return VirtioGPUTransfer3D(
        box: box,
        offset: reader.readUInt64(),
        resourceID: reader.readUInt32(),
        level: reader.readUInt32(),
        stride: reader.readUInt32(),
        layerStride: reader.readUInt32()
    )
}

private func writeTransfer3D(_ transfer: VirtioGPUTransfer3D, into writer: inout VirtioGPUWireWriter) {
    writer.writeUInt32(transfer.box.x)
    writer.writeUInt32(transfer.box.y)
    writer.writeUInt32(transfer.box.z)
    writer.writeUInt32(transfer.box.width)
    writer.writeUInt32(transfer.box.height)
    writer.writeUInt32(transfer.box.depth)
    writer.writeUInt64(transfer.offset)
    writer.writeUInt32(transfer.resourceID)
    writer.writeUInt32(transfer.level)
    writer.writeUInt32(transfer.stride)
    writer.writeUInt32(transfer.layerStride)
}

private func readCursor(_ reader: inout VirtioGPUWireReader) -> VirtioGPUCursorUpdate {
    let scanoutID = reader.readUInt32()
    let x = reader.readUInt32()
    let y = reader.readUInt32()
    reader.skip(byteCount: 4)
    let resourceID = reader.readUInt32()
    let hotX = reader.readUInt32()
    let hotY = reader.readUInt32()
    reader.skip(byteCount: 4)
    return VirtioGPUCursorUpdate(
        scanoutID: scanoutID,
        x: x,
        y: y,
        resourceID: resourceID,
        hotX: hotX,
        hotY: hotY
    )
}

private func writeEntries(_ entries: [VirtioGPUMemoryEntry], into writer: inout VirtioGPUWireWriter) {
    for entry in entries {
        writer.writeUInt64(entry.address)
        writer.writeUInt32(entry.length)
        writer.writeZeros(count: 4)
    }
}

private func writeFixedPlanes(_ planes: [UInt32], into writer: inout VirtioGPUWireWriter) {
    for index in 0..<4 {
        writer.writeUInt32(index < planes.count ? planes[index] : 0)
    }
}
