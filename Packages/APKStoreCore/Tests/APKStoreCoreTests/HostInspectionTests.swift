import Foundation
import Testing
import ZIPFoundation

@testable import APKStoreCore

// MARK: - ContainerReader

private func makeZip(
    _ entries: [(name: String, body: Data)],
    in directory: URL,
    file: String = "container.bin"
) throws -> URL {
    let url = directory.appendingPathComponent(file)
    let archive = try Archive(url: url, accessMode: .create)
    for entry in entries {
        try archive.addEntry(with: entry.name, type: .file, uncompressedSize: UInt32(entry.body.count)) {
            position, size in
            entry.body.subdata(in: position..<position + size)
        }
    }
    return url
}

private func makeAPKStub(_ bytes: Int = 64) -> Data {
    // Minimal ZIP with a local header is enough for detection tests (content-based).
    Data(repeating: 0x50, count: bytes)
}

@Test func containerReaderDetectsApksXapkApkmAndZipOfApks() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let reader = ContainerReader()

    let apks = try makeZip(
        [("toc.pb", Data()), ("splits/base.apk", makeAPKStub()), ("splits/config.x86.apk", makeAPKStub())],
        in: directory, file: "a.apks"
    )
    #expect(try reader.detect(at: apks) == .apks)

    let xapk = try makeZip(
        [
            ("manifest.json", Data("{\"xapk_version\":2,\"split_apks\":[{\"file\":\"b.apk\"}]}".utf8)),
            ("b.apk", makeAPKStub()),
        ],
        in: directory, file: "b.xapk"
    )
    #expect(try reader.detect(at: xapk) == .xapk(splitFiles: ["b.apk"]))

    let apkm = try makeZip(
        [("info.json", Data("{\"apkm_version\":1}".utf8)), ("c.apk", makeAPKStub())],
        in: directory, file: "c.apkm"
    )
    #expect(try reader.detect(at: apkm) == .apkm)

    let zipAPKs = try makeZip(
        [("base.apk", makeAPKStub()), ("config.arm64_v8a.apk", makeAPKStub())],
        in: directory, file: "d.zip"
    )
    #expect(try reader.detect(at: zipAPKs) == .zipOfAPKs)
}

@Test func containerReaderRefusesAABOBBAndTraversal() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let reader = ContainerReader()

    let aab = try makeZip([("BundleConfig.pb", Data())], in: directory, file: "a.aab")
    #expect(throws: StoreFailure.unsupportedContainer(.appBundle)) {
        try reader.detect(at: aab)
    }

    let obb = try makeZip(
        [("manifest.json", Data("{\"xapk_version\":2}".utf8)), ("a.apk", makeAPKStub()), ("main.obb", Data())],
        in: directory, file: "b.xapk"
    )
    #expect(throws: StoreFailure.expansionFilesNotSupported) {
        try reader.detect(at: obb)
    }

    let traversal = try makeZip(
        [("../evil.apk", makeAPKStub()), ("base.apk", makeAPKStub())],
        in: directory, file: "e.zip"
    )
    #expect(throws: StoreFailure.archiveLimitExceeded(.unsafeName)) {
        try reader.detect(at: traversal)
    }
}

@Test func containerReaderExtractsOnlyAPKsWithFixedNames() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let reader = ContainerReader()

    let payload = Data(repeating: 0x41, count: 100)
    let apks = try makeZip(
        [("toc.pb", Data()), ("splits/base.apk", payload), ("splits/part.apk", Data()), ("docs/readme.txt", Data())],
        in: directory, file: "a.apks"
    )
    let out = directory.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let extracted = try reader.extract(.apks, from: apks, into: out)
    #expect(extracted.map(\.lastPathComponent) == ["split01.apk", "split02.apk"])
    #expect(try Data(contentsOf: extracted[0]) == payload)
}

@Test func containerReaderDetectsPlainAPK() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = try makeZip([("AndroidManifest.xml", Data())], in: directory, file: "app.apk")
    #expect(try ContainerReader().detect(at: url) == .apk)
}

// MARK: - SplitSelector

private func split(_ name: String, attributes: SplitAttributes = SplitAttributes()) -> SplitCandidate {
    SplitCandidate(name: name, splitName: name == "base.apk" ? nil : String(name.dropLast(4)), attributes: attributes)
}

@Test func splitSelectorKeepsGuestABIAndNearestDensity() throws {
    let selection = try SplitSelector().select([
        split("base.apk"),
        split("config.arm64_v8a.apk"),
        split("config.x86.apk"),
        split("config.mdpi.apk"),
        split("config.xhdpi.apk"),
        split("config.fr.apk"),
    ])
    #expect(selection.included.contains("config.arm64_v8a.apk"))
    #expect(selection.included.contains("config.xhdpi.apk"))
    #expect(selection.included.contains("config.fr.apk"))
    #expect(selection.excludedSplits == ["config.x86", "config.mdpi"])
}

@Test func splitSelectorRefusesMissingRequiredSplitTypes() throws {
    #expect(throws: StoreFailure.incompleteSplitSet(missing: ["abi"])) {
        try SplitSelector().select([
            split("base.apk", attributes: SplitAttributes(requiredSplitTypes: ["abi"])),
            split("config.fr.apk", attributes: SplitAttributes(splitTypes: ["language"])),
        ])
    }
}

