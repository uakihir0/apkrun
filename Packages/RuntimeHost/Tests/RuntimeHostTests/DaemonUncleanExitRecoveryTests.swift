import DiagnosticsCore
import Foundation
import Testing

@testable import RuntimeHost

@Test func debugRecoveryIndexesNewestReportAndRemovesOnlyApkrunForwards() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DaemonUncleanExitRecovery-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let reportDirectory = root.appendingPathComponent("DiagnosticReports", isDirectory: true)
    try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)

    let oldReport = reportDirectory.appendingPathComponent("apkrund-old.ips")
    let newestReport = reportDirectory.appendingPathComponent("apkrund-new.ips")
    let unrelatedReport = reportDirectory.appendingPathComponent("APKRun-new.ips")
    try Data("{}".utf8).write(to: oldReport)
    try Data("{}".utf8).write(to: newestReport)
    try Data("{}".utf8).write(to: unrelatedReport)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 10)],
        ofItemAtPath: oldReport.path
    )
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 20)],
        ofItemAtPath: newestReport.path
    )
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 30)],
        ofItemAtPath: unrelatedReport.path
    )
    let recorder = RecoveryADBCommandRecorder(
        responses: [
            "-s 127.0.0.1:6520 forward --list": .init(
                status: 0,
                output: """
                    127.0.0.1:6520 tcp:41001 localabstract:apkrun-guestd-control
                    127.0.0.1:6520 tcp:41002 localabstract:other-socket
                    127.0.0.1:6520 tcp:41003 localabstract:apkrun-guestd-input
                    other-device tcp:41999 localabstract:apkrun-guestd-control
                    malformed apkrun-control
                    """
            ),
            "-s 127.0.0.1:6520 forward --remove tcp:41001": .init(status: 0),
            "-s 127.0.0.1:6520 forward --remove tcp:41003": .init(status: 0),
            "disconnect 127.0.0.1:6520": .init(status: 0),
        ]
    )
    let indexURL = root.appendingPathComponent("data/Diagnostics/index.json")
    let recovery = DaemonUncleanExitRecovery(
        diagnosticReportsDirectory: reportDirectory,
        diagnosticsIndex: DiagnosticsIndexStore(fileURL: indexURL),
        configuration: .debug,
        adbExecutable: root.appendingPathComponent("fake-adb"),
        commandRunner: { _, arguments, _ in
            await recorder.run(arguments)
        }
    )

    let result = await recovery.recover()

    #expect(
        result.indexedCrashReport?.resolvingSymlinksInPath().path
            == newestReport.resolvingSymlinksInPath().path
    )
    #expect(result.removedADBForwards == 2)
    #expect(result.issues.isEmpty)
    #expect(
        await recorder.calls == [
            ["-s", "127.0.0.1:6520", "forward", "--list"],
            ["-s", "127.0.0.1:6520", "forward", "--remove", "tcp:41001"],
            ["-s", "127.0.0.1:6520", "forward", "--remove", "tcp:41003"],
            ["disconnect", "127.0.0.1:6520"],
        ]
    )
    let indexedReports = try DiagnosticsIndexStore(fileURL: indexURL).read().daemonCrashReports
    #expect(
        indexedReports.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }
            == [newestReport.resolvingSymlinksInPath().path]
    )
}

@Test func releaseRecoveryIndexesReportWithoutRunningADB() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DaemonUncleanExitRecovery-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let reportDirectory = root.appendingPathComponent("DiagnosticReports", isDirectory: true)
    try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
    let report = reportDirectory.appendingPathComponent("apkrund-release.ips")
    try Data("{}".utf8).write(to: report)

    let recorder = RecoveryADBCommandRecorder(responses: [:])
    let indexURL = root.appendingPathComponent("data/Diagnostics/index.json")
    let recovery = DaemonUncleanExitRecovery(
        diagnosticReportsDirectory: reportDirectory,
        diagnosticsIndex: DiagnosticsIndexStore(fileURL: indexURL),
        configuration: .release,
        adbExecutable: root.appendingPathComponent("fake-adb"),
        commandRunner: { _, arguments, _ in
            await recorder.run(arguments)
        }
    )

    let result = await recovery.recover()

    #expect(
        result.indexedCrashReport?.resolvingSymlinksInPath().path
            == report.resolvingSymlinksInPath().path
    )
    #expect(result.removedADBForwards == 0)
    #expect(result.issues.isEmpty)
    #expect(await recorder.calls.isEmpty)
}

@Test func debugRecoveryStillDisconnectsWhenForwardListingFails() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DaemonUncleanExitRecovery-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = RecoveryADBCommandRecorder(
        responses: [
            "-s 127.0.0.1:6520 forward --list": .init(status: 1),
            "disconnect 127.0.0.1:6520": .init(status: 0),
        ]
    )
    let recovery = DaemonUncleanExitRecovery(
        diagnosticReportsDirectory: root.appendingPathComponent("missing-reports", isDirectory: true),
        diagnosticsIndex: DiagnosticsIndexStore(fileURL: root.appendingPathComponent("index.json")),
        configuration: .debug,
        adbExecutable: root.appendingPathComponent("fake-adb"),
        commandRunner: { _, arguments, _ in
            await recorder.run(arguments)
        }
    )

    let result = await recovery.recover()

    #expect(result.issues == [.adbForwardListFailed])
    #expect(
        await recorder.calls == [
            ["-s", "127.0.0.1:6520", "forward", "--list"],
            ["disconnect", "127.0.0.1:6520"],
        ]
    )
}

