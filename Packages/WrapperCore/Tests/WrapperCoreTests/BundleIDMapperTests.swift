import RuntimeAPI
import Testing

@testable import WrapperCore

@Test func bundleIDMapperMatchesDesignExamples() throws {
    let examples = [
        ("com.discord", "io.apkrun.android.com.discord"),
        ("org.mozilla.fenix", "io.apkrun.android.org.mozilla.fenix"),
        ("com.example.my_app", "io.apkrun.android.com.example.my-app"),
        ("com.UCMobile.intl", "io.apkrun.android.com.UCMobile.intl-h12958863"),
    ]

    for (rawPackageID, expectedBundleID) in examples {
        let packageID = try #require(RuntimePackageID(rawValue: rawPackageID))
        #expect(BundleIDMapper.map(packageID) == expectedBundleID)
    }
}

@Test func bundleIDMapperIsDeterministicAndCaseDistinctForOneThousandIDs() throws {
    var state: UInt64 = 0x7a31_4d29_8520_b6c1
    let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
    var mappedBundleIDs = Set<String>()

    for index in 0..<1_000 {
        var randomSegment = "p"
        for _ in 0..<12 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            randomSegment.append(alphabet[Int((state >> 32) % UInt64(alphabet.count))])
        }
        let rawPackageID = "com.\(randomSegment).app\(index)"
        let packageID = try #require(RuntimePackageID(rawValue: rawPackageID))
        let bundleID = BundleIDMapper.map(packageID)

        #expect(BundleIDMapper.map(packageID) == bundleID)
        #expect(bundleID.hasPrefix("io.apkrun.android."))
        #expect(
            bundleID.unicodeScalars.allSatisfy { scalar in
                (65...90).contains(scalar.value)
                    || (97...122).contains(scalar.value)
                    || (48...57).contains(scalar.value)
                    || scalar.value == 45
                    || scalar.value == 46
            })
        mappedBundleIDs.insert(bundleID.lowercased())
    }

    #expect(mappedBundleIDs.count == 1_000)

    let lowercasePackageID = try #require(RuntimePackageID(rawValue: "com.example.app"))
    let uppercasePackageID = try #require(RuntimePackageID(rawValue: "com.Example.app"))
    #expect(BundleIDMapper.map(lowercasePackageID).lowercased() != BundleIDMapper.map(uppercasePackageID).lowercased())
}
