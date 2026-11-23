import Foundation

/// A spawned tool's captured output (wrapper.md §11 tools run through
/// `Process` with absolute paths).
public struct ToolResult: Sendable, Equatable {
    /// The exit status.
    public var status: Int32
    /// Everything the tool wrote to stdout.
    public var stdout: String
    /// Everything the tool wrote to stderr.
    public var stderr: String

    /// Creates a tool result.
    public init(status: Int32, stdout: String = "", stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Runs a command-line tool and captures its output. The default
/// implementation is `SystemToolRunner`; T0 tests substitute a fake that
/// records argument lists (wrapper.md §11).
public protocol WrapperToolRunner: Sendable {
    /// Runs `executable` with `arguments`; returns when the tool exits.
    func run(executable: String, arguments: [String]) throws -> ToolResult
}

/// Runs tools through `Process` with absolute paths.
public struct SystemToolRunner: WrapperToolRunner {
    /// Creates the runner.
    public init() {}

    /// Runs the tool and captures status, stdout, and stderr.
    public func run(executable: String, arguments: [String]) throws -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ToolResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}

/// What `notarytool submit --wait --output-format json` reports.
public struct NotarySubmission: Sendable, Equatable {
    /// `Accepted`, `Invalid`, or `In Progress` (a timed-out `--wait`).
    public var status: String
    /// The submission UUID.
    public var submissionID: String?
    /// Apple's `statusSummary`, when present.
    public var summary: String?

    /// Creates a submission record.
    public init(status: String, submissionID: String? = nil, summary: String? = nil) {
        self.status = status
        self.submissionID = submissionID
        self.summary = summary
    }
}

/// Builds a distribution wrapper (wrapper.md §11): a portable bundle
/// generated in staging, Developer ID signed, optionally notarized and
/// stapled, delivered as `<name>.app` + `<name>.zip`. It is never placed
/// in an Applications folder and never registered.
public struct DistributionWrapperBuilder: Sendable {
    /// The outcome of a build: file URLs are wherever the caller placed
    /// the staged products.
    public struct Product: Sendable, Equatable {
        /// The bundle, still in its staging directory.
        public var appURL: URL
        /// The ditto zip of the (re-zipped after stapling) bundle.
        public var zipURL: URL
        /// The deterministic bundle ID.
        public var bundleID: String
        /// The 40-hex code directory hash after signing.
        public var cdhash: String
        /// The Apple team ID of the signing identity, when reported.
        public var teamID: String?
        /// Whether the bundle was notarized and stapled.
        public var notarized: Bool
        /// The notary submission ID (only with `--notarize`).
        public var submissionID: String?
        /// The `spctl` assessment line (only with `--notarize`).
        public var assessment: String?

        /// Creates a product record.
        public init(
            appURL: URL,
            zipURL: URL,
            bundleID: String,
            cdhash: String,
            teamID: String? = nil,
            notarized: Bool,
            submissionID: String? = nil,
            assessment: String? = nil
        ) {
            self.appURL = appURL
            self.zipURL = zipURL
            self.bundleID = bundleID
            self.cdhash = cdhash
            self.teamID = teamID
            self.notarized = notarized
            self.submissionID = submissionID
            self.assessment = assessment
        }
    }

    /// Every tool call goes through this runner.
    public var runner: any WrapperToolRunner
    /// The strict in-process signature check after `codesign --verify`
    /// (`SecStaticCodeCheckValidity` by default).
    public var securityCheck: @Sendable (URL, String) -> Bool
    /// Reads a bundle's team ID (`SecCodeCopySigningInformation` by default).
    public var teamIDReader: @Sendable (URL) -> String?

    /// Creates a builder.
    public init(
        runner: any WrapperToolRunner = SystemToolRunner(),
        securityCheck: @escaping @Sendable (URL, String) -> Bool = {
            WrapperCodeSign.signatureIsValid(bundleURL: $0, identifier: $1)
        },
        teamIDReader: @escaping @Sendable (URL) -> String? = {
            WrapperCodeSign.teamID(of: $0)
        }
    ) {
        self.runner = runner
        self.securityCheck = securityCheck
        self.teamIDReader = teamIDReader
    }

    /// §11 pre-checks: `xcrun --find notarytool`, `xcrun --find stapler`,
    /// and `security find-identity -v -p codesigning` naming `identity`.
    public func precheck(identity: String) throws(WrapperFailure) {
        for tool in ["notarytool", "stapler"] {
            let result = try runTool("/usr/bin/xcrun", ["--find", tool])
            guard result.status == 0,
                !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw .distributionToolMissing(tool)
            }
        }
        let identities = try runTool(
            "/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])
        guard identities.status == 0,
            identities.stdout.contains(identity)
        else {
            throw .identityNotFound(identity)
        }
    }

    /// §11 steps 2–3: Developer ID sign with Hardened Runtime and a secure
    /// timestamp, then verify strictly and read the cdhash and team ID.
    public func sign(
        bundleURL: URL, bundleID: String, identity: String
    ) throws(WrapperFailure) -> (cdhash: String, teamID: String?) {
        let result = try runTool(
            "/usr/bin/codesign",
            [
                "--force",
                "--sign", identity,
                "--identifier", bundleID,
                "--options", "runtime",
                "--timestamp",
                bundleURL.path,
            ])
        guard result.status == 0 else {
            throw .signingFailed(
                status: result.status,
                message: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let verify = try runTool(
            "/usr/bin/codesign", ["--verify", "--strict", bundleURL.path])
        guard verify.status == 0, securityCheck(bundleURL, bundleID) else {
            throw .verificationFailed("strict check failed after signing")
        }
        guard let cdhash = WrapperCodeSign.cdhash(of: bundleURL) else {
            throw .verificationFailed("no cdhash after signing")
        }
        return (cdhash, teamIDReader(bundleURL))
    }

    /// §11 step 4: ditto the bundle into `<name>.zip` inside
    /// `workDirectory`. Without notarization this is the shareable archive;
    /// with notarization it is the submission payload.
    public func makeZip(
        bundleURL: URL, name: String, workDirectory: URL
    ) throws(WrapperFailure) -> URL {
        let zip = workDirectory.appendingPathComponent("\(name).zip")
        let result = try runTool(
            "/usr/bin/ditto",
            ["-c", "-k", "--keepParent", bundleURL.path, zip.path])
        guard result.status == 0 else {
            throw .verificationFailed(
                "ditto failed: "
                    + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return zip
    }

    /// §11 steps 4–5: submit the zip, staple the ticket on `Accepted`,
    /// re-zip the stapled bundle, and assess with `spctl`. An `Invalid`
    /// (or still `In Progress`) submission throws `notarizationFailed`
    /// with the `notarytool log` summary.
    public func notarize(
        bundleURL: URL,
        name: String,
        keychainProfile: String,
        workDirectory: URL
    ) async throws(WrapperFailure) -> (
        zipURL: URL, submissionID: String?, assessment: String
    ) {
        let zip = try makeZip(bundleURL: bundleURL, name: name, workDirectory: workDirectory)
        let submission = try runTool(
            "/usr/bin/xcrun",
            [
                "notarytool", "submit", zip.path,
                "--keychain-profile", keychainProfile,
                "--wait", "--output-format", "json",
            ])
        guard let parsed = Self.parseNotarySubmission(submission.stdout),
            let submissionID = parsed.submissionID
        else {
            throw .notarizationFailed(
                submissionID: "",
                summary: submission.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard parsed.status == "Accepted" else {
            let summary = try await notaryLogSummary(
                submissionID: submissionID,
                keychainProfile: keychainProfile,
                fallback: parsed.summary)
            throw .notarizationFailed(submissionID: submissionID, summary: summary)
        }
        let staple = try runTool("/usr/bin/xcrun", ["stapler", "staple", bundleURL.path])
        guard staple.status == 0 else {
            throw .notarizationFailed(
                submissionID: submissionID,
                summary: staple.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // Re-zip so the archive carries the stapled ticket.
        let stapledZip = try makeZip(
            bundleURL: bundleURL, name: name, workDirectory: workDirectory)
        let assess = try runTool(
            "/usr/sbin/spctl", ["--assess", "--type", "execute", "-vv", bundleURL.path])
        let assessment = (assess.stdout + "\n" + assess.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard assess.status == 0, assessment.contains("Notarized Developer ID") else {
            throw .notarizationFailed(
                submissionID: submissionID,
                summary: assessment.isEmpty ? "Gatekeeper rejected the app" : assessment)
        }
        return (stapledZip, submissionID, assessment)
    }

    /// The `notarytool log` output used as the `notarizationFailed`
    /// summary (wrapper.md §11).
    private func notaryLogSummary(
        submissionID: String,
        keychainProfile: String,
        fallback: String?
    ) async throws(WrapperFailure) -> String {
        if let result = try? runTool(
            "/usr/bin/xcrun",
            [
                "notarytool", "log", submissionID,
                "--keychain-profile", keychainProfile,
            ]),
            result.status == 0
        {
            let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return String(text.prefix(2000))
            }
        }
        return fallback ?? "notarytool returned no log"
    }

    /// Runs a tool through the runner, translating a spawn failure into a
    /// signing failure (`distributionToolMissing` is checked up front).
    private func runTool(
        _ executable: String, _ arguments: [String]
    ) throws(WrapperFailure) -> ToolResult {
        do {
            return try runner.run(executable: executable, arguments: arguments)
        } catch {
            throw .signingFailed(status: -1, message: "\(executable) could not start")
        }
    }

    /// Parses `notarytool submit --output-format json` output; handles the
    /// `Accepted`, `Invalid`, and `In Progress` statuses (wrapper.md §11).
    public static func parseNotarySubmission(_ output: String) -> NotarySubmission? {
        guard let data = output.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let status = object["status"] as? String
        else {
            return nil
        }
        return NotarySubmission(
            status: status,
            submissionID: object["id"] as? String,
            summary: object["statusSummary"] as? String)
    }
}
