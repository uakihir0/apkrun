import Darwin
import DiagnosticsCore
import Foundation

/// Copy-on-write copies with `clonefile(2)` (android-image.md §5.1, §6.3, §10.3).
///
/// A clone keeps the mode of its source. A file of an installed image is read-only, so a clone
/// of one is read-only too. Anything that is written after it is cloned must therefore be made
/// writable with `cloneWritable`. Installed templates stay read-only: the store clones them with
/// `clone` and never writes the copy (IR-337, IR-359).
enum FileCloner {
    /// A copy-on-write copy that keeps the holes of sparse files and the mode of the source.
    static func clone(_ source: URL, _ destination: URL) throws {
        guard clonefile(source.path, destination.path, 0) == 0 else {
            let code = errno
            switch code {
            case EXDEV, ENOTSUP, EOPNOTSUPP:
                throw ImageFailure.cloneUnsupported(volume: destination.deletingLastPathComponent().path)
            default:
                throw ImageFailure.cloneFailed(
                    underlying: UnderlyingError(domain: "NSPOSIXErrorDomain", code: Int(code)))
            }
        }
    }

    /// A copy-on-write copy whose owner can write it, for a file that is written after cloning.
    static func cloneWritable(_ source: URL, _ destination: URL) throws(ImageFailure) {
        do {
            try clone(source, destination)
        } catch let failure as ImageFailure {
            throw failure
        } catch {
            throw .cloneFailed(underlying: UnderlyingError(domain: "NSCocoaErrorDomain", code: (error as NSError).code))
        }
        try makeOwnerWritable(destination)
    }

    /// Adds the owner's write bit to `url` and keeps its other bits, so the read bits of the
    /// source stay as they were.
    static func makeOwnerWritable(_ url: URL) throws(ImageFailure) {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw .cloneFailed(underlying: UnderlyingError(domain: "NSPOSIXErrorDomain", code: Int(errno)))
        }
        guard chmod(url.path, status.st_mode | S_IWUSR) == 0 else {
            throw .cloneFailed(underlying: UnderlyingError(domain: "NSPOSIXErrorDomain", code: Int(errno)))
        }
    }
}
