import RuntimeAPI
import SwiftUI

/// The app page's **Mac App** section (host-ui.md §7.6, wrapper.md §9.1).
///
/// Shows the wrapper's status, name, and location. The actions talk to
/// apkrund: **Update Mac App** is `refreshWrapper`, **Create Mac App** is
/// `createWrapper`, and **Remove Mac App…** is `removeWrapper { trash: true }`
/// after a confirmation.
struct MacAppSection: View {
    let packageID: RuntimePackageID
    let entry: WrapperListEntryWire?
    let onShowInFinder: (URL) -> Void
    let onRefresh: () -> Void
    let onMakeLocal: () -> Void
    let onCreate: () -> Void
    let onRemove: () -> Void

    @State private var confirmRemove = false

    var body: some View {
        Section {
            if let entry {
                LabeledContent("Name", value: entry.summary.displayName)
                LabeledContent("Status", value: statusText(entry))
                LabeledContent("Location") {
                    Text(entry.summary.bundleURL.deletingLastPathComponent().path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Show in Finder") {
                        onShowInFinder(entry.summary.bundleURL)
                    }
                    if entry.refreshReasons.isEmpty == false {
                        Button("Update Mac App") { onRefresh() }
                    }
                    if entry.summary.kind == .portable {
                        // §7.6: rebuilds the wrapper as `local` without
                        // `bootstrap/` (wrapper-json.md §3.1).
                        Button("Make Local Mac App") { onMakeLocal() }
                    }
                    Button("Remove Mac App…", role: .destructive) {
                        confirmRemove = true
                    }
                }
                if entry.refreshReasons.isEmpty == false {
                    Text(refreshReasonText(entry.refreshReasons))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No Mac app for this package.")
                    .foregroundStyle(.secondary)
                Button("Create Mac App") { onCreate() }
            }
        } header: {
            Text("Mac App")
        }
        .confirmationDialog(
            "Remove the Mac app?",
            isPresented: $confirmRemove,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { onRemove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Mac app goes to the Trash. The Android app stays installed.")
        }
    }

    private func statusText(_ entry: WrapperListEntryWire) -> String {
        switch entry.state ?? .missing {
        case .valid:
            "Installed"
        case .moved(let url):
            "Moved to \(url.lastPathComponent)"
        case .missing:
            "In the Trash or deleted"
        case .inaccessible:
            "Mac cannot access the location"
        case .signatureInvalid:
            "Modified since it was created"
        case .unknownPackage:
            "No APKRun package"
        }
    }

    private func refreshReasonText(_ reasons: [WrapperRefreshReason]) -> String {
        let parts = reasons.map { reason -> String in
            switch reason {
            case .launcher:
                "a new APKRun"
            case .icon:
                "a new icon"
            case .displayName:
                "a new name"
            }
        }
        return "Update available: \(parts.joined(separator: ", "))."
    }
}
