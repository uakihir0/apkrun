import AppKit

@MainActor
final class LauncherStatusWindowController: NSObject {
    var onAction: (@MainActor (LauncherAction) -> Void)?
    var onQuit: (@MainActor () -> Void)?

    private let window: NSWindow
    private let iconView = NSImageView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let primaryButton = NSButton(title: "", target: nil, action: nil)
    private let secondaryButton = NSButton(title: "", target: nil, action: nil)
    private let quitButton = NSButton(title: LauncherStrings.quit, target: nil, action: nil)
    private var primaryAction: LauncherAction?
    private var secondaryAction: LauncherAction?
    private let appName: String

    init(appName: String, screen: LauncherScreen) {
        self.appName = appName
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        configureWindow()
        show(screen)
    }

    func show(_ screen: LauncherScreen) {
        let presentation = screen.presentation
        messageLabel.stringValue = presentation.message
        messageLabel.setAccessibilityIdentifier("launcher.screen.message")
        detailLabel.stringValue = presentation.detail ?? ""
        detailLabel.isHidden = presentation.detail == nil

        primaryAction = presentation.primaryAction
        primaryButton.title = presentation.primaryAction.map(LauncherStrings.title(for:)) ?? ""
        primaryButton.isHidden = presentation.primaryAction == nil
        primaryButton.setAccessibilityIdentifier("launcher.screen.primaryAction")

        secondaryAction = presentation.secondaryAction
        secondaryButton.title = presentation.secondaryAction.map(LauncherStrings.title(for:)) ?? ""
        secondaryButton.isHidden = presentation.secondaryAction == nil
        secondaryButton.setAccessibilityIdentifier("launcher.screen.secondaryAction")

        window.title = appName
    }

    func showWindow() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window.close()
    }

    func takeWindowForSession() -> NSWindow {
        window.orderOut(nil)
        window.contentView = nil
        return window
    }

    private func configureWindow() {
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 300)
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityIdentifier("launcher.screen.icon")
        messageLabel.font = .systemFont(ofSize: 16, weight: .medium)
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 4
        messageLabel.setAccessibilityIdentifier("launcher.screen.message")

        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 4

        primaryButton.bezelStyle = .rounded
        primaryButton.keyEquivalent = "\r"
        primaryButton.target = self
        primaryButton.action = #selector(primaryButtonPressed)

        secondaryButton.bezelStyle = .rounded
        secondaryButton.target = self
        secondaryButton.action = #selector(secondaryButtonPressed)

        quitButton.bezelStyle = .rounded
        quitButton.target = self
        quitButton.action = #selector(quitButtonPressed)
        quitButton.setAccessibilityIdentifier("launcher.screen.quit")

        let buttons = NSStackView(views: [primaryButton, secondaryButton, quitButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.distribution = .fillEqually
        buttons.spacing = 12

        let stack = NSStackView(views: [iconView, messageLabel, detailLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.distribution = .fill
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        window.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            primaryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            secondaryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            quitButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
    }

    @objc private func primaryButtonPressed() {
        guard let primaryAction else { return }
        onAction?(primaryAction)
    }

    @objc private func secondaryButtonPressed() {
        guard let secondaryAction else { return }
        onAction?(secondaryAction)
    }

    @objc private func quitButtonPressed() {
        onQuit?()
    }
}
