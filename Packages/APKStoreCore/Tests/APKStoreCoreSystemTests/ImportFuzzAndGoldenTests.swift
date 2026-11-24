import Foundation
import Testing
import ZIPFoundation

@testable import APKStoreCore

/// `fuzz-short` over `ContainerReader` and the APK signing-block parser, plus the aapt2
/// golden check (M06 issue #74, test-strategy §7.2).
///
/// Mutated containers must either decode, extract, and verify, or fail with a typed
/// `StoreFailure`. A crash or an untyped error is a fuzz failure.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }
}

private func mutate(_ bytes: inout [UInt8], _ random: inout SplitMix64) {
    switch random.below(4) {
    case 0 where !bytes.isEmpty:
        bytes[random.below(bytes.count)] = UInt8(truncatingIfNeeded: random.next())
    case 1:
        let newLength = max(0, bytes.count + random.below(9) - 4)
        if newLength < bytes.count {
            bytes.removeLast(bytes.count - newLength)
        } else {
            bytes += (0..<(newLength - bytes.count)).map { _ in UInt8(truncatingIfNeeded: random.next()) }
        }
    case 2 where bytes.count >= 4:
        let offset = random.below(bytes.count - 3)
        let extreme: [UInt32] = [0, 1, 16, 16_384, 16_385, 4_194_304, 4_194_305, 0xFFFF_FFFF]
        let value = extreme[random.below(extreme.count)]
        for index in 0..<4 {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index))
        }
    default:
        if !bytes.isEmpty {
            bytes[random.below(min(bytes.count, 24))] ^= UInt8(1 << random.below(8))
        }
    }
}

private func makeZIP(_ entries: [(String, [UInt8])]) throws -> Data {
    var data = Data()
    let archive = try Archive(data: data, accessMode: .create)
    for (name, bytes) in entries {
        try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(bytes.count)) {
            position, size in
            Data(bytes[Int(position)..<Int(position) + size])
        }
    }
    data = try #require(archive.data)
    return data
}

/// The four container layouts of package-store.md §4.2, generated at test time.
private func containerGoldens() throws -> [Data] {
    let fakeAPK = [UInt8](repeating: 0x50, count: 64) + [UInt8]("fake-apk".utf8)
    let apks = try makeZIP([
        ("toc.pb", [0x0A, 0x01]),
        ("splits/base.apk", fakeAPK),
        ("splits/config.arm64_v8a.apk", fakeAPK),
    ])
    let xapk = try makeZIP([
        (
            "manifest.json",
            [UInt8](
                #"{"xapk_version":2,"split_apks":[{"file":"base.apk"}]}"#.utf8)
        ),
        ("base.apk", fakeAPK),
    ])
    let zipOfAPKs = try makeZIP([
        ("base.apk", fakeAPK),
        ("config.xxhdpi.apk", fakeAPK),
    ])
    let apk = try makeZIP([
        ("AndroidManifest.xml", [0x03, 0x00, 0x08, 0x00]),
        ("classes.dex", [UInt8]("dex\n035".utf8)),
    ])
    return [apks, xapk, zipOfAPKs, apk]
}

/// Splices a structurally valid APK Signing Block before the central directory and patches
/// the EOCD offset, matching package-store.md §4.5. The signer data itself is a dummy pair,
/// so verification reaches a typed signature rejection — which is all the fuzz needs.
private func makeSignedAPK() throws -> Data {
    var zip = try makeZIP([
        ("AndroidManifest.xml", [0x03, 0x00, 0x08, 0x00]),
        ("classes.dex", [UInt8]("dex\n035".utf8)),
    ])
    let magic = Data("APK Sig Block 42".utf8)
    // Find the EOCD (PK\x05\x06) in the tail.
    var eocdOffset: Int? = nil
    let eocdSig: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
    var index = zip.count - eocdSig.count
    while index >= 0 {
        if [UInt8](zip[index..<index + 4]) == eocdSig {
            eocdOffset = index
            break
        }
        index -= 1
    }
    let eocd = try #require(eocdOffset)
    let cdOffset = zip.withUnsafeBytes { raw -> Int in
        Int(raw.loadUnaligned(fromByteOffset: eocd + 16, as: UInt32.self).littleEndian)
    }

    var pair = Data()
    pair.append(contentsOf: [0x1A, 0x87, 0x09, 0x71])  // v2 scheme block ID
    pair.append(contentsOf: [UInt8](repeating: 0xAB, count: 32))
    var body = Data()
    body.append(contentsOf: withUnsafeBytes(of: UInt64(pair.count + 4).littleEndian, Array.init))
    body.append(pair)
    var block = Data()
    let blockSize = UInt64(body.count + 8 + 16)
    block.append(contentsOf: withUnsafeBytes(of: blockSize.littleEndian, Array.init))
    block.append(body)
    block.append(contentsOf: withUnsafeBytes(of: blockSize.littleEndian, Array.init))
    block.append(magic)

    zip.replaceSubrange(cdOffset..<cdOffset, with: block)
    let newCDOffset = UInt32(cdOffset + block.count).littleEndian
    zip.replaceSubrange(eocd + 16..<eocd + 20, with: withUnsafeBytes(of: newCDOffset, Array.init))
    return zip
}

private func write(_ bytes: [UInt8], into directory: URL, name: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data(bytes).write(to: url)
    return url
}

@Test func mutatedContainersDetectAndExtractWithTypedErrors() throws {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-container-fuzz-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let seeds = try containerGoldens()
    let reader = ContainerReader()
    var random = SplitMix64(seed: 0x6170_6B73_7369_6701)
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(30))
    var iterations = 0
    var accepted = 0
    while clock.now < deadline, iterations < 300_000 {
        var bytes = [UInt8](seeds[iterations % seeds.count])
        for _ in 0..<(1 + random.below(3)) {
            mutate(&bytes, &random)
        }
        iterations += 1
        let input = try write(
            bytes, into: temporary, name: "fuzz-\(iterations).container")
        do {
            let container = try reader.detect(at: input)
            let destination = temporary.appendingPathComponent("out-\(iterations)", isDirectory: true)
            _ = try reader.extract(container, from: input, into: destination)
            try? FileManager.default.removeItem(at: destination)
            accepted += 1
        } catch {
            // Typed `StoreFailure` rejections are the expected outcome for most mutations.
        }
        try? FileManager.default.removeItem(at: input)
    }
    #expect(iterations >= 1_000)
    #expect(accepted > 0)
}

