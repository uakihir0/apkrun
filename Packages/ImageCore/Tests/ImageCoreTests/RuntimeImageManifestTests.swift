import Foundation
import Testing

@testable import ImageCore

/// `Images/tools/tests/fixtures/runtime-manifests/`, which Python checks as well (#66).
private let manifestFixtures: URL = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 {
        url.deleteLastPathComponent()
    }
    return url.appendingPathComponent("Images/tools/tests/fixtures/runtime-manifests")
}()

private func fixtureFiles(_ directory: String, suffix: String) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: manifestFixtures.appendingPathComponent(directory), includingPropertiesForKeys: nil
    )
    .filter { $0.lastPathComponent.hasSuffix(suffix) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

@Test
func everyValidFixtureLoadsAndRoundTrips() throws {
    let files = try fixtureFiles("valid", suffix: ".json")
    #expect(files.count == 7)
    for url in files {
        let data = try Data(contentsOf: url)
        let manifest = try RuntimeImageManifest.load(data)
        let encoded = try JSONEncoder().encode(manifest)
        #expect(try RuntimeImageManifest.load(encoded) == manifest, "\(url.lastPathComponent)")
    }
}

@Test
func everyInvalidFixtureFailsWithTheRuleItNames() throws {
    let files = try fixtureFiles("invalid", suffix: ".json")
    #expect(files.count == 44)
    for url in files {
        let name = url.deletingPathExtension().lastPathComponent
        let expected = try String(
            contentsOf: url.deletingLastPathComponent().appendingPathComponent("\(name).expected.txt"),
            encoding: .ascii
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try RuntimeImageManifest.load(try Data(contentsOf: url))
            Issue.record("\(name) must fail")
        } catch ImageFailure.manifestInvalid(_, let reason) {
            #expect(reason.hasPrefix("\(expected):"), "\(name): \(reason)")
        } catch {
            Issue.record("\(name) failed with \(error) instead of manifestInvalid")
        }
    }
}

@Test
func aStockManifestEncodesItsRequiredNullsAsNull() throws {
    let url = manifestFixtures.appendingPathComponent("valid/stock-cf16373615.json")
    let manifest = try RuntimeImageManifest.load(try Data(contentsOf: url))
    let text = String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)
    #expect(text.contains("\"pinnedManifestSHA256\":null"))
    #expect(text.contains("\"builderImageDigest\":null"))
    #expect(text.contains("\"guest\":null"))
    #expect(!text.contains("\"legal\""))
    #expect(!text.contains("\"composition\""))
}

@Test
func aComposedManifestKeepsCompositionProvenance() throws {
    let url = manifestFixtures.appendingPathComponent("valid/apkrun-composed-cf16373615.json")
    let manifest = try RuntimeImageManifest.load(try Data(contentsOf: url))
    #expect(manifest.kind == .apkrun)
    #expect(manifest.provenance.source.origin == "ci.android.com")
    #expect(manifest.provenance.composition?.sourceManifest.path == "Images/manifests/16373615/android-image.json")
    #expect(
        manifest.provenance.composition?.productInputs.map(\.path) == [
            "Guest/product/compose.json",
            "Guest/product/init/apkrun.rc",
            "Guest/product/prebuilt/ApkRunGuest.apk",
            "Guest/product/prebuilt/ApkRunGuest.json",
            "Guest/product/prebuilt/ApkRunStore.apk",
            "Guest/product/prebuilt/ApkRunStore.json",
        ])
    #expect(manifest.requirements.agents.map(\.package) == ["io.apkrun.guest", "io.apkrun.store"])
    #expect(
        manifest.provenance.composition?.testOverlayInputs?.map(\.path) == [
            "Tests/Fixtures/AndroidImageProduct/compose.json",
            "Tests/Fixtures/AndroidImageProduct/init/apkrun-test.rc",
        ])
    #expect(manifest.provenance.builderImageDigest == nil)
    let encoded = String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)
    #expect(encoded.contains("\"composition\""))
}

