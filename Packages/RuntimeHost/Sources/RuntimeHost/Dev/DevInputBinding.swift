import DiagnosticsCore
import Foundation
import RuntimeCore

/// Keeps the development input route bound to the input channel of the Guest Agent (#024, decision D11).
///
/// A router sends on one channel and cannot change it, so the route is bound to a new router over a new channel. The
/// channel changes when the Guest Agent restarts: the control session then has a new token, and the input connection
/// is opened again. The binding looks at the control session a few times a second, and it binds again when the token
/// has changed or the bound channel is no longer usable. The binding runs until its task is cancelled.
struct DevInputBinding: Sendable {
    /// How often the control session is looked at.
    static let pollInterval: Duration = .milliseconds(250)

    let route: DevInputRoute
    let agent: DevelopmentGuestAgent
    let logSink: (any LogSink)?

    /// Binds the route now, and again after each restart of the agent, until the task is cancelled. A failure is
    /// reported once, and the binding tries again at the next look.
    func run(report: @escaping @Sendable (DevBootEvent) -> Void) async {
        var channel: GuestInputChannel?
        var boundToken: Data?
        var reportedFailure = false
        while !Task.isCancelled {
            if let token = await agent.supervisor.session?.sessionToken {
                var usable = false
                if let channel {
                    usable = await channel.connection.isUsable
                }
                if token != boundToken || !usable {
                    do {
                        let next = try await agent.inputChannel()
                        await route.bind(router: InputRouter(channel: next, logSink: logSink))
                        channel = next
                        boundToken = token
                        reportedFailure = false
                        report(.message("input is bound to display 0"))
                    } catch {
                        if !reportedFailure {
                            report(.warning("input is not bound: \(error.qualifiedCode)"))
                            reportedFailure = true
                        }
                    }
                }
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }
}
