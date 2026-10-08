import Foundation
import Testing

@testable import GuestProtocol

/// The envelope body kinds that the golden frames must cover, one each (guest-protocol.md §4.1).
private let requiredBodyKinds: Set<String> = [
    "hello", "helloAck", "request", "response", "event", "cancel",
    "inputBatch", "inputAck", "imeCommand", "imeState", "bulk",
]

/// The typed failure that each invalid golden frame must produce.
private let expectedFailures: [String: GuestProtocolFailure] = [
    "invalid-zero-length": .malformedFrame,
    "invalid-oversize": .frameTooLarge,
    "invalid-truncated": .malformedFrame,
    "invalid-malformed": .malformedFrame,
    "invalid-no-body": .malformedFrame,
]

private func bodyKind(of envelope: GPEnvelope) -> String? {
    switch envelope.body {
    case .hello?: "hello"
    case .helloAck?: "helloAck"
    case .request?: "request"
    case .response?: "response"
    case .event?: "event"
    case .cancel?: "cancel"
    case .inputBatch?: "inputBatch"
    case .inputAck?: "inputAck"
    case .imeCommand?: "imeCommand"
    case .imeState?: "imeState"
    case .bulk?: "bulk"
    case nil: nil
    }
}

@Test func goldenValidFramesDecodeAndReencodeByteForByte() throws {
    let names = try GoldenFrames.validNames()
    #expect(names.count >= requiredBodyKinds.count)
    for name in names {
        let frame = try GoldenFrames.frame(named: name)
        let envelope = try FrameCodec.decode(frame)
        let reencoded = try FrameCodec.encode(envelope)
        #expect(reencoded == frame, "\(name) does not re-encode to the same bytes")
    }
}

@Test func goldenValidFramesCoverEveryEnvelopeBodyKind() throws {
    var covered = Set<String>()
    for name in try GoldenFrames.validNames() {
        let envelope = try FrameCodec.decode(try GoldenFrames.frame(named: name))
        if let kind = bodyKind(of: envelope) {
            covered.insert(kind)
        }
    }
    #expect(covered.isSuperset(of: requiredBodyKinds), "missing: \(requiredBodyKinds.subtracting(covered))")
}

@Test func invalidGoldenFramesFailWithTheirTypedError() throws {
    let names = try GoldenFrames.invalidNames()
    #expect(Set(names) == Set(expectedFailures.keys), "every invalid frame needs an expected failure")
    for name in names {
        let frame = try GoldenFrames.frame(named: name)
        do {
            _ = try FrameCodec.decode(frame)
            Issue.record("\(name) decoded, but it must be rejected")
        } catch {
            #expect(error == expectedFailures[name], "\(name) failed with \(error)")
        }
    }
}

@Test func encodingRejectsEmptyAndOversizeBodies() throws {
    do {
        _ = try FrameCodec.frame(body: Data())
        Issue.record("an empty body must be rejected")
    } catch {
        #expect(error == .malformedFrame)
    }

    do {
        _ = try FrameCodec.frame(body: Data(count: FrameCodec.maximumBodySize + 1))
        Issue.record("a body over the limit must be rejected")
    } catch {
        #expect(error == .frameTooLarge)
    }

    let largest = try FrameCodec.frame(body: Data(count: FrameCodec.maximumBodySize))
    #expect(largest.count == FrameCodec.lengthPrefixSize + FrameCodec.maximumBodySize)

    // An envelope with no fields serializes to zero bytes, which is not a valid body.
    do {
        _ = try FrameCodec.encode(GPEnvelope())
        Issue.record("an empty envelope must not produce a frame")
    } catch {
        #expect(error == .malformedFrame)
    }
}

@Test func encodingRejectsAnEnvelopeWithoutABody() throws {
    // The envelope has an id, so its serialized form is not empty. Only the missing body fails.
    var envelope = GPEnvelope()
    envelope.id = 1
    do {
        _ = try FrameCodec.encode(envelope)
        Issue.record("an envelope without a body must not produce a frame")
    } catch {
        #expect(error == .malformedFrame)
    }
}

@Test func lengthPrefixIsBigEndianAndCountsOnlyTheBody() throws {
    let frame = try FrameCodec.frame(body: Data(count: 0x0102))
    #expect(Array(frame.prefix(4)) == [0x00, 0x00, 0x01, 0x02])
    #expect(frame.count == 4 + 0x0102)
}

@Test func streamingDecoderReassemblesEveryValidFrameFromSingleBytes() throws {
    let names = try GoldenFrames.validNames()
    var stream = Data()
    var expectedBodies: [Data] = []
    for name in names {
        let frame = try GoldenFrames.frame(named: name)
        stream.append(frame)
        expectedBodies.append(frame.dropFirst(FrameCodec.lengthPrefixSize))
    }

    var decoder = FrameDecoder()
    var bodies: [Data] = []
    for byte in stream {
        decoder.append(Data([byte]))
        while let body = try decoder.nextBody() {
            bodies.append(body)
        }
    }
    #expect(bodies == expectedBodies)
    #expect(decoder.pendingByteCount == 0)
}

@Test func streamingDecoderRejectsAnOversizeLengthBeforeTheBodyArrives() throws {
    var decoder = FrameDecoder()
    decoder.append(Data([0x00, 0x40, 0x00, 0x01]))
    do {
        _ = try decoder.nextBody()
        Issue.record("the length alone must be enough to reject the frame")
    } catch {
        #expect(error == .frameTooLarge)
    }
}

@Test func streamingDecoderRejectsAZeroLengthPrefix() throws {
    var decoder = FrameDecoder()
    decoder.append(Data([0x00, 0x00, 0x00, 0x00]))
    do {
        _ = try decoder.nextBody()
        Issue.record("a zero length must be rejected")
    } catch {
        #expect(error == .malformedFrame)
    }
}

@Test func streamingDecoderWaitsForTheWholeBodyAndReportsPendingBytes() throws {
    var decoder = FrameDecoder()
    decoder.append(Data([0x00, 0x00, 0x00, 0x0A]))
    decoder.append(Data([1, 2, 3, 4, 5]))
    #expect(try decoder.nextBody() == nil)
    #expect(decoder.pendingByteCount == 9)

    decoder.append(Data([6, 7, 8, 9, 10]))
    #expect(try decoder.nextBody() == Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]))
    #expect(decoder.pendingByteCount == 0)
}

@Test func streamingDecoderReadsManySmallFramesFromOneBufferAndKeepsAPartialTail() throws {
    // 200 000 frames of 100 bytes arrive in one append, a 20 MB buffer. Each frame is consumed
    // without copying the rest of the buffer.
    let frame = try FrameCodec.frame(body: Data(count: 96))
    let count = 200_000
    var stream = Data(capacity: frame.count * count)
    for _ in 0..<count {
        stream.append(frame)
    }
    stream.append(frame.prefix(3))

    var decoder = FrameDecoder()
    decoder.append(stream)
    var bodies = 0
    while try decoder.nextBody() != nil {
        bodies += 1
    }
    #expect(bodies == count)
    #expect(decoder.pendingByteCount == 3)

    decoder.append(frame.dropFirst(3))
    #expect(try decoder.nextBody() == Data(count: 96))
    #expect(decoder.pendingByteCount == 0)
}

@Test func decodeRejectsTrailingBytesAfterTheFrame() throws {
    var frame = try GoldenFrames.frame(named: "valid-cancel")
    frame.append(0x00)
    do {
        _ = try FrameCodec.decode(frame)
        Issue.record("trailing bytes must be rejected")
    } catch {
        #expect(error == .malformedFrame)
    }
}
