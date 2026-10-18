import Foundation
import Testing

@testable import APKStoreCore

@Test func packageIDAcceptsAndroidPackageGrammar() throws {
    let packageID = try #require(PackageID(rawValue: "org.Example_app.app2"))

    #expect(packageID.rawValue == "org.Example_app.app2")
    #expect(PackageID(rawValue: "a.b") != nil)
    #expect(PackageID(rawValue: "a." + String(repeating: "b", count: 253)) != nil)
    #expect(PackageID(rawValue: "a." + String(repeating: "b", count: 254)) == nil)
}

@Test func packageIDRejectsInvalidSegmentsAndNames() {
    for value in [
        "",
        "single",
        ".org.example",
        "org.example.",
        "org..example",
        "_org.example",
        "org._example",
        "org.2example",
        "org.ex-ample",
        "org.exämple",
    ] {
        #expect(PackageID(rawValue: value) == nil, "Unexpectedly accepted \(value)")
    }
}

@Test func packageIDCodableValidatesAndPreservesCase() throws {
    let encoded = try JSONEncoder().encode(try #require(PackageID(rawValue: "com.Example.app")))
    let decoded = try JSONDecoder().decode(PackageID.self, from: encoded)

    #expect(decoded.rawValue == "com.Example.app")
    #expect(PackageID(rawValue: "com.Example.app") != PackageID(rawValue: "com.example.app"))
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(PackageID.self, from: Data("\"not-a-package\"".utf8))
    }
}

@Test func versionCodeUsesSigned64BitAndroidLongVersionCode() {
    let versionCodeMajor: Int64 = 3
    let baseVersionCode: Int64 = 42
    let longVersionCode: VersionCode = (versionCodeMajor << 32) | baseVersionCode

    #expect(VersionCode.self == Int64.self)
    #expect(longVersionCode == 12_884_901_930)
    #expect(VersionCode(Int64.max) == Int64.max)
}

@Test func sha256DigestRequiresCanonicalLowercaseEncoding() throws {
    let digest = try #require(SHA256Digest(hex: String(repeating: "a", count: 64)))

    #expect(digest.rawValue == "sha256:" + String(repeating: "a", count: 64))
    #expect(digest.hexValue == String(repeating: "a", count: 64))
    #expect(SHA256Digest(rawValue: "sha256:" + String(repeating: "A", count: 64)) == nil)
    #expect(SHA256Digest(rawValue: "sha256:" + String(repeating: "a", count: 63)) == nil)
    #expect(
        SHA256Digest(data: Data("abc".utf8)).rawValue
            == "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

@Test func sha256DigestCodableUsesValidatedString() throws {
    let digest = try #require(SHA256Digest(hex: String(repeating: "0", count: 64)))
    let encoded = try JSONEncoder().encode(digest)
    let decoded = try JSONDecoder().decode(SHA256Digest.self, from: encoded)

    #expect(decoded == digest)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SHA256Digest.self, from: Data("\"sha256:xyz\"".utf8))
    }
}

@Test func artifactSetDigestIsStableAndSortedByFileName() throws {
    let base = ArtifactFile(
        name: "base.apk",
        splitName: nil,
        size: 100,
        sha256: try #require(SHA256Digest(hex: String(repeating: "a", count: 64)))
    )
    let density = ArtifactFile(
        name: "split_config.xhdpi.apk",
        splitName: "config.xhdpi",
        size: 50,
        sha256: try #require(SHA256Digest(hex: String(repeating: "b", count: 64)))
    )
    let expected = try #require(
        SHA256Digest(hex: "e430308563cd1363e84ca1c5b460efde5bcba5f4f5c8ac2f933c02cde3500af9")
    )

    #expect(try ArtifactSet.computeSetDigest(for: [base, density]) == expected)
    #expect(try ArtifactSet.computeSetDigest(for: [density, base]) == expected)
}

@Test func artifactSetDigestRejectsDuplicateFileNames() throws {
    let digest = try #require(SHA256Digest(hex: String(repeating: "c", count: 64)))
    let first = ArtifactFile(name: "base.apk", splitName: nil, size: 10, sha256: digest)
    let duplicate = ArtifactFile(name: "base.apk", splitName: "feature", size: 12, sha256: digest)

    #expect(throws: SetDigestError.duplicateFileName("base.apk")) {
        try ArtifactSet.computeSetDigest(for: [first, duplicate])
    }
}

@Test func packageStateCodableMatchesPersistedMetadataShape() throws {
    let encoder = JSONEncoder()

    #expect(String(data: try encoder.encode(PackageState.installed), encoding: .utf8) == "\"installed\"")
    #expect(
        String(data: try encoder.encode(PackageState.needsReinstall(.userdataReset)), encoding: .utf8)
            == "{\"needsReinstall\":{\"_0\":\"userdataReset\"}}"
    )

    let error = StoredError(domain: "store", code: "store.guestStorageFull")
    let state = PackageState.broken(.reinstallFailed(error))
    let encoded = try encoder.encode(state)
    let decoded = try JSONDecoder().decode(PackageState.self, from: encoded)
    #expect(decoded == state)

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(PackageState.self, from: Data("{\"installed\":{}}".utf8))
    }
}

@Test func updateProviderConfigurationUsesFlatProviderSpecificObject() throws {
    let provider = UpdateProviderRef(
        type: .direct,
        configuration: .direct(url: "https://example.org/manifest.json")
    )
    let encoded = try JSONEncoder().encode(provider)
    let object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    let configuration = try #require(object["configuration"] as? [String: String])

    #expect(object["type"] as? String == "direct")
    #expect(configuration == ["url": "https://example.org/manifest.json"])
    #expect(try JSONDecoder().decode(UpdateProviderRef.self, from: encoded) == provider)
}

@Test func packageRecordDefaultsToManualUpdateAuthority() throws {
    let date = Date(timeIntervalSince1970: 0)
    let record = PackageRecord(
        packageId: try #require(PackageID(rawValue: "com.example.app")),
        displayName: "Example",
        versionCode: 4_294_967_338,
        signingCertificates: [
            try #require(SHA256Digest(hex: String(repeating: "d", count: 64)))
        ],
        installer: .apkrun,
        state: .installed,
        artifacts: ArtifactSlots(currentMatchesAndroid: true),
        android: AndroidPackageFacts(
            minSdk: 24,
            targetSdk: 35,
            nativeAbis: [],
            userdataGeneration: UUID(uuidString: "622ec21f-5ab6-4077-8b13-293c025adcfb")!,
            lastSyncedAt: date
        ),
        source: PackageSource(kind: .adopted, at: date),
        createdAt: date,
        updatedAt: date
    )

    #expect(record.updateAuthority == .manual)
}
