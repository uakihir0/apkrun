import Foundation
import ImageCore
import XCTest

final class G2TestImageTrustStoreTests: XCTestCase {
    func testStockBundleKeepsTheStandardTrustStore() throws {
        let fixture = try bundle(manifest: #"{"kind":"stock"}"#)
        let standard = ImageTrustStore(keys: [])

        let trust = try G2TestImageTrustStore.make(for: fixture, standard: standard)

        XCTAssertEqual(trust, standard)
    }

    func testComposedBundleAddsFixtureKeyWithoutReplacingStandardKeys() throws {
        let fixture = try bundle(
            manifest: #"{"kind":"apkrun","provenance":{"composition":{"schemaVersion":1}}}"#
        )
        let developerKey = ImageTrustStore.Key(publicKey: Data(repeating: 7, count: 32))
        let standard = ImageTrustStore(keys: [developerKey])

        let trust = try G2TestImageTrustStore.make(for: fixture, standard: standard)

        let fixturePublicKeyURL = try XCTUnwrap(
            Bundle(for: G2TestTrustTestBundleMarker.self)
                .url(forResource: "test-image-ed25519", withExtension: "pub")
        )
        let fixturePublicKeyText = try String(contentsOf: fixturePublicKeyURL, encoding: .utf8)
        let fixturePublicKey = try XCTUnwrap(
            Data(base64Encoded: fixturePublicKeyText.trimmingCharacters(in: .whitespacesAndNewlines))
        )
        let fixtureKeyID = ImageSignature.keyID(of: fixturePublicKey)

        XCTAssertEqual(trust.key(for: developerKey.keyID), developerKey)
        XCTAssertNotNil(trust.key(for: fixtureKeyID))
        XCTAssertNil(ImageTrustStore.release.key(for: fixtureKeyID))
    }

    func testComposedBundleDoesNotAddTheFixtureKeyToTheStandardStore() throws {
        let fixture = try bundle(
            manifest: #"{"kind":"apkrun","provenance":{"composition":{"schemaVersion":1}}}"#
        )
        let standard = ImageTrustStore(keys: [])

        _ = try G2TestImageTrustStore.make(for: fixture, standard: standard)

        let fixturePublicKeyURL = try XCTUnwrap(
            Bundle(for: G2TestTrustTestBundleMarker.self)
                .url(forResource: "test-image-ed25519", withExtension: "pub")
        )
        let fixturePublicKeyText = try String(contentsOf: fixturePublicKeyURL, encoding: .utf8)
        let fixturePublicKey = try XCTUnwrap(
            Data(base64Encoded: fixturePublicKeyText.trimmingCharacters(in: .whitespacesAndNewlines))
        )
        let fixtureKeyID = ImageSignature.keyID(of: fixturePublicKey)

        XCTAssertNil(standard.key(for: fixtureKeyID))
        XCTAssertNil(ImageTrustStore.standard(home: temporaryDirectory()).key(for: fixtureKeyID))
    }

    private func bundle(manifest: String) throws -> URL {
        let directory = temporaryDirectory().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: directory.appendingPathComponent("manifest.json"))
        return directory
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-g2-image-trust-\(UUID().uuidString)", isDirectory: true)
    }
}

private final class G2TestTrustTestBundleMarker: NSObject {}
