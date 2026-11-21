import AppKit
import Foundation
import RuntimeAPI
import RuntimeClient

/// The window-side clipboard wiring of desktop-integration.md §4.
///
/// One controller per session window: it reports `focusChanged`, pushes Mac
/// clips on ⌘V and when the window becomes key, and applies guest clips from
/// the `integrations` topic to `NSPasteboard.general`.
@MainActor
final class ClipboardController {
    /// The 500 ms wait for a `ClipAck` before a paste goes through anyway (§4.5).
    static let pasteAckTimeout: Duration = .milliseconds(500)

    private let client: RuntimeControlClient
    private let sessionID: UUID
    private let packageID: String
    private let adapter: PasteboardAdapter
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private var eventTask: Task<Void, Never>?
    /// The window the controller serves; the limit message is a sheet on it.
    private weak var window: NSWindow?
    /// True while a consumed ⌘V is being re-dispatched, so the monitor passes it.
    private var replayingPaste = false

    /// Creates the controller for a session window.
    init(
        client: RuntimeControlClient,
        sessionID: UUID,
        packageID: String,
        adapter: PasteboardAdapter
    ) {
        self.client = client
        self.sessionID = sessionID
        self.packageID = packageID
        self.adapter = adapter
    }

    /// Starts watching `window`, the ⌘V monitor, and the integrations topic.
    func install(on window: NSWindow) {
        self.window = window
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in await self.windowBecameKey() }
            })
        observers.append(
            center.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in await self.reportFocus(false) }
            })
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self else { return event }
            let replaying = MainActor.assumeIsolated { self.replayingPaste }
            guard !replaying,
                event.modifierFlags.contains(.command),
                event.charactersIgnoringModifiers == "v"
            else {
                return event
            }
            // The §4.5 ordering: the ⌘V reaches Android only after the clip
            // push is acknowledged or the timeout passes, so the event is
            // consumed here and re-dispatched afterwards.
            Task { @MainActor in
                await self.pushHostClip(trigger: .paste)
                self.replayingPaste = true
                defer { self.replayingPaste = false }
                if let window = event.window {
                    window.sendEvent(event)
                } else {
                    NSApp.sendEvent(event)
                }
            }
            return nil
        }
        eventTask = Task { [weak self] in
            await self?.consumeIntegrationEvents()
        }
    }

    /// Stops every watcher; the window is closing.
    func uninstall() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        eventTask?.cancel()
        eventTask = nil
    }

    /// The window became key: report focus, then push a changed clip (§4.2).
    private func windowBecameKey() async {
        await reportFocus(true)
        await pushHostClip(trigger: .focus)
    }

    /// `focusChanged` is one-way; failures are only counted by apkrund.
    private func reportFocus(_ isKey: Bool) async {
        _ = try? await client.focusChanged(sessionID: sessionID, isKey: isKey)
    }

    /// Reads the pasteboard and pushes the clip when it changed (§4.2).
    @discardableResult
    private func pushHostClip(trigger: ClipTrigger) async -> ClipAck? {
        guard let item = adapter.readHostClip(trigger: trigger) else {
            return nil
        }
        // The §4.5 ordering: the window pushes and waits for the ClipAck
        // before the ⌘V reaches Android; 500 ms without a reply still pastes
        // the plain text already committed.
        let ack = await withTaskGroup(of: ClipAck?.self) { group in
            group.addTask { [client, sessionID, item] in
                try? await client.pushClipboard(sessionID: sessionID, item: item)
            }
            group.addTask {
                try? await Task.sleep(for: Self.pasteAckTimeout)
                return nil
            }
            defer { group.cancelAll() }
            // The first completed task decides: the ack, or the timeout's nil.
            // A nil element also marks a failed push; both end the wait.
            return await group.next() ?? nil
        }
        if ack == nil {
            adapter.pushFailed(changeCount: adapter.lastReadChangeCount)
        }
        // An image the limits dropped still shows the limit message on the
        // window (desktop-integration.md §4.4).
        if adapter.droppedImageTooLarge != nil || ack?.droppedImageTooLarge == true {
            showImageLimitMessage()
        }
        return ack
    }

    /// "The window shows the limit message" (desktop-integration.md §4.4):
    /// an image over 16 MiB or 8192 px per side does not cross.
    private func showImageLimitMessage() {
        let alert = NSAlert()
        alert.messageText = "The image is too large to paste."
        alert.informativeText =
            "Images over 16 MB or 8192 pixels per side are not sent. The text still went through."
        alert.alertStyle = .informational
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// Applies `clipboardFromGuest` events for this session (§4.3).
    private func consumeIntegrationEvents() async {
        guard let events = try? await client.subscribe(to: .integrations) else {
            return
        }
        for await envelope in events {
            guard !Task.isCancelled,
                case .integrations(.clipboardFromGuest(let sessionID, let packageID, let item)) =
                    envelope.payload,
                sessionID == self.sessionID
            else {
                continue
            }
            await applyGuestClip(item, packageID: packageID)
        }
    }

    /// Writes a guest clip to the pasteboard and reports `clipboardWritten`.
    private func applyGuestClip(_ item: ClipItem, packageID: RuntimePackageID) async {
        guard
            let write = adapter.writeGuestClip(
                item, package: packageID.rawValue, seq: 0, transient: item.sensitive)
        else {
            return
        }
        _ = try? await client.clipboardWritten(
            sessionID: sessionID,
            written: ClipboardWritten(changeCount: write.changeCount, digest: write.digest))
    }
}
