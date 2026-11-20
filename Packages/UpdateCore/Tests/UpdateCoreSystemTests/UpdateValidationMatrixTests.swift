import APKStoreCore
import Foundation
import Testing

@testable import UpdateCore

// T0/T1 for #42: the §4.3 HelloUpdate derived set against scripted installed
// state, covering every ValidationFailure, the rotation rules of
// update-system.md §6 V3, "not run" entries, and the refused notification.
// The store runs the real strict verifier over the committed fixtures; the
// inspector is scripted so one fixture can stand in for several versionCodes.

private let apksDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // UpdateCoreSystemTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // UpdateCore
    .deletingLastPathComponent()  // Packages
    .deletingLastPathComponent()  // repo root
    .appendingPathComponent("Tests/Fixtures/apks")

private func fixtureAPK(_ name: String) -> URL {
    apksDirectory.appendingPathComponent("HelloUpdate-\(name).apk")
}

private final class MatrixKnobs: @unchecked Sendable {
    /// The versionCode the scripted inspector reports.
    var versionCode: VersionCode = 1
    /// The packageID the scripted inspector reports.
    var packageID = helloUpdateID
}

private actor MatrixChannel: StoreAgentChannel {
    nonisolated let capabilities: StoreCapabilities = [.install, .metadata]
    private var packages: [PackageID: StorePackageInfo] = [:]

    func install(_ request: StoreInstallRequest, files _: [URL]) async throws -> StorePackageInfo {
        let info = StorePackageInfo(
            packageID: request.packageID,
            displayName: "HelloUpdate",
            versionCode: request.versionCode,
            enabled: true,
            targetSDK: 37,
            minSDK: 29,
            signingDigests: request.signerDigests)
        packages[request.packageID] = info
        return info
    }

    func uninstall(_ package: PackageID, keepData _: Bool) async throws {
        packages[package] = nil
    }

    func packageInfo(_ package: PackageID) async throws -> StorePackageInfo? {
        packages[package]
    }

    func listPackages(_: StorePackageFilter) async throws -> [StorePackageSummary] {
        []
    }
}

private struct MatrixRuntime: StoreRuntimeAccess {
    let channel: MatrixChannel

    func withStoreAgent<T: Sendable>(
        _: UUID,
        _ body: @Sendable (any StoreAgentChannel) async throws -> T
    ) async throws -> T {
        try await body(channel)
    }

    func userdataGeneration() async -> UUID? { nil }
}

private func makeMatrixStore(at root: URL, knobs: MatrixKnobs) -> PackageStore {
    PackageStore(
        packagesDirectory: root.appendingPathComponent("Packages", isDirectory: true),
        runtimeAccess: MatrixRuntime(channel: MatrixChannel()),
        inspector: { _ in
            APKFacts(
                packageID: knobs.packageID,
                versionCode: knobs.versionCode,
                versionName: "\(knobs.versionCode).0",
                splitName: nil,
                displayName: "HelloUpdate",
                minSDK: 29,
                targetSDK: 37,
                nativeABIs: ["arm64-v8a"])
        })
}

private func makeMatrixCoordinator(
    store: PackageStore, root: URL,
    notifier: (any HostNotificationSink)? = nil
) -> UpdateCoordinator {
    UpdateCoordinator(
        store: store,
        stateStore: UpdateStateStore(directory: root.appendingPathComponent("Updates")),
        notifier: notifier,
        developerModeEnabled: { true },
        downloadRetrySleep: { _ in },
        providerFactory: { ref in ScriptedProvider(ref: ref, steps: []) })
}

