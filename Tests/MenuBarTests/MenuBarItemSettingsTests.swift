import Foundation
import ServiceManagement
import Testing

@MainActor
@Test
func menuBarItemSettingsRegistersAndLaunchesByDefault() {
    let service = MenuBarTestLoginItemRegistration(status: .notRegistered)
    let processController = MenuBarTestItemProcessController()
    let testDefaults = MenuBarTestDefaults()
    defer { testDefaults.clear() }
    let model = makeMenuBarItemSettingsModel(
        service: service,
        processController: processController,
        defaults: testDefaults.defaults
    )

    model.initializeForApplicationLaunch()

    #expect(service.registerCount == 1)
    #expect(service.status == .enabled)
    #expect(model.isEnabled)
    #expect(!model.needsApproval)
    #expect(processController.launchCount == 1)
}

@MainActor
@Test
func menuBarItemSettingsDisablingUnregistersAndTerminatesHelper() {
    let service = MenuBarTestLoginItemRegistration(status: .enabled)
    let processController = MenuBarTestItemProcessController(isRunning: true)
    let testDefaults = MenuBarTestDefaults()
    defer { testDefaults.clear() }
    let model = makeMenuBarItemSettingsModel(
        service: service,
        processController: processController,
        defaults: testDefaults.defaults
    )

    model.setEnabled(false)

    #expect(service.unregisterCount == 1)
    #expect(service.status == .notRegistered)
    #expect(!model.isEnabled)
    #expect(processController.terminateCount == 1)
    #expect(!processController.isRunning(bundleIdentifier: "io.apkrun.APKRunMenuBar"))
}

@MainActor
@Test
func menuBarItemSettingsTerminatesHelperWhenLaunchCompletesAfterDisabling() {
    let service = MenuBarTestLoginItemRegistration(status: .enabled)
    let processController = MenuBarTestItemProcessController()
    let testDefaults = MenuBarTestDefaults()
    defer { testDefaults.clear() }
    let model = makeMenuBarItemSettingsModel(
        service: service,
        processController: processController,
        defaults: testDefaults.defaults
    )

    model.initializeForApplicationLaunch()
    model.setEnabled(false)
    processController.completeLaunch()

    #expect(!model.isEnabled)
    #expect(processController.terminateCount == 2)
    #expect(!processController.isRunning(bundleIdentifier: "io.apkrun.APKRunMenuBar"))
}

@MainActor
@Test
func menuBarItemSettingsOpensLoginItemsWhenApprovalIsRequired() {
    let service = MenuBarTestLoginItemRegistration(status: .requiresApproval)
    let processController = MenuBarTestItemProcessController()
    let testDefaults = MenuBarTestDefaults()
    defer { testDefaults.clear() }
    let model = makeMenuBarItemSettingsModel(
        service: service,
        processController: processController,
        defaults: testDefaults.defaults
    )

    model.initializeForApplicationLaunch()

    #expect(model.isEnabled)
    #expect(model.needsApproval)
    #expect(service.openSettingsCount == 1)
    #expect(processController.launchCount == 0)

    model.setEnabled(true)

    #expect(service.openSettingsCount == 2)
}

@MainActor
private func makeMenuBarItemSettingsModel(
    service: MenuBarTestLoginItemRegistration,
    processController: MenuBarTestItemProcessController,
    defaults: UserDefaults
) -> MenuBarItemSettingsModel {
    MenuBarItemSettingsModel(
        service: service,
        processController: processController,
        defaults: defaults,
        helperURL: Bundle.main.bundleURL,
        helperBundleIdentifier: "io.apkrun.APKRunMenuBar"
    )
}

private final class MenuBarTestDefaults {
    private let suiteName = "io.apkrun.menuBarLoginItemTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        clear()
    }

    func clear() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private final class MenuBarTestLoginItemRegistration: MenuBarLoginItemRegistration {
    var status: SMAppService.Status
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openSettingsCount = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        status = .notRegistered
    }

    func openLoginItemsSettings() {
        openSettingsCount += 1
    }
}

@MainActor
private final class MenuBarTestItemProcessController: MenuBarItemProcessController {
    private(set) var launchCount = 0
    private(set) var terminateCount = 0
    private var running: Bool
    private var launchCompletion: (@MainActor @Sendable (Error?) -> Void)?

    init(isRunning: Bool = false) {
        running = isRunning
    }

    func isRunning(bundleIdentifier: String) -> Bool {
        running
    }

    func launch(
        at url: URL,
        completion: @escaping @MainActor @Sendable (Error?) -> Void
    ) {
        launchCount += 1
        launchCompletion = completion
    }

    func terminate(bundleIdentifier: String) {
        terminateCount += 1
        running = false
    }

    func completeLaunch(error: Error? = nil) {
        running = error == nil
        let completion = launchCompletion
        launchCompletion = nil
        completion?(error)
    }
}
