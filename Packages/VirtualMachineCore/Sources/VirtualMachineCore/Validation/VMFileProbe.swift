import Foundation

/// Path-bearing file facts used only inside validation and its tests.
package struct VMFileProbe: Equatable, Sendable {
    package let exists: Bool
    package let isRegularFile: Bool
    package let sizeBytes: UInt64?
    package let first64Bytes: Data
    package let isReadable: Bool
    package let isWritable: Bool
    package let resolvedFileURL: URL?

    package init(
        exists: Bool,
        isRegularFile: Bool,
        sizeBytes: UInt64?,
        first64Bytes: Data,
        isReadable: Bool,
        isWritable: Bool,
        resolvedFileURL: URL?
    ) {
        self.exists = exists
        self.isRegularFile = isRegularFile
        self.sizeBytes = sizeBytes
        self.first64Bytes = first64Bytes
        self.isReadable = isReadable
        self.isWritable = isWritable
        self.resolvedFileURL = resolvedFileURL
    }
}
