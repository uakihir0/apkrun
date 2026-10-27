import Foundation
import RuntimeAPI
import Testing

@testable import WrapperCore

@Test func registrySortsEntriesAndRoundTripsWithAtomicPrivateWrite() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("WrapperRegistryTests-\(UUID().uuidString)", isDirectory: true)
    defer {
        // Test cleanup must not affect the registry assertions.
        try? FileManager.default.removeItem(at: rootURL)
    }

    let registryURL = rootURL.appendingPathComponent("Wrappers/registry.json")
    let registry = WrapperRegistry(fileURL: registryURL)
    let missingRegistry = try await registry.read()
    #expect(missingRegistry.wrappers.isEmpty)
    #expect(missingRegistry.denied.isEmpty)

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let active = try makeEntry(packageID: "com.example.active", state: .active, createdAt: now)
    let pending = try makeEntry(packageID: "com.example.pending", state: .pending, createdAt: now)
    let refreshing = try makeEntry(packageID: "com.example.refreshing", state: .refreshing, createdAt: now)
    let expiredDenial = try WrapperRegistryFile.DeniedEntry(
        bundleID: "io.apkrun.android.com.example.expired",
        cdhash: String(repeating: "a", count: 40),
        until: now.addingTimeInterval(-1)
    )
    let currentDenial = try WrapperRegistryFile.DeniedEntry(
        bundleID: "io.apkrun.android.com.example.denied",
        cdhash: String(repeating: "b", count: 40),
        until: now.addingTimeInterval(3_600)
    )
    let input = try WrapperRegistryFile(
        wrappers: [refreshing, active, pending],
        denied: [expiredDenial, currentDenial]
    )

    try await registry.write(input, now: now)

    let expected = try WrapperRegistryFile(
        wrappers: [active, pending, refreshing],
        denied: [currentDenial]
    )
    let readBack = try await registry.read()
    #expect(readBack == expected)

    let encoded = try Data(contentsOf: registryURL)
    #expect(encoded.last == 0x0A)
    let permissions = try FileManager.default.attributesOfItem(atPath: registryURL.path)[.posixPermissions]
    #expect((permissions as? NSNumber)?.intValue == 0o600)
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: registryURL.deletingLastPathComponent().path) == [
            "registry.json"
        ])
}

@Test func registryDropsUnknownKeysAndRejectsUnsupportedSchemaVersions() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("WrapperRegistryValidationTests-\(UUID().uuidString)", isDirectory: true)
    defer {
        // Test cleanup must not affect the registry assertions.
        try? FileManager.default.removeItem(at: rootURL)
    }

    let registryURL = rootURL.appendingPathComponent("registry.json")
    let registry = WrapperRegistry(fileURL: registryURL)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

    try Data(#"{"schemaVersion":1,"wrappers":[],"denied":[],"unexpected":true}"#.utf8)
        .write(to: registryURL, options: .atomic)
    let decoded = try await registry.read()
    #expect(decoded.wrappers.isEmpty)
    try await registry.write(decoded)
    let rewritten = try String(contentsOf: registryURL, encoding: .utf8)
    #expect(!rewritten.contains("unexpected"))

    try Data(#"{"schemaVersion":2,"wrappers":[],"denied":[]}"#.utf8)
        .write(to: registryURL, options: .atomic)
    await #expect(throws: WrapperRegistry.Failure.unsupportedSchemaVersion(2)) {
        try await registry.read()
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: rootURL.path) == ["registry.json"])
}

