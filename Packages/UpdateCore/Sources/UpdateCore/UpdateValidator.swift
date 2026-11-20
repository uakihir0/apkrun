import APKStoreCore
import Foundation

// The validation pipeline of update-system.md §6. In #39 the checks are
// V0 (intrinsic, inside PackageStore.inspect) plus V1 package identity,
// V2 version ordering, and V3 signer-set equality; lineage rotations are
// #42, and V4–V6 arrive with the providers that need them.

/// One check of a validation report.
public struct ValidationCheck: Codable, Sendable, Equatable {
    /// The check identifier (`V0`…`V6`, update-system.md §6).
    public var id: String
    /// What the check verified, in plain text.
    public var title: String
    /// `passed` or `refused`.
    public var verdict: String
    /// The refusal detail when `verdict == "refused"`.
    public var detail: String?

    /// Creates a check line.
    public init(id: String, title: String, verdict: String, detail: String? = nil) {
        self.id = id
        self.title = title
        self.verdict = verdict
        self.detail = detail
    }
}

/// The report saved as `staged/validation.json` (§6): one line per check that
/// ran, plus non-blocking observations (§6 notes).
public struct ValidationReport: Codable, Sendable, Equatable {
    /// Every check that ran, in order, ending at the first refusal.
    public var checks: [ValidationCheck]
    /// `accepted` or `refused`.
    public var outcome: String
    /// Non-blocking observations: new permissions, target-SDK change, a size
    /// change above 50 % (§6).
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
}

/// Runs V1–V3 of update-system.md §6 for a verified download ticket.
public struct UpdateValidator: Sendable {
    /// Creates a validator.
    public init() {}

    /// Validates `preview` — the artifact set `PackageStore.inspect(ticket:)`
    /// produced — against the installed record and the provider's candidate.
    /// The first refusal throws `ValidationRefusal` carrying the failure and
    /// the partial report; a clean run returns the accepted report.
    public func validate(
        preview: PackageImportPreview,
        installed record: PackageRecord,
        candidate _: UpdateCandidate
    ) throws(ValidationRefusal) -> ValidationReport {
        var checks: [ValidationCheck] = [
            ValidationCheck(
                id: "V0",
                title: "intrinsic checks I1–I12",
                verdict: "passed")
        ]
        var notes: [String] = []

        func refuse(
            _ check: ValidationCheck, _ failure: UpdateFailure
        ) throws(ValidationRefusal) -> Never {
            checks.append(check)
            throw ValidationRefusal(
                failure: failure,
                report: ValidationReport(
                    checks: checks, outcome: "refused", notes: notes))
        }

        // V1 — the package ID must equal the installed package's.
        guard preview.packageID == record.packageId else {
            try refuse(
                ValidationCheck(
                    id: "V1",
                    title: "package ID equals installed package",
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
                verdict: "passed"))

        // V2 — the candidate versionCode must increase (FR-UPD-05).
        if preview.versionCode == record.versionCode {
            try refuse(
                ValidationCheck(
                    id: "V2", title: "versionCode increases",
                    verdict: "refused",
                    detail: "notNewer(\(preview.versionCode))"),
                .validation(detail: "notNewer(\(preview.versionCode))"))
        }
        if preview.versionCode < record.versionCode {
            try refuse(
                ValidationCheck(
                    id: "V2", title: "versionCode increases",
                    verdict: "refused",
                    detail:
                        "downgrade(installed:\(record.versionCode),candidate:\(preview.versionCode))"),
                .validation(
                    detail:
                        "downgrade(installed: \(record.versionCode), candidate: \(preview.versionCode))"))
        }
        checks.append(
            ValidationCheck(id: "V2", title: "versionCode increases", verdict: "passed"))

        // V3 — signer continuity. In #39 the sets must be equal; lineage
        // rotations arrive in #42 (§6 V3 steps 2–4).
        let installedSigners = Set(record.signingCertificates)
        let candidateSigners = Set(preview.artifactSet.signerDigests)
        guard candidateSigners == installedSigners else {
            try refuse(
                ValidationCheck(
                    id: "V3", title: "signer continuity",
                    verdict: "refused",
                    detail:
                        "signerMismatch(installed:\(installedSigners.count),candidate:\(candidateSigners.count))"),
                .validation(detail: "signerMismatch"))
        }
        checks.append(
            ValidationCheck(id: "V3", title: "signer continuity", verdict: "passed"))

        // Non-blocking notes (§6): a size change above 50 %.
        let installedSize = record.artifacts.current?.size ?? 0
        let stagedSize = preview.artifactSet.files.reduce(Int64(0)) { $0 + $1.size }
        if installedSize > 0 {
            let delta = Double(stagedSize - installedSize) / Double(installedSize)
            if abs(delta) > 0.5 {
                notes.append(
                    "size change \(delta > 0 ? "+" : "")\(Int(delta * 100))% of installed set")
            }
        }

        return ValidationReport(checks: checks, outcome: "accepted", notes: notes)
    }
}