@Test
func aComposedGuestOnlyManifestRemainsCompatible() throws {
    let url = manifestFixtures.appendingPathComponent(
        "valid/apkrun-composed-guest-only-cf16373615.json"
    )
    let manifest = try RuntimeImageManifest.load(try Data(contentsOf: url))
    let composition = try #require(manifest.provenance.composition)
    #expect(manifest.kind == .apkrun)
    #expect(manifest.requirements.agents.map(\.package) == ["io.apkrun.guest"])
    #expect(
        !composition.productInputs.contains {
            $0.path == "Guest/product/prebuilt/ApkRunStore.apk"
                || $0.path == "Guest/product/prebuilt/ApkRunStore.json"
        })
}

@Test
func aCompositionRejectsTestOverlayOutsideTheFixedFixtureRoot() throws {
    let url = manifestFixtures.appendingPathComponent("valid/apkrun-composed-cf16373615.json")
    var document = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    )
    var provenance = try #require(document["provenance"] as? [String: Any])
    var composition = try #require(provenance["composition"] as? [String: Any])
    composition["testOverlayInputs"] = [
        ["path": "Guest/product/init/apkrun.rc", "sha256": String(repeating: "a", count: 64)]
    ]
    provenance["composition"] = composition
    document["provenance"] = provenance
    do {
        _ = try RuntimeImageManifest.load(try JSONSerialization.data(withJSONObject: document))
        Issue.record("test overlay provenance must stay under the fixed fixture root")
    } catch ImageFailure.manifestInvalid(let path, let reason) {
        #expect(path == "/provenance/composition/testOverlayInputs/0/path")
        #expect(reason.contains("AndroidImageProduct"))
    }
}

@Test
func anUnknownFieldAtAnyDepthIsRejected() throws {
    let url = manifestFixtures.appendingPathComponent("valid/stock-cf16373615.json")
    let original = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    var document = try #require(original)
    var provenance = try #require(document["provenance"] as? [String: Any])
    var source = try #require(provenance["source"] as? [String: Any])
    source["unexpected"] = true
    provenance["source"] = source
    document["provenance"] = provenance
    let data = try JSONSerialization.data(withJSONObject: document)
    do {
        _ = try RuntimeImageManifest.load(data)
        Issue.record("an unknown nested field must be rejected")
    } catch ImageFailure.manifestInvalid(let path, let reason) {
        #expect(reason.hasPrefix("schema:"), "\(reason)")
        #expect(reason.contains("unexpected"))
        #expect(path == "/provenance/source/unexpected")
    }
}

@Test
func aMissingNullableFieldIsRejectedEvenWhenItIsNull() throws {
    let url = manifestFixtures.appendingPathComponent("valid/stock-cf16373615.json")
    var document = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    )
    var provenance = try #require(document["provenance"] as? [String: Any])
    provenance.removeValue(forKey: "reference")
    document["provenance"] = provenance
    do {
        _ = try RuntimeImageManifest.load(try JSONSerialization.data(withJSONObject: document))
        Issue.record("reference is required, even as null")
    } catch ImageFailure.manifestInvalid(_, let reason) {
        #expect(reason.hasPrefix("schema:"), "\(reason)")
    }
}

@Test
func aNewerSchemaVersionNeedsANewerAPKRun() throws {
    let url = manifestFixtures.appendingPathComponent("valid/stock-cf16373615.json")
    var document = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    )
    document["schemaVersion"] = 2
    do {
        _ = try RuntimeImageManifest.load(try JSONSerialization.data(withJSONObject: document))
        Issue.record("schemaVersion 2 must be refused")
    } catch ImageFailure.manifestInvalid(let path, let reason) {
        #expect(path == "manifest.json")
        #expect(reason == "needs a newer APKRun")
    }
}

@Test
func anOversizedManifestIsRefusedBeforeParsing() {
    let data = Data(repeating: 0x20, count: 1024 * 1024 + 1)
    #expect(throws: ImageFailure.self) {
        _ = try RuntimeImageManifest.load(data)
    }
}
