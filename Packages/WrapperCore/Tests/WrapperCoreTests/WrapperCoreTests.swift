import CryptoKit
import DiagnosticsCore
import Foundation
import RuntimeAPI
import Testing

@testable import WrapperCore

// MARK: - T0: WrapperFileName (wrapper.md §4.3)

@Test func fileNameSlashAndColonBecomeDashes() {
    #expect(WrapperFileName.sanitize(displayName: "a/b:c", packageID: "com.x") == "a-b-c")
}

@Test func fileNameSpecExample() {
    // §6.2 check: io.apkrun.fixture.odd_name → io.apkrun.android.io.apkrun.fixture.odd-name
    #expect(
        BundleIDMapper.map("io.apkrun.fixture.odd_name")
            == "io.apkrun.android.io.apkrun.fixture.odd-name")
}

@Test func fileNameEmojiWithZWJSurvives() {
    let result = WrapperFileName.sanitize(displayName: "Game 👨‍👩‍👧 Night", packageID: "com.x")
    #expect(result == "Game 👨‍👩‍👧 Night")
}

@Test func fileNameVariationSelectorSurvives() {
    let result = WrapperFileName.sanitize(displayName: "Color ❤️ App", packageID: "com.x")
    #expect(result == "Color ❤️ App")
}

@Test func fileNameControlAndFormatStripped() {
    let result = WrapperFileName.sanitize(
        displayName: "a\u{7}b\u{200B}c\u{E0001}d", packageID: "com.x")
    #expect(result == "abcd")
}

@Test func fileNameWhitespaceCollapsedAndTrimmed() {
    #expect(
        WrapperFileName.sanitize(displayName: "  My   App \n Name  ", packageID: "com.x")
            == "My App Name")
}

@Test func fileNameLeadingDotsStripped() {
    #expect(WrapperFileName.sanitize(displayName: "..hidden", packageID: "com.x") == "hidden")
}

@Test func fileNameTruncatesAt200UTF8BytesOnGraphemeBoundary() {
    // 150 two-byte characters plus a long emoji tail.
    let name = String(repeating: "é", count: 150) + String(repeating: "😀", count: 20)
    let result = WrapperFileName.sanitize(displayName: name, packageID: "com.x")
    #expect(result.utf8.count <= 200)
    #expect(result.unicodeScalars.count == 100)  // 100 é = 200 bytes
}

@Test func fileNameEmptyFallsBackToPackageSegment() {
    #expect(
        WrapperFileName.sanitize(displayName: "\u{0}\u{1F}", packageID: "com.example.game")
            == "game")
    #expect(WrapperFileName.sanitize(displayName: "", packageID: "single") == "single")
}

@Test func sanitizedDisplayNameKeepsSlashes() {
    #expect(WrapperFileName.sanitizedDisplayName("a/b") == "a/b")
}

// MARK: - T0: BundleIDMapper (wrapper.md §4.1)

@Test func bundleIDDeterministic() {
    #expect(BundleIDMapper.map("com.example.app") == "io.apkrun.android.com.example.app")
    #expect(BundleIDMapper.map("jp.foo.bar_baz") == "io.apkrun.android.jp.foo.bar-baz")
}

@Test func bundleIDUppercaseGetsHashSuffix() {
    let a = BundleIDMapper.map("com.Example.App")
    #expect(a.hasPrefix("io.apkrun.android.com.Example.App-h"))
    #expect(BundleIDMapper.map("com.Example.App") == a)  // deterministic
    #expect(BundleIDMapper.map("com.example.app") != a)  // case-sensitive
}

// MARK: - T1: generation, conflicts, registry, validator

func makeLauncherStub(at dir: URL) throws -> URL {
    let executable = dir.appendingPathComponent("APKRunLauncher")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
    process.arguments = [
        "-arch", "arm64", "-x", "c", "-o", executable.path, "-",
    ]
    process.standardInput = Pipe()
    try process.run()
    if let pipe = process.standardInput as? Pipe {
        pipe.fileHandleForWriting.write(Data("int main(void){return 0;}\n".utf8))
        try? pipe.fileHandleForWriting.close()
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw WrapperFailure.launcherTemplateInvalid("clang failed")
    }
    return executable
}

