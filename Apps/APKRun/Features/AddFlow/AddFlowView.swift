import RuntimeAPI
import SwiftUI

/// The add-flow sheet (host-ui.md §6).
extension RuntimeImportWarning {
    /// User-facing wording for the review-stage warning list.
    var message: String {
        switch self {
        case .missingHardwareFeature(let feature):
            "Requires \(feature), which this Mac may not provide."
        case .certificateOnlyVerification:
            "Signature was checked against the certificate only."
        case .signingNotChecked:
            "The signature was not verified."
        case .debuggable:
            "This is a debuggable build."
        case .lowTargetSDK(let target):
            "Targets Android API \(target); it may not run correctly."
        }
    }
}

struct AddFlowView: View {
    @Environment(AddFlowModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.stage {
            case .inspecting:
                ProgressView("Inspecting…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            case .review:
                if let preview = model.preview {
                    reviewStage(preview)
                }
            case .installing:
                ProgressView("Installing…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            case .installed:
                installedStage
            case .failed(let message):
                VStack(alignment: .leading, spacing: 12) {
                    Label("Couldn't add this file", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text(message)
                    HStack {
                        Spacer()
                        Button("Done") { model.dismiss() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(24)
        .frame(minWidth: 420)
    }

    /// The §6.1 review stage.
    @ViewBuilder
    private func reviewStage(_ preview: RuntimeImportPreview) -> some View {
        let version =
            preview.versionName.map { "\($0) (\(preview.versionCode))" }
            ?? "\(preview.versionCode)"
        let sheet = AddFlowSheet(
            relation: preview.relation,
            displayName: preview.displayName,
            version: version)

        HStack(spacing: 12) {
            Image(systemName: "app")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading) {
                Text(preview.displayName).font(.title3)
                Text("\(preview.packageID.rawValue) · version \(version)")
                    .foregroundStyle(.secondary)
                if let digest = preview.signerDigests.first {
                    Text("Signed by: \(digest.rawValue)")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }

        if let headline = sheet.headline {
            Text(headline)
        }

        if let compatibility = preview.compatibility {
            compatibilityNotice(compatibility)
        }

        ForEach(preview.warnings.indices, id: \.self) { index in
            Label(preview.warnings[index].message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.caption)
        }

        if sheet.showsOptions {
            updateChoices
            if model.showsMacAppRow {
                macAppOptions
            }
        }

        if let installError = model.installError {
            Text(installError).foregroundStyle(.red).font(.caption)
        }

        HStack {
            Spacer()
            Button("Cancel") { model.dismiss() }
            if let action = sheet.action {
                // §10.3: unsupported apps may be installed, but the
                // button says so plainly.
                let actionTitle =
                    model.installError != nil
                    ? "Try Again"
                    : preview.compatibility?.level == "unsupported"
                        ? "Install Anyway" : action
                Button(actionTitle) {
                    model.install()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.needsLocationChoice)
            } else {
                Button("Done") { model.dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// The §10.3 compatibility verdict and its known issues. It is
    /// advisory: the review never blocks an install.
    private func compatibilityNotice(_ info: RuntimeCompatibilityInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text("Compatibility: \(info.label)")
            } icon: {
                Image(systemName: compatibilitySymbol(info.level))
                    .foregroundStyle(compatibilityColor(info.level))
            }
            ForEach(info.issues, id: \.id) { issue in
                Text(issue.title["en"] ?? issue.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func compatibilitySymbol(_ level: String) -> String {
        switch level {
        case "works": return "checkmark.circle.fill"
        case "unsupported": return "xmark.octagon.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private func compatibilityColor(_ level: String) -> Color {
        switch level {
        case "works": return .green
        case "unsupported": return .red
        default: return .yellow
        }
    }

    /// §6.1 Updates row.
    private var updateChoices: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(
                "Updates",
                selection: Bindable(model).updateChoice
            ) {
                Text("Automatic").tag(UpdateChoice.automatic)
                    .disabled(model.suggestedProvider == nil)
                Text("Notify only").tag(UpdateChoice.notifyOnly)
                    .disabled(model.suggestedProvider == nil)
                Text("Manual").tag(UpdateChoice.manual)
            }
            .pickerStyle(.radioGroup)
            if model.suggestedProvider == nil {
                Text("Choose an update source to turn on automatic updates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("An update source was detected; turn on Automatic or Notify only to use it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// §6.1 Create Mac app row.
    private var macAppOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Create Mac app", isOn: Bindable(model).createMacApp)
            if model.createMacApp {
                TextField("Mac app name", text: Bindable(model).macAppName)
                Picker(
                    "Location",
                    selection: Bindable(model).location
                ) {
                    Text("Applications (for me)").tag(AddFlowLocation.userApplications)
                    Text("Applications (all users)").tag(AddFlowLocation.allApplications)
                    Text("Other…").tag(AddFlowLocation.other)
                }
                .onChange(of: model.location) { _, newValue in
                    guard newValue == .other else { return }
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.prompt = "Choose"
                    if panel.runModal() == .OK, let url = panel.url {
                        model.customDirectoryURL = url
                    } else {
                        model.location = .userApplications
                    }
                }
                if model.needsLocationChoice {
                    Text("Choose where the Mac app goes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.location == .other, let url = model.customDirectoryURL {
                    Text(url.path(percentEncoded: false))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// §6.2 done stage.
    private var installedStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let preview = model.preview {
                Label("\(preview.displayName) was installed.", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                if let wrapperError = model.wrapperError {
                    Text("\(preview.displayName) was installed, but the Mac app couldn't be created: \(wrapperError)")
                        .foregroundStyle(.red)
                }
            }
            HStack {
                Spacer()
                if model.wrapperError != nil {
                    Button("Try Again") { model.retryWrapper() }
                }
                if model.wrapperStagingToken != nil {
                    Button("Choose Another Location…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        panel.prompt = "Choose"
                        if panel.runModal() == .OK, let url = panel.url {
                            model.placeStagedWrapper(at: url)
                        }
                    }
                }
                if model.installedPackageID != nil {
                    Button("Open") { model.openInstalled() }
                }
                Button("Done") { model.dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
