import Foundation

/// Identifies the Linux kernel format from its leading header bytes.
enum KernelImageInspector {
    static func inspect(_ bytes: Data) -> KernelImageFormat {
        if bytes.starts(with: [0x1F, 0x8B]) {
            return .gzip
        }

        if bytes.starts(with: [0x02, 0x21, 0x4C, 0x18])
            || bytes.starts(with: [0x04, 0x22, 0x4D, 0x18])
        {
            return .lz4
        }

        if bytes.count >= 8,
            bytes[0] == 0x4D,
            bytes[1] == 0x5A,
            Array(bytes[4..<8]) == Array("zimg".utf8)
        {
            return .zboot
        }

        if bytes.count >= 0x3C,
            Array(bytes[0x38..<0x3C]) == [0x41, 0x52, 0x4D, 0x64]
        {
            return .arm64Image
        }

        return .unknown
    }
}
