import DiagnosticsCore
import Foundation
import IntegrationCore
import RuntimeCore

enum LocaleTimeReconnectReadiness {
    static func waitForReady(
        states: AsyncStream<GuestAgentSupervisor.State>,
        onReady: @Sendable () async -> Void
    ) async {
        for await state in states {
            switch state {
            case .ready:
                await onReady()
                return
            case .stopped, .incompatible, .unavailable:
                return
            case .connecting, .reconnecting, .unresponsive:
                continue
            }
        }
    }
}

enum LocaleTimeHostSettings {
    static let suiteName = "io.apkrun"
    static let changedNotification = Notification.Name("io.apkrun.system.localeTimeSettingsDidChange")

    private enum Key {
        static let syncLocale = "system.syncLocale"
        static let syncTimeZone = "system.syncTimeZone"
        static let syncClockFormat = "system.syncClockFormat"
    }

    static func current() -> LocaleTimeSyncSettings {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return LocaleTimeSyncSettings()
        }
        defaults.register(defaults: [
            Key.syncLocale: true,
            Key.syncTimeZone: true,
            Key.syncClockFormat: true,
        ])
        return LocaleTimeSyncSettings(
            syncLocale: defaults.bool(forKey: Key.syncLocale),
            syncTimeZone: defaults.bool(forKey: Key.syncTimeZone),
            syncClockFormat: defaults.bool(forKey: Key.syncClockFormat)
        )
    }
}

struct DevelopmentGuestLocaleTimeChannel: LocaleTimeGuestChannel {
    private let agent: DevelopmentGuestAgent

    init(agent: DevelopmentGuestAgent) {
        self.agent = agent
    }

    func setLocale(_ languageTags: [String]) async throws {
        try await agent.applyLocale(languageTags)
    }

    func setTimeZone(_ identifier: String) async throws {
        switch try await agent.applyTimeZone(identifier) {
        case .applied:
            break
        case .notFound:
            throw LocaleTimeChannelFailure.timeZoneNotFound
        }
    }

    func setClockFormat(_ format: LocaleTimeSnapshot.ClockFormat) async throws {
        try await agent.applyClockFormat(isTwentyFourHour: format == .twentyFourHour)
    }

    func syncTime(unixTimeMilliseconds: Int64, roundTripMilliseconds: UInt32) async throws {
        try await agent.synchronizeWallClock(
            unixTimeMilliseconds: unixTimeMilliseconds,
            roundTripMilliseconds: roundTripMilliseconds
        )
    }
}

struct LocaleTimeHealthCheck: HealthCheck {
    private let currentWarnings: @Sendable () async -> [LocaleTimeWarning]

    let id = "integrations.time"
    let group = HealthGroup.integrations
    let requirement = HealthRequirement.runningRuntime
    let cost = HealthCost.quick
    let title = LocalizedText(key: "integrations.time", fallback: "Locale and time")

    init(currentWarnings: @escaping @Sendable () async -> [LocaleTimeWarning]) {
        self.currentWarnings = currentWarnings
    }

    func run(_ context: HealthContext) async -> HealthResult {
        let warnings = await currentWarnings()
        let isWarning = !warnings.isEmpty
        let error =
            isWarning
            ? ErrorInfo(
                code: "runtime.timeSyncFailed",
                message: LocalizedText(
                    key: "runtime.timeSyncFailed",
                    fallback: "Android's clock or time zone may differ from the Mac's."
                ),
                remediation: LocalizedText(
                    key: "runtime.timeSyncFailed.remediation",
                    fallback: "Restart Android. If it happens again, create a diagnostics report."
                ),
                action: .restartAndroid
            )
            : nil
        return HealthResult(
            id: id,
            group: group,
            state: isWarning ? .warning : .pass,
            title: title,
            detail: isWarning ? warnings.map(\.rawValue).joined(separator: ", ") : nil,
            error: error,
            measuredAt: context.clock.now
        )
    }
}
