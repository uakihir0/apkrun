import AppKit
import Foundation
import RuntimeAPI
import RuntimeClient
import UniformTypeIdentifiers

/// The window-side file integration of desktop-integration.md §6.
///
/// One controller per session window:
///
/// * `exportOffered` events of the session open a save panel
///   ("Save to Mac"); the panel's file goes to `acceptExport` and the
///   streamed bytes land in it after the host's SHA-256 check and the
///   `com.apple.quarantine` mark (§6.3). Cancelling the panel declines.
/// * `DropDestination` turns the session window into a drop target: each
///   dropped file opens for reading and goes to `importFiles` (§6.2).
@MainActor
final class FileTransferController {
    /// The package display name used in the save panel prompt.
    private let packageName: String
    private let client: RuntimeControlClient
    private let sessionID: UUID
    private var eventTask: Task<Void, Never>?

    /// Creates the controller for a session window.
    init(client: RuntimeControlClient, sessionID: UUID, packageName: String) {
        self.client = client
        self.sessionID = sessionID
        self.packageName = packageName
    }

    /// Starts watching the integrations topic.
    func install() {
        eventTask = Task { [weak self] in
            await self?.consumeIntegrationEvents()
        }
    }

    /// Stops watching; the window is closing. Pending offers expire in the
    /// host on their own.
    func uninstall() {
        eventTask?.cancel()
        eventTask = nil
    }

    /// Applies `exportOffered` events for this session (§6.3).
    private func consumeIntegrationEvents() async {
        guard let events = try? await client.subscribe(to: .integrations) else {
            return
        }
        for await envelope in events {
            guard !Task.isCancelled,
                case .integrations(
                    .exportOffered(let sessionID, _, let offer)) = envelope.payload,
                sessionID == self.sessionID
            else {
                continue
            }
            await present(offer)
        }
    }

    /// Shows the save panel and resolves through `acceptExport` (§6.3).
    private func present(_ offer: ExportOffer) async {
        let panel = NSSavePanel()
        panel.title = "Save to Mac"
        panel.message = "\(packageName) wants to save a file to your Mac."
        panel.nameFieldStringValue = Self.safeName(offer.name)
        if let type = UTType(mimeType: offer.type) {
            panel.allowedContentTypes = [type]
        }
        let parent = NSApp.keyWindow ?? NSApp.mainWindow
        let response: NSApplication.ModalResponse
        if let parent {
            response = await panel.beginSheetModal(for: parent)
        } else {
            response = panel.runModal()
        }
        var handle: FileHandle?
        if response == .OK, let url = panel.url {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
        }
        do {
            try await client.acceptExport(
                sessionID: sessionID, offerID: offer.offerID,
                fileIndex: nil, target: handle)
        } catch {
            // The offer is gone (expired, session ended, or the transport
            // failed): the file the panel created stays empty.
            if let url = panel.url {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try? handle?.close()
    }

    /// The Android file name, made safe for a save panel (§6.3).
    static func safeName(_ name: String) -> String {
        let cleaned =
            name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\0", with: "")
        return cleaned.isEmpty ? "file" : cleaned
    }
}

/// The drop side (§6.2): a view for the session window's content that
/// accepts file drops and resolves each to `importFiles` with the open
/// file handles.
@MainActor
final class FileDropView: NSView {
    private let client: RuntimeControlClient
    private let sessionID: UUID
    /// `client.importFiles` is called with this target (runtime-api.md §11.2).
    private let target: String

    /// Creates the drop view for a session window's content area.
    init(
        frame: NSRect, client: RuntimeControlClient, sessionID: UUID,
        target: String = "shareToApp"
    ) {
        self.client = client
        self.sessionID = sessionID
        self.target = target
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not decoded")
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let objects = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true])
        return objects?.isEmpty == false ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        Task { @MainActor in _ = await self.handleDrop(sender) }
        return true
    }

    /// The pasteboard items of a drop → `importFiles`. Returns whether the
    /// drop was accepted.
    private func handleDrop(_ sender: any NSDraggingInfo) async -> Bool {
        guard
            let objects = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL],
            !objects.isEmpty
        else {
            return false
        }
        var handles: [FileHandle] = []
        var infos: [ImportFileInfo] = []
        for (index, url) in objects.prefix(20).enumerated() {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .contentTypeKey])
            handles.append(handle)
            infos.append(
                ImportFileInfo(
                    fileIndex: handles.count - 1,
                    name: url.lastPathComponent,
                    size: Int64(values?.fileSize ?? 0),
                    uti: values?.contentType?.identifier
                        ?? UTType(filenameExtension: url.pathExtension)?.identifier
                        ?? "public.data"))
            _ = index
        }
        guard !handles.isEmpty else { return false }
        defer {
            for handle in handles {
                try? handle.close()
            }
        }
        do {
            _ = try await client.importFiles(
                sessionID: sessionID, files: handles, infos: infos, target: target)
            return true
        } catch {
            return false
        }
    }
}
