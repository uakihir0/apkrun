import Testing

@testable import IntegrationCore

@Test func mapsWholeHourGMTOffsetsWithEtcGMTSignInverted() {
    let cases: [(Int, String)] = [
        (0, "Etc/GMT"),
        (5 * 3_600, "Etc/GMT-5"),
        (-8 * 3_600, "Etc/GMT+8"),
    ]

    for (secondsFromGMT, expectedIdentifier) in cases {
        #expect(
            TimeZoneFallback.etcGMTIdentifier(secondsFromGMT: secondsFromGMT)
                == .success(expectedIdentifier)
        )
    }
}

@Test func reportsNonWholeHourOffsetsAsUnsupported() {
    let cases = [19_800, -12_600]

    for secondsFromGMT in cases {
        #expect(
            TimeZoneFallback.etcGMTIdentifier(secondsFromGMT: secondsFromGMT)
                == .failure(.unsupportedNonWholeHourOffset(secondsFromGMT: secondsFromGMT))
        )
    }
}
