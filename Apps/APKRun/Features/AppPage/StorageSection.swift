import RuntimeAPI
import SwiftUI

/// §7.7 Storage: the sizes and the destructive actions — Repair…,
/// Uninstall…, and Remove Mac App….
struct StorageSection: View {
    @Bindable var model: PackageDetailModel

    var body: some View {
        Section("Storage") {
            if let details = model.details {
                LabeledContent(
                    "APK files",
                    value: PackageDetailModel.sizeText(details.artifactBytes))
                LabeledContent(
                    "Android data",
                    value: PackageDetailModel.sizeText(details.androidDataBytes))
                LabeledContent(
                    "Total",
                    value: PackageDetailModel.sizeText(
                        details.artifactBytes + (details.androidDataBytes ?? 0)))
                if let staged = details.staged {
                    LabeledContent(
                        "Staged update",
                        value: PackageDetailModel.sizeText(staged.size))
                }
            }
        }
        Section {
            Button("Repair…") { model.showsRepair = true }
            Button("Uninstall…", role: .destructive) { model.showsUninstall = true }
            if model.wrapper != nil {
                Button("Remove Mac App…", role: .destructive) {
                    model.removeWrapper()
                }
            }
        }
    }
}