private func matrixCandidate(
    record: PackageRecord,
    declaredVersionCode: VersionCode? = 2,
    declaredSignerDigests: [SHA256Digest]? = nil,
    declaredSHA256: SHA256Digest? = nil
) throws -> UpdateCandidate {
    let repo = fixtureRepo()
    let bookmark = try repo.bookmarkData(
        options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    return UpdateCandidate(
        packageID: record.packageId,
        provider: UpdateProviderRef(
            type: .local,
            configuration: .local(
                path: repo.path, bookmark: bookmark.base64EncodedString())),
        declaredVersionCode: declaredVersionCode,
        declaredSignerDigests: declaredSignerDigests,
        artifacts: [
            RemoteArtifact(
                url: repo.appendingPathComponent(
                    "io.apkrun.fixture.helloupdate/2/app.apk"),
                kind: .apk,
                sha256: declaredSHA256)
        ],
        cursor: ProviderCursor(type: .local, value: "2"))
}

/// Installs `installedAPK` as `installedVersionCode`, then runs `validate` on
/// a download ticket holding `candidateAPK` at `candidateVersionCode`.
private func installThenValidate(
    at root: URL,
    installedAPK: String,
    installedVersionCode: VersionCode,
    candidateAPK: String,
    candidateVersionCode: VersionCode,
    candidate: UpdateCandidate? = nil,
    explicitSelection: Bool = false,
    notifier: (any HostNotificationSink)? = nil
) async throws -> (UpdateCoordinator, PackageRecord, UpdateCoordinator.UpdateValidationOutcome) {
    let knobs = MatrixKnobs()
    let store = makeMatrixStore(at: root, knobs: knobs)
    try await store.open()
    knobs.versionCode = installedVersionCode
    let preview = try await store.importPackage(files: [fixtureAPK(installedAPK)])
    let record = try await store.installImported(ticket: preview.ticket)

    let coordinator = makeMatrixCoordinator(store: store, root: root, notifier: notifier)
    knobs.versionCode = candidateVersionCode
    let ticket = try await store.beginDownloadTicket(for: record.packageId)
    try FileManager.default.copyItem(
        at: fixtureAPK(candidateAPK),
        to: ticket.directory.appendingPathComponent("app.apk"))
    let outcome = await coordinator.validate(
        record.packageId, ticket: ticket.ticket,
        candidate: try candidate ?? matrixCandidate(record: record),
        trigger: .userInitiated,
        explicitSelection: explicitSelection)
    return (coordinator, record, outcome)
}

@Test func v1ToV2AcceptedWithFullReport() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, _, outcome) = try await installThenValidate(
        at: root, installedAPK: "v1", installedVersionCode: 1,
        candidateAPK: "v2", candidateVersionCode: 2)
    guard case .validated(let validated) = outcome else {
        Issue.record("expected .validated, got \(outcome)")
        return
    }
    #expect(validated.report.outcome == "accepted")
    #expect(validated.report.checks.map { $0.id } == ["V0", "V1", "V2", "V3", "V4", "V5", "V6"])
    #expect(validated.report.checks.allSatisfy { $0.verdict == "passed" })
}

@Test func otherSignerRefusedAndNotified() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let notifier = RecordingNotifier()
    let (_, record, outcome) = try await installThenValidate(
        at: root, installedAPK: "v1", installedVersionCode: 1,
        candidateAPK: "v2-other-signer", candidateVersionCode: 2,
        notifier: notifier)
    guard case .failed(let failure) = outcome else {
        Issue.record("expected .failed, got \(outcome)")
        return
    }
    #expect(failure == .validation(detail: "signerMismatch(installed:1,candidate:1)"))
    #expect(await notifier.refusedSent.count == 1)
    #expect(await notifier.refusedSent.first?.packageID == record.packageId)
}

@Test func rotationWithInstalledDataAccepted() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, _, outcome) = try await installThenValidate(
        at: root, installedAPK: "v1", installedVersionCode: 1,
        candidateAPK: "v2-rotate-installed-data", candidateVersionCode: 2)
    guard case .validated(let validated) = outcome else {
        Issue.record("expected .validated, got \(outcome)")
        return
    }
    #expect(validated.report.checks.first(where: { $0.id == "V3" })?.verdict == "passed")
    #expect(validated.report.notes.contains { $0.contains("rotation accepted") })
}

