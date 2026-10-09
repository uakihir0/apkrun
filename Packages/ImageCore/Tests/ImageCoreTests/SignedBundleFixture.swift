import CryptoKit
import Darwin
import Foundation
import Testing

@testable import ImageCore

/// The repository root, from this file's path (#065).
let imageRepositoryRoot: URL = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 {
        url.deleteLastPathComponent()
    }
    return url
}()

/// The test image key, `Tests/Fixtures/signing/test-image-ed25519` (PKCS#8 PEM, Ed25519).
let testImagePrivateKey: Curve25519.Signing.PrivateKey = {
    let pem = try! String(
        contentsOf: imageRepositoryRoot.appendingPathComponent("Tests/Fixtures/signing/test-image-ed25519"),
        encoding: .ascii
    )
    let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
    // The PKCS#8 wrapper of an Ed25519 key is 16 bytes; the 32-byte seed closes it.
    let der = Data(base64Encoded: body)!
    return try! Curve25519.Signing.PrivateKey(rawRepresentation: der.suffix(32))
}()

/// The key ID of the test key, which `ImageTrustStore` trusts in tests.
let testImageKeyID = ImageSignature.keyID(of: testImagePrivateKey.publicKey.rawRepresentation)

/// The trust list that tests install: the test key only.
let testImageTrust = ImageTrustStore(keys: [
    ImageTrustStore.Key(publicKey: testImagePrivateKey.publicKey.rawRepresentation)
])

/// Writes small, valid bundles signed with the test key (runtime-image-manifest.md §3–§7).
///
/// The bundle passes every rule, so `ImageStore` installs it. Its disks are 4 MiB sparse files,
/// with one written byte at the start, so the tests can see whether clones keep the holes.
enum SignedBundleFixture {
    /// Writes a bundle under `directory`. `base` is the Android build part of the version, such as `cf1`.
    @discardableResult
    static func write(
        to directory: URL,
        version: String = "2026.10.0-cf1-arm64",
        kernel: Data = Data(repeating: 0x42, count: 64)
    ) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["boot", "disks", "templates"] {
            try fileManager.createDirectory(
                at: directory.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let contents: [(String, Data)] = [
            ("boot/kernel", kernel),
            ("boot/ramdisk.img", Data("fixture-ramdisk".utf8)),
            (
                "boot/bootconfig.txt",
                Data("[vendor]\nandroidboot.hardware = \"cutf_cvm\"\n[image]\nandroidboot.slot_suffix = \"_a\"\n".utf8)
            ),
            ("boot/cmdline.txt", Data("console=hvc0 bootconfig".utf8)),
        ]
        for (path, data) in contents {
            try data.write(to: directory.appendingPathComponent(path))
        }
        try sparseFile(at: directory.appendingPathComponent("disks/os.img"))
        try sparseFile(at: directory.appendingPathComponent("templates/userdata.img"))

        var files: [[String: Any]] = []
        for path in [
            "boot/bootconfig.txt", "boot/cmdline.txt", "boot/kernel", "boot/ramdisk.img",
            "disks/os.img", "templates/userdata.img",
        ] {
            let url = directory.appendingPathComponent(path)
            files.append(["path": path, "size": try size(of: url), "sha256": try sha256(of: url)])
        }
        let manifest = try manifestDocument(version: version, files: files)
        let manifestBytes =
            try JSONSerialization.data(
                withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]
            ) + Data("\n".utf8)
        try manifestBytes.write(to: directory.appendingPathComponent("manifest.json"))

        let sums = files.map { "\($0["sha256"]!)  \($0["path"]!)\n" }.joined()
        try Data(sums.utf8).write(to: directory.appendingPathComponent("SHA256SUMS"))

        let signature = try testImagePrivateKey.signature(for: manifestBytes)
        let signatureFile =
            "apkrun-signature-v1\nkey-id: \(testImageKeyID)\nalgorithm: ed25519\n"
            + "signature: \(signature.base64EncodedString())\n"
        try Data(signatureFile.utf8).write(to: directory.appendingPathComponent("manifest.sig"))
        return directory
    }

