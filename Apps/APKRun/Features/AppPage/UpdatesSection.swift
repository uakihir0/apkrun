import RuntimeAPI
import SwiftUI

/// §7.5 Updates: the update mode (writes `update.mode` plus the record's
/// authority and provider through `setUpdatePolicy`, update-system.md
/// §2.3), the **Updated by** picker (`setUpdateAuthority`, asking first
/// for `external`; `googlePlay` is read-only), **Check Now**, the last
/// check result, the recent history, **Roll Back to ‹version›…**, and the
/// health-check keys.
struct UpdatesSection: View {
    @Bindable var model: PackageDetailModel

    var body: some View {
        Section("Updates") {
            if model.displayedAuthority == .external {
                LabeledContent("How often") {
                    Text("Managed by another installer")
                        .foregroundStyle(.secondary)
                }
            } else {
                LabeledContent("How often") {
                    Picker(
                        "How often",
                        selection: Binding(
                            get: { displayedMode },
                            set: { model.setMode($0) })
                    ) {
                        Text("Automatically").tag(UpdateChoice.automatic)
                        Text("Ask me").tag(UpdateChoice.notifyOnly)
                        Text("Never").tag(UpdateChoice.manual)
                    }
                    .labelsHidden()
                    .fixedSize()
                    SettingAccessories(key: "update.mode", model: model)
                }
            }
            if model.displayedAuthority == .googlePlay {
                LabeledContent("Updated by", value: "Google Play")
            } else {
                LabeledContent("Updated by") {
                    Picker(
                        "Updated by",
                        selection: Binding(
                            get: { model.displayedAuthority },
                            set: { model.pickAuthority($0) })
                    ) {
                        Text("APKRun").tag(AuthorityChoice.apkrun)
                        Text("Another app store in Android").tag(AuthorityChoice.external)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if let status = model.updateStatus {
                if let phase = status.phase {
                    LabeledContent("Status", value: Self.phaseText(phase))
                }
                if let candidate = status.candidate {
                    LabeledContent("Update") {
                        HStack {
                            Text(versionText(candidate) + " is ready")
                            Button("Update Now") { model.updateNow() }
                        }
                    }
                }
                LabeledContent("Last checked") {
                    HStack {
                        if let last = status.lastCheckAt {
                            Text(last.formatted(date: .abbreviated, time: .shortened))
                        } else {
                            Text("Never").foregroundStyle(.secondary)
                        }
                        Button("Check Now") { model.checkNow() }
                    }
                }
                if let next = status.nextCheckAt {
                    LabeledContent(
                        "Next check",
                        value: next.formatted(date: .abbreviated, time: .shortened))
                }
                if status.incompatibleReason == "signerDiffers" {
                    // §4.5: F-Droid builds carry F-Droid's signature.
                    Text(
                        "F-Droid's builds of \(model.displayName) are signed by F-Droid, "
                            + "not by the developer of the installed copy. "
                            + "To use F-Droid updates, uninstall \(model.displayName) "
                            + "and install it from F-Droid."
                    )
                    .foregroundStyle(.secondary)
                    .font(.callout)
                }
            }
            toggle(
                "Undo updates that fail to start", key: "update.autoRollback")
            toggle(
                "Open the app briefly after updating to check it",
                key: "update.healthCheckLaunch")
        }
        if !model.history.isEmpty {
            Section("Update history") {
                ForEach(model.history, id: \.time) { entry in
                    LabeledContent {
                        Text(entry.outcome)
                            .foregroundStyle(entry.outcome == "failed" ? .red : .primary)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(
                                "\(entry.from.map(String.init) ?? "?") → \(entry.to.map(String.init) ?? "?")"
                            )
                            Text(entry.time.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        if let previous = model.details?.previous {
            Section {
                Button(
                    "Roll Back to \(previous.versionName ?? String(previous.versionCode))…",
                    role: .destructive
                ) {
                    model.confirmRollback = true
                }
            }
        }
    }

    /// The displayed mode: **Never** is the record's `manual` authority,
    /// not an `update.mode` value (configuration.md §3.1).
    private var displayedMode: UpdateChoice {
        if model.displayedAuthority == .apkrun,
            model.updateStatus?.authority == "manual"
        {
            return .manual
        }
        return UpdateChoice(rawValue: model.value("update.mode")) ?? .automatic
    }

    private func versionText(_ candidate: WireUpdateCandidate) -> String {
        if let version = candidate.versionCode {
            return "Version \(version)"
        }
        return "An update"
    }

    private static func phaseText(_ phase: WireUpdatePhase) -> String {
        switch phase {
        case .checking: "Checking for updates"
        case .available: "Update available"
        case .downloading(let progress): "Downloading (\(Int(progress * 100))%)"
        case .validating: "Checking the update"
        case .staged: "Ready to install"
        case .installing: "Installing"
        case .healthChecking: "Checking the update"
        case .rollingBack: "Rolling back"
        case .completed: "Up to date"
        case .unknown: "—"
        }
    }

    @ViewBuilder
    private func toggle(_ title: String, key: String) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { model.value(key) == "true" },
                set: { model.set(key, $0 ? "true" : "false") }))
        if model.isRecommended(key) || model.isCustomized(key) {
            SettingAccessories(key: key, model: model)
        }
    }
}