struct Fixture {
    let root: URL
    let destination: URL
    let staging: URL
    let registryFile: URL
    let registry: WrapperRegistry
    let launcher: LauncherBuild

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wrappercore-\(UUID().uuidString)")
        destination = root.appendingPathComponent("dest")
        staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        registryFile = root.appendingPathComponent("registry.json")
        registry = WrapperRegistry(
            fileURL: registryFile, stagingRoot: root)
        let executable = try makeLauncherStub(at: root)
        launcher = LauncherBuild(
            launcherAPI: "1.0", launcherVersion: "0.1.0", executableURL: executable)
        _ = await registry.load()
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    /// A single-APK `BootstrapSet` like the store hands to
    /// `stageForDistribution` for a distribution request.
    func bootstrapPayload(package: String = "com.example.game") throws -> BootstrapSet {
        let source = root.appendingPathComponent("base.apk")
        let bytes = Data("fixture-apk".utf8)
        try bytes.write(to: source)
        let digest =
            "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let entry = BootstrapFileEntry(name: "base.apk", sha256: digest, size: Int64(bytes.count))
        return BootstrapSet(
            document: BootstrapDocument(
                packageId: package,
                versionCode: 1,
                setDigest: BootstrapSetDigest.compute(files: [entry]),
                signers: ["sha256:" + String(repeating: "1", count: 64)],
                files: [entry]),
            files: [
                BootstrapSet.SourceFile(
                    name: "base.apk", sourceURL: source, sha256: digest,
                    size: Int64(bytes.count))
            ])
    }

    func configuration(
        package: String = "com.example.game", name: String = "Test Game"
    ) throws -> WrapperConfiguration {
        WrapperConfiguration(
            packageID: RuntimePackageID(rawValue: package)!,
            displayName: name,
            icon: .placeholder,
            category: nil,
            window: WindowDefaults(),
            updates: WrapperUpdateDefaults(),
            integrations: IntegrationDefaults(),
            kind: .local
        )
    }

    func request(package: String = "com.example.game", name: String = "Test Game")
        throws -> WrapperGenerationRequest
    {
        WrapperGenerationRequest(
            configuration: try configuration(package: package, name: name),
            destination: .directory(destination),
            replace: .never
        )
    }

    func generator() -> AppWrapperGenerator {
        AppWrapperGenerator(
            environment: AppWrapperGenerator.Environment(
                launcher: launcher,
                registry: registry,
                installer: WrapperInstaller(register: { _ in 0 }, noteChanged: { _ in }),
                stagingRoot: staging
            )
        )
    }
}

private func sha256Tree(at url: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    let enumerator = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: nil)!
    for case let file as URL in enumerator {
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        else { continue }
        let relative = file.path.replacingOccurrences(of: url.path + "/", with: "")
        let data = try Data(contentsOf: file)
        result[relative] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    return result
}

@Test func generationProducesCompleteBundle() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanup() }
    let generated = try await fixture.generator().generate(fixture.request())
    #expect(generated.bundleID == "io.apkrun.android.com.example.game")
    let contents = generated.bundleURL.appendingPathComponent("Contents")
    for path in ["Info.plist", "PkgInfo", "Resources/wrapper.json", "Resources/AppIcon.icns", "MacOS/APKRunLauncher"] {
        #expect(FileManager.default.fileExists(atPath: contents.appendingPathComponent(path).path), "\(path) missing")
    }
    #expect(generated.cdhash.count == 40)
    let entry = await fixture.registry.entry(bundleID: generated.bundleID)
    #expect(entry?.state == .active)
    // wrapper.json must not carry version, APK path, or digest (FR-WRP-03).
    let document = try WrapperDocumentCodec.load(from: generated.bundleURL)
    #expect(document.application.packageId == "com.example.game")
    let json = String(
        decoding: try Data(contentsOf: contents.appendingPathComponent("Resources/wrapper.json")), as: UTF8.self)
    for banned in ["versionCode", "versionName", "apkPath", "digest", "sha256"] {
        #expect(!json.lowercased().contains(banned.lowercased()), "wrapper.json contains \(banned)")
    }
}

