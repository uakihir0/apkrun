import AppKit
import RuntimeAPI

@MainActor
final class LauncherAboutWindowController: NSObject {
    let window: NSWindow
    private let packageID: RuntimePackageID
    private let androidVersionLabel = NSTextField(labelWithString: "")
    private let runtimeVersionLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()

    init(
        appName: String,
        packageID: RuntimePackageID,
        packageDetails: RuntimePackageDetails?,
        runtimeVersion: String,
        launcherVersion: String,
        packageIcon: NSImage? = nil
    ) {
        self.packageID = packageID
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 330),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        configureWindow(
            appName: appName,
            launcherVersion: launcherVersion,
            icon: packageIcon ?? Self.fallbackIcon()
        )
        update(packageDetails: packageDetails, runtimeVersion: runtimeVersion)
    }

    func update(packageDetails: RuntimePackageDetails?, runtimeVersion: String) {
        guard let packageDetails else {
            androidVersionLabel.stringValue = LauncherStrings.text("launcher.about.androidVersionUnknown")
            runtimeVersionLabel.stringValue = LauncherStrings.text(
                "launcher.about.runsWith",
                arguments: [runtimeVersion]
            )
            return
        }
        let summary = packageDetails.summary
        let version: String
        if let versionName = summary.versionName, let versionCode = summary.versionCode {
            version = "\(versionName) (\(versionCode))"
        } else if let versionName = summary.versionName {
            version = versionName
        } else if let versionCode = summary.versionCode {
            version = String(versionCode)
        } else {
            version = LauncherStrings.text("launcher.about.androidVersionUnknown")
        }
        androidVersionLabel.stringValue = LauncherStrings.text(
            "launcher.about.androidVersion",
            arguments: [version]
        )
        runtimeVersionLabel.stringValue = LauncherStrings.text(
            "launcher.about.runsWith",
            arguments: [runtimeVersion]
        )
    }

    func showWindow() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureWindow(appName: String, launcherVersion: String, icon image: NSImage?) {
        window.title = LauncherStrings.text("launcher.menu.about", arguments: [appName])
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 300)

        iconView.image = image
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityIdentifier("launcher.about.icon")

        let name = NSTextField(labelWithString: appName)
        name.font = .systemFont(ofSize: 20, weight: .semibold)
        name.alignment = .center
        name.setAccessibilityIdentifier("launcher.about.name")

        androidVersionLabel.alignment = .center
        androidVersionLabel.setAccessibilityIdentifier("launcher.about.androidVersion")

        let package = NSTextField(
            labelWithString: LauncherStrings.text("launcher.about.packageID", arguments: [packageID.rawValue])
        )
        package.alignment = .center
        package.textColor = .secondaryLabelColor
        package.setAccessibilityIdentifier("launcher.about.packageID")

        runtimeVersionLabel.alignment = .center

        let launcher = NSTextField(
            labelWithString: LauncherStrings.text(
                "launcher.about.launcherVersion",
                arguments: [launcherVersion]
            )
        )
        launcher.alignment = .center
        launcher.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [iconView, name, androidVersionLabel, package, runtimeVersionLabel, launcher])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.distribution = .fill
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 72),
            iconView.heightAnchor.constraint(equalToConstant: 72),
        ])
    }

    private static func fallbackIcon() -> NSImage? {
        NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path)
    }
}
