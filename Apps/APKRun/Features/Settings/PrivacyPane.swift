import RuntimeAPI
import RuntimeClient
import SwiftUI

/// The Privacy pane of the Settings scene (wrapper.md §7.3 step 5).
///
/// It lists **Mac apps you didn't allow** from `deniedWrappers`; **Remove**
/// calls `clearWrapperDenial(bundleID)` so the next launch asks again.
struct PrivacyPane: View {
    @State private var denied: [DeniedWrapper] = []
    @State private var loadFailed = false

    var body: some View {
        Form {
            Section {
                if denied.isEmpty {
                    Text("No Mac apps are denied.")
                        .foregroundStyle(.secondary)
                }
                ForEach(denied, id: \.bundleID) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.bundleID)
                            Text("Denied until \(entry.until.formatted())")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") { remove(entry) }
                    }
                }
            } header: {
                Text("Mac apps you didn't allow")
            } footer: {
                Text(
                    "Removing an entry lets the Mac app ask again the next time it opens."
                )
            }
            if loadFailed {
                Text("APKRun's background service is not running.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .task { await reload() }
    }

    private func remove(_ entry: DeniedWrapper) {
        Task {
            try? await ApprovalCenter.shared.client?.clearWrapperDenial(
                bundleID: entry.bundleID,
                cdhash: entry.cdhash
            )
            await reload()
        }
    }

    private func reload() async {
        guard let client = ApprovalCenter.shared.client else {
            loadFailed = true
            return
        }
        if let entries = try? await client.deniedWrappers() {
            denied = entries
            loadFailed = false
        } else {
            loadFailed = true
        }
    }
}