@Test func rotationWithoutInstalledDataRefused() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let notifier = RecordingNotifier()
    let (_, _, outcome) = try await installThenValidate(
        at: root, installedAPK: "v1", installedVersionCode: 1,
        candidateAPK: "v2-rotate-no-installed-data", candidateVersionCode: 2,
        notifier: notifier)
    guard case .failed(let failure) = outcome else {
        Issue.record("expected .failed, got \(outcome)")
        return
    }
    #expect(failure == .validation(detail: "lineageMissingCapability"))
    #expect(await notifier.refusedSent.count == 1)
}

@Test func rotationBackWithRollbackAccepted() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Installed set: B-signed V2 with lineage A→B granting A rollback. The
    // candidate is plain V2 signed by A — an undone rotation (§6 V3 rule 3).
    let (_, _, outcome) = try await installThenValidate(
        at: root, installedAPK: "v2-rotate-rollback", installedVersionCode: 1,
        candidateAPK: "v2", candidateVersionCode: 2)
    guard case .validated(let validated) = outcome else {
        Issue.record("expected .validated, got \(outcome)")
        return
    }
    #expect(validated.report.notes.contains { $0.contains("undone") })
}

@Test func rotationBackWithoutRollbackRefused() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Installed set: B-signed V2 whose lineage grants A installedData only.
    // Returning to plain key A needs ROLLBACK — refused.
    let (_, _, outcome) = try await installThenValidate(
        at: root, installedAPK: "v2-rotate-installed-data", installedVersionCode: 1,
        candidateAPK: "v2", candidateVersionCode: 2)
    guard case .failed(let failure) = outcome else {
        Issue.record("expected .failed, got \(outcome)")
        return
    }
    #expect(failure == .validation(detail: "lineageMissingCapability"))
}

@Test func rotationBackViaCandidateLineageAccepted() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // The candidate itself carries the B→A lineage granting B installedData —
    // an ordinary rotation back (§6 V3 rule 2).
    let (_, _, outcome) = try await installThenValidate(
        at: root, installedAPK: "v2-rotate-installed-data", installedVersionCode: 1,
        candidateAPK: "v2-rotate-back", candidateVersionCode: 2)
    guard case .validated = outcome else {
        Issue.record("expected .validated, got \(outcome)")
        return
    }
}

@Test func corruptedAPKRefusedByV0() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, _, outcome) = try await installThenValidate(
        at: root, installedAPK: "v1", installedVersionCode: 1,
        candidateAPK: "v2-corrupted", candidateVersionCode: 2)
    guard case .failed(let failure) = outcome else {
        Issue.record("expected .failed, got \(outcome)")
        return
    }
    guard case .validation(let detail) = failure else {
        Issue.record("expected .validation, got \(failure)")
        return
    }
    #expect(detail.hasPrefix("intrinsic("))
    #expect(detail.contains("invalidSignature"))
}

@Test func downgradeRefused() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, _, outcome) = try await installThenValidate(
        at: root, installedAPK: "v2", installedVersionCode: 2,
        candidateAPK: "v1", candidateVersionCode: 1)
    guard case .failed(let failure) = outcome else {
        Issue.record("expected .failed, got \(outcome)")
        return
    }
    #expect(failure == .validation(detail: "downgrade(installed: 2, candidate: 1)"))
}