@Test func generatedBundleContainsNoAPKFile() async throws {
    // #49: the wrapper is independent of the APK file — the bundle never
    // embeds the source archive (wrapper.md §14, FR-WRP-03).
    let fixture = try await Fixture()
    defer { fixture.cleanup() }
    let generated = try await fixture.generator().generate(fixture.request())
    let enumerator = FileManager.default.enumerator(
        at: generated.bundleURL, includingPropertiesForKeys: nil)
    let files = enumerator?.allObjects.compactMap { $0 as? URL } ?? []
    for file in files where file.pathExtension == "apk" {
        Issue.record("generated bundle contains APK file \(file.path)")
    }
}

@Test func wrapperFileHashesGiveAStableSortedList() throws {
    // #50 step 1: the G9 check compares this list before and after an
    // update — a fixed directory must always produce the same sorted
    // (path, sha256) entries.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-hashes-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Contents/Resources"),
        withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Contents/MacOS"),
        withIntermediateDirectories: true)
    try Data("launcher".utf8).write(
        to: root.appendingPathComponent("Contents/MacOS/APKRunLauncher"))
    try Data("plist".utf8).write(
        to: root.appendingPathComponent("Contents/Info.plist"))
    try Data("json".utf8).write(
        to: root.appendingPathComponent("Contents/Resources/wrapper.json"))

    let hashes = try WrapperFileHashes.compute(bundleURL: root)
    #expect(
        hashes.map(\.path) == [
            "Contents/Info.plist",
            "Contents/MacOS/APKRunLauncher",
            "Contents/Resources/wrapper.json",
        ])
    let sha256 = { (bytes: String) in
        SHA256.hash(data: Data(bytes.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    #expect(hashes[0].sha256 == sha256("plist"))
    #expect(hashes[1].sha256 == sha256("launcher"))
    #expect(hashes[2].sha256 == sha256("json"))
    // A second pass over the same directory is identical, and an xattr
    // (the kind Spotlight adds) does not change the list.
    setxattr(
        root.appendingPathComponent("Contents/Info.plist").path,
        "com.apple.FinderInfo", "x", 1, 0, 0)
    #expect(try WrapperFileHashes.compute(bundleURL: root) == hashes)
}

@Test func generationIsByteIdentical() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanup() }
    let first = try await fixture.generator().generate(fixture.request())
    let tree1 = try sha256Tree(at: first.bundleURL)
    let fixture2 = try await Fixture()
    defer { fixture2.cleanup() }
    let second = try await fixture2.generator().generate(fixture2.request())
    let tree2 = try sha256Tree(at: second.bundleURL)
    #expect(tree1 == tree2)
}

@Test func generationRefusesNameConflict() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanup() }
    // An unrelated .app at the same path.
    let conflict = fixture.destination.appendingPathComponent("Test Game.app")
    try FileManager.default.createDirectory(at: conflict, withIntermediateDirectories: true)
    await #expect(throws: WrapperFailure.self) {
        try await fixture.generator().generate(fixture.request())
    }
}

@Test func generationRefusesExistingWrapperWithoutReplace() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanup() }
    _ = try await fixture.generator().generate(fixture.request())
    await #expect(throws: WrapperFailure.self) {
        try await fixture.generator().generate(fixture.request())
    }
}

@Test func generationWithReplaceSameWrapperSucceeds() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanup() }
    _ = try await fixture.generator().generate(fixture.request())
    var request = try fixture.request()
    request.replace = .sameWrapper
    let regenerated = try await fixture.generator().generate(request)
    #expect(regenerated.bundleID == "io.apkrun.android.com.example.game")
}

