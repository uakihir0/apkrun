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
}