    /// A 4 MiB file whose first byte is written and whose tail is a hole. APFS allocates the gap
    /// when a write lands after it, so the byte goes first and the file is extended afterwards.
    private static func sparseFile(at url: URL) throws {
        let megabyte: UInt64 = 1024 * 1024
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data([0x01]))
        try handle.truncate(atOffset: 4 * megabyte)
    }

    private static func size(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The §4 document for the fixture's files. Console ports and GPU profiles come from the
    /// shared §4.1 example, which the Python fixtures check.
    private static func manifestDocument(version: String, files: [[String: Any]]) throws -> [String: Any] {
        let exampleURL = imageRepositoryRoot.appendingPathComponent(
            "Images/tools/tests/fixtures/runtime-manifests/valid/stock-cf16373615.json"
        )
        let example = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: exampleURL)) as? [String: Any]
        )
        let hash = String(repeating: "a", count: 64)
        let base = String(version.split(separator: "-")[1])
        let build = String(base.dropFirst(2))
        let short = version.split(separator: "-")[0]
        let megabyte = 1024 * 1024
        func entry(_ path: String) -> [String: Any] {
            files.first { $0["path"] as? String == path } ?? [:]
        }
        return [
            "schemaVersion": 1,
            "imageVersion": version,
            "kind": "stock",
            "provenance": [
                "source": [
                    "origin": "ci.android.com",
                    "branch": "aosp-main",
                    "target": "aosp_cf_arm64_only_phone-userdebug",
                    "buildId": build,
                    "archives": [["name": "fixture.zip", "size": 1, "sha256": hash]],
                ],
                "android": ["release": "17", "sdk": 37, "variant": "userdebug", "securityPatch": "2026-09"],
                "deviceFamily": "cuttlefish-phone-arm64",
                "layout": ["path": "Images/tools/layouts/cuttlefish-phone-arm64.json", "sha256": hash],
                "reference": NSNull(),
                "tools": [
                    "apkrunImage": "1.0.0",
                    "mkbootimg": String(repeating: "1", count: 40),
                    "avbtool": String(repeating: "2", count: 40),
                ],
                "revisions": ["imagesTools": String(repeating: "3", count: 40), "guest": NSNull()],
                "pinnedManifestSHA256": NSNull(),
                "builderImageDigest": NSNull(),
            ],
            "guest": ["sdk": 37, "abis": ["arm64-v8a"], "targetSdkFloor": 24],
            "boot": [
                "kernel": entry("boot/kernel"),
                "ramdisk": entry("boot/ramdisk.img"),
                "bootconfig": entry("boot/bootconfig.txt"),
                "cmdline": entry("boot/cmdline.txt"),
                "kernelPageSize": 4096,
                "bootconfigOverrides": [],
            ],
            "disks": [
                [
                    "role": "os",
                    "path": "disks/os.img",
                    "readOnly": true,
                    "identifier": "apkrun-os",
                    "logicalSize": 4 * megabyte,
                    "partitions": [["label": "boot_a", "firstLBA": 2048, "size": megabyte, "sha256": hash]],
                ]
            ],
            "templates": [
                [
                    "role": "userdata",
                    "path": "templates/userdata.img",
                    "readOnly": false,
                    "identifier": "apkrun-data",
                    "logicalSize": 4 * megabyte,
                    "userdataStrategy": "blankFormattable",
                    "partitions": [["label": "userdata", "firstLBA": 2048, "size": megabyte, "sha256": hash]],
                ]
            ],
            "consolePorts": example["consolePorts"]!,
            "gpuProfiles": example["gpuProfiles"]!,
            "requirements": ["minimumRuntimeVersion": "0.1.0", "guestProtocol": ["min": 1, "max": 1], "agents": []],
            "userdata": ["schemaVersion": 1, "upgradableFrom": [1]],
            "compatibility": ["upgradeFrom": ["minimumImageVersion": String(short)]],
            "files": files,
        ]
    }
}
