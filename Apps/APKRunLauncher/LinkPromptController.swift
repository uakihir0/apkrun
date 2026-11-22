import AppKit
import Foundation
import RuntimeAPI
import RuntimeClient

/// The window-side link prompt of desktop-integration.md §7.2 and
/// runtime-api.md §11.2.
///
/// One controller per session window: it watches the `integrations` topic
/// for `linkPrompt` events of its session and presents the sheet — Open in
/// Browser, Keep in Android, Cancel, a Remember checkbox, the bold
/// registrable domain, and the sign-in hint. A prompt the user ignores
/// resolves as Cancel at its expiry.
@MainActor
final class LinkPromptController {
    /// The package display name used in the sheet title.
    private let packageName: String
    private let client: RuntimeControlClient
    private let sessionID: UUID
    private var eventTask: Task<Void, Never>?
    /// The open sheet, so the expiry can end it.
    private weak var openSheet: NSWindow?
    private var expiryTask: Task<Void, Never>?

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

    /// Stops watching; the window is closing.
    func uninstall() {
        eventTask?.cancel()
        eventTask = nil
        expiryTask?.cancel()
        expiryTask = nil
    }

    /// Applies `linkPrompt` events for this session (§7.2).
    private func consumeIntegrationEvents() async {
        guard let events = try? await client.subscribe(to: .integrations) else {
            return
        }
        for await envelope in events {
            guard !Task.isCancelled,
                case .integrations(
                    .linkPrompt(let sessionID, let packageID, let prompt)) = envelope.payload,
                sessionID == self.sessionID
            else {
                continue
            }
            await present(prompt, packageID: packageID)
        }
    }

    /// Shows the sheet on `window` and resolves through `resolveLinkPrompt`.
    private func present(_ prompt: LinkPrompt, packageID: RuntimePackageID) async {
        let alert = NSAlert()
        alert.messageText = LauncherStrings.text("\(packageName) wants to open a link.")
        alert.informativeText =
            prompt.signInHint
            ? "The link may be a sign-in page. Open it in your browser, not in \(packageName)."
            : "Open the link in your browser, or keep it in \(packageName)."
        alert.alertStyle = .informational

        let openButton = alert.addButton(withTitle: LauncherStrings.text("Open in Browser"))
        if prompt.keepInAndroidAvailable {
            alert.addButton(withTitle: LauncherStrings.text("Keep in Android"))
        }
        alert.addButton(withTitle: LauncherStrings.text("Cancel"))
        openButton.keyEquivalent = "\r"

        // The bold registrable domain plus the Remember checkbox (§7.2).
        let domainLabel = NSTextField(wrappingLabelWithString: "")
        let domainText = NSMutableAttributedString(
            string: prompt.host.isEmpty ? prompt.scheme : prompt.host)
        if !prompt.registrableDomain.isEmpty,
            let range = prompt.host.range(of: prompt.registrableDomain)
        {
            domainText.setAttributes(
                [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)],
                range: NSRange(range, in: prompt.host))
        }
        domainLabel.attributedStringValue = domainText
        let rememberBox = NSButton(
            checkboxWithTitle: "Remember this choice", target: nil, action: nil)
        let accessory = NSStackView(views: [domainLabel, rememberBox])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        alert.accessoryView = accessory

        // Auto-cancel at the prompt expiry (§7.2: 60 s).
        let remaining = prompt.expiresAt.timeIntervalSinceNow
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, remaining)))
            guard !Task.isCancelled, let self, let sheet = self.openSheet,
                let parent = sheet.sheetParent
            else { return }
            await MainActor.run { parent.endSheet(sheet, returnCode: .cancel) }
        }

        let windows = NSApp.windows.filter { $0.isKeyWindow }
        let parentWindow = windows.first ?? NSApp.mainWindow
        let response: NSApplication.ModalResponse
        if let parentWindow {
            openSheet = alert.window
            response = await alert.beginSheetModal(for: parentWindow)
        } else {
            response = alert.runModal()
        }
        openSheet = nil
        expiryTask?.cancel()
        expiryTask = nil

        let choice: LinkChoice
        switch response {
        case .alertFirstButtonReturn:
            choice = .openOnMac
        case .alertSecondButtonReturn where prompt.keepInAndroidAvailable:
            choice = .keepInAndroid
        default:
            choice = .cancel
        }
        _ = try? await client.resolveLinkPrompt(
            sessionID: sessionID,
            promptID: prompt.promptID,
            choice: choice,
            remember: rememberBox.state == .on)
    }
}
