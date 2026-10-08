import Foundation

/// The golden frames of `testdata/frames`, which the Swift and Kotlin tests share
/// (guest-protocol.md §16). `scripts/generate-protos.sh` writes them.
enum GoldenFrames {
    /// The directory of the frames, found from the location of this source file.
    static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // GuestProtocolTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // GuestProtocol
        .appendingPathComponent("testdata/frames", isDirectory: true)

    /// The names of the valid frames, sorted.
    static func validNames() throws -> [String] {
        try names(prefix: "valid-")
    }

    /// The names of the invalid frames, sorted.
    static func invalidNames() throws -> [String] {
        try names(prefix: "invalid-")
    }

    /// The bytes of a frame, including its length prefix.
    static func frame(named name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent("\(name).bin"))
    }

    private static func names(prefix: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".bin") }
            .map { String($0.dropLast(".bin".count)) }
            .sorted()
    }
}
