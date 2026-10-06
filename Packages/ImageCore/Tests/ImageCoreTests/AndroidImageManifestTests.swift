import Foundation
import Testing

@testable import ImageCore

@Test
func androidImageManifestCodableRoundTripPreservesTheDocument() throws {
    let manifest = try decodeManifest(validManifestJSON)
    let encoded = try JSONEncoder().encode(manifest)
    let decoded = try JSONDecoder().decode(AndroidImageManifest.self, from: encoded)

    #expect(decoded == manifest)
    try AndroidImageManifestValidator().validate(decoded)
}

@Test
func androidImageManifestAcceptsEverySharedValidFixtureAndCommittedManifest() throws {
    let fixtureDirectory = manifestFixtureDirectory
    let validFixtures = try FileManager.default.contentsOfDirectory(
        at: fixtureDirectory.appendingPathComponent("valid", isDirectory: true),
        includingPropertiesForKeys: nil
    )
    let committedManifestDirectory =
        repositoryRoot
        .appendingPathComponent("Images/manifests", isDirectory: true)
    let buildDirectories = try FileManager.default.contentsOfDirectory(
        at: committedManifestDirectory,
        includingPropertiesForKeys: [.isDirectoryKey]
    )

    for url in validFixtures.filter({ $0.pathExtension == "json" }) {
        let manifest = try JSONDecoder().decode(
            AndroidImageManifest.self,
            from: Data(contentsOf: url)
        )
        try AndroidImageManifestValidator().validate(manifest)
    }
    for directory in buildDirectories {
        let manifestURL = directory.appendingPathComponent("android-image.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            continue
        }
        let manifest = try JSONDecoder().decode(
            AndroidImageManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        try AndroidImageManifestValidator().validate(manifest)
    }
}

@Test
func androidImageManifestFixturesMatchPythonManifestOnlyErrors() throws {
    let fixtureDirectory = manifestFixtureDirectory
    let invalidDirectory = fixtureDirectory.appendingPathComponent(
        "invalid",
        isDirectory: true
    )
    let pythonOnlyURL = invalidDirectory.appendingPathComponent("python-only.txt")
    let pythonOnly = Set(
        try String(contentsOf: pythonOnlyURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    )
    let invalidFixtures = try FileManager.default.contentsOfDirectory(
        at: invalidDirectory,
        includingPropertiesForKeys: nil
    )

    for url in invalidFixtures where url.pathExtension == "json" && !pythonOnly.contains(url.lastPathComponent) {
        let expectedURL = url.deletingPathExtension().appendingPathExtension("expected.txt")
        let expected = try String(contentsOf: expectedURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(
            throws: ImageFailure.manifestInvalid(
                path: "android-image.json",
                reason: expected
            )
        ) {
            let manifest = try JSONDecoder().decode(
                AndroidImageManifest.self,
                from: Data(contentsOf: url)
            )
            try AndroidImageManifestValidator().validate(manifest)
        }
    }
}

@Test
func androidImageManifestRejectsNewerSchemaVersionsBeforeUnknownKeys() throws {
    let json =
        validManifestJSON
        .replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 3")
        .replacingOccurrences(of: "\"architecture\":", with: "\"futureField\": true, \"architecture\":")

    #expect(
        throws: ImageFailure.manifestInvalid(
            path: "android-image.json",
            reason: "android-image.json: schemaVersion 3 is newer than this tool supports (1). Update Images/tools."
        )
    ) {
        try decodeManifest(json)
    }
}

@Test
func androidImageManifestReportsJSONTypeMismatchesAsTypedFailures() throws {
    let json = validManifestJSON.replacingOccurrences(
        of: "\"sdk\": 37",
        with: "\"sdk\": \"37\""
    )

    #expect(
        throws: ImageFailure.manifestInvalid(
            path: "android-image.json",
            reason:
                "android-image.json:android.sdk: expected Int, found an incompatible JSON type. Correct the field type to match schema version 1."
        )
    ) {
        try decodeManifest(json)
    }
}

@Test
func androidImageManifestRejectsIntegerOutsideSwiftIntRangeAsTypedFailure() throws {
    let json = validManifestJSON.replacingOccurrences(
        of: "\"size\": 1",
        with: "\"size\": 9223372036854775808"
    )

    #expect(throws: ImageFailure.self) {
        try decodeManifest(json)
    }
}