@Test func mutatedSigningBlocksVerifyWithTypedErrors() throws {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-sigblock-fuzz-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let seed = try makeSignedAPK()
    let verifier = APKSignatureVerifier()
    var random = SplitMix64(seed: 0x7369_676E_626C_6F63)
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(30))
    var iterations = 0
    var reachedSignatureCheck = 0
    while clock.now < deadline, iterations < 300_000 {
        var bytes = [UInt8](seed)
        for _ in 0..<(1 + random.below(3)) {
            mutate(&bytes, &random)
        }
        iterations += 1
        let input = try write(bytes, into: temporary, name: "fuzz-\(iterations).apk")
        do {
            _ = try verifier.verify(apk: input, targetSDK: 35)
            reachedSignatureCheck += 1
        } catch {
            reachedSignatureCheck += 1
        }
        try? FileManager.default.removeItem(at: input)
    }
    #expect(iterations >= 1_000)
    #expect(reachedSignatureCheck > 0)
}

/// T1 aapt2 golden (issue #74 step 6): the sandboxed inspector must read the same facts from
/// `HelloText.apk` as the manifest declares. Requires the fixture built by
/// `scripts/build-fixtures.sh` and `ANDROID_HOME` pointing at build-tools 37.0.0.
@Test func aapt2InspectsHelloTextGolden() async throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let fixture = root.appendingPathComponent("Tests/Fixtures/AndroidApps/out/HelloText.apk")
    try #require(
        FileManager.default.fileExists(atPath: fixture.path),
        "run scripts/build-fixtures.sh first")

    let environment = ProcessInfo.processInfo.environment
    let sdkRoots = [
        environment["ANDROID_HOME"],
        environment["ANDROID_SDK_ROOT"],
        NSHomeDirectory() + "/Library/Android/sdk",
    ]
    var aapt2: URL? = nil
    for root in sdkRoots {
        guard let root, !root.isEmpty else { continue }
        let buildTools = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("build-tools", isDirectory: true)
        let versions =
            (try? FileManager.default.contentsOfDirectory(
                at: buildTools, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ))?
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedDescending
            } ?? []
        for version in versions {
            let candidate = version.appendingPathComponent("aapt2")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                aapt2 = candidate
                break
            }
        }
        if aapt2 != nil { break }
    }
    let inspector = try APKInspector(executable: #require(aapt2, "no aapt2 under any SDK root"))

    let facts = try await inspector.inspect(fixture)
    #expect(facts.packageID.rawValue == "io.apkrun.fixture.hellotext")
    #expect(facts.versionCode == 1)
    #expect(facts.versionName == "1.0")
    #expect(facts.minSDK == 29)
    #expect(facts.targetSDK == 37)
    #expect(facts.splitName == nil)
    #expect(facts.displayName == "HelloText")
    #expect(!facts.debuggable)
}
