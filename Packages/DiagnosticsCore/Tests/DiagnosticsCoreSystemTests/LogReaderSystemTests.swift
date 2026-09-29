import DiagnosticsCore
import DiagnosticsCoreTestSupport
import Foundation
import Testing

@testable import DiagnosticsCore

@Test func logReaderFallsBackWhenUnifiedLogProcessFails() async throws {
    try await verifyMirrorFallback(for: LogCommandResult(exitCode: 1))
}

@Test func logReaderFallsBackWhenUnifiedLogProducesNoOutput() async throws {
    try await verifyMirrorFallback(
        for: LogCommandResult(exitCode: -1, timedOut: true)
    )
}

@Test func systemLogCommandRunnerCapturesOutputAndReportsStartup() async throws {
    let runner = SystemLogCommandRunner(executableURL: URL(fileURLWithPath: "/usr/bin/printf"))
    let startup = SystemCommandStartupRecorder()
    let result = try await runner.run(
        arguments: ["runner-output"],
        initialOutputTimeout: .seconds(2),
        captureOutput: true,
        onStarted: startup.record,
        onReady: {},
        onOutput: { _ in }
    )

    #expect(startup.started)
    #expect(result.exitCode == 0)
    #expect(String(decoding: result.standardOutput, as: UTF8.self) == "runner-output")
    #expect(!result.timedOut)
}

@Test func systemLogCommandRunnerTimesOutBeforeFirstOutput() async throws {
    let runner = SystemLogCommandRunner(executableURL: URL(fileURLWithPath: "/bin/sleep"))
    let startup = SystemCommandStartupRecorder()
    let result = try await runner.run(
        arguments: ["5"],
        initialOutputTimeout: .milliseconds(50),
        captureOutput: false,
        onStarted: startup.record,
        onReady: {},
        onOutput: { _ in }
    )

    #expect(startup.started)
    #expect(result.timedOut)
}

@Test func systemLogCommandRunnerSignalsStreamReadinessFromTheSubscriptionNotice() async throws {
    let runner = SystemLogCommandRunner(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        signalsReadiness: true
    )
    let readiness = SystemCommandStartupRecorder()
    let result = try await runner.run(
        arguments: [
            "-c",
            "printf '%s\\n' 'Filtering the log data using predicate' >&2",
        ],
        initialOutputTimeout: .seconds(2),
        captureOutput: false,
        onStarted: {},
        onReady: readiness.record,
        onOutput: { _ in }
    )

    #expect(readiness.started)
    #expect(result.exitCode == 0)
    #expect(result.standardError.isEmpty)
}

@Test func systemLogCommandRunnerBoundsCapturedStandardError() async throws {
    let runner = SystemLogCommandRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))
    let result = try await runner.run(
        arguments: ["-c", "head -c 100000 /dev/zero >&2"],
        initialOutputTimeout: .seconds(2),
        captureOutput: true,
        onStarted: {},
        onReady: {},
        onOutput: { _ in }
    )

    #expect(result.exitCode == 0)
    #expect(result.standardError.count == 64 * 1_024)
}

@Test func systemLogCommandRunnerCancelsBeforeStartingTheProcess() async throws {
    let gate = SystemCommandStartGate()
    let startup = SystemCommandStartupRecorder()
    let runner = SystemLogCommandRunner(executableURL: URL(fileURLWithPath: "/bin/sleep"))
    let task = Task {
        await gate.wait()
        _ = try await runner.run(
            arguments: ["5"],
            initialOutputTimeout: nil,
            captureOutput: false,
            onStarted: startup.record,
            onReady: {},
            onOutput: { _ in }
        )
    }

    task.cancel()
    await gate.open()
    do {
        _ = try await task.value
        Issue.record("cancelled process unexpectedly returned a result")
    } catch is CancellationError {
        // Expected: cancellation before queue setup must not launch /usr/bin/sleep.
    }

    #expect(!startup.started)
}