@Test
func androidImageManifestRejectsUnknownKeysAtEveryFixedObjectLevel() throws {
    let invalidJSON = [
        validManifestJSON.replacingOccurrences(
            of: "\"schemaVersion\": 1,",
            with: "\"schemaVersion\": 1, \"unexpected\": true,"
        ),
        validManifestJSON.replacingOccurrences(
            of: "\"origin\": \"ci.android.com\",",
            with: "\"origin\": \"ci.android.com\", \"unexpected\": true,"
        ),
        validManifestJSON.replacingOccurrences(
            of: "\"name\": \"archive.zip\",",
            with: "\"name\": \"archive.zip\", \"unexpected\": true,"
        ),
        validManifestJSON.replacingOccurrences(
            of: "\"release\": \"17\",",
            with: "\"release\": \"17\", \"unexpected\": true,"
        ),
        validManifestJSON.replacingOccurrences(
            of: "\"id\": \"boot\",",
            with: "\"id\": \"boot\", \"unexpected\": true,"
        ),
        validManifestJSON.replacingOccurrences(
            of: "\"kernel\": \"boot\",",
            with: "\"kernel\": \"boot\", \"unexpected\": true,"
        ),
        validManifestJSON.replacingOccurrences(
            of: "\"name\": \"system_a\",",
            with: "\"name\": \"system_a\", \"unexpected\": true,"
        ),
        validManifestJSON.replacingOccurrences(
            of: "\"blankPartitions\": [],",
            with: "\"blankPartitions\": [{\"partition\": \"metadata\", \"size\": 4096, \"unexpected\": true}],"
        ),
    ]

    for json in invalidJSON {
        #expect(throws: ImageFailure.self) {
            try decodeManifest(json)
        }
    }
}

@Test
func androidImageManifestEscapesControlCharactersInUnknownFieldNames() throws {
    let json = validManifestJSON.replacingOccurrences(
        of: "\"schemaVersion\": 1,",
        with: "\"schemaVersion\": 1, \"future\\nINJECTED\": true,"
    )
    let expectedReason =
        "android-image.json: unknown field \"future\\u{A}INJECTED\". "
        + "Remove it or use schema version 1."

    #expect(
        throws: ImageFailure.manifestInvalid(
            path: "android-image.json",
            reason: expectedReason
        )
    ) {
        try decodeManifest(json)
    }
}

@Test
func androidImageManifestEscapesControlCharactersInAndroidInfoKeys() throws {
    let json = validManifestJSON.replacingOccurrences(
        of: "\"androidInfo\": {}",
        with: "\"androidInfo\": {\"x\\nINJECTED\": \"37\"}"
    )
    let expectedReason =
        "android-image.json: androidInfo must be keys of 1–64 ASCII letters, digits, "
        + "underscores, dots, or hyphens; found \"x\\u{A}INJECTED\"."

    #expect(
        throws: ImageFailure.manifestInvalid(
            path: "android-image.json",
            reason: expectedReason
        )
    ) {
        try decodeManifest(json)
    }
}

@Test
func androidImageManifestRejectsAndroidInfoKeysWithTrailingLineFeeds() throws {
    let json = validManifestJSON.replacingOccurrences(
        of: "\"androidInfo\": {}",
        with: "\"androidInfo\": {\"x\\n\": \"37\"}"
    )
    let expectedReason =
        "android-image.json: androidInfo must be keys of 1–64 ASCII letters, digits, "
        + "underscores, dots, or hyphens; found \"x\\u{A}\"."

    #expect(
        throws: ImageFailure.manifestInvalid(
            path: "android-image.json",
            reason: expectedReason
        )
    ) {
        try decodeManifest(json)
    }
}

