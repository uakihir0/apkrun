import CryptoKit
import Darwin
import ServiceManagement
import SwiftUI

@main
struct APKRunApp: App {
    @State private var registrationTitle = "Background service setup failed"
    @State private var registrationMessage: String?
    @State private var isRegistrationErrorPresented = false
    @StateObject private var approvalCenter = ApprovalCenter.shared

    /// Whether apkrund opened the app for a wrapper approval (host-ui.md §3.3).
    /// Only the approval window is shown then.
    private let approvalOnly: Bool

    init() {
        approvalOnly = CommandLine.arguments.dropFirst().contains("--approve")
        _approvalCenter = StateObject(wrappedValue: .shared)
        if CommandLine.arguments.dropFirst().contains("--register-runtime") {
            RuntimeRegistrationCommand.run()
        }
        Task { @MainActor in
            ApprovalCenter.shared.start()
        }

        do {
            if try RuntimeRegistrationCommand.registerRuntimeAgentIfNeeded() {
                _registrationTitle = State(initialValue: "Approval required")
                _registrationMessage = State(
                    initialValue:
                        "Allow APKRun in System Settings > General > Login Items, then reopen it."
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
            ApprovalWindowOpener(center: approvalCenter) {
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
                                ?? "Move APKRun.app to Applications and reopen it."
                        )
                    }
            }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(approvalOnly ? .suppressed : .automatic)

        // The wrapper approval prompt (host-ui.md §10.1).
        Window("Approval Required", id: "approval") {
            ApprovalPromptView()
                .environmentObject(approvalCenter)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(approvalOnly ? .presented : .automatic)

        settingsScene
    }
}

/// Opens the approval window when a prompt arrives while the app is running
/// (host-ui.md §10.1).
private struct ApprovalWindowOpener<Content: View>: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var center: ApprovalCenter
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .onReceive(center.$current) { prompt in
                if prompt != nil {
                    openWindow(id: "approval")
                    NSApp.activate(ignoringOtherApps: true)
                }
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
