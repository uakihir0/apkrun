import AppKit
import WindowingCore

@MainActor
enum LauncherMenus {
    private static let target = LauncherMenuTarget()

    static func install(
        appName: String,
        showAbout: @escaping @MainActor () -> Void,
        showInAPKRun: @escaping @MainActor () -> Void,
        openSettings: @escaping @MainActor () -> Void,
        closeWindow: @escaping @MainActor () -> Void,
        restartApp: @escaping @MainActor () -> Void,
        canRestartApp: @escaping @MainActor () -> Bool,
        sendBack: @escaping @MainActor () -> Void,
        openHelp: @escaping @MainActor () -> Void,
        reportProblem: @escaping @MainActor () -> Void
    ) {
        target.showAbout = showAbout
        target.showInAPKRun = showInAPKRun
        target.openSettings = openSettings
        target.closeWindow = closeWindow
        target.restartApp = restartApp
        target.canRestartApp = canRestartApp
        target.sendBack = sendBack
        target.openHelp = openHelp
        target.reportProblem = reportProblem

        let menu = NSMenu()
        menu.addItem(applicationMenu(appName: appName))
        menu.addItem(fileMenu())
        menu.addItem(editMenu())
        menu.addItem(viewMenu())
        menu.addItem(androidMenu())
        menu.addItem(windowMenu())
        menu.addItem(helpMenu())
        NSApp.mainMenu = menu
    }

