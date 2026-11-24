import DiagnosticsCore
import Foundation
import RuntimeAPI
import Testing

@testable import RuntimeHost

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-perf-tests-\(UUID().uuidString)", isDirectory: true)
}

private func sampleRecord(packageID: String = "io.apkrun.fixture.hellotext") -> LaunchRecord {
    LaunchRecord(
        recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
        packageID: packageID,
        versionCode: 7,
        sessionID: "session-1",
        operationID: "op-1",
        launchState: "warm",
        windowMode: "secondaryDisplay",
        build: "0.2.0",
        image: "2026.10.0-cf16373615-arm64",
        gpuProfile: "drmVirgl",
        markers: ["WRAPPER_PROCESS_START": 0, "FIRST_FRAME_DISPLAYED": 812.5],
        totalMs: 812.5,
        outcome: "shown"
    )
}

@Test func launchRecordLineCarriesEveryField() throws {
    let line = PerfRecordWriter.line(for: sampleRecord())
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    #expect(object["v"] as? Int == 1)
    #expect(object["packageID"] as? String == "io.apkrun.fixture.hellotext")
    #expect(object["versionCode"] as? Int64 == 7)
    #expect(object["launchState"] as? String == "warm")
    #expect(object["windowMode"] as? String == "secondaryDisplay")
    #expect(object["outcome"] as? String == "shown")
    #expect(object["recordedAt"] is String)
    let markers = try #require(object["markers"] as? [String: Double])
    #expect(markers["FIRST_FRAME_DISPLAYED"] == 812.5)
}

@Test func launchRecordsRoundTripAndRotateAtTheCap() throws {
    let root = temporaryDirectory()
    let writer = PerfRecordWriter(
        launchFile: root.appendingPathComponent("perf/launches.jsonl"),
        bootFile: root.appendingPathComponent("perf/boots.jsonl"))
    for index in 0..<PerfRecordWriter.launchLimit + 10 {
        var record = sampleRecord(packageID: "io.apkrun.fixture.pkg\(index)")
        record.versionCode = Int64(index)
        writer.appendLaunch(record)
    }
    let records = writer.launchRecords()
    #expect(records.count == PerfRecordWriter.launchLimit)
    // The newest records survive; the ten oldest are trimmed.
    #expect(records.first?.versionCode == 10)
    #expect(records.last?.versionCode == Int64(PerfRecordWriter.launchLimit + 9))
}

@Test func enforceLimitsTrimsBootRecordsToo() throws {
    let root = temporaryDirectory()
    let bootFile = root.appendingPathComponent("perf/boots.jsonl")
    try FileManager.default.createDirectory(
        at: bootFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    let lines = (0..<PerfRecordWriter.bootLimit + 5).map { "{\"v\":1,\"n\":\($0)}" }
    try (lines.joined(separator: "\n") + "\n").write(to: bootFile, atomically: true, encoding: .utf8)

    let writer = PerfRecordWriter(
        launchFile: root.appendingPathComponent("perf/launches.jsonl"),
        bootFile: bootFile)
    writer.enforceLimits()

    let kept = try String(contentsOf: bootFile, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: true)
    #expect(kept.count == PerfRecordWriter.bootLimit)
    #expect(kept.first == "{\"v\":1,\"n\":5}")
}

@Test func perfStatisticsRequiresDeveloperMode() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": root.path]
    )
    let host = RuntimeHost(paths: paths)

    do {
        _ = try await host.perfStatistics(PerfStatisticsRequest())
        Issue.record("perfStatistics must fail without developer mode")
    } catch let failure as RuntimeWireError {
        #expect(failure.code == "runtime.developerModeRequired")
    }
    do {
        _ = try await host.frameStatistics(sessionID: nil)
        Issue.record("frameStatistics must fail without developer mode")
    } catch let failure as RuntimeWireError {
        #expect(failure.code == "runtime.developerModeRequired")
    }

    try GlobalSettings.store(GlobalSettings(developerEnabled: true), to: paths.settingsFile)
    _ = try await host.perfStatistics(PerfStatisticsRequest())
    _ = try await host.frameStatistics(sessionID: nil)
}

@Test func perfStatisticsResetClearsInputHistograms() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": root.path]
    )
    try GlobalSettings.store(GlobalSettings(developerEnabled: true), to: paths.settingsFile)
    let host = RuntimeHost(paths: paths)

    InputLatencyRecorder.shared.reset()
    // A unique segment name keeps the counts exact while other tests
    // record their own input histograms in parallel.
    InputLatencyRecorder.shared.record(segment: "input.reset.test", microseconds: 2_000)
    let first = try await host.perfStatistics(PerfStatisticsRequest())
    #expect(first.input.contains { $0.segment == "input.reset.test" && $0.counts.reduce(0, +) == 1 })

    // The reset read still reports what was collected; the read after it
    // has the segment cleared.
    let second = try await host.perfStatistics(PerfStatisticsRequest(reset: true))
    #expect(second.input.contains { $0.segment == "input.reset.test" && $0.counts.reduce(0, +) == 1 })

    let third = try await host.perfStatistics(PerfStatisticsRequest())
    #expect(third.input.allSatisfy { $0.segment != "input.reset.test" })
    InputLatencyRecorder.shared.reset()
}
