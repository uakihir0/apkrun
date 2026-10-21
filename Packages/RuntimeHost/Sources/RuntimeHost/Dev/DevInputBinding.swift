import DiagnosticsCore
import Foundation
import RuntimeCore

/// An input channel and the liveness check for its transport.
struct DevBoundInputChannel: Sendable {
    let input: any InputChannel
    let isUsable: @Sendable () async -> Bool
}

/// Keeps the development input routes bound to the input channel of the Guest Agent (#25, decision D11).
///
/// A router sends on one channel and cannot change it, so the routes bind to a new router over a new channel. The
/// channel changes when the Guest Agent restarts: the control session then has a new token, and the input connection
/// is opened again. When the control session ends, the routes are unbound until the next session is ready. The binding
/// runs until its task is cancelled.
struct DevInputBinding: Sendable {
    /// How often the control session is looked at.
    static let pollInterval: Duration = .milliseconds(250)

    let routes: [DevInputRoute]
    let logSink: (any LogSink)?
    private let currentSessionToken: @Sendable () async -> Data?
    private let openInputChannel: @Sendable () async throws(GuestAgentFailure) -> DevBoundInputChannel
    private let focusDisplay: @Sendable (Int32) async throws(GuestAgentFailure) -> Void
    private let adbShellInvocationCount: @Sendable () async -> Int
    private let pollingInterval: Duration

    init(route: DevInputRoute, agent: DevelopmentGuestAgent, logSink: (any LogSink)?) {
        self.init(routes: [route], agent: agent, logSink: logSink)
    }

    init(routes: [DevInputRoute], agent: DevelopmentGuestAgent, logSink: (any LogSink)?) {
        self.init(
            routes: routes,
            currentSessionToken: { await agent.supervisor.readySessionToken() },
            openInputChannel: {
                () async throws(GuestAgentFailure) -> DevBoundInputChannel in
                let channel = try await agent.inputChannel()
                return DevBoundInputChannel(
                    input: channel,
                    isUsable: { await channel.connection.isUsable }
                )
            },
            focusDisplay: {
                (displayID: Int32) async throws(GuestAgentFailure) -> Void in
                try await agent.focusDisplay(displayID: displayID)
            },
            adbShellInvocationCount: { await agent.adbShellInvocationCount },
            logSink: logSink,
            pollingInterval: Self.pollInterval
        )
    }

    init(
        routes: [DevInputRoute],
        currentSessionToken: @escaping @Sendable () async -> Data?,
        openInputChannel: @escaping @Sendable () async throws(GuestAgentFailure) -> DevBoundInputChannel,
        focusDisplay: @escaping @Sendable (Int32) async throws(GuestAgentFailure) -> Void,
        adbShellInvocationCount: @escaping @Sendable () async -> Int,
        logSink: (any LogSink)? = nil,
        pollingInterval: Duration = Self.pollInterval
    ) {
        self.routes = routes
        self.currentSessionToken = currentSessionToken
        self.openInputChannel = openInputChannel
        self.focusDisplay = focusDisplay
        self.adbShellInvocationCount = adbShellInvocationCount
        self.logSink = logSink
        self.pollingInterval = pollingInterval
    }

    /// Binds the routes now, and again after each restart of the agent, until the task is cancelled. A failure is
    /// reported once, and the binding tries again at the next look.
    func run(report: @escaping @Sendable (DevBootEvent) -> Void) async {
        let logger = APKLogger(category: InputLogCategory.route, sink: logSink)
        var channel: DevBoundInputChannel?
        var boundToken: Data?
        var hasBoundBefore = false
        var reportedFailure = false
        while !Task.isCancelled {
            if let token = await currentSessionToken() {
                let usable = await channel?.isUsable() ?? false
                if token != boundToken || !usable {
                    if channel != nil {
                        // The old input stream belongs to a different or closed Guest Agent session. The guest
                        // releases its input state when that stream closes, so do not send another cancelAll on it.
                        for route in routes {
                            await route.unbind(cancelGuestState: false)
                        }
                        channel = nil
                        boundToken = nil
                    }
                    do {
                        let next = try await openInputChannel()
                        // Recovery may replace the control session while the secondary connection opens. Retry under
                        // that session's token, and do not bind a secondary channel that has already closed (#101).
                        guard await currentSessionToken() == token, await next.isUsable() else {
                            try? await Task.sleep(for: pollingInterval)
                            continue
                        }
                        let router = InputRouter(
                            channel: next.input,
                            focusDisplay: { displayID in
                                try await focusDisplay(displayID)
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
                        guard await currentSessionToken() == token, await next.isUsable() else {
                            for route in routes {
                                await route.unbind(cancelGuestState: false)
                            }
                            try? await Task.sleep(for: pollingInterval)
                            continue
                        }
                        await router.cancelAllRegisteredDisplays()
                        guard await currentSessionToken() == token, await next.isUsable() else {
                            for route in routes {
                                await route.unbind(cancelGuestState: false)
                            }
                            try? await Task.sleep(for: pollingInterval)
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
            } else if channel != nil {
                // A missing control session means the old secondary connection is no longer a valid input route.
                for route in routes {
                    await route.unbind(cancelGuestState: false)
                }
                channel = nil
                boundToken = nil
            }
            try? await Task.sleep(for: pollingInterval)
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
