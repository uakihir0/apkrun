import CryptoKit
import Foundation
import RuntimeAPI
import Testing
import WrapperCore

/// T0 — `bootstrap.json` encoding, §3.2 validation, and the portable bundle
/// write (issue #90).
@Suite("BootstrapDocument codec")
struct BootstrapDocumentTests {

    private static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func fixtureFiles() -> (files: [BootstrapFileEntry], data: [Data]) {
        let base = Data("base-payload".utf8)
        let split = Data("split-payload".utf8)
        return (
            [
                BootstrapFileEntry(name: "base.apk", sha256: "sha256:" + Self.hex(base), size: Int64(base.count)),
                BootstrapFileEntry(
                    name: "split_config.arm64_v8a.apk",
                    sha256: "sha256:" + Self.hex(split), size: Int64(split.count)),
            ],
            [base, split]
        )
    }

    @Test func encodeDecodeRoundTripWithSortedKeys() throws {
        let (files, _) = fixtureFiles()
        let document = BootstrapDocument(
            packageId: "com.example.game",
            versionCode: 42,
            versionName: "1.0",
            setDigest: BootstrapSetDigest.compute(files: files),
            signers: ["sha256:aabb"],
            files: files
        )
        let data = try BootstrapDocumentCodec.encode(document)
        let text = String(decoding: data, as: UTF8.self)
        // §1.3: sorted keys — the top-level fields appear in key order.
        var position = text.startIndex
        for key in [
            "files", "formatVersion", "packageId", "setDigest", "signers",
            "versionCode", "versionName",
        ] {
            let marker = "\"" + key + "\""
            guard let found = text.range(of: marker, range: position..<text.endIndex)
            else {
                Issue.record("missing or out-of-order key \(key)")
                break
            }
            position = found.upperBound
        }
        let decoded = try BootstrapDocumentCodec.decode(data)
        #expect(decoded == document)
    }

    @Test func formatVersionTwoRejected() throws {
        var json: [String: Any] = [
            "formatVersion": 2,
            "packageId": "com.example.game",
            "versionCode": 1,
            "setDigest": "sha256:ab",
            "signers": ["sha256:a"],
            "files": [["name": "base.apk", "sha256": "sha256:b", "size": 1]],
        ]
        #expect(throws: WrapperFailure.self) {
            _ = try BootstrapDocumentCodec.decode(JSONSerialization.data(withJSONObject: json))
        }
        json["formatVersion"] = 1
        _ = try BootstrapDocumentCodec.decode(JSONSerialization.data(withJSONObject: json))
    }

    @Test func malformedRejected() {
        #expect(throws: WrapperFailure.self) {
            _ = try BootstrapDocumentCodec.decode(Data("not json".utf8))
        }
        #expect(throws: WrapperFailure.self) {
            _ = try BootstrapDocumentCodec.decode(
                Data(repeating: 0x20, count: BootstrapDocument.maximumDocumentBytes + 1))
        }
    }

    @Test func constraintViolationsRejected() throws {
        let (files, _) = fixtureFiles()
        func doc(
            signers: [String] = ["sha256:a"],
            files: [BootstrapFileEntry]? = nil
        ) -> BootstrapDocument {
            BootstrapDocument(
                packageId: "com.example.game", versionCode: 1,
                setDigest: "sha256:cc", signers: signers,
                files: files ?? self.fixtureFiles().files)
        }
        // Unsorted / duplicate signers.
        #expect(throws: WrapperFailure.self) {
            try BootstrapDocumentCodec.validate(doc(signers: ["sha256:b", "sha256:a"]))
        }
        #expect(throws: WrapperFailure.self) {
            try BootstrapDocumentCodec.validate(doc(signers: ["sha256:a", "sha256:a"]))
        }
        // base.apk not first; bad file name; bad size.
        #expect(throws: WrapperFailure.self) {
            try BootstrapDocumentCodec.validate(doc(files: [files[1], files[0]]))
        }
        #expect(throws: WrapperFailure.self) {
            try BootstrapDocumentCodec.validate(
                doc(files: [
                    BootstrapFileEntry(name: "../base.apk", sha256: "sha256:x", size: 1)
                ]))
        }
        #expect(throws: WrapperFailure.self) {
            try BootstrapDocumentCodec.validate(
                doc(files: [
                    BootstrapFileEntry(name: "base.apk", sha256: "sha256:x", size: 0)
                ]))
        }
    }

    @Test func fileNameRules() {
        #expect(BootstrapFileName.isValid("base.apk"))
        #expect(BootstrapFileName.isValid("split_config.arm64_v8a.apk"))
        #expect(BootstrapFileName.isValid("split_ja.apk"))
        #expect(!BootstrapFileName.isValid("other.apk"))
        #expect(!BootstrapFileName.isValid("split_.apk"))
        #expect(!BootstrapFileName.isValid("split_.bad.apk"))
        #expect(!BootstrapFileName.isValid("split_1bad.apk"))
        #expect(!BootstrapFileName.isValid("split_has-dash.apk"))
    }

    @Test func setDigestIsOrderAndTabSensitive() {
        let (files, _) = fixtureFiles()
        let digest = BootstrapSetDigest.compute(files: files)
        #expect(digest.hasPrefix("sha256:"))
        #expect(BootstrapSetDigest.compute(files: [files[1], files[0]]) != digest)
    }
}

