import AppKit
import RuntimeAPI
import RuntimeClient
import SwiftUI

@main
struct APKRunMenuBarApp: App {
    var body: some Scene {
        MenuBarExtra("APKRun", systemImage: "command") {
            RuntimeMenuContent()
        }
    }
}

private struct RuntimeMenuContent: View {
    @State private var client: RuntimeControlClient?
    @State private var hostState = "checking"
    @State private var runtimeState = "checking"
    @State private var errorMessage: String?
    @State private var isBusy = false

    var body: some View {
        Text("Service: \(hostState)")
        Text("Android: \(runtimeState)")

        if let errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }

        Button(runtimeState == "ready" ? "Stop Android" : "Start Android") {
            Task {
                await performRuntimeAction()
            }
        }
        .disabled(isBusy)

        Button("Refresh Status") {
            Task {
                await refresh()
            }
        }
        .disabled(isBusy)

        Divider()

        Button("Quit APKRun") {
            NSApp.terminate(nil)
        }
    }

    private func performRuntimeAction() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let client = try runtimeClient()
            if runtimeState == "ready" {
                _ = try await client.stopRuntime()
            } else {
                _ = try await client.startRuntime()
            }
            let status = try await client.runtimeStatus()
            hostState = status.hostState
            runtimeState = status.runtimeState
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let status = try await runtimeClient().runtimeStatus()
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
        let client = try RuntimeControlClient(clientKind: .menuBar)
        self.client = client
        return client
    }
}
