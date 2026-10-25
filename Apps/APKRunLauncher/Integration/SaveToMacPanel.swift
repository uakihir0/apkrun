import AppKit
import Foundation
import UniformTypeIdentifiers

/// Presents one save panel and completes a user-approved Android file export.
@MainActor
enum SaveToMacPanel {
    /// Runs the export only after the user selects a destination in the save panel.
    ///
    /// The callback writes the offered content to the selected URL. A failed transfer or a
    /// failed quarantine update removes the partial destination.
    static func save(
        for window: NSWindow,
        offeredName: String,
        mimeType: String?,
        sourcePackageID: String,
        applicationDisplayName: String,
        transfer: @MainActor (URL) async throws -> Void
    ) async throws -> URL? {
        let suggestedName = ExportFileNameSanitizer.sanitize(
            offeredName,
            mimeType: mimeType,
            sourcePackageID: sourcePackageID
        )
        guard
            let destination = await chooseDestination(
                for: window,
                suggestedName: suggestedName,
                mimeType: mimeType
            )
        else {
            return nil
        }

        do {
            try await transfer(destination)
            try MacQuarantine.set(
                at: destination,
                agentName: quarantineAgentName(applicationDisplayName)
            )
            return destination
        } catch {
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
            } catch {
                throw Failure.partialOutputCleanupFailed
            }
            throw error
        }
    }

    private static func chooseDestination(
        for window: NSWindow,
        suggestedName: String,
        mimeType: String?
    ) async -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = suggestedName
        if let contentType = contentType(for: mimeType) {
            panel.allowedContentTypes = [contentType]
        }

        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    private static func contentType(for mimeType: String?) -> UTType? {
        guard let mimeType else {
            return nil
        }
        let mediaType = mimeType.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let mediaType else {
            return nil
        }
        return UTType(mimeType: mediaType)
    }

    private static func quarantineAgentName(_ applicationDisplayName: String) -> String {
        let displayName = applicationDisplayName
            .precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: ";", with: "-")
            .components(separatedBy: CharacterSet.controlCharacters)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = displayName.isEmpty ? "APKRun" : displayName
        return "\(name) (APKRun)"
    }

    /// A user-approved output could not be removed after a failed transfer.
    enum Failure: Error, Equatable {
        case partialOutputCleanupFailed
    }
}
