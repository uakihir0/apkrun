import Foundation
import Testing

@testable import ImageCore

/// `Images/tools/tests/fixtures/`, shared with the Python tests (#065).
private let toolsFixtures: URL = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 {
        url.deleteLastPathComponent()
    }
    return url.appendingPathComponent("Images/tools/tests/fixtures")
}()

private let signingFixtures = toolsFixtures.appendingPathComponent("signing")

/// The test key, which the repository keeps in `Tests/Fixtures/signing` (#065).
private let testPublicKey: Data = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 {
        url.deleteLastPathComponent()
    }
    let text = try! String(
        contentsOf: url.appendingPathComponent("Tests/Fixtures/signing/test-image-ed25519.pub"),
        encoding: .ascii
    )
    return Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines))!
}()

private struct VectorFile: Decodable {
    struct Key: Decodable {
        let keyID: String
        let publicKey: String
    }

    struct Case: Decodable {
        let name: String
        let message: String
        let signatureFile: String
        let trustedKeys: [String]
        let expected: String
        let keyID: String?
    }

    let keys: [String: Key]
    let cases: [Case]
}

@Test
func theKeyIDIsTheFirstEightBytesOfSHA256InLowercaseHex() {
    #expect(ImageSignature.keyID(of: testPublicKey) == "d4a6987f22e8f45f")
    #expect(ImageSignature.keyID(of: Data(repeating: 0, count: 32)).count == 16)
}

@Test
func theSharedSignatureVectorsGiveTheHandWrittenOutcomes() throws {
    let data = try Data(contentsOf: signingFixtures.appendingPathComponent("image-signature-vectors.json"))
    let vectors = try JSONDecoder().decode(VectorFile.self, from: data)
    #expect(vectors.cases.count == 17)
    for vector in vectors.cases {
        let trust = ImageTrustStore(
            keys: try vector.trustedKeys.map { name in
                let key = try #require(vectors.keys[name])
                return ImageTrustStore.Key(publicKey: try #require(Data(base64Encoded: key.publicKey)))
            }
        )
        let message = try #require(Data(base64Encoded: vector.message))
        let signatureFile = Data(vector.signatureFile.utf8)
        if vector.expected == "ok" {
            let parsed = try ImageSignature.verify(
                message: message, signatureFile: signatureFile, trust: trust
            )
            #expect(parsed.keyID == vector.keyID, "\(vector.name)")
            continue
        }
        do {
            _ = try ImageSignature.verify(message: message, signatureFile: signatureFile, trust: trust)
            Issue.record("\(vector.name) must fail as \(vector.expected)")
        } catch let failure {
            switch (vector.expected, failure) {
            case ("manifestInvalid", ImageFailure.manifestInvalid(let path, _)):
                #expect(path == "manifest.sig", "\(vector.name)")
            case ("untrustedKey", ImageFailure.untrustedKey(let keyID)),
                ("signatureInvalid", ImageFailure.signatureInvalid(let keyID)):
                #expect(keyID == vector.keyID, "\(vector.name)")
            default:
                Issue.record("\(vector.name): \(failure) is not \(vector.expected)")
            }
        }
    }
}

@Test
func theTrustStoreFindsOnlyTheKeysItHolds() {
    let trust = ImageTrustStore(keys: [ImageTrustStore.Key(publicKey: testPublicKey)])
    #expect(trust.key(for: "d4a6987f22e8f45f")?.publicKey == testPublicKey)
    #expect(trust.key(for: "0123456789abcdef") == nil)
    #expect(ImageTrustStore.release.keys.isEmpty)
}

#if DEBUG
    @Test
    func aDeveloperKeyFileIsTrustedOnlyWhenItHoldsOneKey() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-trust-\(UUID().uuidString)", isDirectory: true)
        let config = home.appendingPathComponent(".config/apkrun", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let keyFile = config.appendingPathComponent("dev-image-key.pub")

        #expect(ImageTrustStore.standard(home: home).keys.isEmpty)

        try Data((testPublicKey.base64EncodedString() + "\n").utf8).write(to: keyFile)
        #expect(ImageTrustStore.standard(home: home).key(for: "d4a6987f22e8f45f") != nil)

        try Data("not a key\n".utf8).write(to: keyFile)
        #expect(ImageTrustStore.standard(home: home).keys.isEmpty)
    }
    @Test
    func aDeveloperKeyAnotherUserCanWriteIsNotTrusted() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-trust-mode-\(UUID().uuidString)", isDirectory: true)
        let config = home.appendingPathComponent(".config/apkrun", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let keyFile = config.appendingPathComponent("dev-image-key.pub")
        try Data((testPublicKey.base64EncodedString() + "\n").utf8).write(to: keyFile)

        for mode in [0o664, 0o646, 0o666] as [Int] {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: keyFile.path)
            #expect(ImageTrustStore.standard(home: home).keys.isEmpty, "mode \(String(mode, radix: 8))")
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        #expect(ImageTrustStore.standard(home: home).key(for: "d4a6987f22e8f45f") != nil)
    }

    @Test
    func aDeveloperKeyThatIsASymbolicLinkIsNotTrusted() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-trust-link-\(UUID().uuidString)", isDirectory: true)
        let config = home.appendingPathComponent(".config/apkrun", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let target = home.appendingPathComponent("elsewhere.pub")
        try Data((testPublicKey.base64EncodedString() + "\n").utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: config.appendingPathComponent("dev-image-key.pub"), withDestinationURL: target
        )
        #expect(ImageTrustStore.standard(home: home).keys.isEmpty)
    }
#endif
