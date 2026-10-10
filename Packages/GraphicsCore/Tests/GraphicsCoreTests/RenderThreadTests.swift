import Foundation
import Testing

@testable import GraphicsCore

/// A small thread-safe record that the render-thread closures append to.
private final class Record: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    func append(_ value: Int) {
        lock.withLock { values.append(value) }
    }

    var snapshot: [Int] {
        lock.withLock { values }
    }
}

@Test func workRunsInSubmissionOrderOnTheRenderThread() async throws {
    let thread = RenderThread(name: "io.apkrun.graphics.test-order")
    thread.start()
    let record = Record()
    for value in 0..<200 {
        thread.submit { record.append(value) }
    }
    let onThread = thread.sync { () -> Bool in true }
    #expect(onThread == true)
    #expect(record.snapshot == Array(0..<200))
    thread.stop()
    try await eventually { thread.hasExited }
}

@Test func syncReturnsTheResultOfWorkOnTheRenderThread() async throws {
    let thread = RenderThread(name: "io.apkrun.graphics.test-sync")
    thread.start()
    let value = thread.sync { () -> String in
        "computed"
    }
    #expect(value == "computed")
    let onRenderThread = thread.sync { thread.isCurrentThread }
    #expect(onRenderThread == true)
    #expect(thread.isCurrentThread == false)
    thread.stop()
    try await eventually { thread.hasExited }
}

@Test func aSyncCallFromTheRenderThreadRunsInline() async throws {
    let thread = RenderThread(name: "io.apkrun.graphics.test-inline")
    thread.start()
    let nested = thread.sync { () -> Int in
        thread.sync { () -> Int in 41 } ?? 0
    }
    #expect(nested == 41)
    thread.stop()
    try await eventually { thread.hasExited }
}

@Test func workRunsBeforeTheThreadStopsAndSyncAfterStopReturnsNil() async throws {
    let thread = RenderThread(name: "io.apkrun.graphics.test-stop")
    thread.start()
    let record = Record()
    thread.submit { record.append(1) }
    thread.stop()
    try await eventually { thread.hasExited }
    #expect(record.snapshot == [1])
    #expect(thread.sync { () -> Int in 5 } == nil)
}

@Test func pollingRunsWhileRequestedAndStopsWhenTheHandlerSaysSo() async throws {
    let thread = RenderThread(name: "io.apkrun.graphics.test-poll")
    let polls = Record()
    thread.setPollHandler {
        polls.append(1)
        return polls.snapshot.count < 20
    }
    thread.start()
    thread.sync { thread.requestPolling() }
    try await eventually { polls.snapshot.count >= 20 }
    try await Task.sleep(for: .milliseconds(50))
    let settled = polls.snapshot.count
    try await Task.sleep(for: .milliseconds(50))
    #expect(polls.snapshot.count == settled)
    thread.stop()
    try await eventually { thread.hasExited }
}

@Test func aPollRequestNeverRunsTheHandlerWithoutAPendingRequest() async throws {
    let thread = RenderThread(name: "io.apkrun.graphics.test-idle")
    let polls = Record()
    thread.setPollHandler {
        polls.append(1)
        return true
    }
    thread.start()
    _ = thread.sync { () -> Bool in true }
    try await Task.sleep(for: .milliseconds(20))
    #expect(polls.snapshot.isEmpty)
    thread.stop()
    try await eventually { thread.hasExited }
}
