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
                        Button("Rename…") { model.section = .macApp }
                    }
                }
            }
            LabeledContent("Icon") {
                HStack {
                    Button("Choose…") { iconImporter = true }
                    if model.wrapper != nil {
                        Button("Update Mac App") { model.section = .macApp }
                    }
                }
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
        }
        .fileImporter(
            isPresented: $iconImporter,
            allowedContentTypes: [.png, .jpeg, .icns]
        ) { _ in
            // A custom icon only changes the Mac app when the user clicks
            // **Update Mac App** (ADR-0009): send them to that section.
            model.section = .macApp
        }
    }

    private func androidDataText(_ details: RuntimePackageDetails) -> String {
        guard let bytes = details.androidDataBytes else { return "" }
        return " + \(PackageDetailModel.sizeText(bytes)) in Android"
    }
}
