import APKStoreCore
import Foundation

// The validation pipeline of update-system.md §6: V0 runs inside
// PackageStore.inspect; V1–V6 run here in table order, the first refusal
// stops the pipeline, and every check the pipeline did not reach is
// reported "not run".

/// One check of a validation report.
public struct ValidationCheck: Codable, Sendable, Equatable {
    /// The check identifier (`V0`…`V6`, update-system.md §6).
    public var id: String
    /// What the check verified, in plain text.
    public var title: String
    /// The values the check compared, for the "Details" view.
    public var inputs: [String: String]
    /// `passed`, `refused`, or `not run`.
    public var verdict: String
    /// The refusal detail when `verdict == "refused"`.
    public var detail: String?

    /// Creates a check line.
    public init(
        id: String,
        title: String,
        inputs: [String: String] = [:],
        verdict: String,
        detail: String? = nil
    ) {
        self.id = id
        self.title = title
        self.inputs = inputs
        self.verdict = verdict
        self.detail = detail
    }
}

/// The report saved as `staged/validation.json` (§6): one line per check,
/// including the ones the pipeline did not reach, plus non-blocking
/// observations (§6 notes).
public struct ValidationReport: Codable, Sendable, Equatable {
    /// Every check, in order, ending at the first refusal; the rest are
    /// `not run`.
    public var checks: [ValidationCheck]
    /// `accepted` or `refused`.
    public var outcome: String
    /// Non-blocking observations: new permissions, target-SDK change, a size
    /// change above 50 %, an accepted rotation (§6).
    public var notes: [String]

    /// Creates a report.
    public init(checks: [ValidationCheck], outcome: String, notes: [String] = []) {
        self.checks = checks
        self.outcome = outcome
        self.notes = notes
    }
}

/// A validation refusal: the `UpdateFailure` the run reports plus the report
/// of the checks that ran before the refusal.
public struct ValidationRefusal: Error, Sendable {
    /// The failure the history records (`update.validation`).
    public var failure: UpdateFailure
    /// The report ending at the refused check.
    public var report: ValidationReport
    /// The check that refused (`V1`…`V6`); V3 and V5 refusals post the
    /// "Update refused" notification (§9).
    public var checkID: String
}

/// Runs V1–V6 of update-system.md §6 for a verified download ticket.
public struct UpdateValidator: Sendable {
    /// Creates a validator.
    public init() {}

