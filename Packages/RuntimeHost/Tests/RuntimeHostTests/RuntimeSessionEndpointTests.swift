import Foundation
import RuntimeAPI
import Testing

@testable import RuntimeHost

@Test func sessionEndpointBindsTheCapturedSessionAndIgnoresPayloadIdentity() async throws {
    let sessionID = try #require(UUID(uuidString: "f19b7331-f940-4ce6-91d1-a0f979d08f3f"))
    let attackerSessionID = try #require(UUID(uuidString: "aeb02299-2a11-4e70-96c5-1ca9a8418bad"))
    let service = SessionImportSpy()
    let endpoint = RuntimeSessionEndpointService(sessionID: sessionID, service: service)
    let request = RuntimeImportFilesSessionRequest(
        header: APIRequestHeader(clientKind: .wrapper),
        request: ImportFilesRequest(
            files: [ImportFileInfo(fileIndex: 0, name: "notes.txt", size: 1, uti: "public.plain-text")],
            target: .shareToApp
        )
    )
    var envelope = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    var importRequest = try #require(envelope["request"] as? [String: Any])
    importRequest["sessionID"] = attackerSessionID.uuidString
    envelope["request"] = importRequest
    let requestData = try JSONSerialization.data(withJSONObject: envelope)

    let replyData = await receiveReply(
        from: endpoint,
        request: requestData,
        files: [FileHandle.nullDevice]
    )
    let reply = try JSONDecoder().decode(RuntimeImportFilesSessionReply.self, from: replyData)

    #expect(reply.result?.disposition == .shared)
    #expect(reply.error == nil)
    #expect(await service.lastSessionID == sessionID)
    #expect(await service.importCount == 1)
}

@Test func sessionEndpointRejectsNonWrapperHeadersBeforeForwarding() async throws {
    let service = SessionImportSpy()
    let endpoint = RuntimeSessionEndpointService(sessionID: UUID(), service: service)
    let request = RuntimeImportFilesSessionRequest(
        header: APIRequestHeader(clientKind: .launcher),
        request: ImportFilesRequest(
            files: [ImportFileInfo(fileIndex: 0, name: "notes.txt", size: 1, uti: "public.plain-text")],
            target: .shareToApp
        )
    )
    let replyData = await receiveReply(
        from: endpoint,
        request: try JSONEncoder().encode(request),
        files: [FileHandle.nullDevice]
    )
    let reply = try JSONDecoder().decode(RuntimeImportFilesSessionReply.self, from: replyData)

    #expect(reply.result == nil)
    #expect(reply.error?.code == "runtime.notAuthorized")
    #expect(await service.importCount == 0)
}

@Test func sessionEndpointBindsTheCapturedSessionForExport() async throws {
    let sessionID = try #require(UUID(uuidString: "f19b7331-f940-4ce6-91d1-a0f979d08f3f"))
    let attackerSessionID = try #require(UUID(uuidString: "aeb02299-2a11-4e70-96c5-1ca9a8418bad"))
    let service = SessionImportSpy()
    let endpoint = RuntimeSessionEndpointService(sessionID: sessionID, service: service)
    let request = RuntimeAcceptExportSessionRequest(
        header: APIRequestHeader(clientKind: .wrapper),
        request: AcceptExportRequest(offerID: UUID(), fileIndex: 0)
    )
    var envelope = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    var exportRequest = try #require(envelope["request"] as? [String: Any])
    exportRequest["sessionID"] = attackerSessionID.uuidString
    envelope["request"] = exportRequest
    let requestData = try JSONSerialization.data(withJSONObject: envelope)

    let replyData = await receiveExportReply(
        from: endpoint,
        request: requestData,
        file: FileHandle.nullDevice
    )
    let reply = try JSONDecoder().decode(RuntimeAcceptExportSessionReply.self, from: replyData)

    #expect(reply.result != nil)
    #expect(reply.error == nil)
    #expect(await service.lastExportSessionID == sessionID)
    #expect(await service.exportCount == 1)
}

@Test func sessionEndpointRejectsExportHandleIndexMismatch() async throws {
    let service = SessionImportSpy()
    let endpoint = RuntimeSessionEndpointService(sessionID: UUID(), service: service)
    let request = RuntimeAcceptExportSessionRequest(
        header: APIRequestHeader(clientKind: .wrapper),
        request: AcceptExportRequest(offerID: UUID(), fileIndex: nil)
    )
    let replyData = await receiveExportReply(
        from: endpoint,
        request: try JSONEncoder().encode(request),
        file: FileHandle.nullDevice
    )
    let reply = try JSONDecoder().decode(RuntimeAcceptExportSessionReply.self, from: replyData)

    #expect(reply.result == nil)
    #expect(reply.error?.code == "integration.transferFailed")
    #expect(await service.exportCount == 0)
}

private func receiveReply(
    from endpoint: RuntimeSessionEndpointService,
    request: Data,
    files: [FileHandle]
) async -> Data {
    await withCheckedContinuation { continuation in
        endpoint.importFiles(request, files: files) { response in
            continuation.resume(returning: response)
        }
    }
}

private func receiveExportReply(
    from endpoint: RuntimeSessionEndpointService,
    request: Data,
    file: FileHandle?
) async -> Data {
    await withCheckedContinuation { continuation in
        endpoint.acceptExport(request, file: file) { response in
            continuation.resume(returning: response)
        }
    }
}

private actor SessionImportSpy: RuntimeSessionService {
    private(set) var lastSessionID: UUID?
    private(set) var importCount = 0
    private(set) var lastExportSessionID: UUID?
    private(set) var exportCount = 0

    func launch(_ request: RuntimeLaunchRequest) async throws(RuntimeWireError) -> RuntimeLaunchResult {
        throw .runtime("internal", message: "Not used by this test.")
    }

    func terminate(_ request: RuntimeTerminateRequest) async throws(RuntimeWireError) -> RuntimeTerminateResult {
        throw .runtime("internal", message: "Not used by this test.")
    }

    func importFiles(
        _ request: ImportFilesRequest,
        files: [FileHandle]
    ) async throws(RuntimeWireError) -> ImportResult {
        lastSessionID = request.sessionID
        importCount += 1
        return ImportResult(
            contentURIs: ["content://io.apkrun.guest.files/import/notes"],
            disposition: .shared
        )
    }

    func acceptExport(
        _ request: AcceptExportRequest,
        file: FileHandle?
    ) async throws(RuntimeWireError) {
        lastExportSessionID = request.sessionID
        exportCount += 1
    }
}
