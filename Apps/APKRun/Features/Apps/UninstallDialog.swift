import RuntimeAPI
import SwiftUI

/// The choices the uninstall dialog maps onto `RuntimeUninstallOptions`
/// (host-ui.md §8, package-store.md §8).
struct UninstallChoices: Equatable, Sendable {
    var keepData = false
    var trashWrapper = true
    var forget = false

    var options: RuntimeUninstallOptions {
        RuntimeUninstallOptions(
            keepData: keepData,
            trashWrappers: trashWrapper,
            forget: forget
        )
    }
}

/// "Uninstall ‹App›?" (host-ui.md §8).
///
/// Shown as a sheet from the app page and the app-row menu. When Android
/// cannot start, only **Remove from APKRun** (`forget`) is offered.
struct UninstallDialog: View {
    let displayName: String
    let hasWrapper: Bool
    let appIsOpen: Bool
    let runtimeUnavailable: Bool
    let onUninstall: (UninstallChoices) -> Void
    let onCancel: () -> Void

    @State private var choices = UninstallChoices()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Uninstall “\(displayName)”?")
                .font(.headline)
            if runtimeUnavailable {
                Text("Android cannot start, so \(displayName) may still be installed there.")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(displayName) and its data will be removed from Android.")
                if appIsOpen {
                    Text("\(displayName) is open and will be closed.")
                        .foregroundStyle(.secondary)
                }
                Toggle(
                    "Keep app data (reinstalling \(displayName) later restores it)",
                    isOn: $choices.keepData)
                if hasWrapper {
                    Toggle(
                        "Also move the Mac app to the Trash",
                        isOn: $choices.trashWrapper)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                if runtimeUnavailable {
                    Button("Remove from APKRun", role: .destructive) {
                        choices.forget = true
                        onUninstall(choices)
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Uninstall", role: .destructive) {
                        onUninstall(choices)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
