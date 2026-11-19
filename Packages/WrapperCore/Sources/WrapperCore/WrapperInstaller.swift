import CoreServices
import DiagnosticsCore
import Foundation
import RuntimeAPI

/// Places a staged `.app` at its destination (wrapper.md §6.2 steps 11 and 13):
/// `rename` on the same volume, or copy to `.<name>.apkrun-<uuid>` plus rename
/// across volumes, then `LSRegisterURL` and `noteFileSystemChanged`.
public struct WrapperInstaller: Sendable {
    /// The result of a placement.
    public struct Placement: Sendable {
        /// The final bundle location.
        public let finalURL: URL
        /// A non-fatal `LSRegisterURL` failure, when it happened.
        public let registrationWarning: WrapperFailure?

        /// Creates a placement result.
        public init(finalURL: URL, registrationWarning: WrapperFailure?) {
            self.finalURL = finalURL
            self.registrationWarning = registrationWarning
        }
    }

    private let logger: APKLogger
    private let register: @Sendable (URL) -> OSStatus
    private let noteChanged: @Sendable (URL) -> Void

    /// Creates an installer. The two callbacks exist so tests do not talk to
    /// LaunchServices.
    public init(
        sink: (any LogSink)? = nil,
        register: (@Sendable (URL) -> OSStatus)? = nil,
        noteChanged: (@Sendable (URL) -> Void)? = nil
    ) {
        logger = APKLogger(category: WrapperLogCategory.generate, sink: sink)
        self.register = register ?? { LSRegisterURL($0 as CFURL, true) }
        self.noteChanged = noteChanged ?? { _ in }
    }

    /// Resolves the destination directory of a request (wrapper.md §6.3) and
    /// probes that it is writable. `EPERM` maps to `destinationNotAccessible`;
    /// other failures map to `destinationNotWritable`.
    public func resolveDestination(
        _ destination: WrapperDestination,
        stagingToken: String
    ) throws(WrapperFailure) -> URL {
        var directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        switch destination {
        case .userApplications:
            break
        case .applications:
            directory = URL(fileURLWithPath: "/Applications", isDirectory: true)
        case .directory(let url):
            directory = url
        }
        if let failure = probeWrite(directory, stagingToken: stagingToken) {
            throw failure
        }
        return directory
    }

    /// Classifies an existing item at the destination path (wrapper.md §6.4).
    ///
    /// - Parameters:
    ///   - existing: the item at `<dest>/<name>.app`.
    ///   - packageID: the package being generated.
    /// - Returns: what occupies the path, or `nil` when nothing does.
    public func classifyConflict(
        at existing: URL,
        packageID: RuntimePackageID
    ) -> ExistingItemKind? {
        guard FileManager.default.fileExists(atPath: existing.path) else { return nil }
        if let identity = InfoPlistWriter.identity(of: existing) {
            if let other = identity.packageID {
                if other == packageID.rawValue {
                    return nil  // same-package wrapper; handled by the caller
                }
                if let mapped = RuntimePackageID(rawValue: other) {
                    return .otherWrapper(mapped)
                }
                return .otherApp
            }
            return .otherApp
        }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: existing.path, isDirectory: &isDirectory)
        if isDirectory.boolValue,
            existing.pathExtension == "app"
        {
            return .otherApp
        }
        return .file
    }

    /// Whether the item at the path is a wrapper of `packageID` (checked via
    /// `APKRunPackageID`, never by parsing the bundle ID).
    public func isWrapperOf(_ packageID: RuntimePackageID, at url: URL) -> Bool {
        InfoPlistWriter.identity(of: url)?.packageID == packageID.rawValue
    }

    /// Places the staged bundle at `finalURL`: `rename` on the same volume, or
    /// copy to `.<name>.apkrun-<uuid>` then rename across volumes.
    public func place(staged: URL, to finalURL: URL) throws(WrapperFailure) -> Placement {
        if let failure = moveIntoPlace(staged, to: finalURL) {
            throw failure
        }
        let status = register(finalURL)
        var warning: WrapperFailure?
        if status != noErr {
            warning = .registrationFailed(status)
            logger.warning(
                "LSRegisterURL failed with status \(status, .public).",
                errorCode: "wrapper.registrationFailed")
        }
        noteChanged(finalURL)
        return Placement(finalURL: finalURL, registrationWarning: warning)
    }

    /// Whether two URLs are on the same volume (`rename` can cross them).
    private func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let volumeA = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let volumeB = try? b.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        guard let volumeA, let volumeB else { return true }
        return volumeA.isEqual(volumeB)
    }

    /// Writes and removes a probe file in `directory`; returns the failure
    /// when it is not writable (kept outside typed throws to work around a
    /// Swift 6.4 SILGen crash in `resolveDestination`).
    private func probeWrite(_ directory: URL, stagingToken: String) -> WrapperFailure? {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let probe = directory.appendingPathComponent(".apkrun-probe-\(UUID().uuidString)")
            try Data().write(to: probe)
            try FileManager.default.removeItem(at: probe)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain,
                error.code == NSFileWriteNoPermissionError
                    || error.code == NSFileReadNoPermissionError
            {
                return .destinationNotAccessible(directory, stagingToken: stagingToken)
            }
            return .destinationNotWritable(directory)
        }
        return nil
    }

    /// Moves `staged` to `finalURL`; returns the failure on error (kept
    /// outside typed throws to work around a Swift 6.4 SILGen crash).
    private func moveIntoPlace(_ staged: URL, to finalURL: URL) -> WrapperFailure? {
        do {
            let destinationExists = FileManager.default.fileExists(atPath: finalURL.path)
            if sameVolume(staged, finalURL) {
                if destinationExists {
                    _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: staged)
                } else {
                    try FileManager.default.moveItem(at: staged, to: finalURL)
                }
            } else {
                let temp = finalURL.deletingLastPathComponent()
                    .appendingPathComponent(
                        ".\(finalURL.lastPathComponent).apkrun-\(UUID().uuidString)",
                        isDirectory: true
                    )
                do {
                    try FileManager.default.copyItem(at: staged, to: temp)
                    if destinationExists {
                        _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: temp)
                    } else {
                        try FileManager.default.moveItem(at: temp, to: finalURL)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: temp)
                    throw error
                }
            }
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain,
                error.code == NSFileWriteNoPermissionError
                    || error.code == NSFileReadNoPermissionError
            {
                return .destinationNotWritable(finalURL.deletingLastPathComponent())
            }
            return .verificationFailed("placement failed: \(error.localizedDescription)")
        }
        return nil
    }
}
