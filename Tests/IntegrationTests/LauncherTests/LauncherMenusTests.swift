import AppKit
import WindowingCore
import XCTest

@MainActor
final class LauncherMenusTests: XCTestCase {
    func testViewMenuUsesTheSessionViewZoomActions() throws {
        let app = NSApplication.shared
        let previousMenu = app.mainMenu
        let previousServicesMenu = app.servicesMenu
        defer {
            app.mainMenu = previousMenu
            app.servicesMenu = previousServicesMenu
        }
        installMenus()

        let mainMenu = try XCTUnwrap(app.mainMenu)
        let viewMenu = try XCTUnwrap(
            mainMenu.items.first {
                $0.submenu?.items.contains { $0.action == #selector(IOSurfaceLayerView.actualSize(_:)) } == true
            }?.submenu
        )
        let actualSize = try XCTUnwrap(
            viewMenu.items.first { $0.action == #selector(IOSurfaceLayerView.actualSize(_:)) }
        )
        let zoomIn = try XCTUnwrap(viewMenu.items.first { $0.action == #selector(IOSurfaceLayerView.zoomIn(_:)) })
        let zoomOut = try XCTUnwrap(viewMenu.items.first { $0.action == #selector(IOSurfaceLayerView.zoomOut(_:)) })

        XCTAssertEqual(actualSize.keyEquivalent, "0")
        XCTAssertEqual(zoomIn.keyEquivalent, "=")
        XCTAssertEqual(zoomOut.keyEquivalent, "-")
    }

    func testAboutMenuInvokesTheCustomAboutCallback() throws {
        let app = NSApplication.shared
        let previousMenu = app.mainMenu
        let previousServicesMenu = app.servicesMenu
        defer {
            app.mainMenu = previousMenu
            app.servicesMenu = previousServicesMenu
        }
        var aboutCount = 0
        LauncherMenus.install(
            appName: "HelloText",
            showAbout: { aboutCount += 1 },
            showInAPKRun: {},
            openSettings: {},
            closeWindow: {},
            restartApp: {},
            canRestartApp: { true },
            sendBack: {},
            openHelp: {},
            reportProblem: {}
        )

        let appMenu = try XCTUnwrap(app.mainMenu?.items.first?.submenu)
        let about = try XCTUnwrap(appMenu.items.first)
        XCTAssertEqual(about.title, LauncherStrings.text("launcher.menu.about", arguments: ["HelloText"]))
        XCTAssertTrue(app.sendAction(try XCTUnwrap(about.action), to: about.target, from: about))
        XCTAssertEqual(aboutCount, 1)
    }

    func testHelpMenuInvokesItsHelpAndReportCallbacks() throws {
        let app = NSApplication.shared
        let previousMenu = app.mainMenu
        let previousHelpMenu = app.helpMenu
        let previousServicesMenu = app.servicesMenu
        defer {
            app.mainMenu = previousMenu
            app.helpMenu = previousHelpMenu
            app.servicesMenu = previousServicesMenu
        }
        var helpCount = 0
        var reportCount = 0
        LauncherMenus.install(
            appName: "HelloText",
            showAbout: {},
            showInAPKRun: {},
            openSettings: {},
            closeWindow: {},
            restartApp: {},
            canRestartApp: { true },
            sendBack: {},
            openHelp: { helpCount += 1 },
            reportProblem: { reportCount += 1 }
        )

        let helpMenu = try XCTUnwrap(app.helpMenu)
        XCTAssertEqual(helpMenu.items.count, 2)
        for item in helpMenu.items {
            XCTAssertNotNil(item.action)
            XCTAssertNotNil(item.target)
            XCTAssertTrue(app.sendAction(item.action!, to: item.target, from: item))
        }
        XCTAssertEqual(helpCount, 1)
        XCTAssertEqual(reportCount, 1)
    }

    func testApplicationMenuUsesTheAppKitServicesMenu() throws {
        let app = NSApplication.shared
        let previousMenu = app.mainMenu
        let previousServicesMenu = app.servicesMenu
        defer {
            app.mainMenu = previousMenu
            app.servicesMenu = previousServicesMenu
        }
        installMenus()

        let appMenu = try XCTUnwrap(app.mainMenu?.items.first?.submenu)
        let services = try XCTUnwrap(
            appMenu.items.first { $0.title == LauncherStrings.text("launcher.menu.services") }
        )
        XCTAssertNotNil(services.submenu)
        XCTAssertTrue(app.servicesMenu === services.submenu)
    }

    func testDockMenuInvokesShowInAPKRunCallback() throws {
        let app = NSApplication.shared
        let previousMenu = app.mainMenu
        let previousServicesMenu = app.servicesMenu
        defer {
            app.mainMenu = previousMenu
            app.servicesMenu = previousServicesMenu
        }
        var showInAPKRunCount = 0
        LauncherMenus.install(
            appName: "HelloText",
            showAbout: {},
            showInAPKRun: { showInAPKRunCount += 1 },
            openSettings: {},
            closeWindow: {},
            restartApp: {},
            canRestartApp: { true },
            sendBack: {},
            openHelp: {},
            reportProblem: {}
        )

        let dockMenu = LauncherMenus.dockMenu()
        let showInAPKRun = try XCTUnwrap(dockMenu.items.first)
        XCTAssertEqual(showInAPKRun.title, LauncherStrings.text("launcher.menu.showInAPKRun"))
        XCTAssertTrue(
            app.sendAction(
                try XCTUnwrap(showInAPKRun.action),
                to: showInAPKRun.target,
                from: showInAPKRun
            )
        )
        XCTAssertEqual(showInAPKRunCount, 1)
    }

    func testAndroidMenuInvokesRestartCallback() throws {
        let app = NSApplication.shared
        let previousMenu = app.mainMenu
        let previousServicesMenu = app.servicesMenu
        defer {
            app.mainMenu = previousMenu
            app.servicesMenu = previousServicesMenu
        }
        let state = RestartMenuState()
        LauncherMenus.install(
            appName: "HelloText",
            showAbout: {},
            showInAPKRun: {},
            openSettings: {},
            closeWindow: {},
            restartApp: { state.restartCount += 1 },
            canRestartApp: { state.canRestart },
            sendBack: {},
            openHelp: {},
            reportProblem: {}
        )

        let androidMenu = try XCTUnwrap(
            app.mainMenu?.items.first { $0.title == LauncherStrings.text("launcher.menu.android") }?.submenu
        )
        let restart = try XCTUnwrap(
            androidMenu.items.first { $0.title == LauncherStrings.text("launcher.menu.restartApp") }
        )
        androidMenu.update()
        XCTAssertFalse(restart.isEnabled)
        state.canRestart = true
        androidMenu.update()
        XCTAssertTrue(restart.isEnabled)
        XCTAssertTrue(app.sendAction(try XCTUnwrap(restart.action), to: restart.target, from: restart))
        XCTAssertEqual(state.restartCount, 1)
    }

    private func installMenus() {
        LauncherMenus.install(
            appName: "HelloText",
            showAbout: {},
            showInAPKRun: {},
            openSettings: {},
            closeWindow: {},
            restartApp: {},
            canRestartApp: { true },
            sendBack: {},
            openHelp: {},
            reportProblem: {}
        )
    }
}

@MainActor
private final class RestartMenuState {
    var canRestart = false
    var restartCount = 0
}