@Test func providerHashMismatchRefused() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let knobs = MatrixKnobs()
    let store = makeMatrixStore(at: root, knobs: knobs)
    try await store.open()
    knobs.versionCode = 1
    let preview = try await store.importPackage(files: [fixtureAPK("v1")])
    let record = try await store.installImported(ticket: preview.ticket)
    let coordinator = makeMatrixCoordinator(store: store, root: root)
    knobs.versionCode = 2
    let ticket = try await store.beginDownloadTicket(for: record.packageId)
    try FileManager.default.copyItem(
        at: fixtureAPK("v2"), to: ticket.directory.appendingPathComponent("app.apk"))
    let wrong = SHA256Digest(data: Data("not the apk".utf8))
    let outcome = await coordinator.validate(
        record.packageId, ticket: ticket.ticket,
        candidate: try matrixCandidate(record: record, declaredSHA256: wrong),
        trigger: .userInitiated)
    guard case .failed(let failure) = outcome else {
        Issue.record("expected .failed, got \(outcome)")
        return
    }
    guard case .validation(let detail) = failure else {
        Issue.record("expected .validation, got \(failure)")
        return
    }
    #expect(detail.hasPrefix("providerHashMismatch(file:"))
}

@Test func providerMetadataMismatchRefusedAndNotified() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let notifier = RecordingNotifier()
    let knobs = MatrixKnobs()
    let store = makeMatrixStore(at: root, knobs: knobs)
    try await store.open()
    knobs.versionCode = 1
    let preview = try await store.importPackage(files: [fixtureAPK("v1")])
    let record = try await store.installImported(ticket: preview.ticket)

    let coordinator = makeMatrixCoordinator(store: store, root: root, notifier: notifier)
    knobs.versionCode = 2
    let ticket = try await store.beginDownloadTicket(for: record.packageId)
    try FileManager.default.copyItem(
        at: fixtureAPK("v2"), to: ticket.directory.appendingPathComponent("app.apk"))
    // The provider declares versionCode 3 while the APK is versionCode 2.
    let outcome = await coordinator.validate(
        record.packageId, ticket: ticket.ticket,
        candidate: try matrixCandidate(record: record, declaredVersionCode: 3),
        trigger: .userInitiated)
    guard case .failed(let failure) = outcome else {
        Issue.record("expected .failed, got \(outcome)")
        return
    }
    #expect(failure == .validation(detail: "providerMetadataMismatch(versionCode)"))
    #expect(await notifier.refusedSent.count == 1)
}

@Test func skippedVersionRefusedUnlessExplicit() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let knobs = MatrixKnobs()
    let store = makeMatrixStore(at: root, knobs: knobs)
    try await store.open()
    knobs.versionCode = 1
    let preview = try await store.importPackage(files: [fixtureAPK("v1")])
    let record = try await store.installImported(ticket: preview.ticket)

    let stateStore = UpdateStateStore(directory: root.appendingPathComponent("Updates"))
    await stateStore.update(record.packageId) { $0.skippedVersions = [2] }
    let coordinator = UpdateCoordinator(
        store: store,
        stateStore: stateStore,
        developerModeEnabled: { true },
        downloadRetrySleep: { _ in },
        providerFactory: { ref in ScriptedProvider(ref: ref, steps: []) })
    knobs.versionCode = 2
    let ticket = try await store.beginDownloadTicket(for: record.packageId)
    try FileManager.default.copyItem(
        at: fixtureAPK("v2"), to: ticket.directory.appendingPathComponent("app.apk"))

    let refused = await coordinator.validate(
        record.packageId, ticket: ticket.ticket,
        candidate: try matrixCandidate(record: record),
        trigger: .userInitiated)
    guard case .failed(let failure) = refused else {
        Issue.record("expected .failed, got \(refused)")
        return
    }
    #expect(failure == .validation(detail: "skippedVersion(2)"))

    // The same version passes when the user picked it explicitly.
    let ticket2 = try await store.beginDownloadTicket(for: record.packageId)
    try FileManager.default.copyItem(
        at: fixtureAPK("v2"), to: ticket2.directory.appendingPathComponent("app.apk"))
    let accepted = await coordinator.validate(
        record.packageId, ticket: ticket2.ticket,
        candidate: try matrixCandidate(record: record),
        trigger: .userInitiated, explicitSelection: true)
    guard case .validated = accepted else {
        Issue.record("expected .validated, got \(accepted)")
        return
    }
}