    private static func applicationMenu(appName: String) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()
        menu.addItem(
            menuItem(
                "launcher.menu.about",
                action: #selector(LauncherMenuTarget.about(_:)),
                target: target,
                arguments: [appName]
            )
        )
        menu.addItem(
            menuItem(
                "launcher.menu.settings",
                action: #selector(LauncherMenuTarget.settings(_:)),
                target: target,
                keyEquivalent: ","
            )
        )
        menu.addItem(.separator())
        let servicesTitle = LauncherStrings.text("launcher.menu.services")
        let servicesMenu = NSMenu(title: servicesTitle)
        NSApp.servicesMenu = servicesMenu
        let servicesItem = NSMenuItem(title: servicesTitle, action: nil, keyEquivalent: "")
        servicesItem.submenu = servicesMenu
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(
            menuItem(
                "launcher.menu.hide",
                action: #selector(NSApplication.hide(_:)),
                target: NSApp,
                keyEquivalent: "h"
            )
        )
        menu.addItem(
            menuItem(
                "launcher.menu.hideOthers",
                action: #selector(NSApplication.hideOtherApplications(_:)),
                target: NSApp,
                keyEquivalent: "h",
                modifiers: [.option, .command]
            )
        )
        menu.addItem(
            menuItem(
                "launcher.menu.showAll",
                action: #selector(NSApplication.unhideAllApplications(_:)),
                target: NSApp
            )
        )
        menu.addItem(.separator())
        menu.addItem(
            menuItem(
                "launcher.menu.quit",
                action: #selector(NSApplication.terminate(_:)),
                target: NSApp,
                keyEquivalent: "q",
                arguments: [appName]
            )
        )
        item.submenu = menu
        item.title = appName
        return item
    }

    private static func fileMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()
        menu.addItem(
            menuItem(
                "launcher.menu.closeWindow",
                action: #selector(LauncherMenuTarget.close(_:)),
                target: target,
                keyEquivalent: "w"
            )
        )
        item.submenu = menu
        item.title = LauncherStrings.text("launcher.menu.file")
        return item
    }

    private static func editMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()
        menu.addItem(menuItem("launcher.menu.undo", action: Selector(("undo:")), keyEquivalent: "z"))
        menu.addItem(
            menuItem(
                "launcher.menu.redo",
                action: Selector(("redo:")),
                keyEquivalent: "z",
                modifiers: [.shift, .command]
            )
        )
        menu.addItem(.separator())
        menu.addItem(menuItem("launcher.menu.cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        menu.addItem(menuItem("launcher.menu.copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        menu.addItem(menuItem("launcher.menu.paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        menu.addItem(
            menuItem("launcher.menu.selectAll", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        )
        item.submenu = menu
        item.title = LauncherStrings.text("launcher.menu.edit")
        return item
    }

    private static func viewMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()
        menu.addItem(
            menuItem(
                "launcher.menu.actualSize",
                action: #selector(IOSurfaceLayerView.actualSize(_:)),
                keyEquivalent: "0"
            )
        )
        menu.addItem(
            menuItem(
                "launcher.menu.zoomIn",
                action: #selector(IOSurfaceLayerView.zoomIn(_:)),
                keyEquivalent: "="
            )
        )
        menu.addItem(
            menuItem(
                "launcher.menu.zoomOut",
                action: #selector(IOSurfaceLayerView.zoomOut(_:)),
                keyEquivalent: "-"
            )
        )
        menu.addItem(
            menuItem(
                "launcher.menu.fullScreen",
                action: #selector(NSWindow.toggleFullScreen(_:)),
                keyEquivalent: "f",
                modifiers: [.control, .command]
            )
        )
        item.submenu = menu
        item.title = LauncherStrings.text("launcher.menu.view")
        return item
    }

    private static func androidMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()
        menu.addItem(
            menuItem(
                "launcher.menu.back",
                action: #selector(LauncherMenuTarget.back(_:)),
                target: target,
                keyEquivalent: "["
            )
        )
        menu.addItem(.separator())
        menu.addItem(
            menuItem(
                "launcher.menu.restartApp",
                action: #selector(LauncherMenuTarget.restart(_:)),
                target: target
            )
        )
        menu.addItem(.separator())
        menu.addItem(
            menuItem(
                "launcher.menu.showInAPKRun",
                action: #selector(LauncherMenuTarget.showInAPKRun(_:)),
                target: target
            )
        )
        item.submenu = menu
        item.title = LauncherStrings.text("launcher.menu.android")
        return item
    }

    static func dockMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(
            menuItem(
                "launcher.menu.showInAPKRun",
                action: #selector(LauncherMenuTarget.showInAPKRun(_:)),
                target: target
            )
        )
        return menu
    }

    private static func windowMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()
        menu.addItem(
            menuItem(
                "launcher.menu.minimize",
                action: #selector(NSWindow.performMiniaturize(_:)),
                keyEquivalent: "m"
            )
        )
        menu.addItem(menuItem("launcher.menu.zoom", action: #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(
            menuItem(
                "launcher.menu.bringAllToFront",
                action: #selector(NSApplication.arrangeInFront(_:)),
                target: NSApp
            )
        )
        item.submenu = menu
        item.title = LauncherStrings.text("launcher.menu.window")
        NSApp.windowsMenu = menu
        return item
    }

    private static func helpMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()
        menu.addItem(
            menuItem(
                "launcher.menu.apkrunHelp",
                action: #selector(LauncherMenuTarget.help(_:)),
                target: target
            )
        )
        menu.addItem(
            menuItem(
                "launcher.menu.reportProblem",
                action: #selector(LauncherMenuTarget.reportProblem(_:)),
                target: target
            )
        )
        item.submenu = menu
        item.title = LauncherStrings.text("launcher.menu.help")
        NSApp.helpMenu = menu
        return item
    }

    private static func menuItem(
        _ stringKey: String,
        action: Selector?,
        target explicitTarget: AnyObject? = nil,
        keyEquivalent: String? = nil,
        modifiers: NSEvent.ModifierFlags = .command,
        arguments: [CVarArg] = []
    ) -> NSMenuItem {
        let shortcut = keyEquivalent ?? ""
        let item = NSMenuItem(
            title: LauncherStrings.text(stringKey, arguments: arguments),
            action: action,
            keyEquivalent: shortcut
        )
        item.target = explicitTarget
        if !shortcut.isEmpty {
            item.keyEquivalentModifierMask = modifiers
        }
        return item
    }
}

@MainActor
private final class LauncherMenuTarget: NSObject, NSMenuItemValidation {
    var showAbout: (@MainActor () -> Void)?
    var showInAPKRun: (@MainActor () -> Void)?
    var openSettings: (@MainActor () -> Void)?
    var closeWindow: (@MainActor () -> Void)?
    var restartApp: (@MainActor () -> Void)?
    var canRestartApp: (@MainActor () -> Bool)?
    var sendBack: (@MainActor () -> Void)?
    var openHelp: (@MainActor () -> Void)?
    var reportProblem: (@MainActor () -> Void)?

    @objc func about(_ sender: Any?) {
        showAbout?()
    }

    @objc func settings(_ sender: Any?) {
        openSettings?()
    }

    @objc func close(_ sender: Any?) {
        closeWindow?()
    }

    @objc func restart(_ sender: Any?) {
        restartApp?()
    }

    @objc func back(_ sender: Any?) {
        sendBack?()
    }

    @objc func showInAPKRun(_ sender: Any?) {
        showInAPKRun?()
    }

    @objc func help(_ sender: Any?) {
        openHelp?()
    }

    @objc func reportProblem(_ sender: Any?) {
        reportProblem?()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(restart(_:)) else { return true }
        return canRestartApp?() ?? false
    }
}
