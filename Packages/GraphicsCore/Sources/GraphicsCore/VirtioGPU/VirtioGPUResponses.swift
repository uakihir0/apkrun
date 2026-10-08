/// One `virtio_gpu_display_one`: a scanout's rectangle, enable bit, and flags.
struct VirtioGPUDisplayOne: Equatable, Sendable {
    var rect: VirtioGPURect
    var enabled: UInt32
    var flags: UInt32

}

/// The payload of a response, one case per response code in §4.2 and each error.
enum VirtioGPUResponseBody: Equatable, Sendable {
    /// `OK_NODATA`.
    case okNoData
    /// `OK_DISPLAY_INFO`, with exactly `VirtioGPUProtocol.displayInfoEntryCount` entries.
    case okDisplayInfo(modes: [VirtioGPUDisplayOne])
    /// `OK_CAPSET_INFO`.
    case okCapsetInfo(id: UInt32, maxVersion: UInt32, maxSize: UInt32)
    /// `OK_CAPSET`, with the capset bytes.
    case okCapset(data: [UInt8])
    /// `OK_EDID`, with the EDID bytes (at most 1024).
    case okEDID(edid: [UInt8])
    /// An error response.
    case error(VirtioGPUErrorCode)
}

/// A decoded response: its header and payload.
struct VirtioGPUResponse: Equatable, Sendable {
    var header: VirtioGPUControlHeader
    var body: VirtioGPUResponseBody

}

private enum ResponseSize {
    static let okNoData = 24
    static let displayInfo = 24 + VirtioGPUProtocol.displayInfoEntryCount * 24
    static let capsetInfo = 40
    static let edid = 24 + 8 + VirtioGPUProtocol.edidResponseCapacity
}

extension VirtioGPUProtocol {
    /// Encodes a response to `request`. The header echoes the request's context and ring
    /// fields. The fence identifier is echoed only when the request set the fence flag.
    static func encodeResponse(
        _ body: VirtioGPUResponseBody,
        answering request: VirtioGPUControlHeader
    ) -> [UInt8] {
        let type: UInt32
        var writer = VirtioGPUWireWriter(capacity: headerByteCount)
        switch body {
        case .okNoData: type = VirtioGPUResponseType.okNoData.rawValue
        case .okDisplayInfo: type = VirtioGPUResponseType.okDisplayInfo.rawValue
        case .okCapsetInfo: type = VirtioGPUResponseType.okCapsetInfo.rawValue
        case .okCapset: type = VirtioGPUResponseType.okCapset.rawValue
        case .okEDID: type = VirtioGPUResponseType.okEDID.rawValue
        case .error(let code): type = code.rawValue
        }
        VirtioGPUControlHeader(
            type: type,
            flags: request.flags,
            fenceID: request.hasFence ? request.fenceID : 0,
            contextID: request.contextID,
            ringIndex: request.ringIndex
        )
        .encode(into: &writer)

        switch body {
        case .okNoData, .error:
            break
        case .okDisplayInfo(let modes):
            precondition(modes.count == displayInfoEntryCount, "OK_DISPLAY_INFO has one entry per scanout.")
            for mode in modes {
                writer.writeRect(mode.rect)
                writer.writeUInt32(mode.enabled)
                writer.writeUInt32(mode.flags)
            }
        case .okCapsetInfo(let id, let maxVersion, let maxSize):
            writer.writeUInt32(id)
            writer.writeUInt32(maxVersion)
            writer.writeUInt32(maxSize)
            writer.writeZeros(count: 4)
        case .okCapset(let data):
            writer.writeBytes(data)
        case .okEDID(let edid):
            precondition(edid.count <= edidResponseCapacity, "The EDID response holds at most 1024 bytes.")
            writer.writeUInt32(UInt32(edid.count))
            writer.writeZeros(count: 4)
            writer.writeBytes(edid)
            writer.writeZeros(count: edidResponseCapacity - edid.count)
        }
        return writer.bytes
    }

    /// Decodes one response, checking its length against its response code.
    static func decodeResponse(_ bytes: [UInt8]) throws(VirtioGPUProtocolError) -> VirtioGPUResponse {
        let header = try VirtioGPUControlHeader(decodingFrom: bytes)
        var reader = VirtioGPUWireReader(bytes)
        reader.skip(byteCount: headerByteCount)

        if let code = VirtioGPUErrorCode(rawValue: header.type) {
            try requireResponseLength(bytes, headerByteCount, type: header.type)
            return VirtioGPUResponse(header: header, body: .error(code))
        }
        switch VirtioGPUResponseType(rawValue: header.type) {
        case .okNoData:
            try requireResponseLength(bytes, ResponseSize.okNoData, type: header.type)
            return VirtioGPUResponse(header: header, body: .okNoData)
        case .okDisplayInfo:
            try requireResponseLength(bytes, ResponseSize.displayInfo, type: header.type)
            let modes = (0..<displayInfoEntryCount).map { _ in
                VirtioGPUDisplayOne(
                    rect: reader.readRect(),
                    enabled: reader.readUInt32(),
                    flags: reader.readUInt32()
                )
            }
            return VirtioGPUResponse(header: header, body: .okDisplayInfo(modes: modes))
        case .okCapsetInfo:
            try requireResponseLength(bytes, ResponseSize.capsetInfo, type: header.type)
            let id = reader.readUInt32()
            let maxVersion = reader.readUInt32()
            let maxSize = reader.readUInt32()
            return VirtioGPUResponse(
                header: header,
                body: .okCapsetInfo(id: id, maxVersion: maxVersion, maxSize: maxSize)
            )
        case .okCapset:
            guard bytes.count >= headerByteCount else {
                throw .truncated(command: header.type, expectedByteCount: headerByteCount, actualByteCount: bytes.count)
            }
            return VirtioGPUResponse(
                header: header,
                body: .okCapset(data: reader.readBytes(count: bytes.count - headerByteCount))
            )
        case .okEDID:
            try requireResponseLength(bytes, ResponseSize.edid, type: header.type)
            let size = Int(reader.readUInt32())
            guard size <= edidResponseCapacity else {
                throw .invalidField(command: header.type, field: "size")
            }
            reader.skip(byteCount: 4)
            return VirtioGPUResponse(header: header, body: .okEDID(edid: reader.readBytes(count: size)))
        case nil:
            throw .invalidField(command: header.type, field: "type")
        }
    }
}

private func requireResponseLength(
    _ bytes: [UInt8],
    _ expected: Int,
    type: UInt32
) throws(VirtioGPUProtocolError) {
    if bytes.count < expected {
        throw .truncated(command: type, expectedByteCount: expected, actualByteCount: bytes.count)
    }
    if bytes.count > expected {
        throw .oversized(command: type, actualByteCount: bytes.count, limitByteCount: expected)
    }
}
