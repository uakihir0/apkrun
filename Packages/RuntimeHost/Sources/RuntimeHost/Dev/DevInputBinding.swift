import DiagnosticsCore
import Foundation
import RuntimeCore

/// An input channel and the connection state that tells the binding when it must be replaced.
struct DevInputBindingChannel: Sendable {
    let input: any InputChannel
    let isUsable: @Sendable () async -> Bool
}

/// Keeps the development input route bound to the input channel of the Guest Agent (#25, decision D11).
///
/// A router sends on one channel and cannot change it, so the route is bound to a new router over a new channel.
/// The binding releases the route as soon as the supervisor reports a lost connection, and binds it again after the
/// next control session is ready. It also checks periodically for an input-only connection failure.
struct DevInputBinding: Sendable {
    /// How often the input connection is checked when the control session remains ready.
    static let pollInterval: Duration = .milliseconds(250)

    private enum Wake: Sendable {
        case state(GuestAgentSupervisor.State)
        case poll
    }

    private let routes: [DevInputRoute]
    private let stateUpdates: @Sendable () async -> AsyncStream<GuestAgentSupervisor.State>
    private let sessionToken: @Sendable () async -> Data?
    private let openInputChannel: @Sendable () async throws(GuestAgentFailure) -> DevInputBindingChannel
    private let focusDisplay: InputRouter.FocusDisplayOperation
    private let adbShellInvocationCount: @Sendable () async -> Int
    private let logSink: (any LogSink)?

    init(route: DevInputRoute, agent: DevelopmentGuestAgent, logSink: (any LogSink)?) {
        self.init(routes: [route], agent: agent, logSink: logSink)
    }

    init(routes: [DevInputRoute], agent: DevelopmentGuestAgent, logSink: (any LogSink)?) {
        self.init(
            routes: routes,
            stateUpdates: { await agent.supervisor.stateUpdates() },
            sessionToken: { await agent.supervisor.session?.sessionToken },
            openInputChannel: { () async throws(GuestAgentFailure) -> DevInputBindingChannel in
                let input = try await agent.inputChannel()
                return DevInputBindingChannel(
                    input: input,
                    isUsable: { await input.connection.isUsable }
                )
            },
            focusDisplay: { displayID in try await agent.focusDisplay(displayID: displayID) },
            adbShellInvocationCount: { await agent.adbShellInvocationCount },
            logSink: logSink
        )
    }

    /// Dependency injection keeps the loss/rebind lifecycle testable without a VM.
    init(
        routes: [DevInputRoute],
        stateUpdates: @escaping @Sendable () async -> AsyncStream<GuestAgentSupervisor.State>,
        sessionToken: @escaping @Sendable () async -> Data?,
        openInputChannel: @escaping @Sendable () async throws(GuestAgentFailure) -> DevInputBindingChannel,
        focusDisplay: @escaping InputRouter.FocusDisplayOperation,
        adbShellInvocationCount: @escaping @Sendable () async -> Int,
        logSink: (any LogSink)?
    ) {
        self.routes = routes
        self.stateUpdates = stateUpdates
        self.sessionToken = sessionToken
        self.openInputChannel = openInputChannel
        self.focusDisplay = focusDisplay
        self.adbShellInvocationCount = adbShellInvocationCount
        self.logSink = logSink
    }

    /// Binds the route now, and again after each restart of the agent, until the task is cancelled. A failure is
    /// reported once, and the binding tries again at the next look.
    func run(report: @escaping @Sendable (DevBootEvent) -> Void) async {
        let (wakes, wakeContinuation) = AsyncStream.makeStream(
            of: Wake.self,
            bufferingPolicy: .bufferingNewest(16)
        )
        let updates = await stateUpdates()
        let stateTask = Task {
            for await state in updates {
                wakeContinuation.yield(.state(state))
            }
        }
        let pollTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.pollInterval)
                } catch {
                    return
                }
                wakeContinuation.yield(.poll)
            }
        }
        defer {
            stateTask.cancel()
            pollTask.cancel()
            wakeContinuation.finish()
        }

        var channel: DevInputBindingChannel?
        var boundToken: Data?
        var reportedFailure = false
        for await wake in wakes {
            guard !Task.isCancelled else {
                break
            }
            let state: GuestAgentSupervisor.State
            switch wake {
            case .state(let updated):
                state = updated
            case .poll:
                // Session loss clears the token before its state notification. Checking it on the poll path also
                // handles a missed or coalesced notification without retaining the dead route.
                guard await sessionToken() != nil else {
                    await releaseRoutes()
                    channel = nil
                    boundToken = nil
                    reportedFailure = false
                    continue
                }
                state = .ready
            }

            guard state == .ready, let token = await sessionToken() else {
                await releaseRoutes()
                channel = nil
                boundToken = nil
                reportedFailure = false
                continue
            }

            var usable = false
            if let channel {
                usable = await channel.isUsable()
            }
            guard token != boundToken || !usable else {
                continue
            }

            if channel != nil {
                // A different session token or a broken input stream makes the current router unusable. Detach it
                // before opening another stream so failed open attempts cannot leave the window sending to a dead
                // channel.
                await releaseRoutes()
                channel = nil
                boundToken = nil
                reportedFailure = false
            }

            do {
                let next = try await openInputChannel()
                let router = InputRouter(
                    channel: next.input,
                    focusDisplay: focusDisplay,
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
                report(.message("ADB shell invocations so far: \(await adbShellInvocationCount())"))
            } catch {
                if !reportedFailure {
                    report(.catalogWarning(RuntimeFailure.inputNotBound(cause: error)))
                    reportedFailure = true
                }
            }
        }
        await releaseRoutes()
    }

    private func releaseRoutes() async {
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
