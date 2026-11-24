import Foundation
import Testing

@testable import APKStoreCore

/// diagnostics.md §10.2: matching order, range narrowness, and the
/// never-crashing load.
@Suite("CompatibilityDatabase")
struct CompatibilityDatabaseTests {
    private let digestA = String(repeating: "a", count: 64)
    private let digestB = String(repeating: "b", count: 64)
    private let tested = CompatibilityEntry.TestedWith(
        apkrun: "1.0", image: "android-17", date: "2026-11-01")

    private func entry(
        _ packageID: String,
        signers: [String]? = nil,
        min: Int64? = nil,
        max: Int64? = nil,
        level: CompatibilityLevel = .works
    ) -> CompatibilityEntry {
        CompatibilityEntry(
            packageID: packageID,
            signerDigests: signers,
            versionCodes: (min == nil && max == nil)
                ? nil
                : CompatibilityVersionRange(min: min, max: max),
            level: level,
            issues: [],
            recommendedSettings: [:],
            testedWith: tested,
            source: "lab")
    }

    @Test func packageIDMatch() {
        let db = CompatibilityDatabase(entries: [entry("com.a"), entry("com.b")])
        #expect(db.match(packageID: "com.b")?.packageID == "com.b")
        #expect(db.match(packageID: "com.c") == nil)
    }

    @Test func signerDigestMustMatchWhenListed() {
        let db = CompatibilityDatabase(entries: [entry("com.a", signers: [digestA])])
        #expect(db.match(packageID: "com.a", signerDigests: [digestA]) != nil)
        #expect(db.match(packageID: "com.a", signerDigests: [digestB]) == nil)
        // An entry without digests matches any signer.
        let open = CompatibilityDatabase(entries: [entry("com.a")])
        #expect(open.match(packageID: "com.a", signerDigests: [digestB]) != nil)
    }

    @Test func versionRangeIsInclusiveAndOpenEnded() {
        let db = CompatibilityDatabase(entries: [
            entry("com.a", min: 10, max: 20),
            entry("com.b", min: 10),
            entry("com.c", max: 5),
        ])
        #expect(db.match(packageID: "com.a", versionCode: 10) != nil)
        #expect(db.match(packageID: "com.a", versionCode: 20) != nil)
        #expect(db.match(packageID: "com.a", versionCode: 21) == nil)
        #expect(db.match(packageID: "com.b", versionCode: 999) != nil)
        #expect(db.match(packageID: "com.c", versionCode: 5) != nil)
        #expect(db.match(packageID: "com.c", versionCode: 6) == nil)
    }

    @Test func narrowestRangeWins() {
        let broad = entry("com.a", min: 1, max: 100, level: .compatibilityMode)
        let narrow = entry("com.a", min: 10, max: 20, level: .unsupported)
        let open = entry("com.a", level: .works)
        let db = CompatibilityDatabase(entries: [broad, narrow, open])
        #expect(db.match(packageID: "com.a", versionCode: 15)?.level == .unsupported)
        #expect(db.match(packageID: "com.a", versionCode: 50)?.level == .compatibilityMode)
        // The range-less entry is the widest of all.
        #expect(db.match(packageID: "com.a")?.level == .works)
    }

    @Test func loadReturnsEmptyForMissingOrCorruptFiles() throws {
        let missing = URL(fileURLWithPath: "/nonexistent/compatibility.json")
        #expect(CompatibilityDatabase.load(from: missing).entries.isEmpty)

        let corrupt = FileManager.default.temporaryDirectory
            .appendingPathComponent("compat-corrupt-\(UUID().uuidString).json")
        try "not json {".write(to: corrupt, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: corrupt) }
        #expect(CompatibilityDatabase.load(from: corrupt).entries.isEmpty)

        // A wrong schema version is rejected too.
        let wrong = FileManager.default.temporaryDirectory
            .appendingPathComponent("compat-wrong-\(UUID().uuidString).json")
        try """
        {"schemaVersion": 2, "generatedAt": "x", "entries": []}
        """.write(to: wrong, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: wrong) }
        #expect(CompatibilityDatabase.load(from: wrong).entries.isEmpty)
    }

    @Test func loadParsesTheSeedFormat() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("compat-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-11-22T00:00:00Z",
          "entries": [{
            "packageID": "com.example.app",
            "signerDigests": ["\(digestA)"],
            "versionCodes": {"min": 10, "max": null},
            "level": "compatibilityMode",
            "issues": [{
              "id": "IME-1",
              "title": {"en": "IME overlay drifts", "ja": "IMEずれ"},
              "workaround": {"en": "Use compatibility window mode", "ja": "互換モード"}
            }],
            "recommendedSettings": {"window.displayMode": "compatibility"},
            "testedWith": {"apkrun": "1.0", "image": "android-17", "date": "2026-11-01"},
            "source": "lab"
          }]
        }
        """.write(to: url, atomically: true, encoding: .utf8)
        let db = CompatibilityDatabase.load(from: url)
        #expect(db.schemaVersion == 1)
        let entry = try #require(db.entries.first)
        #expect(entry.packageID == "com.example.app")
        #expect(entry.level == .compatibilityMode)
        #expect(entry.issues.first?.title["ja"] == "IMEずれ")
        #expect(entry.recommendedSettings["window.displayMode"] == "compatibility")
        #expect(
            db.match(
                packageID: "com.example.app",
                signerDigests: [digestA],
                versionCode: 10) == entry)
    }

    @Test func bundleURLResolvesFromHelpersDirectory() {
        let executable = URL(
            fileURLWithPath:
                "/Applications/APKRun.app/Contents/Helpers/apkrund")
        #expect(
            CompatibilityDatabase.bundleURL(executableURL: executable).path
                == "/Applications/APKRun.app/Contents/Resources/compatibility.json")
    }
}

/// configuration.md §3.2: global off-switch → settings.json →
/// recommendation → default.
@Suite("PackageSettingsResolver recommendations")
struct PackageSettingsRecommendationTests {
    @Test func resolutionOrder() {
        // Stored values beat recommendations.
        var resolver = PackageSettingsResolver(
            recommendations: ["window.displayMode": "compatibility"])
        var settings = PackageSettings()
        settings.set("window.displayMode", "phone")
        #expect(resolver.effectiveValue(for: "window.displayMode", in: settings) == "phone")
        // Recommendations beat defaults when nothing is stored.
        settings = PackageSettings()
        #expect(
            resolver.effectiveValue(for: "window.displayMode", in: settings)
                == "compatibility")
        #expect(resolver.isRecommended("window.displayMode", in: settings))
        // The global integrations off-switch beats everything.
        resolver = PackageSettingsResolver(
            globalIntegrationsEnabled: ["files": false],
            recommendations: ["integrations.files": "true"])
        settings.set("integrations.files", "true")
        #expect(resolver.effectiveValue(for: "integrations.files", in: settings) == "false")
    }
}