@Test func runtimeHostRunsInjectedRecoveryOnlyAfterAnUncleanExit() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RuntimeHostUncleanExit-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": root.path]
    )
    _ = try DaemonStateStore(fileURL: paths.daemonStateFile).beginRun(
        pid: 123,
        version: "previous"
    )
    let recovery = RecoveryInvocationRecorder()
    let host = RuntimeHost(
        paths: paths,
        buildInfo: BuildInfo(infoDictionary: ["APKRunConfiguration": "Debug"]),
        environment: ["PATH": ""],
        executableURL: root.appendingPathComponent("apkrund"),
        uncleanExitRecovery: recovery
    )

    try await host.start(publishListener: { .now })

    #expect(await recovery.invocationCount == 1)
    #expect((await host.status()).hostState == "degraded")
    await host.shutdown()
}

@Test func lifecycleStartWaitsForHostInitializationWhileStatusRemainsAvailable() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RuntimeHostStartupGate-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": root.path]
    )
    _ = try DaemonStateStore(fileURL: paths.daemonStateFile).beginRun(
        pid: 123,
        version: "previous"
    )
    let recovery = BlockingRecoveryInvocation()
    let host = RuntimeHost(
        paths: paths,
        buildInfo: BuildInfo(infoDictionary: ["APKRunConfiguration": "Debug"]),
        environment: ["PATH": ""],
        executableURL: root.appendingPathComponent("apkrund"),
        uncleanExitRecovery: recovery
    )
    let hostStart = Task {
        try await host.start(publishListener: { .now })
    }

    await recovery.waitUntilStarted()
    #expect((await host.status()).hostState == "starting")

    let startAttempt = AsyncStream.makeStream(of: Bool.self)
    let runtimeStart = Task<RuntimeHostError?, Never> {
        startAttempt.continuation.yield(true)
        do {
            try await host.startRuntime()
            return nil as RuntimeHostError?
        } catch let error as RuntimeHostError {
            return error
        } catch {
            Issue.record("Unexpected startRuntime error: \(error)")
            return nil
        }
    }
    var iterator = startAttempt.stream.makeAsyncIterator()
    #expect(await iterator.next() == true)
    try await Task.sleep(for: .milliseconds(20))
    await recovery.finish()
    try await hostStart.value

    guard case .startupFailed(step: 5, code: _) = await runtimeStart.value else {
        Issue.record("A lifecycle start should wait for image initialization to finish.")
        await host.shutdown()
        return
    }
    await host.shutdown()
}

@Test func duplicateDaemonLockMakesHostStartupAttemptTerminal() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RuntimeHostDuplicateLock-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": root.path]
    )
    let lockOwner = try InstanceLock.acquire(
        paths: paths,
        owner: .apkrund,
        processID: 123,
        executablePath: root.appendingPathComponent("other-apkrund").path
    )
    let host = RuntimeHost(
        paths: paths,
        buildInfo: BuildInfo(infoDictionary: ["APKRunConfiguration": "Debug"]),
        environment: ["PATH": ""],
        executableURL: root.appendingPathComponent("apkrund")
    )

    await #expect(throws: RuntimeHostError.runtimeFailure(.instanceLocked(owner: .apkrund))) {
        try await host.start(publishListener: { .now })
    }
    lockOwner.close()

    await #expect(throws: RuntimeHostError.alreadyStarted) {
        try await host.start(publishListener: { .now })
    }
}

private actor RecoveryADBCommandRecorder {
    private let responses: [String: DaemonUncleanExitRecovery.ADBCommandResult]
    private(set) var calls: [[String]] = []

    init(responses: [String: DaemonUncleanExitRecovery.ADBCommandResult]) {
        self.responses = responses
    }

    func run(_ arguments: [String]) -> DaemonUncleanExitRecovery.ADBCommandResult {
        calls.append(arguments)
        return responses[arguments.joined(separator: " ")] ?? .init(status: nil)
    }
}

private actor RecoveryInvocationRecorder: DaemonUncleanExitRecovering {
    private(set) var invocationCount = 0

    func recover() async -> DaemonUncleanExitRecoveryResult {
        invocationCount += 1
        return DaemonUncleanExitRecoveryResult(
            indexedCrashReport: nil,
            removedADBForwards: 0,
            issues: []
        )
    }
}

private actor BlockingRecoveryInvocation: DaemonUncleanExitRecovering {
    private var didStart = false
    private var startupWaiter: CheckedContinuation<Void, Never>?
    private var recoveryWaiter: CheckedContinuation<DaemonUncleanExitRecoveryResult, Never>?

    func recover() async -> DaemonUncleanExitRecoveryResult {
        didStart = true
        startupWaiter?.resume()
        startupWaiter = nil
        return await withCheckedContinuation { continuation in
            recoveryWaiter = continuation
        }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            if didStart {
                continuation.resume()
            } else {
                startupWaiter = continuation
            }
        }
    }

    func finish() {
        recoveryWaiter?.resume(
            returning: DaemonUncleanExitRecoveryResult(
                indexedCrashReport: nil,
                removedADBForwards: 0,
                issues: []
            )
        )
        recoveryWaiter = nil
    }
}