@Test func registryRecoveryActivatesPlacedPending() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanup() }
    let generated = try await fixture.generator().generate(fixture.request())
    // Simulate a crash after placement: force the entry back to pending.
    var entry = (await fixture.registry.entry(bundleID: generated.bundleID))!
    entry.state = .pending
    entry.stagingPath = fixture.staging.appendingPathComponent("crash/Test Game.app").path
    try await fixture.registry.markPending(entry)
    await fixture.registry.recover()
    let recovered = await fixture.registry.entry(bundleID: generated.bundleID)
    #expect(recovered?.state == .active)
    #expect(recovered?.cdhash == generated.cdhash)
}

@Test func registryRecoveryDropsMissingPendingAndCleansStaging() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanup() }
    var entry = WrapperRegistryEntry(
        bundleId: BundleIDMapper.map("com.example.lost"),
        packageId: "com.example.lost",
        kind: .local,
        state: .pending,
        path: fixture.destination.appendingPathComponent("Lost.app").path,
        cdhash: String(repeating: "a", count: 40),
        launcherVersion: "0.1.0",
        launcherAPI: "1.0",
        fileName: "Lost",
        displayName: "Lost",
        createdAt: Date()
    )
    let stagingDir = fixture.staging.appendingPathComponent("tok/Lost.app")
    try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
    entry.stagingPath = stagingDir.path
    try await fixture.registry.markPending(entry)
    await fixture.registry.recover()
    #expect(await fixture.registry.entry(bundleID: entry.bundleId) == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.staging.appendingPathComponent("tok").path))
}

@Test func registryCorruptFileIsKeptAside() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanup() }
    try Data("not json at all".utf8).write(to: fixture.registryFile)
    let outcome = await fixture.registry.load()
    guard case .corrupt = outcome else {
        Issue.record("expected corrupt outcome, got \(outcome)")
        return
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.registryFile.path))
    let siblings = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
    #expect(siblings.contains { $0.hasPrefix("registry.json.corrupt-") })
}

@Test func registryKeepsOneEntryPerBundleID() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanup() }
    _ = try await fixture.generator().generate(fixture.request())
    let entries = await fixture.registry.entries()
    #expect(entries.count == 1)
    #expect(entries.first?.bundleId == "io.apkrun.android.com.example.game")
}

// MARK: - T1: WrapperSigner (wrapper.md §7.1)

@Test func signerSignsAdHocAndReturnsCdhash() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanup() }
    let generated = try await fixture.generator().generate(fixture.request())
    let bundleID = "io.apkrun.android.com.example.game"
    #expect(generated.cdhash.count == 40)
    #expect(generated.cdhash.allSatisfy { $0.isHexDigit })
    #expect(WrapperCodeSign.signatureIdentifier(of: generated.bundleURL) == bundleID)
    #expect(
        WrapperCodeSign.signatureIsValid(
            bundleURL: generated.bundleURL, identifier: bundleID))
    let entry = try await fixture.registry.entry(bundleID: bundleID)
    #expect(entry?.state == .active)
    #expect(entry?.cdhash == generated.cdhash)
    #expect(entry?.approval == .generated)
}

@Test func signerRejectsUnsignableBundle() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanup() }
    let bogus = fixture.destination.appendingPathComponent("Bogus.app")
    try FileManager.default.createDirectory(at: bogus, withIntermediateDirectories: true)
    #expect(throws: WrapperFailure.self) {
        try WrapperSigner.sign(bundleURL: bogus, bundleID: "io.apkrun.android.x")
    }
}

@Test func validatorAcceptsGeneratedBundle() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanup() }
    let generated = try await fixture.generator().generate(fixture.request())
    let validator = WrapperValidator(
        registry: fixture.registry,
        currentLauncher: fixture.launcher,
        packageExists: { _ in true })
    let result = try await validator.verify(url: generated.bundleURL, deep: false)
    #expect(result.state == .valid)
    #expect(result.registered)
    #expect(result.problems.isEmpty)
    #expect(result.packageID == "com.example.game")
}

@Test func validatorRejectsNonWrapper() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanup() }
    let fake = fixture.destination.appendingPathComponent("Fake.app")
    try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
    let validator = WrapperValidator(
        registry: fixture.registry,
        packageExists: { _ in true })
    await #expect(throws: WrapperFailure.self) {
        try await validator.verify(url: fake, deep: false)
    }
}

