import Testing

@testable import GraphicsCore

@Test func goldenRequestVectorsDecodeAndReencodeByteForByte() throws {
    let requests = try GraphicsFixtures.virtioGPUVectors().filter { $0.direction == "request" }
    #expect(requests.count == 28)
    for vector in requests {
        let bytes = try vector.bytes
        let request = try VirtioGPUProtocol.decodeRequest(bytes)
        #expect(VirtioGPUProtocol.encodeRequest(request) == bytes, "\(vector.name)")
    }
}

@Test func goldenResponseVectorsDecodeAndReencodeByteForByte() throws {
    let responses = try GraphicsFixtures.virtioGPUVectors().filter { $0.direction == "response" }
    #expect(responses.count == 8)
    for vector in responses {
        let bytes = try vector.bytes
        let response = try VirtioGPUProtocol.decodeResponse(bytes)
        #expect(
            VirtioGPUProtocol.encodeResponse(response.body, answering: response.header) == bytes,
            "\(vector.name)"
        )
    }
}

@Test func everyKnownCommandHasAGoldenRequestVector() throws {
    let vectors = try GraphicsFixtures.virtioGPUVectors().filter { $0.direction == "request" }
    var decodedCommands = Set<VirtioGPUCommand>()
    for vector in vectors {
        let request = try VirtioGPUProtocol.decodeRequest(try vector.bytes)
        if let command = request.header.command {
            decodedCommands.insert(command)
        }
    }
    #expect(decodedCommands == Set(VirtioGPUCommand.allCases))
}

@Test func decodedFieldsMatchTheVirtioGPUHeaderLayout() throws {
    let attach = try VirtioGPUProtocol.decodeRequest(try GraphicsFixtures.vector(named: "resource-attach-backing"))
    #expect(
        attach.body
            == .resourceAttachBacking(
                resourceID: 7,
                entries: [
                    VirtioGPUMemoryEntry(address: 0x8000_0000, length: 0x10_0000),
                    VirtioGPUMemoryEntry(address: 0x8010_0000, length: 0x10_0000),
                ]
            )
    )

    let submit = try VirtioGPUProtocol.decodeRequest(try GraphicsFixtures.vector(named: "submit-3d"))
    #expect(submit.header.contextID == 3)
    #expect(submit.body == .submit3D(commandStream: Array(0..<16)))

    let fenced = try VirtioGPUProtocol.decodeRequest(try GraphicsFixtures.vector(named: "get-display-info-fenced"))
    #expect(fenced.header.hasFence)
    #expect(fenced.header.fenceID == 0x1122_3344_5566_7788)

    let contextCreate = try VirtioGPUProtocol.decodeRequest(try GraphicsFixtures.vector(named: "ctx-create"))
    #expect(contextCreate.body == .ctxCreate(contextInit: 0, debugName: Array("ctx-test".utf8)))

    let cursor = try VirtioGPUProtocol.decodeRequest(try GraphicsFixtures.vector(named: "update-cursor"))
    #expect(
        cursor.body
            == .updateCursor(
                VirtioGPUCursorUpdate(scanoutID: 0, x: 100, y: 200, resourceID: 9, hotX: 4, hotY: 4)
            )
    )
}

@Test func everyFixedLengthRequestRejectsTruncationAtEveryByte() throws {
    for vector in try GraphicsFixtures.virtioGPUVectors() where vector.direction == "request" {
        let bytes = try vector.bytes
        for length in 0..<bytes.count {
            let prefix = Array(bytes.prefix(length))
            #expect(throws: VirtioGPUProtocolError.self, "\(vector.name) truncated to \(length)") {
                _ = try VirtioGPUProtocol.decodeRequest(prefix)
            }
        }
    }
}

@Test func fixedLengthRequestsRejectTrailingBytes() throws {
    for vector in try GraphicsFixtures.virtioGPUVectors() where vector.direction == "request" {
        var bytes = try vector.bytes
        bytes.append(0)
        #expect(throws: VirtioGPUProtocolError.self, "\(vector.name) with one extra byte") {
            _ = try VirtioGPUProtocol.decodeRequest(bytes)
        }
    }
}

@Test func headerTruncationIsReportedAsHeaderTruncation() {
    #expect(throws: VirtioGPUProtocolError.headerTruncated(actualByteCount: 23)) {
        _ = try VirtioGPUProtocol.decodeRequest(Array(repeating: 0, count: 23))
    }
}

@Test func unknownCommandCodesDecodeAsUnsupported() throws {
    let bytes: [UInt8] = [0x99, 0x09, 0, 0] + [UInt8](repeating: 0, count: 20)
    let request = try VirtioGPUProtocol.decodeRequest(bytes)
    #expect(request.header.command == nil)
    #expect(request.body == .unsupported)
    #expect(VirtioGPUProtocol.encodeRequest(request) == bytes)
}

@Test func requestsAboveTheFourMebibyteLimitAreRejected() throws {
    let limit = VirtioGPUProtocol.Limits.maximumRequestByteCount
    var bytes = VirtioGPUControlHeader(type: VirtioGPUCommand.submit3D.rawValue).encodedBytes()
    bytes += [UInt8](repeating: 0, count: limit - bytes.count + 1)
    #expect(throws: VirtioGPUProtocolError.self) {
        _ = try VirtioGPUProtocol.decodeRequest(bytes)
    }
}