@Test func systemLogCommandRunnerTerminatesAnActiveProcessOnCancellation() async throws {
    let startup = SystemCommandStartupRecorder()
    let runner = SystemLogCommandRunner(executableURL: URL(fileURLWithPath: "/bin/sleep"))
    let task = Task {
        try await runner.run(
            arguments: ["5"],
            initialOutputTimeout: nil,
            captureOutput: false,
            onStarted: startup.record,
            onReady: {},
            onOutput: { _ in }
        )
    }

    await startup.waitUntilStarted()
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("cancelled process unexpectedly returned a result")
    } catch is CancellationError {
        // Expected: task cancellation terminates the subprocess.
    }
}

@Test func systemLogCommandRunnerWaitsForPipeCleanupAfterOutputCancellation() async throws {
    let runner = SystemLogCommandRunner(executableURL: URL(fileURLWithPath: "/usr/bin/printf"))
    let outputGate = SystemCommandOutputGate()
    let task = Task {
        try await runner.run(
            arguments: ["output-before-cancel"],
            initialOutputTimeout: nil,
            captureOutput: false,
            onStarted: {},
            onReady: {},
            onOutput: { _ in outputGate.blockUntilReleased() }
        )
    }

    await outputGate.waitUntilBlocked()
    task.cancel()
    outputGate.release()
    do {
        _ = try await task.value
        Issue.record("cancelled process unexpectedly returned a result")
    } catch is CancellationError {
        // Cancellation waits for both pipes to close and suppresses later output.
    }

    let callbackCount = outputGate.callbackCount
    try await Task.sleep(for: .milliseconds(20))
    #expect(outputGate.callbackCount == callbackCount)
}

private func verifyMirrorFallback(for result: LogCommandResult) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("APKRun-LogReader-System-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = APKRunPaths(homeDirectory: directory)
    try FileManager.default.createDirectory(at: paths.logsRoot, withIntermediateDirectories: true)
    let timestamp = ISO8601DateFormatter().string(from: .now)
    let mirror = "\(timestamp) notice io.apkrun.runtime/host fallback-visible\n"
    try mirror.write(to: paths.daemonLogFile, atomically: true, encoding: .utf8)

    let runner = FakeLogCommandRunner(results: [result])
    let reader = LogReader(paths: paths, runner: runner)
    let events = LogReaderSystemEventRecorder()
    let report = try await reader.read(
        LogReadOptions(since: "1h"),
        onEvent: events.append
    )

    #expect(report.usedMirrors)
    #expect(report.emittedEntries == 1)
    #expect(events.entries.map(\.message) == ["fallback-visible"])
    #expect(events.mirrorNoticeCount == 1)
}

// UNCHECKED-SENDABLE: The lock protects the recorded entries and mirror notice count.
private final class LogReaderSystemEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEntries: [LogRecord] = []
    private var storedMirrorNoticeCount = 0

    var entries: [LogRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storedEntries
    }

    var mirrorNoticeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedMirrorNoticeCount
    }

    func append(_ event: LogReadEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .entry(let record):
            storedEntries.append(record)
        case .usingMirrors:
            storedMirrorNoticeCount += 1
        }
    }
}

// UNCHECKED-SENDABLE: The lock protects the started flag and waiter continuations.
private final class SystemCommandStartupRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var started: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didStart
    }

    func record() {
        lock.lock()
        didStart = true
        let pendingWaiters = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if didStart {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

private actor SystemCommandStartGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }
}

// UNCHECKED-SENDABLE: The lock and semaphore protect the output gate and its waiters.
private final class SystemCommandOutputGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var didStart = false
    private var storedCallbackCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var callbackCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCallbackCount
    }

    func blockUntilReleased() {
        lock.lock()
        storedCallbackCount += 1
        didStart = true
        let pendingWaiters = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pendingWaiters {
            waiter.resume()
        }
        semaphore.wait()
    }

    func waitUntilBlocked() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if didStart {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        semaphore.signal()
    }
}