@Test func packageMismatchRefusesWithNotRunEntries() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let knobs = MatrixKnobs()
    let store = makeMatrixStore(at: root, knobs: knobs)
    try await store.open()
    knobs.versionCode = 1
    let preview = try await store.importPackage(files: [fixtureAPK("v1")])
    let record = try await store.installImported(ticket: preview.ticket)

    knobs.versionCode = 2
    let ticket = try await store.beginDownloadTicket(for: record.packageId)
    try FileManager.default.copyItem(
        at: fixtureAPK("v2"), to: ticket.directory.appendingPathComponent("app.apk"))
    let inspected = try await store.inspect(ticket: ticket.ticket)
    // A preview whose package ID disagrees with the record (the store's own
    // inspect() refuses this earlier; the validator still gets a fabricated one).
    let staged = PackageImportPreview(
        ticket: inspected.ticket,
        packageID: PackageID(rawValue: "io.apkrun.fixture.other")!,
        displayName: inspected.displayName,
        versionCode: inspected.versionCode,
        versionName: inspected.versionName,
        artifactSet: inspected.artifactSet,
        sourceFileNames: inspected.sourceFileNames,
        excludedSplits: inspected.excludedSplits,
        warnings: inspected.warnings,
        relation: inspected.relation)

    let candidate = try matrixCandidate(record: record)
    do {
        _ = try UpdateValidator().validate(
            preview: staged, installed: record, candidate: candidate)
        Issue.record("expected ValidationRefusal")
    } catch let refusal {
        #expect(refusal.checkID == "V1")
        #expect(
            refusal.report.checks.map(\.verdict)
                == ["passed", "refused", "not run", "not run", "not run", "not run", "not run"])
    }
    try await store.discardDownload(ticket: ticket.ticket)
}

@Test func validationReportSurvivesStoreReopen() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let knobs = MatrixKnobs()
    let store = makeMatrixStore(at: root, knobs: knobs)
    try await store.open()
    knobs.versionCode = 1
    let preview = try await store.importPackage(files: [fixtureAPK("v1")])
    let record = try await store.installImported(ticket: preview.ticket)

    let coordinator = makeMatrixCoordinator(store: store, root: root)
    knobs.versionCode = 2
    let ticket = try await store.beginDownloadTicket(for: record.packageId)
    try FileManager.default.copyItem(
        at: fixtureAPK("v2"), to: ticket.directory.appendingPathComponent("app.apk"))
    guard
        case .validated(let validated) = await coordinator.validate(
            record.packageId, ticket: ticket.ticket,
            candidate: try matrixCandidate(record: record),
            trigger: .userInitiated)
    else {
        Issue.record("expected .validated")
        return
    }
    try await store.stage(
        ticket: ticket.ticket,
        candidate: StagedUpdateInfo(
            versionCode: 2, versionName: "2.0",
            setDigest: validated.preview.artifactSet.setDigest,
            size: 0, fileCount: 1,
            origin: ArtifactOrigin(type: .local)))

    // T1: reopen the store and read staged/validation.json back.
    let reopened = makeMatrixStore(at: root, knobs: knobs)
    try await reopened.open()
    let reportURL = root.appendingPathComponent(
        "Packages/io.apkrun.fixture.helloupdate/staged/validation.json")
    let data = try Data(contentsOf: reportURL)
    let report = try JSONDecoder().decode(ValidationReport.self, from: data)
    #expect(report == validated.report)
}

// Hand-built signer sets for the §6 V3 primitives the fixtures can't express:
// multi-signer equality and the .certificateOnly fallback.

private func fakeDigest(_ byte: UInt8) -> SHA256Digest {
    SHA256Digest(data: Data(repeating: byte, count: 32))
}