    /// Validates `preview` — the artifact set `PackageStore.inspect(ticket:)`
    /// produced — against the installed record and the provider's candidate.
    /// The first refusal throws `ValidationRefusal` carrying the failure and
    /// the report; a clean run returns the accepted report.
    ///
    /// - `installedSet`: the installed `current/artifact.json`, supplying the
    ///   installed lineage, permission list, and target SDK.
    /// - `skippedVersions`: the package's `skippedVersions` (§8.4) for V6.
    /// - `explicitSelection`: true when the user picked this version itself,
    ///   which lifts the V6 refusal.
    public func validate(
        preview: PackageImportPreview,
        installed record: PackageRecord,
        candidate: UpdateCandidate,
        installedSet: ArtifactSet? = nil,
        skippedVersions: [VersionCode] = [],
        explicitSelection: Bool = false
    ) throws(ValidationRefusal) -> ValidationReport {
        var checks: [ValidationCheck] = [
            ValidationCheck(
                id: "V0",
                title: "intrinsic checks I1–I12",
                verdict: "passed")
        ]
        var notes: [String] = []

        // Every check the pipeline did not reach is reported "not run".
        func finish(_ outcome: String) -> ValidationReport {
            let titles: [(String, String)] = [
                ("V1", "package ID equals installed package"),
                ("V2", "versionCode increases"),
                ("V3", "signer continuity"),
                ("V4", "provider hash matches"),
                ("V5", "provider metadata agrees with APK"),
                ("V6", "not skipped"),
            ]
            for (id, title) in titles where !checks.contains(where: { $0.id == id }) {
                checks.append(
                    ValidationCheck(id: id, title: title, verdict: "not run"))
            }
            return ValidationReport(checks: checks, outcome: outcome, notes: notes)
        }

        func refuse(
            _ check: ValidationCheck, _ failure: UpdateFailure
        ) throws(ValidationRefusal) -> Never {
            checks.append(check)
            throw ValidationRefusal(
                failure: failure,
                report: finish("refused"),
                checkID: check.id)
        }

        // V1 — the package ID must equal the installed package's.
        let v1Inputs = [
            "installed": record.packageId.rawValue,
            "candidate": preview.packageID.rawValue,
        ]
        guard preview.packageID == record.packageId else {
            try refuse(
                ValidationCheck(
                    id: "V1",
                    title: "package ID equals installed package",
                    inputs: v1Inputs,
                    verdict: "refused",
                    detail:
                        "packageMismatch(expected:\(record.packageId.rawValue),found:\(preview.packageID.rawValue))"),
                .validation(
                    detail:
                        "packageMismatch(expected: \(record.packageId.rawValue), found: \(preview.packageID.rawValue))")
            )
        }
        checks.append(
            ValidationCheck(
                id: "V1", title: "package ID equals installed package",
                inputs: v1Inputs, verdict: "passed"))

        // V2 — the candidate versionCode must increase (FR-UPD-05).
        let v2Inputs = [
            "installed": "\(record.versionCode)",
            "candidate": "\(preview.versionCode)",
        ]
        if preview.versionCode == record.versionCode {
            try refuse(
                ValidationCheck(
                    id: "V2", title: "versionCode increases",
                    inputs: v2Inputs,
                    verdict: "refused",
                    detail: "notNewer(\(preview.versionCode))"),
                .validation(detail: "notNewer(\(preview.versionCode))"))
        }
        if preview.versionCode < record.versionCode {
            try refuse(
                ValidationCheck(
                    id: "V2", title: "versionCode increases",
                    inputs: v2Inputs,
                    verdict: "refused",
                    detail:
                        "downgrade(installed:\(record.versionCode),candidate:\(preview.versionCode))"),
                .validation(
                    detail:
                        "downgrade(installed: \(record.versionCode), candidate: \(preview.versionCode))"))
        }
        checks.append(
            ValidationCheck(
                id: "V2", title: "versionCode increases",
                inputs: v2Inputs, verdict: "passed"))

        // V3 — signer continuity (§6): equal sets; else a single-signer
        // rotation when the candidate lineage grants the installed signer
        // INSTALLED_DATA; else an undone rotation when the installed lineage
        // grants the candidate signer ROLLBACK. Multi-signer sets must be
        // equal. When the host verifier only reached `.certificateOnly`, the
        // lineage is not trustworthy and digests are all V3 compares.
        let installedSigners = Set(record.signingCertificates)
        let candidateSigners = Set(preview.artifactSet.signerDigests)
        let certificateOnly = preview.warnings.contains(.certificateOnlyVerification)
        let v3Inputs = [
            "installed": record.signingCertificates.map(\.rawValue).sorted()
                .joined(separator: ","),
            "candidate": preview.artifactSet.signerDigests.map(\.rawValue).sorted()
                .joined(separator: ","),
            "certificateOnly": "\(certificateOnly)",
        ]
        if candidateSigners != installedSigners {
            var accepted = false
            var missingCapability = false
            if !certificateOnly,
                installedSigners.count == 1, candidateSigners.count == 1,
                let installedSigner = installedSigners.first,
                let candidateSigner = candidateSigners.first
            {
                // Rule 2: a rotation the installed signer consented to. The
                // consent is only real when the lineage's newest node is the
                // candidate signer — the strict verifier already requires
                // this, but a preview that reaches V3 through another path
                // must not extend consent past the lineage's end.
                let lineageNodes = preview.artifactSet.lineageNodes
                let rotation =
                    lineageNodes
                    .first(where: { $0.certificateDigest == installedSigner })
                if let rotation,
                    lineageNodes.last?.certificateDigest == candidateSigner,
                    rotation.capabilities.contains(.installedData)
                {
                    accepted = true
                    notes.append(
                        "signer rotation accepted: installed signer granted installedData")
                } else if rotation != nil,
                    lineageNodes.last?.certificateDigest == candidateSigner
                {
                    missingCapability = true
                }
                // Rule 3: the installed package's own lineage lets the
                // candidate's signer take the package back (a rotation being
                // undone). It is tried whether or not rule 2's node existed —
                // a plain candidate carries no lineage at all.
                if !accepted,
                    let undo = installedSet?.lineageNodes
                        .first(where: { $0.certificateDigest == candidateSigner })
                {
                    if undo.capabilities.contains(.rollback) {
                        accepted = true
                        notes.append(
                            "signer rotation undone: installed lineage granted rollback")
                    } else {
                        missingCapability = true
                    }
                }
            }
            if !accepted {
                let detail =
                    missingCapability
                    ? "lineageMissingCapability"
                    : "signerMismatch(installed:\(installedSigners.count),candidate:\(candidateSigners.count))"
                try refuse(
                    ValidationCheck(
                        id: "V3", title: "signer continuity",
                        inputs: v3Inputs,
                        verdict: "refused",
                        detail: detail),
                    .validation(detail: detail))
            }
        }
        checks.append(
            ValidationCheck(
                id: "V3", title: "signer continuity",
                inputs: v3Inputs, verdict: "passed"))

        // V4 — each file's SHA-256 equals the provider-declared digest. The
        // raw download names are gone after inspect; `sourceFileNames` maps
        // the stored files back to the declared artifacts. Container
        // artifacts with no per-file counterpart were verified while
        // streaming and are skipped here.
        var v4Checked: [String] = []
        var v4Refusal: (file: String, declared: String, actual: String)?
        // `sourceFileNames` enumerates the downloads; `files` enumerates the
        // stored artifacts. Their indexes do not correspond: a container
        // source expands into several stored files, and the stored files are
        // re-sorted. Match a declared artifact to its staged content by
        // stored name, then by content digest, and skip only the declared
        // archives whose own bytes were hashed while downloading.
        let stagedByName = Dictionary(
            preview.artifactSet.files.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first })
        let stagedDigests = Set(preview.artifactSet.files.map(\.sha256))
        let containerExtensions: Set<String> = ["apks", "xapk", "apkm", "zip"]
        let expanded =
            preview.artifactSet.files.count != preview.sourceFileNames.count
        for (index, declared) in candidate.artifacts.enumerated() {
            guard let declaredDigest = declared.sha256 else { continue }
            let declaredName = declared.url.lastPathComponent
            let storedName = declared.storedFileName(
                index: index, in: candidate.artifacts)
            if let file = stagedByName[storedName] ?? stagedByName[declaredName] {
                v4Checked.append(file.name)
                if file.sha256 != declaredDigest {
                    v4Refusal = (file.name, declaredDigest.rawValue, file.sha256.rawValue)
                    break
                }
            } else if stagedDigests.contains(declaredDigest) {
                // Staged under a derived name (a source "app.apk" lands as
                // "base.apk"); the content is what the provider declared.
                v4Checked.append(declaredName)
            } else if expanded,
                preview.sourceFileNames.contains(declaredName)
            {
                // The archive was verified while streaming; its members are
                // the staged files, not the archive itself.
                continue
            } else if containerExtensions.contains(
                declared.url.pathExtension.lowercased())
            {
                // A one-member container keeps the counts equal, so `expanded`
                // misses it; its declared digest still belongs to the archive.
                continue
            } else {
                // A plain source must land in the staged set byte-for-byte.
                v4Refusal = (declaredName, declaredDigest.rawValue, "not in the staged set")
                break
            }
        }
        if let v4Refusal {
            let detail =
                "providerHashMismatch(file:\(v4Refusal.file),expected:\(v4Refusal.declared),found:\(v4Refusal.actual))"
            try refuse(
                ValidationCheck(
                    id: "V4", title: "provider hash matches",
                    inputs: [
                        "files": v4Checked.joined(separator: ","),
                        "mismatch": v4Refusal.file,
                    ],
                    verdict: "refused",
                    detail: detail),
                .validation(detail: detail))
        }
        checks.append(
            ValidationCheck(
                id: "V4", title: "provider hash matches",
                inputs: ["files": v4Checked.joined(separator: ",")],
                verdict: "passed"))

