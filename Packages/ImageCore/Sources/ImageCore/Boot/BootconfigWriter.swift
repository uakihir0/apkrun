import Foundation

/// One key of a merged bootconfig and the layer that set it (diagnostics).
public struct BootconfigEntry: Equatable, Sendable {
    /// The bootconfig key.
    public var key: String
    /// The key's value.
    public var value: String
    /// The layer that set the value.
    public var layer: String
}

/// One ordered source of bootconfig keys (android-image.md §6.1).
struct BootconfigLayer: Equatable, Sendable {
    var name: String
    var values: [String: String]
    /// Keys this layer may change from an earlier layer.
    var overrides: Set<String> = []
}

/// Merges the bootconfig layers and builds the initrd trailer (android-image.md §6.1, §6.3).
///
/// The Swift side of `Images/tools/apkrun_image/bootconfig.py`; both are pinned to the
/// golden vectors in `Images/tools/tests/fixtures/bootconfig/`.
enum BootconfigWriter {
    static let magic = Data("#BOOTCONFIG\n".utf8)
    /// The kernel's limit for the whole block.
    static let maximumKernelSize = 32 * 1024
    /// The kernel parser's node limit.
    static let maximumNodes = 1024

    /// Why a bootconfig source or merge is invalid.
    enum Failure: Error, Equatable {
        case invalid(String)
        case conflict(key: String, layerA: String, layerB: String)
        case tooLarge(Int)
    }