@Test func validatorReportsMissingBundle() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanup() }
    let validator = WrapperValidator(
        registry: fixture.registry,
        packageExists: { _ in true })
    let result = try await validator.verify(
        url: fixture.destination.appendingPathComponent("Gone.app"), deep: false)
    #expect(result.state == .missing)
    #expect(!result.registered)
}

@Test func validatorReportsUnknownPackage() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanup() }
    let generated = try await fixture.generator().generate(fixture.request())
    let validator = WrapperValidator(
        registry: fixture.registry,
        packageExists: { _ in false })
    let result = try await validator.verify(url: generated.bundleURL, deep: false)
    #expect(result.state == .unknownPackage)
}

@Test func atomicWriteLeavesNoPartialRegistry() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanup() }
    _ = try await fixture.generator().generate(fixture.request())
    // No .tmp or partial registry files beside registry.json.
    let siblings = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
    #expect(!siblings.contains { $0.hasSuffix(".tmp") })
    #expect(siblings.contains("registry.json"))
}

// MARK: - T0: placeStagedWrapper support (wrapper.md §6.3)

@Test func pendingEntryMatchesStagingToken() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanup() }
    let registry = fixture.registry
    var entry = WrapperRegistryEntry(
        bundleId: "io.apkrun.android.com.example.game",
        packageId: "com.example.game",
        kind: .local,
        state: .pending,
        path: fixture.destination.appendingPathComponent("Game.app").path,
        cdhash: "cd",
        launcherVersion: "0.1.0",
        launcherAPI: "1.0",
        fileName: "Game",
        displayName: "Game",
        createdAt: Date()
    )
    entry.stagingPath =
        fixture.staging
        .appendingPathComponent("tok-123", isDirectory: true)
        .appendingPathComponent("Game.app").path
    try await registry.markPending(entry)
    #expect(await registry.pendingEntry(stagingToken: "tok-123")?.bundleId == entry.bundleId)
    #expect(await registry.pendingEntry(stagingToken: "other") == nil)
}

@Test func registrationCheckWarnsWhenLaunchServicesForgets() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanup() }
    _ = try await fixture.generator().generate(fixture.request())
    let context = HealthContext(
        daemonAvailable: true,
        runtimeRunning: false,
        paths: APKRunPaths(
            allowingHomeOverride: true,
            environment: ["APKRUN_HOME": fixture.root.path]
        )
    )
    let known = WrapperHealthChecks.registration(fixture.registry) { _ in true }
    #expect(await known.run(context).state == .pass)
    let unknown = WrapperHealthChecks.registration(fixture.registry) { _ in false }
    let result = await unknown.run(context)
    #expect(result.state == .warning)
    #expect(result.error?.code == "wrapper.launchServicesMissing")
}

// MARK: - T0: DistributionWrapperBuilder (wrapper.md §11)

/// Records every call and answers from a canned table so the argument
/// lists of the §11 tools can be asserted without spawning anything.
final class FakeToolRunner: WrapperToolRunner, @unchecked Sendable {
    struct Call: Equatable {
        var executable: String
        var arguments: [String]
    }

    private(set) var calls: [Call] = []
    var answers: [(String) -> ToolResult?] = []

    func run(executable: String, arguments: [String]) throws -> ToolResult {
        calls.append(Call(executable: executable, arguments: arguments))
        for answer in answers {
            if let result = answer(executable + " " + arguments.joined(separator: " ")) {
                return result
            }
        }
        return ToolResult(status: 0)
    }
}

private func distributionIdentity() -> String {
    "Developer ID Application: APKRun Tests (ABCDE12345)"
}

/// A fake that passes both `xcrun --find` checks and lists the identity.
private func passingRunner(_ runner: FakeToolRunner = FakeToolRunner()) -> FakeToolRunner {
    runner.answers.append { line in
        guard line.contains("--find") || line.contains("find-identity") else {
            return nil
        }
        return ToolResult(
            status: 0,
            stdout: """
                  1) 1234ABCD "\(distributionIdentity())"
                    1 valid identities found
                """)
    }
    return runner
}

