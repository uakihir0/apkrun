import CryptoKit
import Darwin
import ServiceManagement
import SwiftUI

@main
struct APKRunApp: App {
    @StateObject private var menuBarItemSettings: MenuBarItemSettingsModel
    @State private var registrationTitle = String(
        localized: "Background service setup failed"
    )
    @State private var registrationMessage: String?
    @State private var isRegistrationErrorPresented = false

    init() {
        let menuBarItemSettings = MenuBarItemSettingsModel()
        _menuBarItemSettings = StateObject(wrappedValue: menuBarItemSettings)

        if CommandLine.arguments.dropFirst().contains("--register-runtime") {
            RuntimeRegistrationCommand.run()
        }

        menuBarItemSettings.initializeForApplicationLaunch()

        do {
            if try RuntimeRegistrationCommand.registerRuntimeAgentIfNeeded() {
                _registrationTitle = State(initialValue: String(localized: "Approval required"))
                _registrationMessage = State(
                    initialValue:
                        String(
                            localized:
                                "Allow APKRun in System Settings > General > Login Items, then reopen it."
                        )
                )
                _isRegistrationErrorPresented = State(initialValue: true)
            }
        } catch {
            _registrationMessage = State(initialValue: error.localizedDescription)
            _isRegistrationErrorPresented = State(initialValue: true)
        }
    }

    var body: some Scene {
        WindowGroup("APKRun") {
            Text("APKRun")
                .frame(minWidth: 480, minHeight: 320)
                .alert(registrationTitle, isPresented: $isRegistrationErrorPresented) {
                    Button("Open Login Items Settings") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                    Button("Later", role: .cancel) {}
                } message: {
                    Text(
                        registrationMessage
                            ?? String(localized: "Move APKRun.app to Applications and reopen it.")
                    )
                }
        }
        .windowResizability(.contentSize)

        Settings {
            GeneralSettingsView(model: menuBarItemSettings)
        }
    }
}

@MainActor
private enum RuntimeRegistrationCommand {
    private static let registeredPlistHashKey = "registeredAgentPlistSHA256"

    static func run() -> Never {
        do {
            _ = try registerRuntimeAgentIfNeeded(openSettingsWhenApprovalRequired: true)
            exit(EXIT_SUCCESS)
        } catch {
            fputs(
                "APKRun couldn't register its background service: \(error.localizedDescription)\n"
                    + "Move APKRun.app to Applications and run --register-runtime again.\n",
                stderr
            )
            exit(EXIT_FAILURE)
        }
    }

    static func registerRuntimeAgentIfNeeded(
        openSettingsWhenApprovalRequired: Bool = false
    ) throws -> Bool {
        guard
            let plistName = Bundle.main.object(
                forInfoDictionaryKey: "APKRunLaunchAgentPlistName"
            ) as? String,
            !plistName.isEmpty,
            URL(fileURLWithPath: plistName).lastPathComponent == plistName
        else {
            throw RegistrationError.invalidPlistName
        }

        let plistURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(plistName)
        let plistData = try Data(contentsOf: plistURL)
        let plistHash = SHA256.hash(data: plistData)
            .map { String(format: "%02x", $0) }
            .joined()
        let service = SMAppService.agent(plistName: plistName)
        let serviceStatus = service.status
        let previousHash = UserDefaults.standard.string(forKey: registeredPlistHashKey)

        // Re-registering a pending service discards the user's outstanding approval request.
        let registrationNeeded =
            serviceStatus != .requiresApproval
            && (serviceStatus != .enabled || previousHash != plistHash)
        if registrationNeeded {
            try service.unregister()
            try service.register()
            UserDefaults.standard.set(plistHash, forKey: registeredPlistHashKey)
        }

        let approvalRequired = service.status == .requiresApproval
        if approvalRequired && (registrationNeeded || openSettingsWhenApprovalRequired) {
            SMAppService.openSystemSettingsLoginItems()
        }
        return approvalRequired
    }

    private enum RegistrationError: LocalizedError {
        case invalidPlistName

        var errorDescription: String? {
            switch self {
            case .invalidPlistName:
                "The embedded LaunchAgent plist name is missing or invalid."
            }
        }
    }
}
