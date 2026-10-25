import Foundation
import UniformTypeIdentifiers

/// Validates file URLs presented to a launcher window by a drag operation.
enum FileDropValidation {
    static let maximumFileCount = 20
    static let maximumFileBytes: UInt64 = 2 * 1024 * 1024 * 1024
    static let maximumTotalBytes: UInt64 = 4 * 1024 * 1024 * 1024

    /// A validated regular file and the metadata sent with its file handle.
    struct Item: Equatable, Sendable {
        let url: URL
        let name: String
        let size: UInt64
        let uti: String
    }

    /// A safe, user-displayable reason a drop could not be accepted.
    enum Failure: Error, Equatable, Sendable {
        case noFiles
        case tooManyFiles
        case nonFileURL
        case folder
        case notRegularFile
        case sizeUnavailable
        case fileTooLarge
        case totalTooLarge
    }

    /// Returns file metadata after checking every URL and the aggregate transfer limits.
    static func inspect(_ urls: [URL]) throws -> [Item] {
        guard !urls.isEmpty else {
            throw Failure.noFiles
        }
        guard urls.count <= maximumFileCount else {
            throw Failure.tooManyFiles
        }

        var totalBytes: UInt64 = 0
        var items: [Item] = []
        items.reserveCapacity(urls.count)

        for url in urls {
            guard url.isFileURL else {
                throw Failure.nonFileURL
            }

            let values = try url.resourceValues(forKeys: [
                .contentTypeKey,
                .fileSizeKey,
                .isDirectoryKey,
                .isRegularFileKey,
            ])
            guard values.isDirectory != true else {
                throw Failure.folder
            }
            guard values.isRegularFile == true else {
                throw Failure.notRegularFile
            }
            guard let fileSize = values.fileSize, fileSize >= 0 else {
                throw Failure.sizeUnavailable
            }

            let size = UInt64(fileSize)
            guard size <= maximumFileBytes else {
                throw Failure.fileTooLarge
            }
            guard totalBytes <= maximumTotalBytes - size else {
                throw Failure.totalTooLarge
            }
            totalBytes += size

            let uti =
                values.contentType?.identifier
                ?? UTType(filenameExtension: url.pathExtension)?.identifier
                ?? UTType.data.identifier
            items.append(Item(url: url, name: url.lastPathComponent, size: size, uti: uti))
        }

        return items
    }
}