@Test func distributionPrecheckFindsToolsAndIdentity() throws {
    let runner = passingRunner()
    let builder = DistributionWrapperBuilder(runner: runner)
    try builder.precheck(identity: distributionIdentity())
    #expect(
        runner.calls[0]
            == .init(executable: "/usr/bin/xcrun", arguments: ["--find", "notarytool"]))
    #expect(
        runner.calls[1]
            == .init(executable: "/usr/bin/xcrun", arguments: ["--find", "stapler"]))
    #expect(
        runner.calls[2]
            == .init(
                executable: "/usr/bin/security",
                arguments: ["find-identity", "-v", "-p", "codesigning"]))
}

@Test func distributionPrecheckReportsMissingTool() throws {
    let runner = FakeToolRunner()
    runner.answers.append { line in
        line.contains("stapler") ? ToolResult(status: 1, stderr: "xcrun: error") : nil
    }
    runner.answers.append { _ in
        ToolResult(
            status: 0,
            stdout: " 1) ABCD \"Developer ID Application: APKRun Tests (ABCDE12345)\"\n")
    }
    let builder = DistributionWrapperBuilder(runner: runner)
    #expect(throws: WrapperFailure.distributionToolMissing("stapler")) {
        try builder.precheck(identity: distributionIdentity())
    }
}

@Test func distributionPrecheckReportsUnknownIdentity() throws {
    let runner = FakeToolRunner()
    runner.answers.append { _ in ToolResult(status: 0, stdout: " 1) ABCD \"Other Name (XX)\"\n") }
    let builder = DistributionWrapperBuilder(runner: runner)
    #expect(throws: WrapperFailure.identityNotFound(distributionIdentity())) {
        try builder.precheck(identity: distributionIdentity())
    }
}

@Test func distributionSignUsesDeveloperIDFlags() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanup() }
    let runner = passingRunner()
    let builder = DistributionWrapperBuilder(
        runner: runner, securityCheck: { _, _ in true })
    let generated = try await fixture.generator().generate(fixture.request())
    let bundleID = "io.apkrun.android.com.example.game"
    let (cdhash, _) = try builder.sign(
        bundleURL: generated.bundleURL,
        bundleID: bundleID,
        identity: distributionIdentity())
    #expect(cdhash.count == 40)
    let signCall = runner.calls.first { $0.executable == "/usr/bin/codesign" }
    #expect(
        signCall?.arguments
            == [
                "--force",
                "--sign", distributionIdentity(),
                "--identifier", bundleID,
                "--options", "runtime",
                "--timestamp",
                generated.bundleURL.path,
            ])
    let verifyCall = runner.calls.last { $0.executable == "/usr/bin/codesign" }
    #expect(verifyCall?.arguments == ["--verify", "--strict", generated.bundleURL.path])
}

@Test func distributionNotarizeSubmitsAndStaples() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanup() }
    let runner = passingRunner()
    runner.answers.append { line in
        line.contains("notarytool submit")
            ? ToolResult(
                status: 0,
                stdout: """
                    {"id": "SUB-1", "status": "Accepted"}
                    """)
            : nil
    }
    runner.answers.append { line in
        line.contains("spctl")
            ? ToolResult(status: 0, stderr: "source=Notarized Developer ID\n")
            : nil
    }
    let builder = DistributionWrapperBuilder(
        runner: runner, securityCheck: { _, _ in true })
    let generated = try await fixture.generator().generate(fixture.request())
    let bundleID = "io.apkrun.android.com.example.game"
    _ = try builder.sign(
        bundleURL: generated.bundleURL,
        bundleID: bundleID,
        identity: distributionIdentity())
    let result = try await builder.notarize(
        bundleURL: generated.bundleURL,
        name: "Game",
        keychainProfile: "apkrun-notary",
        workDirectory: fixture.staging)
    #expect(result.submissionID == "SUB-1")
    #expect(result.assessment.contains("Notarized Developer ID"))
    #expect(result.zipURL.lastPathComponent == "Game.zip")
    let submitCall = runner.calls.first { $0.arguments.contains("notarytool") }
    #expect(
        submitCall?.arguments
            == [
                "notarytool", "submit",
                fixture.staging.appendingPathComponent("Game.zip").path,
                "--keychain-profile", "apkrun-notary",
                "--wait", "--output-format", "json",
            ])
    #expect(
        runner.calls.contains {
            $0.executable == "/usr/bin/xcrun"
                && $0.arguments == ["stapler", "staple", generated.bundleURL.path]
        })
}

