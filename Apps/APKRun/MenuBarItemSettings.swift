import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class MenuBarItemSettingsModel: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var needsApproval = false
    @Published private(set) var errorMessage: String?

    private static let loginItemIdentifier = "io.apkrun.APKRunMenuBar"
    private static let initializedDefaultsKey = "io.apkrun.menuBarLoginItemInitialized"
    private let service: SMAppService
    private let defaults: UserDefaults
    private let embeddedHelperURL: URL
    private var isLaunchingHelper = false

    init(
        service: SMAppService? = nil,
        defaults: UserDefaults = .standard
    ) {
        let helperURL = Self.embeddedHelperURL
        embeddedHelperURL = helperURL
        let helperIdentifier =
            Bundle(url: helperURL)?.bundleIdentifier ?? Self.loginItemIdentifier
        self.service = service ?? .loginItem(identifier: helperIdentifier)
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
                    SMAppService.openSystemSettingsLoginItems()
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
                SMAppService.openSystemSettingsLoginItems()
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
            let bundleIdentifier = Bundle(url: helperURL)?.bundleIdentifier
        else {
            errorMessage = String(
                localized:
                    "The menu bar item is unavailable in this copy of APKRun."
            )
            return
        }

        let runningHelpers = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        )
        guard !runningHelpers.contains(where: { !$0.isTerminated }) else { return }

        isLaunchingHelper = true
        NSWorkspace.shared.openApplication(at: helperURL, configuration: .init()) {
            [weak self] _, error in
            Task { @MainActor in
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
    }

    private func terminateHelperIfRunning() {
        let helperBundleIdentifier =
            Bundle(url: embeddedHelperURL)?.bundleIdentifier ?? Self.loginItemIdentifier
        for application in NSRunningApplication.runningApplications(
            withBundleIdentifier: helperBundleIdentifier
        ) where !application.isTerminated {
            _ = application.terminate()
        }
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
                            SMAppService.openSystemSettingsLoginItems()
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
