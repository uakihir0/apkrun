import Foundation
import Testing

@testable import ImageCore

/// `Images/tools/tests/fixtures/runtime-manifests/`, which Python checks as well (#065).
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
    #expect(files.count == 3)
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
    #expect(files.count == 27)
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
