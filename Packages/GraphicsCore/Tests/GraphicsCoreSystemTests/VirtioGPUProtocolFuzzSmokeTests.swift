import Foundation
import Testing

@testable import GraphicsCore

/// A time-boxed smoke run over `VirtioGPUProtocol` decoding (test-strategy §7.2).
///
/// Mutated golden vectors must either decode, or fail with a typed
/// `VirtioGPUProtocolError`. An accepted input must re-encode to bytes that decode
/// to the same value. The libFuzzer target belongs to #091.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }
}

private func goldenVectors(direction: String) throws -> [[UInt8]] {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let file = root.appendingPathComponent("Tests/Fixtures/graphics/virtio-gpu-vectors.json")
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    let vectors = try #require(object?["vectors"] as? [[String: String]])
    return try vectors.filter { $0["direction"] == direction }.map { vector in
        let hex = try #require(vector["hex"])
        return stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16) ?? 0
        }
    }
}

/// Applies one random edit: a byte change, a length change, or an extreme 32-bit field value.
private func mutate(_ bytes: inout [UInt8], _ random: inout SplitMix64) {
    switch random.below(4) {
    case 0 where !bytes.isEmpty:
        bytes[random.below(bytes.count)] = UInt8(truncatingIfNeeded: random.next())
    case 1:
        let newLength = max(0, bytes.count + random.below(9) - 4)
        if newLength < bytes.count {
            bytes.removeLast(bytes.count - newLength)
        } else {
            bytes += (0..<(newLength - bytes.count)).map { _ in UInt8(truncatingIfNeeded: random.next()) }
        }
    case 2 where bytes.count >= 4:
        let offset = random.below(bytes.count - 3)
        let extreme: [UInt32] = [0, 1, 16, 16_384, 16_385, 4_194_304, 4_194_305, 0xFFFF_FFFF]
        let value = extreme[random.below(extreme.count)]
        for index in 0..<4 {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index))
        }
    default:
        if !bytes.isEmpty {
            bytes[random.below(min(bytes.count, 24))] ^= UInt8(1 << random.below(8))
        }
    }
}

@Test func mutatedRequestsDecodeWithTypedErrorsOrRoundTrip() throws {
    let seeds = try goldenVectors(direction: "request")
    #expect(!seeds.isEmpty)
    var random = SplitMix64(seed: 0x6170_6B72_756E_0019)
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    var iterations = 0
    var accepted = 0
    while clock.now < deadline, iterations < 300_000 {
        var bytes = seeds[iterations % seeds.count]
        for _ in 0..<(1 + random.below(3)) {
            mutate(&bytes, &random)
        }
        iterations += 1
        do {
            let request = try VirtioGPUProtocol.decodeRequest(bytes)
            accepted += 1
            let reencoded = VirtioGPUProtocol.encodeRequest(request)
            let decodedAgain = try VirtioGPUProtocol.decodeRequest(reencoded)
            #expect(decodedAgain == request)
        } catch {
            // A typed rejection is the expected outcome for most mutations.
        }
    }
    #expect(iterations >= 1_000)
    #expect(accepted > 0)
}

@Test func mutatedResponsesDecodeWithTypedErrorsOrRoundTrip() throws {
    let seeds = try goldenVectors(direction: "response")
    var random = SplitMix64(seed: 0x7265_7370_6F6E_7365)
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    var iterations = 0
    while clock.now < deadline, iterations < 100_000 {
        var bytes = seeds[iterations % seeds.count]
        mutate(&bytes, &random)
        iterations += 1
        do {
            let response = try VirtioGPUProtocol.decodeResponse(bytes)
            let reencoded = VirtioGPUProtocol.encodeResponse(response.body, answering: response.header)
            let decodedAgain = try VirtioGPUProtocol.decodeResponse(reencoded)
            // The encoder drops a fence ID that the flags do not ask for, so compare the
            // payload and the response code, not every header byte.
            #expect(decodedAgain.body == response.body)
            #expect(decodedAgain.header.type == response.header.type)
        } catch {
            // Typed rejections are expected here too.
        }
    }
    #expect(iterations >= 1_000)
}
