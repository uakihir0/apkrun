import DiagnosticsCore
import Foundation
import RuntimeAPI
import Testing

@testable import RuntimeHost

@Test(.timeLimit(.minutes(1)))
func installOperationRejectsAnExpiredTicketBeforeStartingAndroid() async throws {
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
    do {
        _ = try await host.beginInstallImported(
            request,
            operationID: operationID,
            clientKind: .cli
        )
        Issue.record("An expired import ticket must be rejected before an operation starts.")
    } catch {
        #expect(error.code == "store.importTicketExpired")
    }

    #expect(await host.status().runtimeState == "stopped")
    #expect(try await host.listOperations().isEmpty)
    #expect(try packageEvents.envelopes().isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func forgetOperationDoesNotBootAndroidOrPublishPackageRemoval() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RuntimeForgetOperation-\(UUID().uuidString)", isDirectory: true)
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
        outputQueue: DispatchQueue(label: "RuntimeForgetOperationTests.packages"),
        isConnectionOpen: { true }
    )
    defer { host.eventHub.remove(connectionID: connectionID) }

    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let request = RuntimeUninstallPackageRequest(
        packageID: packageID,
        options: RuntimeUninstallOptions(forget: true)
    )
    let operationID = RuntimeAPI.OperationID()
    let handle = try await host.beginUninstallPackage(
        request,
        operationID: operationID,
        clientKind: .cli
    )
    let duplicate = try await host.beginUninstallPackage(
        request,
        operationID: operationID,
        clientKind: .cli
    )
    let conflictingRequest = RuntimeUninstallPackageRequest(
        packageID: packageID,
        options: RuntimeUninstallOptions(keepData: true)
    )

    #expect(handle == duplicate)
    #expect(handle.kind == RuntimeAPI.OperationKind.uninstall)
    do {
        _ = try await host.beginUninstallPackage(
            conflictingRequest,
            operationID: operationID,
            clientKind: .cli
        )
        Issue.record("An operation ID cannot be reused for a different uninstall request.")
    } catch let error {
        #expect(error.code == "runtime.malformedRequest")
    }

    var finalSnapshot = try await host.operationStatus(operationID)
    for _ in 0..<100 where finalSnapshot.result == nil {
        try await Task.sleep(for: .milliseconds(10))
        finalSnapshot = try await host.operationStatus(operationID)
    }
    guard case .failed(let error)? = finalSnapshot.result else {
        Issue.record("Expected forgetting a missing managed package to fail.")
        return
    }

    #expect(error.code == "store.packageNotFound")
    #expect(await host.status().runtimeState == "stopped")
    #expect(try packageEvents.envelopes().isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func uninstallOperationRejectsKeepingDataWhileForgetting() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RuntimeInvalidUninstall-\(UUID().uuidString)", isDirectory: true)
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
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let request = RuntimeUninstallPackageRequest(
        packageID: packageID,
        options: RuntimeUninstallOptions(keepData: true, forget: true)
    )

    do {
        _ = try await host.beginUninstallPackage(
            request,
            operationID: OperationID(),
            clientKind: .cli
        )
        Issue.record("Incompatible uninstall options must be rejected before an operation starts.")
    } catch let error {
        #expect(error.code == "runtime.malformedRequest")
    }

    #expect(await host.listOperations().isEmpty)
    #expect(await host.status().runtimeState == "stopped")
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
