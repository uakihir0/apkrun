import DiagnosticsCore
import Foundation
import RuntimeCore

/// An input channel and the connection state that tells the binding when it must be replaced.
struct DevInputBindingChannel: Sendable {
    let input: any InputChannel
    let isUsable: @Sendable () async -> Bool
}

typealias DevBoundInputChannel = DevInputBindingChannel

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
    private let pollInterval: Duration
    private let routeActivation: DevInputRouteActivation

    init(
        route: DevInputRoute,
        agent: DevelopmentGuestAgent,
        logSink: (any LogSink)?,
        pollInterval: Duration = Self.pollInterval
    ) {
        self.init(routes: [route], agent: agent, logSink: logSink, pollInterval: pollInterval)
    }

    init(
        routes: [DevInputRoute],
        agent: DevelopmentGuestAgent,
        logSink: (any LogSink)?,
        pollInterval: Duration = Self.pollInterval
    ) {
        self.init(
            routes: routes,
            stateUpdates: { await agent.supervisor.stateUpdates() },
            sessionToken: { await agent.supervisor.readySessionToken() },
            openInputChannel: { () async throws(GuestAgentFailure) -> DevInputBindingChannel in
                let input = try await agent.inputChannel()
                return DevInputBindingChannel(
                    input: input,
                    isUsable: { await input.connection.isUsable }
                )
            },
            focusDisplay: { displayID in try await agent.focusDisplay(displayID: displayID) },
            adbShellInvocationCount: { await agent.adbShellInvocationCount },
            logSink: logSink,
            pollInterval: pollInterval
        )
    }

    /// Dependency injection keeps the loss/rebind lifecycle testable without a VM.
    init(
        routes: [DevInputRoute],
        stateUpdates: @escaping @Sendable () async -> AsyncStream<GuestAgentSupervisor.State> = {
            AsyncStream { continuation in continuation.finish() }
        },
        sessionToken: @escaping @Sendable () async -> Data?,
        openInputChannel: @escaping @Sendable () async throws(GuestAgentFailure) -> DevInputBindingChannel,
        focusDisplay: @escaping InputRouter.FocusDisplayOperation,
        adbShellInvocationCount: @escaping @Sendable () async -> Int,
        logSink: (any LogSink)?,
        pollInterval: Duration = Self.pollInterval,
        routeActivation: DevInputRouteActivation = DevInputRouteActivation()
    ) {
        self.routes = routes
        self.stateUpdates = stateUpdates
        self.sessionToken = sessionToken
        self.openInputChannel = openInputChannel
        self.focusDisplay = focusDisplay
        self.adbShellInvocationCount = adbShellInvocationCount
        self.logSink = logSink
        self.pollInterval = pollInterval
        self.routeActivation = routeActivation
    }

    /// Binds the route now, and again after each restart of the agent, until the task is cancelled. A failure is
    /// reported once, and the binding tries again at the next look.
    func run(report: @escaping @Sendable (DevBootEvent) -> Void) async {
        let logger = APKLogger(category: InputLogCategory.route, sink: logSink)
        let (wakes, wakeContinuation) = AsyncStream.makeStream(
            of: Wake.self,
            bufferingPolicy: .bufferingNewest(16)
        )
        let updates = await stateUpdates()
        let stateTask = Task {
            for await state in updates {
                if state != .ready {
                    routeActivation.deactivate()
                }
                wakeContinuation.yield(.state(state))
            }
        }
        let pollTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: pollInterval)
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
        var hasBoundBefore = false
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
                    await releaseRoutes(cancelGuestState: false)
                    channel = nil
                    boundToken = nil
                    reportedFailure = false
                    continue
                }
                state = .ready
            }

            guard state == .ready, let token = await sessionToken() else {
                await releaseRoutes(cancelGuestState: false)
                channel = nil
                boundToken = nil
                reportedFailure = false
                continue
            }

            var usable = false
            if let boundChannel = channel {
                usable = await boundChannel.isUsable()
                guard await sessionToken() == token else {
                    await releaseRoutes(cancelGuestState: false)
                    channel = nil
                    boundToken = nil
                    reportedFailure = false
                    continue
                }
            }
            guard token != boundToken || !usable else {
                continue
            }

            if channel != nil {
                // A different session token or a broken input stream makes the current router unusable. Detach it
                // before opening another stream so failed open attempts cannot leave the window sending to a dead
                // channel.
                await releaseRoutes(cancelGuestState: false)
                channel = nil
                boundToken = nil
                reportedFailure = false
            }

            do {
                let activationGeneration = routeActivation.activationGeneration
                let next = try await openInputChannel()
                guard await sessionToken() == token else {
                    continue
                }
                guard await next.isUsable() else {
                    continue
                }
                guard await sessionToken() == token else {
                    continue
                }
                routeActivation.setInputChannelUsabilityCheck(next.isUsable)
                let router = InputRouter(
                    channel: next.input,
                    focusDisplay: focusDisplay,
                    logSink: logSink
                )
                var preparedRoutes: [(route: DevInputRoute, session: SessionID, displayID: Int32)] = []
                for (index, route) in routes.enumerated() {
                    guard await route.canBind() else {
                        continue
                    }
                    let session = index == 0 ? DevInputRoute.developmentSession : .app(UUID())
                    switch await route.prepareBinding(
                        router: router,
                        session: session,
                        activation: routeActivation
                    ) {
                    case .prepared:
                        preparedRoutes.append(
                            (route, session, await route.targetDisplayIDForDiagnostics())
                        )
                    case .unavailable:
                        continue
                    case .failed(let failure):
                        report(.warning("input route could not claim its display (\(failure))"))
                    }
                }
                guard await next.isUsable(), await sessionToken() == token else {
                    for prepared in preparedRoutes {
                        await prepared.route.discardPreparedBinding(cancelGuestState: false)
                    }
                    continue
                }
                await router.cancelAllRegisteredDisplays()
                guard await next.isUsable(), await sessionToken() == token else {
                    for prepared in preparedRoutes {
                        await prepared.route.discardPreparedBinding(cancelGuestState: false)
                    }
                    continue
                }
                var displayIDs: [Int32] = []
                for prepared in preparedRoutes {
                    if await prepared.route.activatePreparedBinding(session: prepared.session) {
                        displayIDs.append(prepared.displayID)
                    }
                }
                guard await next.isUsable(), await sessionToken() == token else {
                    await releaseRoutes(cancelGuestState: false)
                    continue
                }
                guard routeActivation.activate(ifUnchangedSince: activationGeneration) else {
                    await releaseRoutes(cancelGuestState: false)
                    continue
                }
                channel = next
                boundToken = token
                reportedFailure = false
                if hasBoundBefore {
                    logger.notice("The input route is bound again to a live input connection")
                    report(.message("input is bound again to a live input connection"))
                }
                hasBoundBefore = true
                report(.message("input is bound to display\(displayIDs.count == 1 ? "" : "s") \(displayIDs)"))
                report(.message("ADB shell invocations so far: \(await adbShellInvocationCount())"))
            } catch {
                if !reportedFailure {
                    report(.catalogWarning(RuntimeFailure.inputNotBound(cause: error)))
                    reportedFailure = true
                }
            }
        }
        routeActivation.deactivate()
        let cancelGuestState = await channel?.isUsable() ?? false
        await releaseRoutes(cancelGuestState: cancelGuestState)
    }

    private func releaseRoutes(cancelGuestState: Bool) async {
        routeActivation.deactivate()
        for route in routes {
            await route.unbind(cancelGuestState: cancelGuestState)
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
