import Foundation

/// The host-owned language, time zone, and clock-format settings for the Android guest.
public struct LocaleTimeSnapshot: Equatable, Sendable {
    /// Android's `Settings.System.TIME_12_24` values.
    public enum ClockFormat: String, Equatable, Sendable {
        case twelveHour = "TWELVE"
        case twentyFourHour = "TWENTY_FOUR"
    }

    /// The preferred BCP 47 language tags, in priority order.
    public let languages: [String]
    /// The current IANA time-zone identifier.
    public let timeZoneIdentifier: String
    /// The current 12-hour or 24-hour clock preference.
    public let clockFormat: ClockFormat

    /// Creates a snapshot from already mapped host values.
    public init(languages: [String], timeZoneIdentifier: String, clockFormat: ClockFormat) {
        self.languages = languages
        self.timeZoneIdentifier = timeZoneIdentifier
        self.clockFormat = clockFormat
    }
}

/// Reads host locale settings and maps them to the guest's locale-time values.
public struct LocaleTimeSnapshotBuilder: Sendable {
    private let preferredLanguages: @Sendable () -> [String]
    private let currentLocale: @Sendable () -> Locale
    private let resetTimeZone: @Sendable () -> Void
    private let currentTimeZoneIdentifier: @Sendable () -> String
    private let dateFormatForHourCycle: @Sendable (Locale) -> String?

    /// Creates a builder with injectable host-value providers for deterministic tests.
    public init(
        preferredLanguages: @escaping @Sendable () -> [String] = { Locale.preferredLanguages },
        currentLocale: @escaping @Sendable () -> Locale = { Locale.autoupdatingCurrent },
        resetTimeZone: @escaping @Sendable () -> Void = { NSTimeZone.resetSystemTimeZone() },
        currentTimeZoneIdentifier: @escaping @Sendable () -> String = { TimeZone.current.identifier },
        dateFormatForHourCycle: @escaping @Sendable (Locale) -> String? = { locale in
            DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale)
        }
    ) {
        self.preferredLanguages = preferredLanguages
        self.currentLocale = currentLocale
        self.resetTimeZone = resetTimeZone
        self.currentTimeZoneIdentifier = currentTimeZoneIdentifier
        self.dateFormatForHourCycle = dateFormatForHourCycle
    }

    /// Reads the current host settings and maps them to the Android representation.
    public func build() -> LocaleTimeSnapshot {
        let locale = currentLocale()
        let languages = Self.languageTags(
            preferredLanguages: preferredLanguages(),
            regionIdentifier: locale.region?.identifier
        )

        resetTimeZone()
        let timeZoneIdentifier = currentTimeZoneIdentifier()
        let clockFormat: LocaleTimeSnapshot.ClockFormat =
            dateFormatForHourCycle(locale)?.contains("a") == true ? .twelveHour : .twentyFourHour

        return LocaleTimeSnapshot(
            languages: languages,
            timeZoneIdentifier: timeZoneIdentifier,
            clockFormat: clockFormat
        )
    }

    private static func languageTags(preferredLanguages: [String], regionIdentifier: String?) -> [String] {
        var languages = Array(preferredLanguages.prefix(8))
        guard let first = languages.first,
            let regionIdentifier
        else {
            return languages
        }
        languages[0] = insertingRegion(regionIdentifier, into: first)
        return languages
    }

    private static func insertingRegion(_ regionIdentifier: String, into languageTag: String) -> String {
        let region = regionIdentifier.uppercased()
        guard isRegion(region) else { return languageTag }

        let subtags = languageTag.split(separator: "-", omittingEmptySubsequences: false)
        guard let language = subtags.first, isLanguage(language) else { return languageTag }

        var insertionIndex = 1
        if language.count <= 3 {
            while insertionIndex < subtags.count,
                insertionIndex <= 3,
                isExtlang(subtags[insertionIndex])
            {
                insertionIndex += 1
            }
        }
        if insertionIndex < subtags.count, isScript(subtags[insertionIndex]) {
            insertionIndex += 1
        }
        if insertionIndex < subtags.count, isRegion(String(subtags[insertionIndex])) {
            return languageTag
        }

        var result = Array(subtags.prefix(insertionIndex).map(String.init))
        result.append(region)
        result.append(contentsOf: subtags.dropFirst(insertionIndex).map(String.init))
        return result.joined(separator: "-")
    }

    private static func isLanguage(_ subtag: Substring) -> Bool {
        (2...8).contains(subtag.count) && subtag.allSatisfy(\.isASCIIAlpha)
    }

    private static func isExtlang(_ subtag: Substring) -> Bool {
        subtag.count == 3 && subtag.allSatisfy(\.isASCIIAlpha)
    }

    private static func isScript(_ subtag: Substring) -> Bool {
        subtag.count == 4 && subtag.allSatisfy(\.isASCIIAlpha)
    }

    private static func isRegion(_ subtag: String) -> Bool {
        let characters = Array(subtag)
        return (characters.count == 2 && characters.allSatisfy(\.isASCIIAlpha))
            || (characters.count == 3 && characters.allSatisfy(\.isASCIIDigit))
    }
}

extension Character {
    fileprivate var isASCIIAlpha: Bool {
        ("A"..."Z").contains(self) || ("a"..."z").contains(self)
    }

    fileprivate var isASCIIDigit: Bool {
        ("0"..."9").contains(self)
    }
}