@Test
func androidImageManifestRejectsTrailingLineFeedsInPatternFields() throws {
    let sha256 = String(repeating: "0", count: 64)
    let invalidJSON = [
        validManifestJSON.replacingOccurrences(
            of: "\"branch\": \"aosp-android-latest-release\"",
            with: "\"branch\": \"aosp-android-latest-release\\n\""
        ),
        validManifestJSON.replacingOccurrences(
            of: "\"target\": \"aosp_cf_arm64_only_phone-userdebug\"",
            with: "\"target\": \"aosp_cf_arm64_only_phone-userdebug\\n\""
        ),
        validManifestJSON.replacingOccurrences(
            of: "\"buildId\": \"16373615\"",
            with: "\"buildId\": \"16373615\\n\""
        ),
        validManifestJSON.replacingOccurrences(
            of: "\"name\": \"archive.zip\"",
            with: "\"name\": \"archive.zip\\n\""
        ),
        validManifestJSON.replacingOccurrences(
            of: "\"release\": \"17\"",
            with: "\"release\": \"17\\n\""
        ),
        validManifestJSON.replacingOccurrences(
            of: "\"securityPatch\": \"2026-09\"",
            with: "\"securityPatch\": \"2026-09\\n\""
        ),
        validManifestJSON.replacingOccurrences(
            of: "\"architecture\": \"arm64\"",
            with: "\"architecture\": \"arm64\\n\""
        ),
        validManifestJSON.replacingOccurrences(
            of: "\"deviceFamily\": \"cuttlefish-phone-arm64\"",
            with: "\"deviceFamily\": \"cuttlefish-phone-arm64\\n\""
        ),
        validManifestJSON.replacingOccurrences(
            of: "\"id\": \"boot\"",
            with: "\"id\": \"boot\\n\""
        ),
        validManifestJSON.replacingOccurrences(
            of: "\"file\": \"boot.img\"",
            with: "\"file\": \"boot.img\\n\""
        ),
        validManifestJSON.replacingOccurrences(
            of: "\"sha256\": \"\(sha256)\"",
            with: "\"sha256\": \"\(sha256)\\n\""
        ),
        validManifestJSON.replacingOccurrences(
            of: "\"partition\": \"boot\"",
            with: "\"partition\": \"boot\\n\""
        ),
        validManifestJSON.replacingOccurrences(
            of: "\"name\": \"system_a\"",
            with: "\"name\": \"system_a\\n\""
        ),
    ]

    for json in invalidJSON {
        #expect(throws: ImageFailure.self) {
            try decodeManifest(json)
        }
    }
}

@Test
func androidImageManifestEscapesAndroidInfoKeysInDecodingPaths() throws {
    let json = validManifestJSON.replacingOccurrences(
        of: "\"androidInfo\": {}",
        with: "\"androidInfo\": {\"x\\nINJECTED\": 37}"
    )
    let expectedReason =
        "android-image.json:androidInfo.x\\u{A}INJECTED: expected String, "
        + "found an incompatible JSON type. Correct the field type to match schema version 1."

    #expect(
        throws: ImageFailure.manifestInvalid(
            path: "android-image.json",
            reason: expectedReason
        )
    ) {
        try decodeManifest(json)
    }
}

@Test
func androidImageManifestEscapesInvalidFixedFieldValues() throws {
    let json = validManifestJSON.replacingOccurrences(
        of: "\"variant\": \"userdebug\"",
        with: "\"variant\": \"bad\\nINJECTED\""
    )
    let expectedReason =
        "android-image.json: android.variant must be user, userdebug, or eng; "
        + "found \"bad\\u{A}INJECTED\"."

    #expect(
        throws: ImageFailure.manifestInvalid(
            path: "android-image.json",
            reason: expectedReason
        )
    ) {
        try decodeManifest(json)
    }
}

@Test
func androidImageManifestBoundsUntrustedDiagnosticValues() {
    let value = String(repeating: "x", count: 129)

    #expect(manifestDiagnosticValue(value) == String(repeating: "x", count: 128) + "…")
}

@Test
func androidImageManifestEscapesBidirectionalFormattingControls() {
    let value = "before\u{061C}\u{202E}middle\u{2066}after"

    #expect(
        manifestDiagnosticValue(value)
            == "before\\u{61C}\\u{202E}middle\\u{2066}after"
    )
}

@Test
func androidImageManifestAllowsSchemaDefinedAndroidInfoKeys() throws {
    let json = validManifestJSON.replacingOccurrences(
        of: "\"androidInfo\": {}",
        with: "\"androidInfo\": {\"ro.build.version.sdk\": \"37\"}"
    )
    let manifest = try decodeManifest(json)

    #expect(manifest.androidInfo == ["ro.build.version.sdk": "37"])
}

