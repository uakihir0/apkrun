import AppKit
import ServiceManagement
import SwiftUI

@MainActor
protocol MenuBarLoginItemRegistration {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openLoginItemsSettings()
}

@MainActor
private final class SystemMenuBarLoginItemRegistration: MenuBarLoginItemRegistration {
    private let service: SMAppService

    init(identifier: String) {
        service = .loginItem(identifier: identifier)
    }

    var status: SMAppService.Status { service.status }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
protocol MenuBarItemProcessController {
    func isRunning(bundleIdentifier: String) -> Bool
    func launch(at url: URL, completion: @escaping @MainActor @Sendable (Error?) -> Void)
    func terminate(bundleIdentifier: String)
}

@MainActor
private final class SystemMenuBarItemProcessController: MenuBarItemProcessController {
    func isRunning(bundleIdentifier: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { !$0.isTerminated }
    }

    func launch(at url: URL, completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
            Task { @MainActor in completion(error) }
        }
    }

    func terminate(bundleIdentifier: String) {
        for application in NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ) where !application.isTerminated {
            _ = application.terminate()
        }
    }
}

@MainActor
final class MenuBarItemSettingsModel: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var needsApproval = false
    @Published private(set) var errorMessage: String?

    private static let loginItemIdentifier = "io.apkrun.APKRunMenuBar"
    private static let initializedDefaultsKey = "io.apkrun.menuBarLoginItemInitialized"
    private let service: any MenuBarLoginItemRegistration
    private let processController: any MenuBarItemProcessController
    private let defaults: UserDefaults
    private let embeddedHelperURL: URL
    private let helperBundleIdentifier: String
    private var isLaunchingHelper = false

    init(
        service: (any MenuBarLoginItemRegistration)? = nil,
        processController: (any MenuBarItemProcessController)? = nil,
        defaults: UserDefaults = .standard,
        helperURL: URL? = nil,
        helperBundleIdentifier: String? = nil
    ) {
        let resolvedHelperURL = helperURL ?? Self.embeddedHelperURL
        let resolvedHelperIdentifier =
            helperBundleIdentifier
            ?? Bundle(url: resolvedHelperURL)?.bundleIdentifier
            ?? Self.loginItemIdentifier
        embeddedHelperURL = resolvedHelperURL
        self.helperBundleIdentifier = resolvedHelperIdentifier
        self.service =
            service
            ?? SystemMenuBarLoginItemRegistration(
                identifier: resolvedHelperIdentifier
            )
        self.processController = processController ?? SystemMenuBarItemProcessController()
        self.defaults = defaults
        refreshRegistrationState()
    }

    func initializeForApplicationLaunch() {
        if !defaults.bool(forKey: Self.initializedDefaultsKey) {
            do {
                if service.status == .notRegistered {
                    try service.register()
                }
                guard service.status != .notFound else {
                    errorMessage = String(
                        localized:
                            "The menu bar item is unavailable in this copy of APKRun."
                    )
                    return
                }
                defaults.set(true, forKey: Self.initializedDefaultsKey)
                if service.status == .requiresApproval {
                    service.openLoginItemsSettings()
                }
            } catch {
                errorMessage = String(
                    localized:
                        "APKRun couldn't register the menu bar item. Check Login Items in System Settings."
                )
                refreshRegistrationState()
                return
            }
        }

        refreshRegistrationState()
        if isEnabled && !needsApproval {
            launchHelperIfNeeded()
        } else {
            terminateHelperIfRunning()
        }
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil

        do {
            if enabled {
                switch service.status {
                case .notRegistered:
                    try service.register()
                case .notFound:
                    errorMessage = String(localized: "The menu bar item is unavailable in this copy of APKRun.")
                case .enabled, .requiresApproval:
                    break
                @unknown default:
                    errorMessage = String(
                        localized:
                            "APKRun couldn't change the menu bar item. Check Login Items in System Settings."
                    )
                }
            } else if service.status != .notRegistered && service.status != .notFound {
                try service.unregister()
            }
        } catch {
            errorMessage = String(
                localized:
                    "APKRun couldn't change the menu bar item. Check Login Items in System Settings."
            )
        }

        refreshRegistrationState()
        if enabled {
            if needsApproval {
                service.openLoginItemsSettings()
            } else if isEnabled {
                launchHelperIfNeeded()
            }
        } else {
            terminateHelperIfRunning()
        }
    }

    func refreshRegistrationState() {
        let status = service.status
        isEnabled = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
        if status == .notFound {
            errorMessage = String(localized: "The menu bar item is unavailable in this copy of APKRun.")
        }
    }

    func synchronizeWithSystem() {
        refreshRegistrationState()
        if isEnabled && !needsApproval {
            launchHelperIfNeeded()
        } else {
            terminateHelperIfRunning()
        }
    }

    private func launchHelperIfNeeded() {
        guard !isLaunchingHelper else { return }

        let helperURL = embeddedHelperURL
        guard
            FileManager.default.fileExists(atPath: helperURL.path),
            Bundle(url: helperURL)?.bundleIdentifier != nil
        else {
            errorMessage = String(
                localized:
                    "The menu bar item is unavailable in this copy of APKRun."
            )
            return
        }

        guard !processController.isRunning(bundleIdentifier: helperBundleIdentifier) else { return }

        isLaunchingHelper = true
        processController.launch(at: helperURL) { [weak self] error in
            guard let self else { return }
            self.isLaunchingHelper = false
            self.refreshRegistrationState()
            guard self.isEnabled, !self.needsApproval else {
                self.terminateHelperIfRunning()
                return
            }
            if error != nil {
                self.errorMessage = String(
                    localized:
                        "APKRun couldn't open the menu bar item. Check Login Items in System Settings."
                )
            }
        }
    }

    func openLoginItemsSettings() {
        service.openLoginItemsSettings()
    }

    private func terminateHelperIfRunning() {
        processController.terminate(bundleIdentifier: helperBundleIdentifier)
    }

    private static var embeddedHelperURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LoginItems", isDirectory: true)
            .appendingPathComponent("APKRunMenuBar.app", isDirectory: true)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var model: MenuBarItemSettingsModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section("General") {
                Toggle(
                    "Show APKRun in the menu bar",
                    isOn: Binding(
                        get: { model.isEnabled },
                        set: { model.setEnabled($0) }
                    )
                )
                .accessibilityLabel("Show APKRun in the menu bar")

                if model.needsApproval {
                    HStack {
                        Text(
                            "Allow APKRun in System Settings > General > Login Items to show the menu bar item."
                        )
                        Button("Open Login Items Settings") {
                            model.openLoginItemsSettings()
                        }
                    }
                }

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .onAppear {
            model.synchronizeWithSystem()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.synchronizeWithSystem()
            }
        }
    }
}
