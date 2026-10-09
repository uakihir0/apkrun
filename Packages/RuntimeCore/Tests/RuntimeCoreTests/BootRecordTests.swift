import Foundation
import Testing

@testable import RuntimeCore

private func sampleRecord(index: Int) -> BootRecord {
    BootRecord(
        recordedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(index)),
        operationID: UUID(uuidString: "3F9A1C2E-0000-4000-8000-000000000001")!,
        bootKind: "cold",
        image: "2026.10.0-cf16373615-arm64",
        gpuProfile: "headless",
        memoryGiB: 4,
        cpuCount: 4,
        markers: ["VM_START": 0, "KERNEL_START": 203.2, "BOOT_COMPLETED": 5179.9],
        outcome: "ready"
    )
}

@Test
func bootRecordEncodesOneLineWithTheDocumentedKeys() throws {
    let line = try BootRecordLog.line(for: sampleRecord(index: 0))

    #expect(!line.contains("\n"))
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    )
    #expect(
        Set(object.keys) == [
            "v", "recordedAt", "operationID", "bootKind", "image", "gpuProfile", "memoryGiB", "cpuCount", "markers",
            "outcome",
        ])
    #expect(object["v"] as? Int == 1)
    #expect(object["recordedAt"] as? String == "2026-09-21T14:13:20Z")
    #expect(object["operationID"] as? String == "3F9A1C2E-0000-4000-8000-000000000001")
    #expect(object["outcome"] as? String == "ready")
    let markers = try #require(object["markers"] as? [String: Double])
    #expect(markers["VM_START"] == 0)
    #expect(markers["BOOT_COMPLETED"] == 5179.9)
}

@Test
func bootRecordRoundTripsThroughItsEncoding() throws {
    let record = sampleRecord(index: 3)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let line = try BootRecordLog.line(for: record)

    let decoded = try decoder.decode(BootRecord.self, from: Data(line.utf8))

    #expect(decoded == record)
}

@Test
func bootRecordLogKeepsTheNewestRecordsInOrder() {
    let lines = (0..<7).map { "line \($0)" }

    #expect(BootRecordLog.retainNewest(lines, limit: 3) == ["line 4", "line 5", "line 6"])
    #expect(BootRecordLog.retainNewest(lines, limit: 7) == lines)
    #expect(BootRecordLog.retainedRecordCount == 200)
}

@Test
func bootRecordAppendWritesAndTrimsTheFile() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-boot-records-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("perf/boots.jsonl")

    for index in 0..<(BootRecordLog.retainedRecordCount + 5) {
        try BootRecordLog.append(sampleRecord(index: index), to: url)
    }

    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == BootRecordLog.retainedRecordCount)
    let first = try #require(lines.first)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let oldest = try decoder.decode(BootRecord.self, from: Data(first.utf8))
    #expect(oldest.recordedAt == sampleRecord(index: 5).recordedAt)
}
