@testable import DiagnosticsCore
import Foundation
import Testing

@Test func logMirrorRotatesAtTheTenMiBProductionLimit() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let logURL = directory.appendingPathComponent("apkrund.log")
    let writer = LogMirrorWriter(fileURL: logURL)
    let payload = String(repeating: "x", count: 900_000)

    for _ in 0 ..< 24 {
        writer.write(
            LogEntry(
                level: .info,
                subsystem: .runtime,
                category: "host",
                publicMessage: payload
            )
        )
        await writer.flush()
    }

    let activeSize = try fileSize(at: logURL)
    #expect(activeSize > 0)
    #expect(activeSize <= 10 * 1_024 * 1_024)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("apkrund.1.log").path))
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("apkrund.2.log").path))
}

@Test func logMirrorDropsEntriesThatExceedItsBoundedBuffer() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let logURL = directory.appendingPathComponent("apkrund.log")
    let writer = LogMirrorWriter(
        fileURL: logURL,
        maximumBufferedBytes: 64,
        flushInterval: 60
    )

    writer.write(
        LogEntry(
            level: .info,
            subsystem: .runtime,
            category: "host",
            publicMessage: String(repeating: "x", count: 100)
        )
    )
    await writer.flush()

    #expect(writer.droppedEntryCount == 1)
    #expect(!FileManager.default.fileExists(atPath: logURL.path))
}

@Test func logMirrorWritesOnlyPublicTextAndCreatesPrivateFiles() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let logURL = directory.appendingPathComponent("apkrund.log")
    let writer = LogMirrorWriter(fileURL: logURL, flushInterval: 60)

    writer.write(
        LogEntry(
            level: .error,
            subsystem: .runtime,
            category: "host",
            publicMessage: "failed to open <private>",
            privateMessage: "failed to open /Users/alice/private.apk"
        )
    )
    await writer.flush()

    let contents = try String(contentsOf: logURL, encoding: .utf8)
    let attributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue

    #expect(contents.contains("failed to open <private>"))
    #expect(!contents.contains("/Users/alice/private.apk"))
    #expect(permissions == 0o600)
    #expect(writer.droppedEntryCount == 0)
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("APKRun-LogMirror-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func fileSize(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.size] as? NSNumber)?.intValue ?? 0
}