    /// Parses `key = value` or `key = "value"` lines, with `#` comments.
    static func parse(_ text: String, layer: String) throws(Failure) -> [String: String] {
        guard text.allSatisfy(\.isASCII) else {
            throw .invalid("bootconfig input in \(layer) must be ASCII")
        }
        var values: [String: String] = [:]
        for (number, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: " "))
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            guard let equals = line.firstIndex(of: "=") else {
                throw .invalid("bootconfig line \(number + 1) in \(layer) is missing '='")
            }
            let key = line[..<equals].trimmingCharacters(in: CharacterSet(charactersIn: " "))
            let rawValue = line[line.index(after: equals)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " "))
            let value: String
            if let quote = rawValue.first, quote == "\"" || quote == "'" {
                let rest = rawValue.dropFirst()
                guard let closing = rest.firstIndex(of: quote) else {
                    throw .invalid("bootconfig line \(number + 1) in \(layer) has unmatched quotes")
                }
                value = String(rest[..<closing])
                let remainder = rest[rest.index(after: closing)...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " "))
                guard remainder.isEmpty || remainder.hasPrefix("#") else {
                    throw .invalid("bootconfig line \(number + 1) in \(layer) has text after a quoted value")
                }
            } else {
                value = String(rawValue.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " "))
                guard !value.contains(","), !value.contains(";") else {
                    throw .invalid("bootconfig line \(number + 1) in \(layer) uses array or statement syntax")
                }
            }
            try validate(key: key, value: value)
            if let existing = values[key], existing != value {
                throw .conflict(key: key, layerA: layer, layerB: layer)
            }
            values[key] = value
        }
        return values
    }

    /// Parses `boot/bootconfig.txt`: a `[vendor]` and an `[image]` section (runtime-image-manifest.md §3.2).
    static func parseSections(_ text: String) throws(Failure) -> (vendor: [String: String], image: [String: String]) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let vendorIndex = lines.firstIndex(of: "[vendor]"),
            let imageIndex = lines.firstIndex(of: "[image]"),
            vendorIndex == 0, vendorIndex < imageIndex
        else {
            throw .invalid("bootconfig.txt needs a [vendor] section and then an [image] section")
        }
        let vendor = lines[(vendorIndex + 1)..<imageIndex].joined(separator: "\n")
        let image = lines[(imageIndex + 1)...].joined(separator: "\n")
        return (try parse(vendor, layer: "vendor"), try parse(image, layer: "image"))
    }

    /// Merges layers in order. A key set again with a different value needs an override.
    static func merge(_ layers: [BootconfigLayer]) throws(Failure) -> [BootconfigEntry] {
        var values: [String: (value: String, layer: String)] = [:]
        for layer in layers {
            let priorKeys = Set(values.keys)
            for key in layer.overrides where layer.values[key] == nil || !priorKeys.contains(key) {
                throw .invalid("override for \(key) in layer \(layer.name) has no earlier value")
            }
            for (key, value) in layer.values.sorted(by: { $0.key < $1.key }) {
                try validate(key: key, value: value)
                if let existing = values[key] {
                    if existing.value == value {
                        continue
                    }
                    guard layer.overrides.contains(key) else {
                        throw .conflict(key: key, layerA: existing.layer, layerB: layer.name)
                    }
                }
                values[key] = (value, layer.name)
            }
        }
        let entries = values.map { BootconfigEntry(key: $0.key, value: $0.value.value, layer: $0.value.layer) }
            .sorted { $0.key < $1.key }
        guard nodeCount(entries.map(\.key)) <= maximumNodes else {
            throw .tooLarge(serialize(entries).count)
        }
        return entries
    }

    /// The canonical text: sorted keys, `key = "value"` lines.
    static func serialize(_ entries: [BootconfigEntry]) -> Data {
        var text = ""
        for entry in entries.sorted(by: { $0.key < $1.key }) {
            text += "\(entry.key) = \"\(entry.value)\"\n"
        }
        return Data(text.utf8)
    }

    /// `[text][NUL padding to 4 bytes][size le32][checksum le32]["#BOOTCONFIG\n"]` (§6.3).
    static func trailer(for block: Data, commandLine: String) throws(Failure) -> Data {
        var tokens = commandLine.split(separator: " ").map(String.init)
        if let separator = tokens.firstIndex(of: "--") {
            tokens = Array(tokens[..<separator])
        }
        guard tokens.contains("bootconfig") else {
            throw .invalid("the kernel command line must contain the bootconfig token")
        }
        var padded = block
        padded.append(contentsOf: [UInt8](repeating: 0, count: (4 - block.count % 4) % 4))
        guard padded.count <= maximumKernelSize else {
            throw .tooLarge(padded.count)
        }
        let checksum = padded.reduce(UInt32(0)) { $0 &+ UInt32($1) }
        var result = padded
        withUnsafeBytes(of: UInt32(padded.count).littleEndian) { result.append(contentsOf: $0) }
        withUnsafeBytes(of: checksum.littleEndian) { result.append(contentsOf: $0) }
        result.append(magic)
        return result
    }

    private static func validate(key: String, value: String) throws(Failure) {
        let keyAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
        guard !key.isEmpty, key.unicodeScalars.allSatisfy(keyAllowed.contains),
            !key.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty)
        else {
            throw .invalid("invalid bootconfig key: \(key)")
        }
        guard value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7E && $0 != "\"" && $0 != "\\" })
        else {
            throw .invalid("bootconfig value for \(key) must be printable ASCII without quotes or backslashes")
        }
    }

    private static func nodeCount(_ keys: [String]) -> Int {
        var nodes = Set<[Substring]>()
        for key in keys {
            let components = key.split(separator: ".")
            for length in 1...components.count {
                nodes.insert(Array(components[..<length]))
            }
        }
        return nodes.count + keys.count
    }
}

extension BootconfigWriter.Failure {
    /// The ImageCore failure for a bootconfig built before a boot.
    var imageFailure: ImageFailure {
        switch self {
        case .invalid(let reason):
            .manifestInvalid(path: "boot/bootconfig.txt", reason: reason)
        case .conflict(let key, let layerA, let layerB):
            .bootconfigConflict(key: key, layerA: layerA, layerB: layerB)
        case .tooLarge(let size):
            .bootconfigTooLarge(size: size)
        }
    }
}
