import Foundation

/// Byte-level checks of `manifest.json` that `JSONDecoder` does not make.
///
/// `JSONDecoder` keeps the first of two equal keys, and Python's `json` keeps the last. A
/// document that repeats a key would therefore mean different things to the two readers
/// (runtime-image-manifest.md §11). A byte-order mark is refused for the same reason, because
/// the Python reader does not take one.
enum RuntimeImageManifestJSON {
    /// The first problem with the bytes, or nil. Malformed JSON is left to the decoder.
    static func firstProblem(in data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return "must not start with a byte-order mark"
        }
        var scanner = KeyScanner(bytes: [UInt8](data))
        do {
            try scanner.value()
            return nil
        } catch let failure as KeyScanner.Failure {
            if case .duplicate(let key) = failure {
                return "repeats the key \(key)"
            }
            return nil
        } catch {
            return nil
        }
    }
}

/// Walks the JSON structure and tracks the keys of each object.
private struct KeyScanner {
    enum Failure: Error {
        case duplicate(String)
        case malformed
    }

    let bytes: [UInt8]
    var index = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    private var peek: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private mutating func skipSpace() {
        while let byte = peek, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            index += 1
        }
    }

    mutating func value() throws {
        skipSpace()
        switch peek {
        case UInt8(ascii: "{"):
            try object()
        case UInt8(ascii: "["):
            try array()
        case UInt8(ascii: "\""):
            _ = try string()
        case .some:
            try token()
        case nil:
            throw Failure.malformed
        }
    }

    private mutating func object() throws {
        index += 1
        var keys: Set<String> = []
        skipSpace()
        if peek == UInt8(ascii: "}") {
            index += 1
            return
        }
        while true {
            skipSpace()
            guard peek == UInt8(ascii: "\"") else {
                throw Failure.malformed
            }
            let key = try string()
            guard keys.insert(key).inserted else {
                throw Failure.duplicate(key)
            }
            skipSpace()
            guard peek == UInt8(ascii: ":") else {
                throw Failure.malformed
            }
            index += 1
            try value()
            skipSpace()
            switch peek {
            case UInt8(ascii: ","):
                index += 1
            case UInt8(ascii: "}"):
                index += 1
                return
            default:
                throw Failure.malformed
            }
        }
    }

    private mutating func array() throws {
        index += 1
        skipSpace()
        if peek == UInt8(ascii: "]") {
            index += 1
            return
        }
        while true {
            try value()
            skipSpace()
            switch peek {
            case UInt8(ascii: ","):
                index += 1
            case UInt8(ascii: "]"):
                index += 1
                return
            default:
                throw Failure.malformed
            }
        }
    }

    /// Reads one string and returns its decoded value, so that `a` and `a` are one key.
    private mutating func string() throws -> String {
        let start = index
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\\") {
                index += 2
                continue
            }
            index += 1
            if byte == UInt8(ascii: "\"") {
                let token = Data(bytes[start..<index])
                guard
                    let decoded = try? JSONSerialization.jsonObject(
                        with: token, options: .fragmentsAllowed
                    ) as? String
                else {
                    throw Failure.malformed
                }
                return decoded
            }
        }
        throw Failure.malformed
    }

    /// Skips a number, `true`, `false`, or `null`.
    private mutating func token() throws {
        let start = index
        while let byte = peek,
            !(byte == UInt8(ascii: ",") || byte == UInt8(ascii: "]")
                || byte == UInt8(ascii: "}") || byte == 0x20 || byte == 0x09 || byte == 0x0A
                || byte == 0x0D)
        {
            index += 1
        }
        guard index > start else {
            throw Failure.malformed
        }
    }
}