@Test
func androidImageManifestValidatorReportsMissingRoleArtifacts() throws {
    var document = try manifestDocument()
    var roles = try object(document["roles"])
    roles["vendorBoot"] = "vendor_boot2"
    document["roles"] = roles

    let manifest = try decodeManifest(document)
    let failure = ImageFailure.manifestInvalid(
        path: "android-image.json",
        reason:
            "roles.vendorBoot = \"vendor_boot2\": no artifact with that id. Known ids: boot, init_boot, vendor_boot, vbmeta, super."
    )

    #expect(throws: failure) {
        try AndroidImageManifestValidator().validate(manifest)
    }
}

@Test
func androidImageManifestValidatorReportsRoleKindMismatches() throws {
    var document = try manifestDocument()
    var artifacts = try array(document["artifacts"])
    var vendorBoot = try object(artifacts[2])
    vendorBoot["kind"] = "bootImage"
    artifacts[2] = vendorBoot
    document["artifacts"] = artifacts

    let manifest = try decodeManifest(document)
    let failure = ImageFailure.manifestInvalid(
        path: "android-image.json",
        reason:
            "artifacts[2] (role vendorBoot): expected kind vendorBootImage on partition vendor_boot, found bootImage on partition vendor_boot. Is the file swapped?"
    )

    #expect(throws: failure) {
        try AndroidImageManifestValidator().validate(manifest)
    }
}

@Test
func androidImageManifestValidatorChecksBootImageRoleKindFromItsPartition() throws {
    var document = try manifestDocument()
    var roles = try object(document["roles"])
    roles["genericRamdisk"] = "boot"
    document["roles"] = roles

    let manifest = try decodeManifest(document)
    let failure = ImageFailure.manifestInvalid(
        path: "android-image.json",
        reason:
            "artifacts[0] (role genericRamdisk): expected kind bootImage on partition init_boot, found bootImage on partition boot. Is the file swapped?"
    )

    #expect(throws: failure) {
        try AndroidImageManifestValidator().validate(manifest)
    }
}

@Test
func androidImageManifestValidatorAcceptsSparseSuperAndUserdataTemplates() throws {
    var document = try manifestDocument()
    var artifacts = try array(document["artifacts"])
    var superArtifact = try object(artifacts[4])
    superArtifact["kind"] = "sparse"
    artifacts[4] = superArtifact
    artifacts.append(
        [
            "id": "userdata",
            "file": "userdata.img",
            "sha256": String(repeating: "0", count: 64),
            "size": 1,
            "kind": "filesystem",
            "partition": "userdata",
        ] as [String: Any])
    document["artifacts"] = artifacts

    var roles = try object(document["roles"])
    roles["userdataTemplate"] = "userdata"
    document["roles"] = roles

    try AndroidImageManifestValidator().validate(decodeManifest(document))
}

@Test
func androidImageManifestValidatorRequiresArm64() throws {
    var document = try manifestDocument()
    document["architecture"] = "x86_64"

    let manifest = try decodeManifest(document)
    let failure = ImageFailure.manifestInvalid(
        path: "android-image.json",
        reason: "architecture x86_64 is not supported. Use an arm64 target."
    )

    #expect(throws: failure) {
        try AndroidImageManifestValidator().validate(manifest)
    }
}

@Test
func androidImageManifestValidatorRejectsDuplicatePartitionNames() throws {
    var document = try manifestDocument()
    document["blankPartitions"] = [["partition": "boot", "size": 4096]]

    let manifest = try decodeManifest(document)
    let failure = ImageFailure.manifestInvalid(
        path: "android-image.json",
        reason: "partition \"boot\" appears in artifacts[0] and blankPartitions[0]."
    )

    #expect(throws: failure) {
        try AndroidImageManifestValidator().validate(manifest)
    }
}

@Test
func androidImageManifestValidatorRejectsDuplicateArtifactIdentifiers() throws {
    var document = try manifestDocument()
    var artifacts = try array(document["artifacts"])
    artifacts.append(
        [
            "id": "boot",
            "file": "extra.bin",
            "sha256": String(repeating: "0", count: 64),
            "size": 1,
            "kind": "unknown",
            "partition": "extra",
        ] as [String: Any])
    document["artifacts"] = artifacts

    let manifest = try decodeManifest(document)
    let failure = ImageFailure.manifestInvalid(
        path: "android-image.json",
        reason: "artifact id \"boot\" appears in artifacts[0] and artifacts[5]."
    )

    #expect(throws: failure) {
        try AndroidImageManifestValidator().validate(manifest)
    }
}

