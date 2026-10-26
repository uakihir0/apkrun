import Foundation

/// The user-controlled locale and clock preferences synchronized with Android.
public struct LocaleTimeSyncSettings: Equatable, Sendable {
    /// Whether Android follows the Mac's language list.
    public var syncLocale: Bool
    /// Whether Android follows the Mac's time zone.
    public var syncTimeZone: Bool
    /// Whether Android follows the Mac's 12/24-hour preference.
    public var syncClockFormat: Bool

    /// Creates locale-time settings with the documented defaults.
    public init(
        syncLocale: Bool = true,
        syncTimeZone: Bool = true,
        syncClockFormat: Bool = true
    ) {
        self.syncLocale = syncLocale
        self.syncTimeZone = syncTimeZone
        self.syncClockFormat = syncClockFormat
    }
}

/// A warning raised while synchronizing locale or time values.
public enum LocaleTimeWarning: String, CaseIterable, Equatable, Hashable, Sendable {
    /// The guest did not have the IANA time-zone identifier, so a fixed-offset zone was applied.
    case timeZoneFixedOffset
    /// The guest did not have the IANA time-zone identifier and the offset includes minutes.
    case timeZoneOffsetUnsupported
    /// The guest rejected the requested time-zone update.
    case timeZoneUpdateFailed
    /// The guest rejected the requested locale update.
    case localeUpdateFailed
    /// The guest rejected the requested clock-format update.
    case clockFormatUpdateFailed
    /// The guest rejected the wall-clock synchronization.
    case clockSyncFailed
}

/// A host event that should refresh locale preferences or the guest wall clock.
public enum LocaleTimeSyncTrigger: Equatable, Sendable {
    /// Android finished booting without an app launch in progress.
    case postBoot
    /// An app launch completed, allowing a deferred post-boot sync to run safely.
    case sessionRunning
    /// The Guest Agent completed a new handshake and snapshot.
    case guestReconnected
    /// A Language & Region setting changed.
    case hostPreferencesChanged
    /// The Mac language order or region changed.
    case hostLocaleChanged
    /// The Mac time zone changed.
    case timeZoneChanged
    /// The Mac wall clock changed.
    case systemClockChanged
    /// The Mac woke from sleep.
    case wake
    /// The periodic 30-minute refresh elapsed.
    case periodic
}

/// Identifies the guest response that needs special locale-time handling.
public enum LocaleTimeChannelFailure: Error, Equatable, Sendable {
    /// The guest image does not know the requested IANA time-zone ID.
    case timeZoneNotFound
}

/// Sends locale and clock values through the guest's versioned control protocol.
public protocol LocaleTimeGuestChannel: Sendable {
    /// Applies the ordered BCP 47 language list.
    func setLocale(_ languageTags: [String]) async throws
    /// Applies an IANA or fixed-offset time-zone identifier.
    func setTimeZone(_ identifier: String) async throws
    /// Applies the Android 12/24-hour preference.
    func setClockFormat(_ format: LocaleTimeSnapshot.ClockFormat) async throws
    /// Applies the Mac wall clock, accounting for half the measured ping round trip.
    func syncTime(unixTimeMilliseconds: Int64, roundTripMilliseconds: UInt32) async throws
}

