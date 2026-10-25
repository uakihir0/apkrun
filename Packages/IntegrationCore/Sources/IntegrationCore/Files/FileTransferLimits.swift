/// The metadata of one file queued for transfer between macOS and Android.
public struct FileTransferItem: Equatable, Sendable {
    /// The item's display name, without its local path.
    public let name: String

    /// The item's exact byte count.
    public let sizeBytes: UInt64

    /// Creates a transfer item from the name and size observed by the file owner.
    public init(name: String, sizeBytes: UInt64) {
        self.name = name
        self.sizeBytes = sizeBytes
    }
}

/// Validates the bounded batch sizes required by desktop-integration.md §6.2.
public enum FileTransferLimits {
    /// Maximum number of files in one drop.
    public static let maximumFileCount = 20

    /// Maximum size of one file (2 GiB).
    public static let maximumFileBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024

    /// Maximum combined size of one drop (4 GiB).
    public static let maximumTotalBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024

    /// Validates item count, individual sizes, and the combined size using overflow-safe arithmetic.
    public static func validate(_ files: [FileTransferItem]) throws(IntegrationFailure) -> UInt64 {
        guard files.count <= maximumFileCount else {
            throw .tooManyFiles(count: files.count, limit: maximumFileCount)
        }

        var totalBytes: UInt64 = 0
        for file in files {
            guard file.sizeBytes <= maximumFileBytes else {
                throw .fileTooLarge(name: file.name, bytes: file.sizeBytes)
            }

            let (nextTotal, overflow) = totalBytes.addingReportingOverflow(file.sizeBytes)
            guard !overflow, nextTotal <= maximumTotalBytes else {
                throw .fileTooLarge(name: "Files", bytes: overflow ? .max : nextTotal)
            }
            totalBytes = nextTotal
        }

        return totalBytes
    }
}
