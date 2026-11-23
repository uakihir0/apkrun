import AppKit
import RuntimeAPI
import RuntimeClient
import SwiftUI

/// The first-run provisioning sheet (host-ui.md §4). It drives the steps of
/// runtime-daemon.md §9.2 from `WireProvisioningState` and stays useful when the
/// user closes the window: apkrund continues, and the next launch resumes at the
/// first incomplete step.
struct OnboardingView: View {
    @Environment(RuntimeStatusModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var failedFirstBoots = 0
    @State private var setupRequested = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to APKRun")
                .font(.title2.bold())
            Text("Run Android apps as Mac apps.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                stepRow(
                    "This Mac can run APKRun",
                    step: .checkingHost
                )
                stepRow(
                    "Installing Android…",
                    step: .installingImage
                )
                stepRow(
                    "Starting Android for the first time",
                    step: .firstBoot
                )
                stepRow(
                    "Checking that everything works",
                    step: .verifying
                )
            }

            if case .failed(let step, let error) = model.provisioning {
                failureBlock(step: step, error: error)
            }

            if model.provisioning == .complete {
                Label("You're ready.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Drag an APK here to add your first app.")
                    .foregroundStyle(.secondary)
            } else {
                Text(
                    "This takes a few minutes. You can close this window. "
                        + "Setup continues when you come back."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                if model.provisioning == .complete {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") {
                        Task { await model.cancelSetup() }
                    }
                }
            }
        }
        .padding(24)
        .frame(minWidth: 460)
        .task {
            model.start()
            await requestSetupIfNeeded()
        }
    }

    // MARK: - Steps

    /// The wire step this UI row tracks. UI rows collapse
    /// `installingAgents` into `verifying` per host-ui.md §4.
    private enum StepKey {
        case checkingHost, installingImage, firstBoot, verifying
    }

    @ViewBuilder
    private func stepRow(_ title: String, step: StepKey) -> some View {
        let state = rowState(for: step)
        HStack(spacing: 10) {
            switch state {
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .active(let fraction):
                if let fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 110)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            case .pending:
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .foregroundStyle(state == .pending ? .secondary : .primary)
            if case .firstBoot(let phase, _) = model.provisioning, step == .firstBoot {
                Text(bootPhaseText(phase))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private enum RowState: Equatable {
        case pending, done, failed
        case active(fraction: Double?)
    }

    private func rowState(for key: StepKey) -> RowState {
        let order: (ProvisioningStep) -> Int = { step in
            switch step {
            case .checkingHost: return 0
            case .installingImage: return 1
            case .creatingInstance: return 1
            case .firstBoot: return 2
            case .installingAgents: return 3
            case .verifying: return 3
            case .unknown: return 0
            }
        }
        let rowRank: Int
        switch key {
        case .checkingHost: rowRank = 0
        case .installingImage: rowRank = 1
        case .firstBoot: rowRank = 2
        case .verifying: rowRank = 3
        }
        switch model.provisioning {
        case .complete:
            return .done
        case .notStarted, .unknown:
            return rowRank == 0 ? .pending : .pending
        case .checkingHost:
            return rowRank == 0 ? .active(fraction: nil) : .pending
        case .installingImage(let fraction):
            return rowRank < 1 ? .done : rowRank == 1 ? .active(fraction: fraction) : .pending
        case .creatingInstance:
            return rowRank < 1 ? .done : rowRank == 1 ? .active(fraction: nil) : .pending
        case .firstBoot(_, let fraction):
            return rowRank < 2 ? .done : rowRank == 2 ? .active(fraction: fraction) : .pending
        case .installingAgents, .verifying:
            return rowRank < 3 ? .done : .active(fraction: nil)
        case .failed(let step, _):
            let rank = order(step)
            if rowRank < rank { return .done }
            if rowRank == rank { return .failed }
            return .pending
        }
    }

    // MARK: - Failure block

    @ViewBuilder
    private func failureBlock(step: ProvisioningStep, error: RuntimeAPI.WireError) -> some View {
        let presented = WireErrorPresenter.present(error)
        VStack(alignment: .leading, spacing: 8) {
            Text(presented.message)
                .foregroundStyle(.red)
            ForEach(presented.hints, id: \.self) { hint in
                Text("• \(hint)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let remediation = presented.remediation {
                Text(remediation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                // A failed host check ends onboarding; everything else retries
                // (host-ui.md §4). The memory warning keeps **Continue**.
                if step == .checkingHost, WireErrorPresenter.isBlockingHostCheck(error) {
                    Button("Quit") { NSApp.terminate(nil) }
                } else {
                    Button("Try Again") {
                        Task { await requestSetup(recreateInstance: false) }
                    }
                }
                Button("Report…") {
                    ReportSupport.report(error: error)
                }
                if step == .installingImage {
                    // Image downloads arrive with the release feed (#59); until then the user
                    // can point onboarding at a local image bundle.
                    Button("Choose Image Folder…") {
                        chooseImageFolder()
                    }
                }
                if step == .firstBoot, failedFirstBoots >= 2 {
                    Button("Start Over") {
                        Task { await requestSetup(recreateInstance: true) }
                    }
                }
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.08), in: .rect(cornerRadius: 8))
    }

    private func bootPhaseText(_ phase: BootPhase) -> String {
        switch phase {
        case .kernel: return "starting the kernel"
        case .`init`: return "starting init"
        case .systemServer: return "starting system services"
        case .bootCompleted: return "finishing boot"
        case .agentsConnecting: return "connecting agents"
        case .unknown: return "starting"
        }
    }

    // MARK: - Setup requests

    private func requestSetupIfNeeded() async {
        // apkrund resumes a persisted record itself; the app only starts setup
        // when provisioning never ran or is waiting on a user decision.
        guard !setupRequested else { return }
        switch model.provisioning {
        case .notStarted:
            setupRequested = true
            await requestSetup(recreateInstance: false)
        case .failed(let step, _):
            if step == .firstBoot { failedFirstBoots += 1 }
        default:
            break
        }
    }

    private func chooseImageFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the Android image bundle folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // APKRun.app is not sandboxed, so a security-scoped bookmark cannot be
        // created; fall back to a plain bookmark that still survives renames.
        guard
            let bookmark =
                (try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ))
                ?? (try? url.bookmarkData(
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ))
        else { return }
        Task {
            _ = try? await model.beginSetup(
                request: SetupRequest(image: .directory(bookmark: bookmark)))
        }
    }

    private func requestSetup(recreateInstance: Bool) async {
        do {
            _ = try await model.beginSetup(
                request: SetupRequest(recreateInstance: recreateInstance))
        } catch {
            // The error surfaces through model.lastError / provisioning state.
        }
    }
}

/// The **Report…** affordance of host-ui.md §9.8: copies the failure details so
/// the user can attach them to a report.
enum ReportSupport {
    static func report(error: RuntimeAPI.WireError) {
        let presented = WireErrorPresenter.present(error)
        var lines = ["\(presented.code): \(presented.message)"]
        for hint in presented.hints {
            lines.append("- \(hint)")
        }
        if let remediation = presented.remediation {
            lines.append("Remediation: \(remediation)")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
