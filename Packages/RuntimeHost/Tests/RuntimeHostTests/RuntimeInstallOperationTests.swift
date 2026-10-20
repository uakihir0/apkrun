import DiagnosticsCore
import Foundation
import RuntimeAPI
import Testing

@testable import RuntimeHost

@Test(.timeLimit(.minutes(1)))
func installOperationReturnsHandleAndRetainsItsTerminalFailure() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RuntimeInstallOperation-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": root.path]
    )
    let host = RuntimeHost(
        paths: paths,
        buildInfo: BuildInfo(infoDictionary: [
            "CFBundleShortVersionString": "0.2.0",
            "CFBundleVersion": "200",
            "APKRunBuildIdentity": "dev",
        ]),
        environment: [:],
        executableURL: root.appendingPathComponent("apkrund")
    )
    try await host.start { ContinuousClock.now }
    defer { Task { await host.shutdown() } }
    let packageEvents = InstallOperationEventSink()
    let connectionID = ObjectIdentifier(packageEvents)
    _ = try host.eventHub.subscribe(
        connectionID: connectionID,
        clientKind: .cli,
        topics: [.packages],
        sink: RuntimeEventSinkReference(value: packageEvents),
        outputQueue: DispatchQueue(label: "RuntimeInstallOperationTests.packages"),
        isConnectionOpen: { true }
    )
    defer { host.eventHub.remove(connectionID: connectionID) }

    let operationID = RuntimeAPI.OperationID()
    let ticket = try #require(
        RuntimeImportTicket(rawValue: "84cfd2a0-504c-4dc2-9d6f-0f579f771902")
    )
    let request = RuntimeInstallImportedRequest(ticket: ticket)
    let handle = try await host.beginInstallImported(
        request,
        operationID: operationID,
        clientKind: .cli
    )
    let duplicate = try await host.beginInstallImported(
        request,
        operationID: operationID,
        clientKind: .cli
    )

    #expect(handle == duplicate)
    #expect(handle.operationID == operationID)
    #expect(handle.kind == .install)

    var finalSnapshot = try await host.operationStatus(operationID)
    for _ in 0..<100 where finalSnapshot.result == nil {
        try await Task.sleep(for: .milliseconds(10))
        finalSnapshot = try await host.operationStatus(operationID)
    }
    guard case .failed(let error)? = finalSnapshot.result else {
        Issue.record("Expected the operation to retain its startup failure.")
        return
    }

    #expect(error.code == "image.noCurrentImage")
    #expect(finalSnapshot.finishedAt != nil)
    #expect(await host.listOperations().filter { $0.operationID == operationID }.count == 1)
    #expect(try await host.cancelOperation(operationID) == .alreadyFinished(.failed(error)))
    try await Task.sleep(for: .milliseconds(40))
    #expect(try packageEvents.envelopes().isEmpty)
}

private final class InstallOperationEventSink: NSObject, RuntimeEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [Data] = []

    func handshake(reply: @escaping (Bool) -> Void) {
        reply(true)
    }

    func deliver(_ batch: Data, reply: @escaping () -> Void) {
        lock.lock()
        batches.append(batch)
        lock.unlock()
        reply()
    }

    func envelopes() throws -> [EventEnvelope] {
        lock.lock()
        let captured = batches
        lock.unlock()
        return try captured.flatMap { try JSONDecoder().decode([EventEnvelope].self, from: $0) }
    }
}