@Test
func androidImageManifestValidatorMatchesVariantToTargetSuffix() throws {
    var document = try manifestDocument()
    var android = try object(document["android"])
    android["variant"] = "user"
    document["android"] = android

    let manifest = try decodeManifest(document)
    let failure = ImageFailure.manifestInvalid(
        path: "android-image.json",
        reason: "android.variant \"user\" does not match target aosp_cf_arm64_only_phone-userdebug."
    )

    #expect(throws: failure) {
        try AndroidImageManifestValidator().validate(manifest)
    }
}

private let validManifestJSON = """
    {
      "schemaVersion": 1,
      "source": {
        "origin": "ci.android.com",
        "branch": "aosp-android-latest-release",
        "target": "aosp_cf_arm64_only_phone-userdebug",
        "buildId": "16373615",
        "archives": [
          {
            "name": "archive.zip",
            "size": 1,
            "sha256": "\(String(repeating: "0", count: 64))"
          }
        ]
      },
      "android": {
        "release": "17",
        "sdk": 37,
        "variant": "userdebug",
        "securityPatch": "2026-09"
      },
      "architecture": "arm64",
      "deviceFamily": "cuttlefish-phone-arm64",
      "artifacts": [
        {
          "id": "boot",
          "file": "boot.img",
          "sha256": "\(String(repeating: "0", count: 64))",
          "size": 1,
          "kind": "bootImage",
          "partition": "boot"
        },
        {
          "id": "init_boot",
          "file": "init_boot.img",
          "sha256": "\(String(repeating: "0", count: 64))",
          "size": 1,
          "kind": "bootImage",
          "partition": "init_boot"
        },
        {
          "id": "vendor_boot",
          "file": "vendor_boot.img",
          "sha256": "\(String(repeating: "0", count: 64))",
          "size": 1,
          "kind": "vendorBootImage",
          "partition": "vendor_boot"
        },
        {
          "id": "vbmeta",
          "file": "vbmeta.img",
          "sha256": "\(String(repeating: "0", count: 64))",
          "size": 1,
          "kind": "vbmeta",
          "partition": "vbmeta"
        },
        {
          "id": "super",
          "file": "super.img",
          "sha256": "\(String(repeating: "0", count: 64))",
          "size": 1,
          "kind": "dynamicPartitions",
          "partition": "super"
        }
      ],
      "roles": {
        "kernel": "boot",
        "genericRamdisk": "init_boot",
        "vendorBoot": "vendor_boot",
        "vbmeta": ["vbmeta"],
        "super": "super"
      },
      "logicalPartitions": [
        {"name": "system_a", "size": 512, "filesystem": "erofs"}
      ],
      "blankPartitions": [],
      "androidInfo": {}
    }
    """

private func decodeManifest(_ json: String) throws -> AndroidImageManifest {
    try JSONDecoder().decode(
        AndroidImageManifest.self,
        from: Data(json.utf8)
    )
}

private func decodeManifest(_ object: [String: Any]) throws -> AndroidImageManifest {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return try JSONDecoder().decode(AndroidImageManifest.self, from: data)
}

private func manifestDocument() throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(validManifestJSON.utf8)) as? [String: Any]
        ?? [:]
}

private func object(_ value: Any?) throws -> [String: Any] {
    guard let value = value as? [String: Any] else {
        throw ManifestTestError.invalidFixture
    }
    return value
}

private func array(_ value: Any?) throws -> [Any] {
    guard let value = value as? [Any] else {
        throw ManifestTestError.invalidFixture
    }
    return value
}

private enum ManifestTestError: Error {
    case invalidFixture
}

private var repositoryRoot: URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 {
        url.deleteLastPathComponent()
    }
    return url
}

private var manifestFixtureDirectory: URL {
    repositoryRoot.appendingPathComponent(
        "Images/tools/tests/fixtures/manifests",
        isDirectory: true
    )
}