/// Installs V1, then hands a mutated record/preview pair to the validator.
private func primitiveValidate(
    at root: URL,
    recordSigners: [SHA256Digest],
    previewSigners: [SHA256Digest],
    previewLineage: [SignerLineageNode] = [],
    previewFiles: [ArtifactFile]? = nil,
    sourceNames: [String]? = nil,
    warnings: [ImportWarning] = [],
    installedLineage: [SignerLineageNode] = [],
    declaredArtifacts: [RemoteArtifact]? = nil
) async throws -> ValidationReport {
    let knobs = MatrixKnobs()
    let store = makeMatrixStore(at: root, knobs: knobs)
    try await store.open()
    let preview = try await store.importPackage(files: [fixtureAPK("v1")])
    var record = try await store.installImported(ticket: preview.ticket)
    record.signingCertificates = recordSigners
    record.versionCode = 1

    knobs.versionCode = 2
    let ticket = try await store.beginDownloadTicket(for: record.packageId)
    try FileManager.default.copyItem(
        at: fixtureAPK("v2"), to: ticket.directory.appendingPathComponent("app.apk"))
    let inspected = try await store.inspect(ticket: ticket.ticket)
    var set = inspected.artifactSet
    set.signerDigests = previewSigners
    set.lineageNodes = previewLineage
    if let previewFiles { set.files = previewFiles }
    let mutated = PackageImportPreview(
        ticket: inspected.ticket,
        packageID: inspected.packageID,
        displayName: inspected.displayName,
        versionCode: inspected.versionCode,
        versionName: inspected.versionName,
        artifactSet: set,
        sourceFileNames: sourceNames ?? inspected.sourceFileNames,
        excludedSplits: inspected.excludedSplits,
        warnings: warnings,
        relation: inspected.relation)

    var installedSet = set
    installedSet.signerDigests = recordSigners
    installedSet.lineageNodes = installedLineage
    var candidate = try matrixCandidate(record: record)
    if let declaredArtifacts { candidate.artifacts = declaredArtifacts }
    return try UpdateValidator().validate(
        preview: mutated,
        installed: record,
        candidate: candidate,
        installedSet: installedSet)
}

@Test func multiSignerSetsMustMatchExactly() async throws {
    let a = fakeDigest(0xAA)
    let b = fakeDigest(0xBB)
    let c = fakeDigest(0xCC)

    let root1 = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root1) }
    let report = try await primitiveValidate(
        at: root1, recordSigners: [a, b], previewSigners: [a, b])
    #expect(report.outcome == "accepted")

    let root2 = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root2) }
    do {
        _ = try await primitiveValidate(
            at: root2, recordSigners: [a, b], previewSigners: [a, c])
        Issue.record("expected ValidationRefusal")
    } catch let refusal as ValidationRefusal {
        #expect(refusal.checkID == "V3")
        #expect(refusal.failure == .validation(detail: "signerMismatch(installed:2,candidate:2)"))
    }
}

@Test func certificateOnlyVerificationSkipsLineage() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = fakeDigest(0xAA)
    let b = fakeDigest(0xBB)
    // Even a lineage granting INSTALLED_DATA cannot help when the host verifier
    // only reached certificate level: digests are all V3 compares (§6).
    do {
        _ = try await primitiveValidate(
            at: root, recordSigners: [a], previewSigners: [b],
            previewLineage: [
                SignerLineageNode(
                    certificateDigest: a, capabilities: [.installedData])
            ],
            warnings: [.certificateOnlyVerification])
        Issue.record("expected ValidationRefusal")
    } catch let refusal as ValidationRefusal {
        #expect(refusal.checkID == "V3")
        #expect(refusal.failure == .validation(detail: "signerMismatch(installed:1,candidate:1)"))
    }
}