@Test func registryPreservesMalformedDocumentsButRejectsOffsetDates() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("WrapperRegistryCorruptTests-\(UUID().uuidString)", isDirectory: true)
    defer {
        // Test cleanup must not affect the registry assertions.
        try? FileManager.default.removeItem(at: rootURL)
    }

    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let registryURL = rootURL.appendingPathComponent("registry.json")
    let registry = WrapperRegistry(fileURL: registryURL)
    let offsetDateDocument =
        #"""
        {"schemaVersion":1,"wrappers":[],"denied":[{"bundleId":"io.apkrun.android.com.example","cdhash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","until":"2026-10-01T09:12:00.125+00:00"}]}
        """#
    try Data(offsetDateDocument.utf8).write(to: registryURL, options: .atomic)

    await #expect(throws: WrapperRegistry.Failure.invalidDocument) {
        try await registry.read()
    }

    let files = try FileManager.default.contentsOfDirectory(atPath: rootURL.path)
    let backupName = try #require(files.first(where: { $0.hasPrefix("registry.json.corrupt-") }))
    #expect(!files.contains("registry.json"))
    #expect(try Data(contentsOf: rootURL.appendingPathComponent(backupName)) == Data(offsetDateDocument.utf8))
}

@Test func registryAcceptsSchemaValidFractionalUTCDate() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("WrapperRegistryDateTests-\(UUID().uuidString)", isDirectory: true)
    defer {
        // Test cleanup must not affect the registry assertions.
        try? FileManager.default.removeItem(at: rootURL)
    }

    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let registryURL = rootURL.appendingPathComponent("registry.json")
    let registry = WrapperRegistry(fileURL: registryURL)
    let document =
        #"""
        {"schemaVersion":1,"wrappers":[],"denied":[{"bundleId":"io.apkrun.android.com.example","cdhash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","until":"2026-10-01T09:12:00.123456789Z"}]}
        """#
    try Data(document.utf8).write(to: registryURL, options: .atomic)

    let decoded = try await registry.read()
    #expect(decoded.denied.count == 1)
    #expect(decoded.denied.first?.until.timeIntervalSince1970 ?? 0 > 1_790_000_000)
}

@Test func failedRegistryWriteLeavesPreviousFileUntouched() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("WrapperRegistryAtomicityTests-\(UUID().uuidString)", isDirectory: true)
    defer {
        // Test cleanup must not affect the registry assertions.
        try? FileManager.default.removeItem(at: rootURL)
    }

    let registryURL = rootURL.appendingPathComponent("Wrappers/registry.json")
    let registry = WrapperRegistry(fileURL: registryURL)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let entry = try makeEntry(packageID: "com.example.atomic", state: .active, createdAt: now)
    let document = try WrapperRegistryFile(wrappers: [entry])
    try await registry.write(document, now: now)
    let originalContents = try Data(contentsOf: registryURL)

    let blockedURL = registryURL.appendingPathComponent("child/registry.json")
    let blockedRegistry = WrapperRegistry(fileURL: blockedURL)
    await #expect(throws: WrapperRegistry.Failure.self) {
        try await blockedRegistry.write(document, now: now)
    }

    #expect(try Data(contentsOf: registryURL) == originalContents)
}

@Test func registryBoundsDecodedBookmarkBytesAtEightKiB() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let maximumBookmark = try makeEntry(
        packageID: "com.example.bookmark",
        state: .active,
        createdAt: now,
        bookmarkSize: 8 * 1024
    )
    #expect(maximumBookmark.bookmark?.count == 8 * 1024)

    #expect(throws: WrapperRegistry.Failure.invalidDocument) {
        try makeEntry(
            packageID: "com.example.bookmark",
            state: .active,
            createdAt: now,
            bookmarkSize: (8 * 1024) + 1
        )
    }
}

@Test func registryRejectsAppPathsWithAnEmptyBundleName() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(throws: WrapperRegistry.Failure.invalidDocument) {
        try makeEntry(
            packageID: "com.example.path",
            state: .active,
            createdAt: now,
            path: "/tmp/.app"
        )
    }
    #expect(throws: WrapperRegistry.Failure.invalidDocument) {
        try makeEntry(
            packageID: "com.example.staging",
            state: .pending,
            createdAt: now,
            stagingPath: "/tmp/.app"
        )
    }
}

@Test func registryCountsLabelUnicodeScalars() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let combiningLabel = String(repeating: "e\u{301}", count: 600)
    #expect(combiningLabel.count < 1024)
    #expect(combiningLabel.unicodeScalars.count > 1024)
    #expect(throws: WrapperRegistry.Failure.invalidDocument) {
        try makeEntry(
            packageID: "com.example.label",
            state: .active,
            createdAt: now,
            displayName: combiningLabel
        )
    }
}

private func makeEntry(
    packageID rawPackageID: String,
    state: WrapperRegistryFile.Entry.State,
    createdAt: Date,
    bookmarkSize: Int = 3,
    path: String? = nil,
    stagingPath: String? = nil,
    displayName: String? = nil
) throws -> WrapperRegistryFile.Entry {
    let packageID = try #require(RuntimePackageID(rawValue: rawPackageID))
    let bundleID = BundleIDMapper.map(packageID)
    return try WrapperRegistryFile.Entry(
        bundleID: bundleID,
        packageID: packageID,
        kind: .local,
        state: state,
        path: path ?? "/tmp/\(packageID.rawValue).app",
        bookmark: state == .pending ? nil : Data(repeating: 1, count: bookmarkSize),
        stagingPath: state == .active ? nil : stagingPath ?? "/tmp/.apkrun-\(packageID.rawValue).app",
        cdhash: String(repeating: "a", count: 40),
        pendingCdhash: state == .refreshing ? String(repeating: "b", count: 40) : nil,
        launcherVersion: "1.0.0",
        launcherAPI: "1.0",
        formatVersion: 1,
        fileName: packageID.rawValue,
        displayName: displayName ?? packageID.rawValue,
        customization: .init(displayName: nil, iconFile: nil),
        iconDigest: nil,
        approval: .generated,
        createdAt: createdAt,
        refreshedAt: nil,
        lastValidatedAt: nil
    )
}
