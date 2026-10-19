import AppKit

@MainActor
final class SessionWindowErrorView: NSView {
    private let heading = NSTextField(labelWithString: "")
    private let messageLabel: NSTextField
    private let remediationLabel: NSTextField
    private let onClose: () -> Void

    init(appName: String, message: String, remediation: String, onClose: @escaping () -> Void) {
        messageLabel = NSTextField(wrappingLabelWithString: message)
        remediationLabel = NSTextField(wrappingLabelWithString: remediation)
        self.onClose = onClose
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        heading.stringValue = "Couldn't start \(appName)"
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        heading.textColor = .white
        messageLabel.textColor = .white
        remediationLabel.textColor = NSColor(calibratedWhite: 0.78, alpha: 1)

        let closeButton = NSButton(title: "Close", target: self, action: #selector(closePressed(_:)))
        closeButton.bezelStyle = .rounded

        let stack = NSStackView(views: [heading, messageLabel, remediationLabel, closeButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            remediationLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Couldn't start \(appName). \(message). \(remediation)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SessionWindowErrorView is created in code.")
    }

    func setAppName(_ appName: String) {
        heading.stringValue = "Couldn't start \(appName)"
        setAccessibilityLabel("Couldn't start \(appName). \(messageLabel.stringValue). \(remediationLabel.stringValue)")
    }

    @objc private func closePressed(_ sender: Any?) {
        onClose()
    }
}
