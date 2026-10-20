import DiagnosticsCore
import Foundation
import RuntimeCore

/// Keeps the development input route bound to the input channel of the Guest Agent (#25, decision D11).
///
/// A router sends on one channel and cannot change it, so the route is bound to a new router over a new channel. The
/// channel changes when the Guest Agent restarts: the control session then has a new token, and the input connection
/// is opened again. The binding looks at the control session a few times a second, and it binds again when the token
/// has changed or the bound channel is no longer usable. The binding runs until its task is cancelled.
struct DevInputBinding: Sendable {
    /// How often the control session is looked at.
    static let pollInterval: Duration = .milliseconds(250)

    let routes: [DevInputRoute]
    let agent: DevelopmentGuestAgent
    let logSink: (any LogSink)?

    init(route: DevInputRoute, agent: DevelopmentGuestAgent, logSink: (any LogSink)?) {
        routes = [route]
        self.agent = agent
        self.logSink = logSink
    }

    init(routes: [DevInputRoute], agent: DevelopmentGuestAgent, logSink: (any LogSink)?) {
        self.routes = routes
        self.agent = agent
        self.logSink = logSink
    }

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
                        let router = InputRouter(
                            channel: next,
                            focusDisplay: { displayID in
                                try await agent.focusDisplay(displayID: displayID)
                            },
                            logSink: logSink
                        )
                        var boundRoutes: [DevInputRoute] = []
                        for (index, route) in routes.enumerated() {
                            guard await route.canBind() else {
                                continue
                            }
                            let session = index == 0 ? DevInputRoute.developmentSession : .app(UUID())
                            if let failure = await route.bind(router: router, session: session) {
                                report(.warning("input route could not claim its display (\(failure))"))
                            } else if await route.canBind() {
                                boundRoutes.append(route)
                            }
                        }
                        await router.cancelAllRegisteredDisplays()
                        channel = next
                        boundToken = token
                        reportedFailure = false
                        let displayIDs = await boundRoutes.asyncMap { await $0.targetDisplayIDForDiagnostics() }
                        report(.message("input is bound to display\(displayIDs.count == 1 ? "" : "s") \(displayIDs)"))
                        report(.message("ADB shell invocations so far: \(await agent.adbShellInvocationCount)"))
                    } catch {
                        if !reportedFailure {
                            report(.catalogWarning(RuntimeFailure.inputNotBound(cause: error)))
                            reportedFailure = true
                        }
                    }
                }
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
        for route in routes {
            await route.unbind()
        }
    }
}

extension Sequence where Element == DevInputRoute {
    fileprivate func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var values: [T] = []
        for element in self {
            values.append(await transform(element))
        }
        return values
    }
}