        // V5 — provider metadata agrees with the APK (FR-UPD-14): package,
        // versionCode, and signer where the provider declared them.
        var v5Inputs: [String: String] = [:]
        var v5Field: String?
        v5Inputs["package"] =
            "\(candidate.packageID.rawValue)→\(preview.packageID.rawValue)"
        if candidate.packageID != preview.packageID {
            v5Field = "package"
        }
        if v5Field == nil, let declared = candidate.declaredVersionCode {
            v5Inputs["versionCode"] = "\(declared)→\(preview.versionCode)"
            if declared != preview.versionCode {
                v5Field = "versionCode"
            }
        }
        if v5Field == nil, let declared = candidate.declaredSignerDigests {
            v5Inputs["signer"] =
                "\(declared.count)→\(preview.artifactSet.signerDigests.count) digests"
            if Set(declared) != Set(preview.artifactSet.signerDigests) {
                v5Field = "signer"
            }
        }
        if let v5Field {
            let detail = "providerMetadataMismatch(\(v5Field))"
            try refuse(
                ValidationCheck(
                    id: "V5", title: "provider metadata agrees with APK",
                    inputs: v5Inputs,
                    verdict: "refused",
                    detail: detail),
                .validation(detail: detail))
        }
        checks.append(
            ValidationCheck(
                id: "V5", title: "provider metadata agrees with APK",
                inputs: v5Inputs, verdict: "passed"))

