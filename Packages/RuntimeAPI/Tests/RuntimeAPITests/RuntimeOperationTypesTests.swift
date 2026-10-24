import Foundation
import Testing

@testable import RuntimeAPI

private func roundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(Value.self, from: data)
}

@Test func operationIDUsesCanonicalLowercaseUUIDv4WireValue() throws {
    let uuid = try #require(UUID(uuidString: "41f9ed7b-a123-4ebd-9a61-7a2be9465780"))
    let operationID = try #require(OperationID(rawValue: uuid))

    #expect(operationID.rawValue == uuid)
    #expect(try roundTrip(operationID) == operationID)
    #expect(try JSONEncoder().encode(operationID) == Data(#""41f9ed7b-a123-4ebd-9a61-7a2be9465780""#.utf8))
    #expect(OperationID(wire: "41F9ED7B-A123-4EBD-9A61-7A2BE9465780") == nil)
    #expect(OperationID(wire: "41f9ed7b-a123-1ebd-9a61-7a2be9465780") == nil)
}

@Test func operationRequestFingerprintIsStableAndIncludesUninstallOptions() throws {
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let removeData = RuntimeUninstallPackageRequest(packageID: packageID)
    let keepData = RuntimeUninstallPackageRequest(
        packageID: packageID,
        options: RuntimeUninstallOptions(keepData: true)
    )

    let removeFingerprint = try RuntimeOperationRequestFingerprint.make(for: removeData)
    let repeatedFingerprint = try RuntimeOperationRequestFingerprint.make(for: removeData)
    let keepFingerprint = try RuntimeOperationRequestFingerprint.make(for: keepData)

    #expect(removeFingerprint == repeatedFingerprint)
    #expect(removeFingerprint != keepFingerprint)
    #expect(RuntimeSHA256Digest(rawValue: removeFingerprint) != nil)
}

@Test func operationDTOsRoundTrip() throws {
    let operationID = OperationID()
    let parent = OperationID()
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let summary = RuntimePackageSummary(
        packageID: packageID,
        displayName: "Hello Text",
        versionCode: 7,
        state: .installed
    )
    let failure = RuntimeWireError.store(
        "installFailed",
        message: "Android could not install the package.",
        remediation: "Check the runtime and retry."
    )
    let handle = OperationHandle(operationID: operationID, parent: parent, kind: .install)
    let progress = OperationProgress(
        fraction: 0.75,
        stage: "installing",
        bytes: 768,
        totalBytes: 1_024,
        message: "Installing Hello Text"
    )
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let finishedAt = Date(timeIntervalSince1970: 1_800_000_030)
    let running = OperationSnapshot(
        operationID: operationID,
        parent: parent,
        kind: .install,
        packageID: packageID,
        clientKind: .cli,
        startedAt: startedAt,
        progress: progress
    )
    let completed = OperationSnapshot(
        operationID: operationID,
        parent: parent,
        kind: .install,
        packageID: packageID,
        requestFingerprint: "sha256:\(String(repeating: "a", count: 64))",
        clientKind: .cli,
        startedAt: startedAt,
        progress: progress,
        result: .succeeded(.package(summary)),
        finishedAt: finishedAt
    )

    #expect(try roundTrip(handle) == handle)
    #expect(try roundTrip(progress) == progress)
    #expect(try roundTrip(OperationOutput.none) == .none)
    #expect(try roundTrip(OperationOutput.package(summary)) == .package(summary))
    let operationKinds: [OperationKind] = [
        .`import`, .inspect, .install, .uninstall, .repair, .rollback, .update, .updateCheck,
        .wrapperCreate, .wrapperRefresh, .wrapperRefreshAll, .distributionWrapper, .bootstrapImport,
        .setup, .resetAndroid, .runtimeStop, .runtimeRestart, .imageCheck, .imageDownload, .imageInstall,
        .imageApply, .imageRollback, .diagnostics,
    ]
    #expect(try operationKinds.map(roundTrip) == operationKinds)
    #expect(try roundTrip(OperationResult.succeeded(.package(summary))) == .succeeded(.package(summary)))
    #expect(try roundTrip(OperationResult.failed(failure)) == .failed(failure))
    #expect(try roundTrip(OperationResult.cancelled) == .cancelled)
    #expect(try roundTrip(OperationResult.unknown) == .unknown)
    #expect(try roundTrip(running) == running)
    #expect(try roundTrip(completed) == completed)
    var legacySnapshot = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(completed)) as? [String: Any]
    )
    legacySnapshot["requestFingerprint"] = nil
    let legacySnapshotData = try JSONSerialization.data(withJSONObject: legacySnapshot)
    #expect(try JSONDecoder().decode(OperationSnapshot.self, from: legacySnapshotData).requestFingerprint == nil)
    #expect(try roundTrip(CancelReply.cancelling) == .cancelling)
    #expect(
        try roundTrip(CancelReply.notCancellable(reason: "The package transaction committed."))
            == .notCancellable(
                reason: "The package transaction committed."
            ))
    #expect(
        try roundTrip(CancelReply.alreadyFinished(.succeeded(.package(summary))))
            == .alreadyFinished(.succeeded(.package(summary)))
    )
}