// MARK: - ArtifactVerifier

private func inspected(
    file: String,
    package: String = "org.example.app",
    versionCode: Int64 = 1,
    split: String? = nil,
    minSDK: Int = 24,
    targetSDK: Int = 35,
    abis: [String] = ["arm64-v8a"],
    signers: [SHA256Digest] = [APKStoreCore.SHA256Digest(data: Data([1]))],
    arscOK: Bool = true
) -> InspectedAPK {
    InspectedAPK(
        file: ArtifactFile(
            name: file, splitName: split, size: 10,
            sha256: APKStoreCore.SHA256Digest(hex: String(repeating: "0", count: 64))!
        ),
        facts: APKFacts(
            packageID: PackageID(rawValue: package)!,
            versionCode: VersionCode(versionCode),
            versionName: nil,
            splitName: split,
            displayName: "App",
            minSDK: minSDK,
            targetSDK: targetSDK,
            nativeABIs: abis
        ),
        signature: APKSignatureInfo(signerDigests: signers, scheme: .v2, level: .verified),
        libraryABIs: abis,
        resourcesArscOK: arscOK
    )
}

@Test func artifactVerifierRejectsMultipleBasesAndMismatchedSets() throws {
    #expect(throws: StoreFailure.multipleBases) {
        try ArtifactVerifier().verify(set: [inspected(file: "a.apk"), inspected(file: "b.apk")])
    }
    #expect(throws: StoreFailure.inconsistentSplits(.package, file: "b.apk")) {
        try ArtifactVerifier().verify(set: [
            inspected(file: "base.apk"),
            inspected(file: "b.apk", package: "org.other", split: "config.x"),
        ])
    }
    #expect(throws: StoreFailure.inconsistentSplits(.signer, file: "b.apk")) {
        try ArtifactVerifier().verify(set: [
            inspected(file: "base.apk"),
            inspected(file: "b.apk", split: "config.x", signers: [APKStoreCore.SHA256Digest(data: Data([2]))]),
        ])
    }
}

@Test func artifactVerifierRejectsABIAndSDKFailures() throws {
    #expect(throws: StoreFailure.unsupportedABI(found: ["x86"], supported: ["arm64-v8a"])) {
        try ArtifactVerifier().verify(set: [inspected(file: "base.apk", abis: ["x86"])])
    }
    #expect(throws: StoreFailure.minSdkTooHigh(required: 40, guest: 37)) {
        try ArtifactVerifier().verify(set: [inspected(file: "base.apk", minSDK: 40)])
    }
    #expect(throws: StoreFailure.targetSdkTooLow(target: 23, floor: 24)) {
        try ArtifactVerifier().verify(set: [inspected(file: "base.apk", targetSDK: 23)])
    }
}

@Test func artifactVerifierRejectsReservedAndMisaligned() throws {
    #expect(throws: StoreFailure.reservedPackage(PackageID(rawValue: "io.apkrun.guest")!)) {
        try ArtifactVerifier().verify(set: [inspected(file: "base.apk", package: "io.apkrun.guest")])
    }
    #expect(throws: StoreFailure.resourcesArscNotAligned(file: "base.apk")) {
        try ArtifactVerifier().verify(set: [inspected(file: "base.apk", targetSDK: 30, arscOK: false)])
    }
}

@Test func artifactVerifierCollectsWarnings() throws {
    let lowTarget = inspected(file: "base.apk", targetSDK: 26)
    let result = try ArtifactVerifier().verify(set: [lowTarget])
    #expect(result.warnings.contains(.lowTargetSDK(target: 26)))
    #expect(result.signerDigests == lowTarget.signature.signerDigests)
}

// MARK: - APKSignatureVerifier

@Test func signatureVerifierRejectsUnsignedAPK() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let apk = try makeZip([("classes.dex", Data(repeating: 1, count: 16))], in: directory, file: "app.apk")
    #expect(throws: StoreFailure.unsignedAPK(file: "app.apk")) {
        try APKSignatureVerifier().verify(apk: apk, targetSDK: 35)
    }
}

@Test func signatureVerifierRejectsJARSignatureAtTarget30() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let apk = try makeZip(
        [("META-INF/TEST.RSA", Data(repeating: 0x30, count: 64))],
        in: directory, file: "app.apk"
    )
    #expect(throws: StoreFailure.legacySignatureNotAllowed(targetSdk: 35)) {
        try APKSignatureVerifier().verify(apk: apk, targetSDK: 35)
    }
}

@Test func lengthPrefixedParsesSequenceFields() {
    var blob = Data()
    blob.append(contentsOf: [3, 0, 0, 0, 0xAA, 0xBB, 0xCC])
    blob.append(contentsOf: [2, 0, 0, 0, 0x11, 0x22])
    let parts = APKSignatureVerifier.lengthPrefixed(blob)
    #expect(parts.count == 2)
    #expect(parts[0] == Data([0xAA, 0xBB, 0xCC]))
    #expect(parts[1] == Data([0x11, 0x22]))
}