@Test func distributionNotarizeReportsInvalid() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanup() }
    let runner = passingRunner()
    runner.answers.append { line in
        line.contains("notarytool submit")
            ? ToolResult(
                status: 0,
                stdout: """
                    {"id": "SUB-9", "status": "Invalid", "statusSummary": "signature invalid"}
                    """)
            : nil
    }
    runner.answers.append { line in
        line.contains("notarytool log")
            ? ToolResult(status: 0, stdout: "Issue 1: the binary is not signed\n")
            : nil
    }
    let builder = DistributionWrapperBuilder(
        runner: runner, securityCheck: { _, _ in true })
    let generated = try await fixture.generator().generate(fixture.request())
    do {
        _ = try await builder.notarize(
            bundleURL: generated.bundleURL,
            name: "Game",
            keychainProfile: "apkrun-notary",
            workDirectory: fixture.staging)
        Issue.record("expected notarizationFailed")
    } catch let failure as WrapperFailure {
        guard case .notarizationFailed(let submissionID, let summary) = failure else {
            Issue.record("expected notarizationFailed, got \(failure)")
            return
        }
        #expect(submissionID == "SUB-9")
        #expect(summary.contains("not signed"))
        #expect(failure.code == "notarizationFailed")
        #expect(failure.qualifiedCode == "wrapper.notarizationFailed")
    }
}

@Test func notarySubmissionParsesStatuses() {
    let accepted = DistributionWrapperBuilder.parseNotarySubmission(
        """
        {"id": "SUB-1", "status": "Accepted"}
        """)
    #expect(accepted?.status == "Accepted")
    #expect(accepted?.submissionID == "SUB-1")
    let invalid = DistributionWrapperBuilder.parseNotarySubmission(
        """
        {"id": "SUB-2", "status": "Invalid", "statusSummary": "bad"}
        """)
    #expect(invalid?.status == "Invalid")
    #expect(invalid?.summary == "bad")
    let inProgress = DistributionWrapperBuilder.parseNotarySubmission(
        """
        {"id": "SUB-3", "status": "In Progress", "message": "Timeout waiting"}
        """)
    #expect(inProgress?.status == "In Progress")
    #expect(inProgress?.submissionID == "SUB-3")
    #expect(DistributionWrapperBuilder.parseNotarySubmission("not json") == nil)
}

@Test func stageForDistributionBuildsPortableUnregistered() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanup() }
    let generator = fixture.generator()
    var configuration = try fixture.request().configuration
    configuration.kind = .distribution
    configuration.bootstrap = try fixture.bootstrapPayload()
    let staged = try await generator.stageForDistribution(
        WrapperGenerationRequest(
            configuration: configuration,
            destination: .directory(fixture.staging),
            replace: .never),
        stagingDirectory: fixture.staging,
        fileName: "Game")
    let plistURL = staged.appendingPathComponent("Contents/Info.plist")
    let plist =
        try PropertyListSerialization.propertyList(
            from: Data(contentsOf: plistURL), format: nil) as? [String: Any]
    #expect(plist?["APKRunWrapperKind"] as? String == "distribution")
    // §11 step 1: staging only — nothing is registered.
    let entries = await fixture.registry.entries()
    #expect(entries.isEmpty)
}

@Test func stageForDistributionRejectsOtherKinds() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanup() }
    let generator = fixture.generator()
    do {
        _ = try await generator.stageForDistribution(
            fixture.request(),
            stagingDirectory: fixture.staging,
            fileName: "Game")
        Issue.record("expected a WrapperFailure")
    } catch is WrapperFailure {
    }
}