@Test func operationReplyEnumsDecodeUnknownFutureCases() throws {
    let decoder = JSONDecoder()
    let unknownString = Data(#""futureCase""#.utf8)
    let unknownCase = Data(#"{"futureCase":{}}"#.utf8)
    let unknownPayload = Data(#"{"futureCase":{"value":1}}"#.utf8)

    #expect(try decoder.decode(OperationKind.self, from: unknownString) == .unknown)
    #expect(try decoder.decode(OperationOutput.self, from: unknownCase) == .unknown)
    #expect(try decoder.decode(OperationOutput.self, from: unknownPayload) == .unknown)
    #expect(try decoder.decode(OperationResult.self, from: unknownCase) == .unknown)
    #expect(try decoder.decode(OperationResult.self, from: unknownPayload) == .unknown)
    #expect(try decoder.decode(CancelReply.self, from: unknownCase) == .unknown)
    #expect(try decoder.decode(CancelReply.self, from: unknownPayload) == .unknown)

    #expect(throws: EncodingError.self) {
        try JSONEncoder().encode(OperationKind.unknown)
    }
    #expect(throws: EncodingError.self) {
        try JSONEncoder().encode(OperationOutput.unknown)
    }
    #expect(throws: EncodingError.self) {
        try JSONEncoder().encode(CancelReply.unknown)
    }
}

@Test func operationControlRequestsAndRepliesRoundTrip() throws {
    let operationID = OperationID()
    let header = APIRequestHeader(operationID: operationID.rawValue, clientKind: .cli)
    let ticket = try #require(RuntimeImportTicket(rawValue: "84cfd2a0-504c-4dc2-9d6f-0f579f771902"))
    let installRequest = RuntimeInstallImportedRequest(ticket: ticket)
    let beginRequest = RuntimeBeginInstallImportedControlRequest(header: header, request: installRequest)
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let uninstallRequest = RuntimeUninstallPackageRequest(
        packageID: packageID,
        options: RuntimeUninstallOptions(keepData: true)
    )
    let beginUninstallRequest = RuntimeBeginUninstallPackageControlRequest(
        header: header,
        request: uninstallRequest
    )
    let cancelRequest = RuntimeCancelOperationControlRequest(header: header, operationID: operationID)
    let listRequest = RuntimeListOperationsControlRequest(header: header)
    let statusRequest = RuntimeOperationStatusControlRequest(header: header, operationID: operationID)
    let handle = OperationHandle(operationID: operationID, kind: .install)
    let uninstallHandle = OperationHandle(operationID: operationID, kind: .uninstall)
    let snapshot = OperationSnapshot(
        operationID: operationID,
        kind: .install,
        startedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let failure = RuntimeWireError.runtime(
        "operationNotFound",
        message: "The operation is no longer available."
    )

    #expect(try roundTrip(beginRequest) == beginRequest)
    #expect(try roundTrip(beginUninstallRequest) == beginUninstallRequest)
    #expect(try roundTrip(cancelRequest) == cancelRequest)
    #expect(try roundTrip(listRequest) == listRequest)
    #expect(try roundTrip(statusRequest) == statusRequest)
    #expect(
        try roundTrip(RuntimeBeginInstallImportedControlReply(result: handle))
            == RuntimeBeginInstallImportedControlReply(result: handle))
    #expect(
        try roundTrip(RuntimeBeginInstallImportedControlReply(error: failure))
            == RuntimeBeginInstallImportedControlReply(error: failure))
    #expect(
        try roundTrip(RuntimeBeginUninstallPackageControlReply(result: uninstallHandle))
            == RuntimeBeginUninstallPackageControlReply(result: uninstallHandle))
    #expect(
        try roundTrip(RuntimeBeginUninstallPackageControlReply(error: failure))
            == RuntimeBeginUninstallPackageControlReply(error: failure))
    #expect(
        try roundTrip(RuntimeCancelOperationControlReply(result: .cancelling))
            == RuntimeCancelOperationControlReply(result: .cancelling))
    #expect(
        try roundTrip(RuntimeCancelOperationControlReply(error: failure))
            == RuntimeCancelOperationControlReply(error: failure))
    #expect(
        try roundTrip(RuntimeListOperationsControlReply(result: [snapshot]))
            == RuntimeListOperationsControlReply(result: [snapshot]))
    #expect(
        try roundTrip(RuntimeListOperationsControlReply(error: failure))
            == RuntimeListOperationsControlReply(error: failure))
    #expect(
        try roundTrip(RuntimeOperationStatusControlReply(result: snapshot))
            == RuntimeOperationStatusControlReply(result: snapshot))
    #expect(
        try roundTrip(RuntimeOperationStatusControlReply(error: failure))
            == RuntimeOperationStatusControlReply(error: failure))

    for requestHeader in [
        beginRequest.header,
        beginUninstallRequest.header,
        cancelRequest.header,
        listRequest.header,
        statusRequest.header,
    ] {
        #expect(requestHeader.apiVersion == APIVersion(major: 1, minor: 13))
        #expect(requestHeader.clientKind == .cli)
    }
}