/// Applies host locale-time settings to a ready Guest Agent connection.
///
/// The synchronizer remembers only acknowledged values, so a reconnect can clear the cache and replay
/// settings while ordinary 30-minute refreshes avoid restarting Android activities unnecessarily.
public actor LocaleTimeSynchronizer {
    private enum TimeZoneState: Equatable {
        case iana(String)
        case fixedOffset(sourceIdentifier: String, guestIdentifier: String)
        case unsupportedOffset(sourceIdentifier: String, secondsFromGMT: Int)

        var sourceIdentifier: String {
            switch self {
            case .iana(let identifier):
                identifier
            case .fixedOffset(let identifier, _), .unsupportedOffset(let identifier, _):
                identifier
            }
        }

        var needsPeriodicOffsetRefresh: Bool {
            switch self {
            case .iana:
                false
            case .fixedOffset, .unsupportedOffset:
                true
            }
        }
    }

    private let channel: any LocaleTimeGuestChannel
    private let snapshotBuilder: LocaleTimeSnapshotBuilder
    private let currentDate: @Sendable () -> Date
    private let onWarningsChanged: @Sendable ([LocaleTimeWarning]) async -> Void
    private let onLocaleApplied: @Sendable () async -> Void
    private var lastLocale: [String]?
    private var lastTimeZone: TimeZoneState?
    private var lastClockFormat: LocaleTimeSnapshot.ClockFormat?
    private var activeWarnings = Set<LocaleTimeWarning>()

    /// Creates a synchronizer with injectable host time sources and warning reporting.
    public init(
        channel: any LocaleTimeGuestChannel,
        snapshotBuilder: LocaleTimeSnapshotBuilder = LocaleTimeSnapshotBuilder(),
        currentDate: @escaping @Sendable () -> Date = { Date() },
        onWarningsChanged: @escaping @Sendable ([LocaleTimeWarning]) async -> Void = { _ in },
        onLocaleApplied: @escaping @Sendable () async -> Void = {}
    ) {
        self.channel = channel
        self.snapshotBuilder = snapshotBuilder
        self.currentDate = currentDate
        self.onWarningsChanged = onWarningsChanged
        self.onLocaleApplied = onLocaleApplied
    }

    /// Sends enabled preferences after the runtime is ready and no app is still launching.
    ///
    /// A false `sessionIsRunning` value deliberately performs no work. The caller can invoke this
    /// again once the session reaches `running`, preventing locale changes from restarting a
    /// foreground app during its launch path.
    @discardableResult
    public func synchronizePreferences(
        settings: LocaleTimeSyncSettings,
        sessionIsRunning: Bool
    ) async -> [LocaleTimeWarning] {
        await synchronizePreferences(
            settings: settings,
            sessionIsRunning: sessionIsRunning,
            refreshTimeZoneFallback: false
        )
    }

    private func synchronizePreferences(
        settings: LocaleTimeSyncSettings,
        sessionIsRunning: Bool,
        refreshTimeZoneFallback: Bool
    ) async -> [LocaleTimeWarning] {
        guard sessionIsRunning else {
            return sortedWarnings()
        }
        let snapshot = snapshotBuilder.build()
        var didApplyLocale = false
        if settings.syncLocale {
            if lastLocale != snapshot.languages {
                do {
                    try await channel.setLocale(snapshot.languages)
                    lastLocale = snapshot.languages
                    didApplyLocale = true
                    await clear(.localeUpdateFailed)
                } catch {
                    await raise(.localeUpdateFailed)
                }
            }
        } else {
            lastLocale = nil
            await clear(.localeUpdateFailed)
        }

        if settings.syncTimeZone {
            let isFallbackForCurrentZone =
                lastTimeZone?.sourceIdentifier == snapshot.timeZoneIdentifier
                && lastTimeZone?.needsPeriodicOffsetRefresh == true
            if lastTimeZone?.sourceIdentifier != snapshot.timeZoneIdentifier
                || (refreshTimeZoneFallback && isFallbackForCurrentZone)
            {
                await synchronizeTimeZone(
                    snapshot.timeZoneIdentifier,
                    refreshFallbackOffset: refreshTimeZoneFallback && isFallbackForCurrentZone
                )
            }
        } else {
            lastTimeZone = nil
            await clear(.timeZoneFixedOffset)
            await clear(.timeZoneOffsetUnsupported)
            await clear(.timeZoneUpdateFailed)
        }

        if settings.syncClockFormat {
            if lastClockFormat != snapshot.clockFormat {
                do {
                    try await channel.setClockFormat(snapshot.clockFormat)
                    lastClockFormat = snapshot.clockFormat
                    await clear(.clockFormatUpdateFailed)
                } catch {
                    await raise(.clockFormatUpdateFailed)
                }
            }
        } else {
            lastClockFormat = nil
            await clear(.clockFormatUpdateFailed)
        }
        if didApplyLocale {
            await onLocaleApplied()
        }
        return sortedWarnings()
    }

    /// Applies the work associated with one documented host event.
    ///
    /// Preference changes are checked on every trigger and only sent when their values changed.
    /// Wall-clock writes run after boot, after a deferred app launch, on a clock change, after wake,
    /// and during the periodic refresh. Locale-only events do not write the guest clock.
    @discardableResult
    public func synchronize(
        trigger: LocaleTimeSyncTrigger,
        settings: LocaleTimeSyncSettings,
        sessionIsRunning: Bool,
        roundTripMilliseconds: UInt32
    ) async -> [LocaleTimeWarning] {
        if trigger == .guestReconnected {
            guestDidReconnect()
        }
        _ = await synchronizePreferences(
            settings: settings,
            sessionIsRunning: sessionIsRunning,
            refreshTimeZoneFallback: trigger == .periodic
        )

        switch trigger {
        case .postBoot, .sessionRunning, .systemClockChanged, .wake, .periodic:
            return await synchronizeClock(
                roundTripMilliseconds: roundTripMilliseconds,
                sessionIsRunning: sessionIsRunning
            )
        case .guestReconnected, .hostPreferencesChanged, .hostLocaleChanged, .timeZoneChanged:
            return sortedWarnings()
        }
    }

    /// Sends the current wall clock when the guest session is running.
    @discardableResult
    public func synchronizeClock(
        roundTripMilliseconds: UInt32,
        sessionIsRunning: Bool
    ) async -> [LocaleTimeWarning] {
        guard sessionIsRunning else {
            return sortedWarnings()
        }
        let unixTimeMilliseconds = Int64((currentDate().timeIntervalSince1970 * 1_000).rounded())
        do {
            try await channel.syncTime(
                unixTimeMilliseconds: unixTimeMilliseconds,
                roundTripMilliseconds: roundTripMilliseconds
            )
            await clear(.clockSyncFailed)
        } catch {
            await raise(.clockSyncFailed)
        }
        return sortedWarnings()
    }

    /// Forgets acknowledged values so a newly connected agent receives the full current state.
    public func guestDidReconnect() {
        lastLocale = nil
        lastTimeZone = nil
        lastClockFormat = nil
    }

    /// Returns active locale-time warnings in stable order.
    public func warnings() -> [LocaleTimeWarning] {
        sortedWarnings()
    }

    private func synchronizeTimeZone(
        _ identifier: String,
        refreshFallbackOffset: Bool = false
    ) async {
        if refreshFallbackOffset {
            await refreshTimeZoneFallbackOffset(for: identifier)
            return
        }

        do {
            try await channel.setTimeZone(identifier)
            lastTimeZone = .iana(identifier)
            await clear(.timeZoneFixedOffset)
            await clear(.timeZoneOffsetUnsupported)
            await clear(.timeZoneUpdateFailed)
        } catch let failure as LocaleTimeChannelFailure {
            guard failure == .timeZoneNotFound else {
                await raise(.timeZoneUpdateFailed)
                return
            }
            guard let timeZone = TimeZone(identifier: identifier) else {
                await raise(.timeZoneUpdateFailed)
                return
            }
            let offset = timeZone.secondsFromGMT(for: currentDate())
            switch TimeZoneFallback.etcGMTIdentifier(secondsFromGMT: offset) {
            case .success(let fallbackIdentifier):
                do {
                    try await channel.setTimeZone(fallbackIdentifier)
                    lastTimeZone = .fixedOffset(
                        sourceIdentifier: identifier,
                        guestIdentifier: fallbackIdentifier
                    )
                    await raise(.timeZoneFixedOffset)
                    await clear(.timeZoneOffsetUnsupported)
                    await clear(.timeZoneUpdateFailed)
                } catch {
                    await raise(.timeZoneUpdateFailed)
                }
            case .failure:
                lastTimeZone = .unsupportedOffset(
                    sourceIdentifier: identifier,
                    secondsFromGMT: offset
                )
                await raise(.timeZoneOffsetUnsupported)
                await clear(.timeZoneFixedOffset)
                await clear(.timeZoneUpdateFailed)
            }
        } catch {
            await raise(.timeZoneUpdateFailed)
        }
    }

    private func refreshTimeZoneFallbackOffset(for identifier: String) async {
        guard let timeZone = TimeZone(identifier: identifier) else {
            await raise(.timeZoneUpdateFailed)
            return
        }

        let offset = timeZone.secondsFromGMT(for: currentDate())
        switch TimeZoneFallback.etcGMTIdentifier(secondsFromGMT: offset) {
        case .success(let fallbackIdentifier):
            if lastTimeZone
                == .fixedOffset(
                    sourceIdentifier: identifier,
                    guestIdentifier: fallbackIdentifier
                )
            {
                return
            }
            do {
                try await channel.setTimeZone(fallbackIdentifier)
                lastTimeZone = .fixedOffset(
                    sourceIdentifier: identifier,
                    guestIdentifier: fallbackIdentifier
                )
                await raise(.timeZoneFixedOffset)
                await clear(.timeZoneOffsetUnsupported)
                await clear(.timeZoneUpdateFailed)
            } catch {
                await raise(.timeZoneUpdateFailed)
            }
        case .failure:
            lastTimeZone = .unsupportedOffset(
                sourceIdentifier: identifier,
                secondsFromGMT: offset
            )
            await raise(.timeZoneOffsetUnsupported)
            await clear(.timeZoneFixedOffset)
            await clear(.timeZoneUpdateFailed)
        }
    }

    private func raise(_ warning: LocaleTimeWarning) async {
        guard activeWarnings.insert(warning).inserted else {
            return
        }
        await onWarningsChanged(sortedWarnings())
    }

    private func clear(_ warning: LocaleTimeWarning) async {
        guard activeWarnings.remove(warning) != nil else {
            return
        }
        await onWarningsChanged(sortedWarnings())
    }

    private func sortedWarnings() -> [LocaleTimeWarning] {
        LocaleTimeWarning.allCases.filter(activeWarnings.contains)
    }
}
