import RuntimeAPI
import SwiftUI

/// The Repair sheet for a `broken` package (host-ui.md §7.7,
/// package-store.md §11.1).
///
/// Explains why the package is broken and offers **Repair…** (`repairPackage`,
/// a reinstall of APKRun's retained APKs) or **Remove from APKRun**
/// (`uninstall { forget: true }`).
struct RepairSheet: View {
    let displayName: String
    let brokenReason: String
    let onRepair: () -> Void
    let onRemove: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Repair “\(displayName)”?")
                .font(.headline)
            Text(brokenReasonText)
                .fixedSize(horizontal: false, vertical: true)
            Text(
                "Repair reinstalls \(displayName) from the copy APKRun kept. "
                    + "Remove from APKRun deletes APKRun's record and copies "
                    + "without touching Android."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Remove from APKRun", role: .destructive) { onRemove() }
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Repair…") { onRepair() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var brokenReasonText: String {
        switch brokenReason {
        case "removedInAndroid":
            "Android no longer has \(displayName)."
        case "artifactMissing":
            "APKRun's copy of \(displayName)'s installation files is missing or changed."
        case "reinstallFailed":
            "The last attempt to reinstall \(displayName) failed."
        case "signerChanged":
            "Android has \(displayName) signed by a different developer."
        case "rollbackFailed":
            "Rolling \(displayName) back failed."
        case let reason where reason.hasPrefix("needsReinstall"):
            "\(displayName) needs to be reinstalled."
        default:
            "\(displayName) is marked as broken (\(brokenReason))."
        }
    }
}
