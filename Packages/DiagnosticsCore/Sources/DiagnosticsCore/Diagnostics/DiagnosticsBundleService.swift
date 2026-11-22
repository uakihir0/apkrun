import Foundation

/// Runs the contributors, redacts, and writes a diagnostics bundle
/// (diagnostics.md §8.1). One instance serves one report so the redactor's
/// placeholders stay stable and its counts accumulate into the manifest.
public final class DiagnosticsBundleService: Sendable {
    /// The phase the collector is in, for the operation's progress stages.
    public enum Phase: String, Sendable {
        /// Contributors are writing their sections.
        case collecting
        /// The staged files are being redacted.
        case redacting
        /// The ZIP is being written.
        case writing
    }

    private let redactor: Redactor
    private let contributors: [DiagnosticsContributor]
    private let build: String

    /// Creates the service for one report.
    /// - Parameters:
    ///   - identity: the user/machine identity and secrets to redact.
    ///   - contributors: the section owners, run in order under their budgets.
    ///   - build: the producing build string for `manifest.json`.
    public init(
        identity: RedactionIdentity,
        contributors: [DiagnosticsContributor],
        build: String
    ) {
        self.redactor = Redactor(identity: identity)
        self.contributors = contributors
        self.build = build
    }

    /// The report's redactor (the caller adds the secrets it discovers while
    /// collecting before `write` runs).
    public var currentRedactor: Redactor { redactor }

    /// Runs every contributor under its budget, then writes the archive into
    /// `output`. A contributor that fails or overruns is recorded in
    /// `omitted`; the report still completes. `onPhase` fires as stages
    /// change; `isCancelled` abandons the run.
    ///
    /// `summaryContext` is called after collection so the summary can report
    /// the omissions it gathered.
    public func run(
        options: DiagnosticsOptions,
        to output: FileHandle,
        summaryContext: (DiagnosticsBundleBuilder) -> DiagnosticsSummaryContext,
        onPhase: (Phase) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) async throws -> DiagnosticsBundleResult {
        onPhase(.collecting)
        let builder = DiagnosticsBundleBuilder()
        for contributor in contributors {
            if isCancelled() { throw CancellationError() }
            await Self.run(contributor: contributor, into: builder, options: options)
        }

        onPhase(.redacting)
        let writer = DiagnosticsBundleWriter(
            redactor: redactor, options: options, build: build)
        onPhase(.writing)
        return try writer.write(
            bundle: builder,
            summaryContext: summaryContext(builder),
            to: output,
            isCancelled: isCancelled)
    }

    /// One contributor under its budget: `budgetExceeded` when the budget
    /// lapses first, the thrown error's name otherwise.
    private static func run(
        contributor: DiagnosticsContributor,
        into builder: DiagnosticsBundleBuilder,
        options: DiagnosticsOptions
    ) async {
        let nanoseconds = UInt64(
            contributor.budget.components.seconds * 1_000_000_000
                + contributor.budget.components.attoseconds / 1_000_000_000)
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await contributor.contribute(to: builder, options: options)
                } catch {
                    builder.omit(
                        contributor.name, reason: "\(type(of: error))")
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: nanoseconds)
                return false
            }
            // false first means the budget lapsed.
            if await group.next() == false {
                builder.omit(contributor.name, reason: "budgetExceeded")
            }
            group.cancelAll()
        }
    }
}
