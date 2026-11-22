import AppKit
import Foundation
import RuntimeAPI
import RuntimeClient
import SwiftUI

/// A report request routed into the sheet (diagnostics.md §8.5): `focusPackage`
/// preselects the package row; `packages` is the picker's list.
struct DiagnosticsReportRequest: Equatable, Identifiable {
    let focusPackage: RuntimePackageID?
    let packages: [RuntimePackageID]

    var id: String { focusPackage?.rawValue ?? "none" }
}

/// The report sheet's stage.
enum DiagnosticsReportStage: Equatable {
    /// The §8.5 step-2 review (contents, toggles, Create Report…).
    case review
    /// `createDiagnostics` is running; progress and Cancel show.
    case running
    /// Done: Show in Finder, Copy Summary, issue link.
    case finished(path: String, summary: String)
    /// A failure with a readable message.
    case failed(String)
}

/// The report sheet's model (diagnostics.md §8.5). Creating the report needs
/// a click; the URL only opened the sheet.
@Observable
@MainActor
final class DiagnosticsReportModel {
    private(set) var stage: DiagnosticsReportStage = .review
    var includeLogcat = false
    var focusPackage: RuntimePackageID?
    private let request: DiagnosticsReportRequest
    private var task: Task<Void, Never>?

    init(request: DiagnosticsReportRequest) {
        self.request = request
        focusPackage = request.focusPackage
    }

    /// The packages the picker offers; the focused one leads (§8.5).
    var packageChoices: [RuntimePackageID] { request.packages }

    /// Create Report… → Save panel → control op on a client-owned handle.
    func create() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.defaultName()
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        FileManager.default.createFile(
            atPath: url.path, contents: nil,
            attributes: [.posixPermissions: 0o600])
        guard let handle = try? FileHandle(forWritingTo: url) else {
            stage = .failed("Cannot write to \(url.path)")
            return
        }
        stage = .running
        let includeLogcat = self.includeLogcat
        let focusPackage = self.focusPackage
        task = Task {
            defer { try? handle.close() }
            do {
                let client = try RuntimeControlClient(clientKind: .app)
                let operation = try await client.createDiagnostics(
                    DiagnosticsRequest(
                        includeLogcat: includeLogcat,
                        focusPackage: focusPackage?.rawValue,
                        createdBy: "app"),
                    output: handle)
                let snapshot = try await Self.waitTerminal(
                    client: client, operationID: operation.operationID)
                try Task.checkCancellation()
                switch snapshot.result {
                case .succeeded(.diagnostics(let info)):
                    stage = .finished(path: url.path, summary: info.summary)
                case .succeeded:
                    stage = .finished(path: url.path, summary: "")
                case .cancelled:
                    try? FileManager.default.removeItem(at: url)
                    stage = .review
                case .failed(let failure):
                    try? FileManager.default.removeItem(at: url)
                    stage = .failed(failure.message)
                case nil, .unknown:
                    stage = .failed("The report stopped without a result.")
                }
            } catch is CancellationError {
                try? handle.truncate(atOffset: 0)
                try? FileManager.default.removeItem(at: url)
                stage = .review
            } catch {
                try? FileManager.default.removeItem(at: url)
                stage = .failed(error.localizedDescription)
            }
        }
    }

    /// Backs a failed stage out to the review form.
    func reset() { stage = .review }

    /// Cancel truncates the partial file and backs out (diagnostics.md §8.1).
    func cancel() {
        task?.cancel()
        task = nil
    }

    /// `~/Desktop/APKRun-Diagnostics-<stamp>.zip` (§8.5).
    static func defaultName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "APKRun-Diagnostics-\(formatter.string(from: Date())).zip"
    }

    /// Polls the operation until it reaches a terminal state.
    private static func waitTerminal(
        client: RuntimeControlClient, operationID: RuntimeAPI.OperationID
    ) async throws -> OperationSnapshot {
        while true {
            try Task.checkCancellation()
            let snapshot = try await client.operationStatus(operationID)
            if snapshot.result != nil { return snapshot }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}

/// The report sheet (diagnostics.md §8.5).
struct DiagnosticsReportSheet: View {
    @Bindable var model: DiagnosticsReportModel
    @Environment(\.dismiss) private var dismiss

    private static let issueTrackerURL =
        URL(string: "https://github.com/uakihir0/apkrun/issues")
        ?? URL(fileURLWithPath: "/")

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Diagnostics Report")
                .font(.headline)
            switch model.stage {
            case .review:
                reviewBody
            case .running:
                Label("Writing the report…", systemImage: "hourglass")
                ProgressView()
                Button("Cancel") { model.cancel() }
            case .finished(let path, let summary):
                Text("The report was written.")
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        URL(fileURLWithPath: path)
                    ])
                }
                Button("Copy Summary") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(summary, forType: .string)
                }
                Link(
                    "Report it on the issue tracker",
                    destination: Self.issueTrackerURL)
                Button("Done") { dismiss() }
            case .failed(let message):
                Text(message).foregroundStyle(.red)
                Button("Back") { model.reset() }
                Button("Close") { dismiss() }
            }
        }
        .padding(20)
        .frame(minWidth: 440)
    }

    /// §8.5 step 2: what is included and never collected, the toggles, and
    /// the focus picker.
    private var reviewBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "Included: host environment, versions, health, logs, runtime and package state — redacted for names, paths, addresses, and secrets. Never collected: file contents, clipboard, keystrokes, or private app data."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            Toggle("Include Android app logs", isOn: $model.includeLogcat)
            if !model.packageChoices.isEmpty {
                Picker("Focus package", selection: $model.focusPackage) {
                    Text("None").tag(RuntimePackageID?.none)
                    ForEach(model.packageChoices, id: \.self) { id in
                        Text(id.rawValue).tag(RuntimePackageID?.some(id))
                    }
                }
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Create Report…") { model.create() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
