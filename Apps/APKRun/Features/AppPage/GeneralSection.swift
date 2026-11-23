import RuntimeAPI
import SwiftUI

/// §7.1 General: the Mac app's name and icon (a change offers **Update
/// Mac App**, ADR-0009), the package record, the signer, compatibility,
/// and sizes.
struct GeneralSection: View {
    @Bindable var model: PackageDetailModel
    @State private var iconImporter = false

    var body: some View {
        Section("General") {
            LabeledContent("Name") {
                HStack {
                    Text(model.wrapper?.summary.displayName ?? model.displayName)
                    if model.wrapper != nil {
                        Button("Rename…") {
                            model.renameText =
                                model.wrapper?.summary.displayName ?? model.displayName
                            model.showsRename = true
                        }
                    }
                }
            }
            LabeledContent("Icon") {
                HStack {
                    if model.wrapper != nil {
                        Button("Android Icon") {
                            model.pendingIconFile = nil
                            model.pendingAndroidIcon = true
                        }
                    }
                    Button("Choose…") { iconImporter = true }
                    if model.wrapper != nil,
                        model.pendingDisplayName != nil || model.pendingIconFile != nil
                            || model.pendingAndroidIcon
                    {
                        Button("Update Mac App") { model.section = .macApp }
                    }
                }
            }
            if model.pendingDisplayName != nil || model.pendingIconFile != nil
                || model.pendingAndroidIcon
            {
                Text("Applies when you choose Update Mac App.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let summary = model.details?.summary {
                LabeledContent("Package", value: summary.packageID.rawValue)
                if let version = summary.versionName {
                    LabeledContent("Version", value: version)
                }
            }
            if let details = model.details {
                LabeledContent(
                    "Size",
                    value:
                        "\(PackageDetailModel.sizeText(details.artifactBytes)) on your Mac"
                        + androidDataText(details))
            }
            if let compatibility = model.details?.compatibility {
                // §10.3: the shipped database's verdict and issues.
                LabeledContent("Compatibility") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(compatibility.label)
                        ForEach(compatibility.issues, id: \.id) { issue in
                            Text(issue.title["en"] ?? issue.id)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $iconImporter,
            allowedContentTypes: [.png, .jpeg, .icns]
        ) { result in
            // A custom icon only changes the Mac app when the user clicks
            // **Update Mac App** (ADR-0009).
            if case .success(let url) = result {
                model.pendingIconFile = try? FileHandle(forReadingFrom: url)
                if model.pendingIconFile != nil {
                    model.pendingAndroidIcon = false
                }
            }
        }
        .alert(
            "Rename ‹\(model.displayName)›",
            isPresented: $model.showsRename
        ) {
            TextField("Name", text: $model.renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let trimmed = model.renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    model.pendingDisplayName = trimmed
                }
            }
        } message: {
            Text("Applies when you choose Update Mac App.")
        }
    }

    private func androidDataText(_ details: RuntimePackageDetails) -> String {
        guard let bytes = details.androidDataBytes else { return "" }
        return " + \(PackageDetailModel.sizeText(bytes)) in Android"
    }
}
