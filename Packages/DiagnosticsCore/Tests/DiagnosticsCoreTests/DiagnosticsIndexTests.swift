import Foundation
import Testing

@testable import DiagnosticsCore

@Test func diagnosticsIndexStoresUniqueDaemonReportsAndCapsHistory() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiagnosticsIndexTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let indexURL = root.appendingPathComponent("Diagnostics/index.json")
    let store = DiagnosticsIndexStore(fileURL: indexURL)

    for number in 0...DiagnosticsIndexStore.retainedDaemonCrashReports {
        let report = root.appendingPathComponent("apkrund-\(number).ips")
        try Data("{}".utf8).write(to: report)
        try store.recordDaemonCrashReport(
            at: report,
            discoveredAt: Date(timeIntervalSince1970: TimeInterval(number))
        )
    }

    let newestReport = root.appendingPathComponent("apkrund-20.ips")
    try store.recordDaemonCrashReport(
        at: newestReport,
        discoveredAt: Date(timeIntervalSince1970: 100)
    )

    let index = try store.read()
    #expect(index.schemaVersion == 1)
    #expect(index.daemonCrashReports.count == DiagnosticsIndexStore.retainedDaemonCrashReports)
    #expect(index.daemonCrashReports.first?.path == root.appendingPathComponent("apkrund-1.ips").path)
    #expect(index.daemonCrashReports.last?.path == newestReport.path)
    #expect(index.daemonCrashReports.last?.discoveredAt == Date(timeIntervalSince1970: 100))

    let indexAttributes = try FileManager.default.attributesOfItem(atPath: indexURL.path)
    #expect((indexAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func diagnosticsIndexRejectsNonDaemonCrashReports() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiagnosticsIndexTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DiagnosticsIndexStore(fileURL: root.appendingPathComponent("index.json"))

    #expect(throws: DiagnosticsIndexError.invalidDaemonCrashReport) {
        try store.recordDaemonCrashReport(at: root.appendingPathComponent("APKRun-123.ips"))
    }
}
