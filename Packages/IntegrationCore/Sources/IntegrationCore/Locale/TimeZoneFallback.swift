/// Maps a host GMT offset to an Android-recognized fixed-offset time-zone identifier.
///
/// Android's `Etc/GMT` identifiers use the POSIX sign convention, which is the inverse of GMT
/// offsets: a host offset of GMT+5 maps to `Etc/GMT-5`.
public enum TimeZoneFallback {
    /// A whole-hour offset becomes an `Etc/GMT` identifier. Offsets containing minutes are not
    /// representable by `Etc/GMT` and are returned as a typed failure.
    public static func etcGMTIdentifier(
        secondsFromGMT: Int
    ) -> Result<String, TimeZoneFallbackFailure> {
        let secondsPerHour = 3_600
        guard secondsFromGMT.isMultiple(of: secondsPerHour) else {
            return .failure(.unsupportedNonWholeHourOffset(secondsFromGMT: secondsFromGMT))
        }

        let hoursFromGMT = secondsFromGMT / secondsPerHour
        guard hoursFromGMT != 0 else {
            return .success("Etc/GMT")
        }

        let etcGMTSign = hoursFromGMT > 0 ? "-" : "+"
        return .success("Etc/GMT\(etcGMTSign)\(abs(hoursFromGMT))")
    }
}

/// Why a host time-zone offset cannot be represented by an `Etc/GMT` identifier.
public enum TimeZoneFallbackFailure: Error, Equatable, Sendable {
    /// `Etc/GMT` accepts only whole-hour offsets.
    case unsupportedNonWholeHourOffset(secondsFromGMT: Int)
}
