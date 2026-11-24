import Foundation

/// The options one report run was created with (diagnostics.md §8.1–§8.2).
public struct DiagnosticsOptions: Sendable, Equatable {
    /// Keep every logcat line, still redacted (`--include-logcat`).
    public var includeLogcat: Bool
    /// Include deep checks and metrics (`--deep`).
    public var deep: Bool
    /// The package whose update history and last 20 launch records are added.
    public var focusPackage: String?
    /// Who produced the bundle: `apkrund`, `cli`, or `app`.
    public var createdBy: String
    /// `full` or `hostOnly` (§8.4).
    public var mode: String
    /// The random report ID; not linked to the Mac or the user.
    public var reportID: String
    /// The report creation time.
    public var createdAt: Date

    /// Creates options for a report run.
    public init(
        includeLogcat: Bool = false,
        deep: Bool = false,
        focusPackage: String? = nil,
        createdBy: String = "apkrund",
        mode: String = "full",
        reportID: String = UUID().uuidString.lowercased(),
        createdAt: Date = Date()
    ) {
        self.includeLogcat = includeLogcat
        self.deep = deep
        self.focusPackage = focusPackage
        self.createdBy = createdBy
        self.mode = mode
        self.reportID = reportID
        self.createdAt = createdAt
    }
}

/// An item a contributor could not deliver, with the reason shown to the user
/// (diagnostics.md §8.1).
public struct DiagnosticsOmittedItem: Sendable, Equatable, Codable {
    /// The bundle path or item name.
    public var item: String
    /// Why it is missing: a check state, `budgetExceeded`, `guestAgentUnavailable`,
    /// `redactionFailed`, or a short error reason.
    public var reason: String

    /// Creates an omitted record.
    public init(item: String, reason: String) {
        self.item = item
        self.reason = reason
    }
}

/// One section owner of the bundle (diagnostics.md §8.2). Each contributor
/// writes only files its module owns, within its budget; a failure or overrun
/// lands in `omitted`, never aborts the report.
public protocol DiagnosticsContributor: Sendable {
    /// The owning module's name (`"store"`, `"graphics"`, …).
    var name: String { get }
    /// The per-contributor time budget (§8.1: 10 s, 45 s for `log show`).
    var budget: Duration { get }
    /// Writes this module's files into `bundle`.
    func contribute(to bundle: DiagnosticsBundleBuilder, options: DiagnosticsOptions) async throws
}

/// Collects the files of one report. Only paths under the bundle tree and
/// only text, JSON, and `.ips` payloads are accepted — a contributor has no
/// way to add the never-collected items of §6.1.
public final class DiagnosticsBundleBuilder: @unchecked Sendable {
    /// A path or payload the bundle refused.
    public enum Failure: Error {
        /// The path escapes the bundle tree or has an unacceptable form.
        case invalidPath(String)
        /// Only text, JSON, `.ips`, `.jsonl`, `.ndjson`, and `.log` payloads.
        case invalidPayload(String)
    }

    /// The payload types a contributor may add.
    private static let allowedExtensions: Set<String> = [
        "txt", "json", "jsonl", "ndjson", "log", "ips",
    ]

    private let lock = NSLock()
    /// Staged `(path, contents)` pairs in add order.
    public private(set) var files: [(path: String, data: Data)] = []
    /// The omitted items in record order.
    public private(set) var omitted: [DiagnosticsOmittedItem] = []

    /// Creates an empty builder.
    public init() {}

    /// Stages raw text or JSON bytes at `path` inside the bundle tree.
    public func add(_ path: String, data: Data) throws {
        try Self.validate(path: path)
        lock.lock()
        defer { lock.unlock() }
        files.append((path: path, data: data))
    }

    /// Stages UTF-8 text at `path`.
    public func add(_ path: String, text: String) throws {
        try add(path, data: Data(text.utf8))
    }

    /// Stages a JSON-encodable value at `path`, pretty-printed.
    public func addJSON(_ path: String, _ value: Any) throws {
        let data = try JSONSerialization.data(
            withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try add(path, data: data)
    }

    /// Records that `item` is missing for `reason`.
    public func omit(_ item: String, reason: String) {
        lock.lock()
        defer { lock.unlock() }
        omitted.append(DiagnosticsOmittedItem(item: item, reason: reason))
    }

    /// A relative path with `/` separators, no `..`, no leading `/`, and an
    /// allowed payload extension (§8.2).
    private static func validate(path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
            !path.split(separator: "/").contains(".."), !path.hasSuffix("/")
        else {
            throw Failure.invalidPath(path)
        }
        let ext = (path as NSString).pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else {
            throw Failure.invalidPayload(path)
        }
    }
}