/// T0 — the generator writes `Contents/Resources/bootstrap/` for `.portable`.
@Suite("Portable wrapper generation")
struct PortableWrapperTests {
    @Test func portableWritesBootstrapDirectory() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        let sourceDir = fixture.root.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let baseData = Data("fake-base-apk".utf8)
        try baseData.write(to: sourceDir.appendingPathComponent("base.apk"))
        let baseHash = SHA256.hash(data: baseData).map { String(format: "%02x", $0) }.joined()

        let files = [
            BootstrapFileEntry(
                name: "base.apk", sha256: "sha256:" + baseHash, size: Int64(baseData.count))
        ]
        let document = BootstrapDocument(
            packageId: "com.example.game",
            versionCode: 7,
            setDigest: BootstrapSetDigest.compute(files: files),
            signers: ["sha256:signer"],
            files: files
        )
        var configuration = try fixture.configuration()
        configuration.kind = .portable
        configuration.bootstrap = BootstrapSet(
            document: document,
            files: [
                .init(
                    name: "base.apk",
                    sourceURL: sourceDir.appendingPathComponent("base.apk"),
                    sha256: "sha256:" + baseHash,
                    size: Int64(baseData.count))
            ]
        )
        let generated = try await fixture.generator().generate(
            WrapperGenerationRequest(
                configuration: configuration,
                destination: .directory(fixture.destination),
                replace: .never
            ))
        let bootstrap = generated.bundleURL.appendingPathComponent(
            "Contents/Resources/bootstrap")
        #expect(try Data(contentsOf: bootstrap.appendingPathComponent("base.apk")) == baseData)
        let json = try BootstrapDocumentCodec.decode(
            Data(contentsOf: bootstrap.appendingPathComponent("bootstrap.json")))
        #expect(json == document)
        // wrapper.json says kind=portable.
        let wrapperJSON = try JSONDecoder().decode(
            WrapperDocument.self,
            from: Data(
                contentsOf: generated.bundleURL.appendingPathComponent(
                    "Contents/Resources/wrapper.json")))
        #expect(wrapperJSON.kind == .portable)
    }

    @Test func portableWithoutPayloadRejected() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }
        var configuration = try fixture.configuration()
        configuration.kind = .portable
        await #expect(throws: WrapperFailure.self) {
            _ = try await fixture.generator().generate(
                WrapperGenerationRequest(
                    configuration: configuration,
                    destination: .directory(fixture.destination),
                    replace: .never
                ))
        }
    }

    /// **Make Local Mac App** (host-ui.md §7.6) flips a portable entry to
    /// `local` through `finishRefresh`.
    @Test func finishRefreshChangesKind() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = WrapperRegistry(
            fileURL: root.appendingPathComponent("registry.json"),
            stagingRoot: root)
        _ = await registry.load()
        let bundleID = "io.apkrun.android.com-example-game"
        try await registry.markPending(
            WrapperRegistryEntry(
                bundleId: bundleID,
                packageId: "com.example.game",
                kind: .portable,
                state: .pending,
                path: root.appendingPathComponent("Game.app").path,
                cdhash: "old",
                launcherVersion: "1",
                launcherAPI: "1",
                fileName: "Game",
                displayName: "Game",
                createdAt: Date()))
        try await registry.activate(
            bundleID: bundleID,
            path: root.appendingPathComponent("Game.app"),
            bookmark: Data())
        try await registry.finishRefresh(
            bundleID: bundleID,
            path: root.appendingPathComponent("Game.app"),
            bookmark: Data(),
            kind: .local)
        #expect(await registry.entry(bundleID: bundleID)?.kind == .local)
    }
}
