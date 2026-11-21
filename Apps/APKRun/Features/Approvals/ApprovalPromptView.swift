import AppKit
import RuntimeAPI
import SwiftUI

/// The wrapper approval prompt of host-ui.md §10.1.
///
/// **Allow** is deliberately not the default button: Return does not press it,
/// because the prompt comes from a file the user may not have chosen.
struct ApprovalPromptView: View {
    @EnvironmentObject private var center: ApprovalCenter

    var body: some View {
        Group {
            if let prompt = center.current {
                promptBody(prompt)
            } else {
                Text("No pending requests.")
                    .foregroundStyle(.secondary)
                    .frame(width: 420, height: 160)
            }
        }
    }

    @ViewBuilder
    private func promptBody(_ prompt: ApprovalPrompt) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                icon(for: prompt)
                Text(
                    "Allow “\(prompt.displayName)” to open \(prompt.packageID.rawValue) in APKRun?"
                )
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            }

            Grid(alignment: .leadingFirstTextBaseline, verticalSpacing: 8) {
                GridRow {
                    Text("Location")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(
                        prompt.bundleURL.path(percentEncoded: false)
                            .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                }
                GridRow {
                    Text("Signed by")
                        .foregroundStyle(.secondary)
                    Text(signerDescription(prompt.signer))
                }
                GridRow {
                    Text("Android app")
                        .foregroundStyle(.secondary)
                    Text(packageDescription(prompt))
                }
                if let replacesURL = prompt.replacesURL {
                    GridRow {
                        Text("")
                        Text(
                            "Replaces the Mac app at \(replacesURL.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)

            Text("Only allow Mac apps you trust.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Don't Allow") { center.decide(allow: false) }
                    .keyboardShortcut(.defaultAction)
                Button("Allow") { center.decide(allow: true) }
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    @ViewBuilder
    private func icon(for prompt: ApprovalPrompt) -> some View {
        if let data = prompt.icon, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .frame(width: 56, height: 56)
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: prompt.bundleURL.path))
                .resizable()
                .frame(width: 56, height: 56)
        }
    }

    private func signerDescription(_ signer: WrapperSigner) -> String {
        switch signer {
        case .developerID(let teamID, let teamName, let notarized):
            let name = teamName ?? teamID ?? "a developer"
            return notarized ? "Developer ID: \(name) ✓" : "Developer ID: \(name)"
        case .adHoc, .unknown:
            return "Not signed by a developer"
        }
    }

    private func packageDescription(_ prompt: ApprovalPrompt) -> String {
        if prompt.packageInstalled {
            if let installedVersion = prompt.installedVersion {
                return "installed, version \(installedVersion)"
            }
            return "installed"
        }
        if let bundledVersion = prompt.bundledVersion {
            return "not installed. This Mac app contains version \(bundledVersion)."
        }
        return "not installed"
    }
}