        // V6 — the version is not in the package's skip list, unless the user
        // selected it explicitly (§8.4).
        let v6Inputs = [
            "versionCode": "\(preview.versionCode)",
            "skippedVersions": skippedVersions.map(String.init).joined(separator: ","),
            "explicitSelection": "\(explicitSelection)",
        ]
        if !explicitSelection, skippedVersions.contains(preview.versionCode) {
            try refuse(
                ValidationCheck(
                    id: "V6", title: "not skipped",
                    inputs: v6Inputs,
                    verdict: "refused",
                    detail: "skippedVersion(\(preview.versionCode))"),
                .validation(detail: "skippedVersion(\(preview.versionCode))"))
        }
        checks.append(
            ValidationCheck(
                id: "V6", title: "not skipped",
                inputs: v6Inputs, verdict: "passed"))

        // Non-blocking notes (§6): newly requested permissions, a target-SDK
        // change, and a size change above 50 %.
        let newPermissions = Set(preview.artifactSet.permissions)
            .subtracting(installedSet?.permissions ?? [])
        if !newPermissions.isEmpty {
            notes.append(
                "new permissions: \(newPermissions.sorted().joined(separator: ", "))")
        }
        let installedTarget: Int? = installedSet?.targetSdk ?? record.android.targetSdk
        if let candidateTarget = preview.artifactSet.targetSdk,
            let installedTarget, candidateTarget != installedTarget
        {
            notes.append("targetSdk change \(installedTarget) → \(candidateTarget)")
        }
        let installedSize = record.artifacts.current?.size ?? 0
        let stagedSize = preview.artifactSet.files.reduce(Int64(0)) { $0 + $1.size }
        if installedSize > 0 {
            let delta = Double(stagedSize - installedSize) / Double(installedSize)
            if abs(delta) > 0.5 {
                notes.append(
                    "size change \(delta > 0 ? "+" : "")\(Int(delta * 100))% of installed set")
            }
        }

        return finish("accepted")
    }
}
