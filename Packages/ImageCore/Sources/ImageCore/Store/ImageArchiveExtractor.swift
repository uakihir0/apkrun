import AppleArchive
import Foundation
import System

/// Extracts a `.aar` image archive into a directory (runtime-image-manifest.md §8.3,
/// android-image.md §12.4). Only plain relative files and directories are allowed:
/// every header is read before extraction, and the extraction filter skips the same
/// set again, so a symlink or `..` entry is never written.
public enum ImageArchiveExtractor {
    /// Extracts `archive` into `directory`, which must already exist.
    public static func extract(_ archive: URL, to directory: URL) throws(ImageFailure) {
        try scan(archive)
        let filter: ArchiveHeader.EntryFilter = { message, path, data in
            switch message {
            case .extractBegin:
                guard case .header(let header) = data else {
                    return .cancel
                }
                return entryAllowed(header.entryType, path: path) ? .ok : .cancel
            default:
                return .ok
            }
        }
        do {
            try ArchiveByteStream.withFileStream(
                path: FilePath(archive.path), mode: .readOnly, options: [],
                permissions: FilePermissions(rawValue: 0o444)
            ) { bytes in
                // Release archives are packed with `aa archive -a lzfse`: the byte stream
                // needs decompression before it decodes. The decompression stream also
                // passes through uncompressed archives.
                try ArchiveByteStream.withDecompressionStream(readingFrom: bytes) { inflated in
                    try ArchiveStream.withDecodeStream(
                        readingFrom: inflated, threadCount: 0
                    ) { input in
                        try ArchiveStream.withExtractStream(
                            extractingTo: FilePath(directory.path), selectUsing: filter
                        ) { output in
                            _ = try ArchiveStream.process(readingFrom: input, writingTo: output)
                        }
                    }
                }
            }
        } catch let failure as ImageFailure {
            throw failure
        } catch {
            throw .manifestInvalid(
                path: archive.lastPathComponent, reason: "archive extraction failed"
            )
        }
    }

    /// Reads every header and refuses unsafe entries before anything is written.
    private static func scan(_ archive: URL) throws(ImageFailure) {
        do {
            try ArchiveByteStream.withFileStream(
                path: FilePath(archive.path), mode: .readOnly, options: [],
                permissions: FilePermissions(rawValue: 0o444)
            ) { bytes in
                try ArchiveByteStream.withDecompressionStream(readingFrom: bytes) { inflated in
                    try ArchiveStream.withDecodeStream(
                        readingFrom: inflated, threadCount: 0
                    ) { input in
                        while let header = try input.readHeader() {
                            guard
                                entryAllowed(header.entryType, path: header.entryPath ?? FilePath())
                            else {
                                throw ImageFailure.imageArchiveUnsafeEntry(
                                    path: header.entryPath?.string ?? ""
                                )
                            }
                        }
                    }
                }
            }
        } catch let failure as ImageFailure {
            throw failure
        } catch {
            throw .manifestInvalid(
                path: archive.lastPathComponent, reason: "not a readable archive"
            )
        }
    }

    /// A relative path of a regular file or directory, with no `..` components.
    static func entryAllowed(_ type: ArchiveHeader.EntryType?, path: FilePath) -> Bool {
        guard type == .regularFile || type == .directory else {
            return false
        }
        guard !path.isEmpty, !path.isAbsolute else {
            return false
        }
        return !path.components.contains("..")
    }
}
