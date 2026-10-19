import Darwin
import Foundation

/// One daemon crash report known to DiagnosticsCore.
public struct DaemonCrashReportReference: Codable, Equatable, Sendable {
    /// The absolute path to the `.ips` report.
    public let path: String
    /// When APKRun discovered the report after an unclean exit.
    public let discoveredAt: Date

    /// Creates a reference to one daemon crash report.
    public init(path: String, discoveredAt: Date) {
        self.path = path
        self.discoveredAt = discoveredAt
    }
}

/// The persisted diagnostics index.
public struct DiagnosticsIndex: Codable, Equatable, Sendable {
    /// The current index schema.
    public let schemaVersion: Int
    /// The newest known apkrund crash reports.
    public var daemonCrashReports: [DaemonCrashReportReference]

    /// Creates a schema version 1 diagnostics index.
    public init(
        schemaVersion: Int = 1,
        daemonCrashReports: [DaemonCrashReportReference] = []
    ) {
        self.schemaVersion = schemaVersion
        self.daemonCrashReports = daemonCrashReports
    }
}

/// Failures while reading or writing the diagnostics index.
public enum DiagnosticsIndexError: Error, Equatable, Sendable {
    /// The index file could not be decoded.
    case unreadable(domain: String, code: Int)
    /// A newer index schema must not be overwritten by this build.
    case unsupportedSchema(version: Int)
    /// The indexed path is not an apkrund `.ips` report.
    case invalidDaemonCrashReport
    /// A file-system operation failed.
    case storage(domain: String, code: Int)
}

/// Atomically records crash-report paths for the Diagnostics bundle builder.
public struct DiagnosticsIndexStore: Sendable {
    /// The maximum number of daemon crash reports retained by the index.
    public static let retainedDaemonCrashReports = 20

    private let fileURL: URL

    /// Creates a store at `fileURL`.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Adds a daemon crash report, retaining the newest references and avoiding duplicate paths.
    public func recordDaemonCrashReport(
        at reportURL: URL,
        discoveredAt: Date = Date()
    ) throws {
        guard reportURL.isFileURL,
            reportURL.lastPathComponent.hasPrefix("apkrund-"),
            reportURL.pathExtension == "ips"
        else {
            throw DiagnosticsIndexError.invalidDaemonCrashReport
        }

        var index = try read()
        let path = reportURL.standardizedFileURL.path
        index.daemonCrashReports.removeAll { $0.path == path }
        index.daemonCrashReports.append(
            DaemonCrashReportReference(path: path, discoveredAt: discoveredAt)
        )
        if index.daemonCrashReports.count > Self.retainedDaemonCrashReports {
            index.daemonCrashReports.removeFirst(
                index.daemonCrashReports.count - Self.retainedDaemonCrashReports
            )
        }
        try write(index)
    }

    /// Reads the current index, returning an empty index when it has not been created yet.
    public func read() throws(DiagnosticsIndexError) -> DiagnosticsIndex {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return DiagnosticsIndex()
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let index = try decoder.decode(DiagnosticsIndex.self, from: Data(contentsOf: fileURL))
            guard index.schemaVersion == 1 else {
                throw DiagnosticsIndexError.unsupportedSchema(version: index.schemaVersion)
            }
            return index
        } catch let error as DiagnosticsIndexError {
            throw error
        } catch {
            let error = error as NSError
            throw .unreadable(domain: error.domain, code: error.code)
        }
    }

    private func write(_ index: DiagnosticsIndex) throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(index).write(to: fileURL, options: .atomic)
            guard chmod(fileURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        } catch {
            let error = error as NSError
            throw DiagnosticsIndexError.storage(domain: error.domain, code: error.code)
        }
    }
}