@Test func multiSignerSetRefusesEvenWithLineage() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = fakeDigest(0xAA)
    let b = fakeDigest(0xBB)
    do {
        _ = try await primitiveValidate(
            at: root, recordSigners: [a, b], previewSigners: [a],
            previewLineage: [
                SignerLineageNode(
                    certificateDigest: b, capabilities: [.installedData])
            ])
        Issue.record("expected ValidationRefusal")
    } catch let refusal as ValidationRefusal {
        #expect(refusal.checkID == "V3")
        #expect(refusal.failure == .validation(detail: "signerMismatch(installed:2,candidate:1)"))
    }
}

private func fakeArtifact(_ name: String, split: String?, _ byte: UInt8) -> ArtifactFile {
    ArtifactFile(
        name: name, splitName: split, size: 10, sha256: fakeDigest(byte))
}

@Test func forgedLineageTailDoesNotConsent() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = fakeDigest(0xAA), b = fakeDigest(0xBB)
    // The lineage grants the installed signer INSTALLED_DATA but ends at A:
    // a signer B carrying it did not earn the rotation (SEC finding on #144).
    do {
        _ = try await primitiveValidate(
            at: root, recordSigners: [a], previewSigners: [b],
            previewLineage: [
                SignerLineageNode(
                    certificateDigest: a, capabilities: [.installedData])
            ])
        Issue.record("expected ValidationRefusal")
    } catch let refusal as ValidationRefusal {
        #expect(refusal.checkID == "V3")
        #expect(
            refusal.failure
                == .validation(detail: "signerMismatch(installed:1,candidate:1)"))
    }
}

@Test func providerContainerHashDoesNotMatchMembers() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = fakeDigest(0xAA)
    // The provider declares the archive's own digest; the staged set holds
    // the expanded members, so V4 must not compare them against it.
    let report = try await primitiveValidate(
        at: root, recordSigners: [a], previewSigners: [a],
        previewFiles: [
            fakeArtifact("base.apk", split: nil, 0x01),
            fakeArtifact("split_config.ja.apk", split: "config.ja", 0x02),
            fakeArtifact("split_feature.apk", split: "feature", 0x03),
        ],
        sourceNames: ["HelloSplit.apks"],
        declaredArtifacts: [
            RemoteArtifact(
                url: URL(fileURLWithPath: "/repo/HelloSplit.apks"),
                kind: .apk, sha256: fakeDigest(0x99))
        ])
    #expect(report.outcome == "accepted")
}

@Test func providerHashMatchesStoredContentNotPositions() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = fakeDigest(0xAA)
    // Sources downloaded as "b.apk" then "a.apk"; the stored set is sorted,
    // so a positional compare would hash the wrong file.
    let report = try await primitiveValidate(
        at: root, recordSigners: [a], previewSigners: [a],
        previewFiles: [
            fakeArtifact("base.apk", split: nil, 0x01),
            fakeArtifact("split_config.arm64_v8a.apk", split: "config.arm64_v8a", 0x02),
        ],
        sourceNames: ["b.apk", "a.apk"],
        declaredArtifacts: [
            RemoteArtifact(
                url: URL(fileURLWithPath: "/repo/a.apk"),
                kind: .apk, sha256: fakeDigest(0x01)),
            RemoteArtifact(
                url: URL(fileURLWithPath: "/repo/b.apk"),
                kind: .apk, sha256: fakeDigest(0x02)),
        ])
    #expect(report.outcome == "accepted")
}

@Test func providerWrongHashOnPlainSourceRefused() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = fakeDigest(0xAA)
    do {
        _ = try await primitiveValidate(
            at: root, recordSigners: [a], previewSigners: [a],
            previewFiles: [fakeArtifact("base.apk", split: nil, 0x01)],
            sourceNames: ["a.apk"],
            declaredArtifacts: [
                RemoteArtifact(
                    url: URL(fileURLWithPath: "/repo/a.apk"),
                    kind: .apk, sha256: fakeDigest(0xEE))
            ])
        Issue.record("expected ValidationRefusal")
    } catch let refusal as ValidationRefusal {
        #expect(refusal.checkID == "V4")
    }
}
