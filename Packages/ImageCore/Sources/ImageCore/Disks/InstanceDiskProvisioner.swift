import Darwin
import DiagnosticsCore
import Foundation

/// Creates one instance disk from an image template (android-image.md §5.1, §5.2).
///
/// The template is cloned with `clonefile(2)`, so the clone shares blocks with
/// it until Android writes. The clone gets GUIDs derived from the instance
/// UUID, and a growable last partition is extended sparse to the requested
/// size. Internal to ImageCore; `InstanceStore` wraps it.
struct InstanceDiskProvisioner: Sendable {
    /// Free space that must remain after growth (§5.2: free space minus a 10 GiB margin).
    static let freeSpaceMargin: Int64 = 10 * 1024 * 1024 * 1024

    var volumeInfo: @Sendable (URL) -> VolumeInfo = VolumeInfo.current(for:)

    /// What provisioning needs to know about the destination volume.
    struct VolumeInfo: Equatable, Sendable {
        var fileSystemType: String
        var volumeName: String
        var availableBytes: Int64

        static func current(for directory: URL) -> VolumeInfo {
            var info = statfs()
            guard statfs(directory.path, &info) == 0 else {
                return VolumeInfo(fileSystemType: "unknown", volumeName: "unknown", availableBytes: 0)
            }
            let type = withUnsafeBytes(of: info.f_fstypename) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            let mountPoint = withUnsafeBytes(of: info.f_mntonname) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            let name = mountPoint == "/" ? "/" : URL(fileURLWithPath: mountPoint).lastPathComponent
            return VolumeInfo(
                fileSystemType: type,
                volumeName: name,
                availableBytes: Int64(info.f_bavail) * Int64(info.f_bsize)
            )
        }
    }

    /// Clones `template` to `destination` and gives the clone its instance identity.
    ///
    /// - Parameters:
    ///   - growTo: the logical size of the grown disk, or `nil` to keep the template size.
    func provision(
        template: URL,
        destination: URL,
        role: String,
        instance: UUID,
        growTo targetSize: UInt64?
    ) throws(ImageFailure) {
        let directory = destination.deletingLastPathComponent()
        let volume = volumeInfo(directory)
        guard volume.fileSystemType == "apfs" else {
            throw .cloneUnsupported(volume: volume.volumeName)
        }
        let templateSize: UInt64
        do {
            let size = try FileManager.default.attributesOfItem(atPath: template.path)[.size]
            templateSize = (size as? NSNumber)?.uint64Value ?? 0
        } catch {
            throw .instanceCorrupt(reason: "the disk template is missing")
        }
        let newSize = targetSize ?? templateSize
        guard newSize >= templateSize else {
            throw .instanceCorrupt(reason: "the requested disk size is below the template size")
        }
        let required = Int64(newSize - templateSize) + Self.freeSpaceMargin
        guard volume.availableBytes >= required else {
            throw .insufficientSpace(required: required, available: volume.availableBytes)
        }

        guard clonefile(template.path, destination.path, 0) == 0 else {
            throw .cloneFailed(underlying: UnderlyingError(domain: NSPOSIXErrorDomain, code: Int(errno)))
        }
        do throws(ImageFailure) {
            try grow(destination, from: templateSize, to: newSize, role: role, instance: instance)
            try Self.syncDirectory(directory)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func grow(
        _ url: URL,
        from oldSize: UInt64,
        to newSize: UInt64,
        role: String,
        instance: UUID
    ) throws(ImageFailure) {
        let descriptor = open(url.path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw .cloneFailed(underlying: UnderlyingError(domain: NSPOSIXErrorDomain, code: Int(errno)))
        }
        defer { close(descriptor) }
        if newSize != oldSize, ftruncate(descriptor, off_t(newSize)) != 0 {
            throw .cloneFailed(underlying: UnderlyingError(domain: NSPOSIXErrorDomain, code: Int(errno)))
        }
        do {
            try GPTDisk.provision(
                fileDescriptor: descriptor,
                oldSize: oldSize,
                newSize: newSize,
                instance: instance,
                role: role
            )
        } catch {
            if case .io(let code) = error {
                throw .cloneFailed(underlying: UnderlyingError(domain: NSPOSIXErrorDomain, code: Int(code)))
            }
            throw .instanceCorrupt(reason: error.reason)
        }
    }

    private static func syncDirectory(_ directory: URL) throws(ImageFailure) {
        let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw .cloneFailed(underlying: UnderlyingError(domain: NSPOSIXErrorDomain, code: Int(errno)))
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw .cloneFailed(underlying: UnderlyingError(domain: NSPOSIXErrorDomain, code: Int(errno)))
        }
    }
}
