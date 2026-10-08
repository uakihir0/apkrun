import Foundation
import Testing

/// Golden graphics fixtures under `Tests/Fixtures/graphics/` at the repository root.
enum GraphicsFixtures {
    struct Vector: Decodable {
        let name: String
        let direction: String
        let queue: String
        let hex: String

        var bytes: [UInt8] {
            get throws {
                try hexBytes(hex)
            }
        }
    }

    private struct VectorFile: Decodable {
        let vectors: [Vector]
    }

    /// One exchange captured from the Linux driver. `response` is `nil` when the element got none.
    struct TraceRecord: Decodable {
        let queue: String
        let request: String
        let response: String?
    }

    private struct TraceFile: Decodable {
        let records: [TraceRecord]
    }

    static func linuxDriverTrace() throws -> [TraceRecord] {
        let data = try Data(contentsOf: url("virtio-gpu-linux-trace.json"))
        return try JSONDecoder().decode(TraceFile.self, from: data).records
    }

    static func url(_ relativePath: String) -> URL {
        // This file is Packages/GraphicsCore/Tests/GraphicsCoreTests/GraphicsFixtures.swift.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            root.deleteLastPathComponent()
        }
        return root.appendingPathComponent("Tests/Fixtures/graphics").appendingPathComponent(relativePath)
    }

    static func virtioGPUVectors() throws -> [Vector] {
        let data = try Data(contentsOf: url("virtio-gpu-vectors.json"))
        return try JSONDecoder().decode(VectorFile.self, from: data).vectors
    }

    static func vector(named name: String) throws -> [UInt8] {
        let found = try virtioGPUVectors().first { $0.name == name }
        return try #require(found).bytes
    }

    static func edid(named name: String) throws -> [UInt8] {
        Array(try Data(contentsOf: url("edid/\(name)")))
    }

    static func hexBytes(_ hex: String) throws -> [UInt8] {
        guard hex.count.isMultiple(of: 2) else {
            throw HexError.oddLength
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw HexError.invalidDigit
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    enum HexError: Error {
        case oddLength
        case invalidDigit
    }
}