@Test func submitRejectsAStreamLargerThanFourMebibytes() throws {
    let size = VirtioGPUProtocol.Limits.maximumSubmitByteCount + 1
    var bytes = VirtioGPUControlHeader(type: VirtioGPUCommand.submit3D.rawValue).encodedBytes()
    bytes += [UInt8(truncatingIfNeeded: size), UInt8(truncatingIfNeeded: size >> 8), 0, 0, 0, 0, 0, 0]
    bytes += [UInt8](repeating: 0, count: size)
    #expect(throws: VirtioGPUProtocolError.self) {
        _ = try VirtioGPUProtocol.decodeRequest(bytes)
    }
}

@Test func attachBackingRejectsMoreThan16384EntriesBeforeReadingThem() throws {
    var bytes = VirtioGPUControlHeader(type: VirtioGPUCommand.resourceAttachBacking.rawValue).encodedBytes()
    let count = UInt32(VirtioGPUProtocol.Limits.maximumBackingEntries + 1)
    bytes += [7, 0, 0, 0]
    bytes += [UInt8(count & 0xFF), UInt8((count >> 8) & 0xFF), 0, 0]
    #expect(throws: VirtioGPUProtocolError.invalidField(command: 0x0106, field: "nr_entries")) {
        _ = try VirtioGPUProtocol.decodeRequest(bytes)
    }
}

@Test func resourceDimensionsOutsideTheLimitAreRejected() throws {
    for dimensions in [(UInt32(0), UInt32(768)), (UInt32(1024), UInt32(8193))] {
        let bytes =
            VirtioGPUControlHeader(type: VirtioGPUCommand.resourceCreate2D.rawValue).encodedBytes()
            + [7, 0, 0, 0, 1, 0, 0, 0]
            + littleEndianBytes(dimensions.0)
            + littleEndianBytes(dimensions.1)
        #expect(throws: VirtioGPUProtocolError.self) {
            _ = try VirtioGPUProtocol.decodeRequest(bytes)
        }
    }
}

@Test func contextDebugNameLongerThan64BytesIsRejected() throws {
    var bytes = VirtioGPUControlHeader(type: VirtioGPUCommand.ctxCreate.rawValue).encodedBytes()
    bytes += [65, 0, 0, 0, 0, 0, 0, 0]
    bytes += [UInt8](repeating: 0x41, count: 64)
    #expect(throws: VirtioGPUProtocolError.invalidField(command: 0x0200, field: "nlen")) {
        _ = try VirtioGPUProtocol.decodeRequest(bytes)
    }
}

@Test func responseHeadersEchoFenceOnlyWhenTheRequestAskedForIt() {
    let fenced = VirtioGPUControlHeader(type: 0x0100, flags: 1, fenceID: 42, contextID: 5, ringIndex: 2)
    let plain = VirtioGPUControlHeader(type: 0x0100, flags: 0, fenceID: 42, contextID: 5, ringIndex: 2)

    let fencedReply = VirtioGPUProtocol.encodeResponse(.okNoData, answering: fenced)
    let plainReply = VirtioGPUProtocol.encodeResponse(.okNoData, answering: plain)

    #expect(fencedReply.count == 24)
    #expect(Array(fencedReply[8..<16]) == [42, 0, 0, 0, 0, 0, 0, 0])
    #expect(Array(plainReply[8..<16]) == [0, 0, 0, 0, 0, 0, 0, 0])
    #expect(Array(plainReply[16..<20]) == [5, 0, 0, 0])
    #expect(plainReply[20] == 2)
}

@Test func unknownResponseCodesAreRejected() {
    let bytes: [UInt8] = [0x99, 0x19, 0, 0] + [UInt8](repeating: 0, count: 20)
    #expect(throws: VirtioGPUProtocolError.invalidField(command: 0x1999, field: "type")) {
        _ = try VirtioGPUProtocol.decodeResponse(bytes)
    }
}

@Test func errorCodesMapToTheirWireValues() {
    #expect(VirtioGPUErrorCode.unspec.rawValue == 0x1200)
    #expect(VirtioGPUErrorCode.invalidScanoutID.rawValue == 0x1202)
    #expect(VirtioGPUErrorCode.invalidResourceID.rawValue == 0x1203)
    #expect(VirtioGPUErrorCode.invalidParameter.rawValue == 0x1205)
    #expect(VirtioGPUCommand.getEDID.rawValue == 0x010A)
    #expect(VirtioGPUCommand.moveCursor.rawValue == 0x0301)
}

extension VirtioGPUControlHeader {
    /// The 24 header bytes, for building test requests by hand.
    fileprivate func encodedBytes() -> [UInt8] {
        var bytes = type.littleEndianBytes + flags.littleEndianBytes
        bytes += (0..<8).map { UInt8(truncatingIfNeeded: fenceID >> (8 * $0)) }
        bytes += contextID.littleEndianBytes
        bytes += [ringIndex, 0, 0, 0]
        return bytes
    }
}

private func littleEndianBytes(_ value: UInt32) -> [UInt8] {
    value.littleEndianBytes
}

extension UInt32 {
    fileprivate var littleEndianBytes: [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: self >> (8 * $0)) }
    }
}
