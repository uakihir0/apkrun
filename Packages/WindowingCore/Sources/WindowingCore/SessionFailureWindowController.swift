import AppKit

/// Shows a launch failure before Android has attached a display to the app window.
@MainActor
public final class SessionFailureWindowController: NSObject, NSWindowDelegate {
    /// Runs when the user closes the failure window.
    public var onClose: (@MainActor () -> Void)?

    private let window: NSWindow

    /// Creates a native failure window with the supplied app name and remediation.
    public init(title: String, appName: String, message: String, remediation: String) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 620))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.cgColor
        let errorView = SessionWindowErrorView(
            appName: appName,
            message: message,
            remediation: remediation
        ) { [weak self] in
            self?.window.performClose(nil)
        }
        errorView.frame = contentView.bounds
        errorView.autoresizingMask = [.width, .height]
        contentView.addSubview(errorView)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        window.delegate = self
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed
        window.center()
    }

    /// Shows the failure window.
    public func show() {
        window.makeKeyAndOrderFront(nil)
    }

    /// Closes the failure window programmatically.
    public func close() {
        window.close()
    }

    /// Notifies the owner after the failure window closes.
    public func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
