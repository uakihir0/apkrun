import Foundation

@testable import APKStoreCore

/// libFuzzer entry points of APKStoreCore (test-strategy.md §7.2, #92).
/// File-backed parsers read the input from a private scratch file.
package enum APKStoreCoreFuzzEntries {
    /// `container-reader`: detect and extract any container shape.
    package static func containerReader(_ bytes: UnsafeBufferPointer<UInt8>) {
        withScratchFile(bytes) { url in
            let reader = ContainerReader()
            guard let container = try? reader.detect(at: url) else { return }
            let destination = url.deletingLastPathComponent()
                .appendingPathComponent("extract", isDirectory: true)
            _ = try? reader.extractAPKs(from: url, into: destination)
            try? FileManager.default.removeItem(at: destination)
            _ = container
        }
    }

    /// `apk-signing-block`: the APK Signing Block parser and verifier.
    package static func apkSigningBlock(_ bytes: UnsafeBufferPointer<UInt8>) {
        withScratchFile(bytes) { url in
            _ = try? APKSignatureVerifier().verify(apk: url, targetSDK: 34)
        }
    }

    /// `aapt2-badging`: the `aapt2 dump badging` output parser.
    package static func aapt2Badging(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard let text = String(data: Data(bytes), encoding: .utf8) else { return }
        _ = try? APKInspector.parseBadging(text)
    }

    private static func withScratchFile(
        _ bytes: UnsafeBufferPointer<UInt8>,
        _ body: (URL) -> Void
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuzz-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("input")
        guard (try? Data(bytes).write(to: file)) != nil else { return }
        body(file)
    }
}
