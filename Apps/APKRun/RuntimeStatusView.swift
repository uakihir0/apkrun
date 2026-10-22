import Observation
import RuntimeAPI
import RuntimeClient
import SwiftUI

@MainActor
@Observable
private final class RuntimeStatusModel {
    private enum Action {
        case refresh
        case start
        case stop
    }

    private(set) var hostState = "checking"
    private(set) var runtimeState = "checking"
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private var client: RuntimeControlClient?

    func refresh() async {
        await perform(.refresh)
    }

    func start() async {
        await perform(.start)
    }

    func stop() async {
        await perform(.stop)
    }

    private func perform(_ action: Action) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let client = try runtimeClient()
            switch action {
            case .refresh:
                break
            case .start:
                _ = try await client.startRuntime()
            case .stop:
                _ = try await client.stopRuntime()
            }
            let status = try await client.runtimeStatus()
            hostState = status.hostState
            runtimeState = status.runtimeState
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func runtimeClient() throws -> RuntimeControlClient {
        if let client {
            return client
        }
        let client = try RuntimeControlClient(clientKind: .app)
        self.client = client
        return client
    }
}

struct RuntimeStatusView: View {
    @State private var model = RuntimeStatusModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("APKRun")
                .font(.largeTitle.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Background service", value: model.hostState)
                LabeledContent("Android", value: model.runtimeState)
            }
            .font(.body.monospaced())

            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if model.runtimeState == "ready" {
                    Button("Stop Android") {
                        Task { await model.stop() }
                    }
                    .keyboardShortcut(.delete, modifiers: [.command])
                } else {
                    Button("Start Android") {
                        Task { await model.start() }
                    }
                    .keyboardShortcut(.defaultAction)
                }

                Button("Refresh") {
                    Task { await model.refresh() }
                }
            }
            .disabled(model.isBusy)
        }
        .padding(28)
        .frame(minWidth: 480, minHeight: 320, alignment: .leading)
        .task {
            await model.refresh()
        }
    }
}
