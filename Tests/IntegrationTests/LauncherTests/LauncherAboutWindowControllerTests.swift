import AppKit
import RuntimeAPI
import XCTest

@MainActor
final class LauncherAboutWindowControllerTests: XCTestCase {
    func testInjectedPackageIconIsUsed() throws {
        let packageIcon = NSImage(size: NSSize(width: 32, height: 32))
        let controller = makeController(packageIcon: packageIcon)

        let iconView = try XCTUnwrap(findAboutIcon(in: controller.window.contentView))
        XCTAssertTrue(iconView.image === packageIcon)
    }

    func testMissingPackageIconFallsBackToTheWrapperIcon() throws {
        let controller = makeController(packageIcon: nil)

        let iconView = try XCTUnwrap(findAboutIcon(in: controller.window.contentView))
        XCTAssertNotNil(iconView.image)
    }

    private func makeController(packageIcon: NSImage?) -> LauncherAboutWindowController {
        LauncherAboutWindowController(
            appName: "HelloText",
            packageID: RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext")!,
            packageDetails: nil,
            runtimeVersion: "1.0.0",
            launcherVersion: "1.0.0",
            packageIcon: packageIcon
        )
    }

    private func findAboutIcon(in view: NSView?) -> NSImageView? {
        guard let view else { return nil }
        if let imageView = view as? NSImageView,
            imageView.accessibilityIdentifier() == "launcher.about.icon"
        {
            return imageView
        }
        for subview in view.subviews {
            if let result = findAboutIcon(in: subview) {
                return result
            }
        }
        return nil
    }
}
