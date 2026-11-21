import AppKit
import Combine
import CryptoKit
import Darwin
import ServiceManagement
import SwiftUI

@main
struct APKRunApp: App {
    @NSApplicationDelegateAdaptor(ApprovalWindowDelegate.self) private var appDelegate
    @State private var registrationTitle = "Background service setup failed"
    @State private var registrationMessage: String?
    @State private var isRegistrationErrorPresented = false
    @StateObject private var approvalCenter = ApprovalCenter.shared
    @State private var runtimeStatus = RuntimeStatusModel()
    @State private var homeModel = HomeModel()

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
            HomeView()
                .frame(minWidth: 640, minHeight: 420)
                .environment(runtimeStatus)
                .environment(homeModel)
                .task {
                    runtimeStatus.start()
                    homeModel.start()
                }
                // apkrun:// URLs only navigate (host-ui.md §3.1).
                .onOpenURL { url in
                    guard let route = AppRouter.route(url) else { return }
                    homeModel.apply(route)
                }
                // First-run provisioning (host-ui.md §4): the sheet reopens
                // whenever setup is not `complete`; apkrund resumes at the
                // first incomplete step.
                .sheet(isPresented: onboardingPresented) {
                    OnboardingView()
                        .environment(runtimeStatus)
                }
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
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(approvalOnly ? .suppressed : .automatic)

        settingsScene
    }

    /// The onboarding sheet opens until setup completes; it never opens on an
    /// approval-only launch (host-ui.md §3.3).
    private var onboardingPresented: Binding<Bool> {
        Binding(
            get: { !approvalOnly && !runtimeStatus.setupComplete },
            set: { _ in }
        )
    }
}

/// Opens and closes the wrapper approval window (host-ui.md §10.1).
///
/// A plain `NSWindowController`, not a SwiftUI `Window` scene: a scene's view
/// tree dies with its last window, so a prompt arriving while every window is
/// closed would never open. The delegate lives as long as the app.
@MainActor
private final class ApprovalWindowDelegate: NSObject, NSApplicationDelegate {
    private var windowController: NSWindowController?
    private var cancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        cancellable = ApprovalCenter.shared.$current.sink { [weak self] prompt in
            if prompt != nil {
                self?.showApprovalWindow()
            } else {
                self?.windowController?.close()
            }
        }
    }

    private func showApprovalWindow() {
        if windowController == nil {
            let rootView = ApprovalPromptView()
                .environmentObject(ApprovalCenter.shared)
            let window = NSWindow(
                contentViewController: NSHostingController(rootView: rootView))
            window.title = "Approval Required"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            windowController = NSWindowController(window: window)
        }
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
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
