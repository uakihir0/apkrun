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

private actor SessionImportSpy: RuntimeSessionService {
    private(set) var lastSessionID: UUID?
    private(set) var importCount = 0

    func launch(_ request: RuntimeLaunchRequest) async throws(RuntimeWireError) -> RuntimeLaunchResult {
        throw .runtime("internal", message: "Not used by this test.")
    }

    func terminate(_ request: RuntimeTerminateRequest) async throws(RuntimeWireError) -> RuntimeTerminateResult {
        throw .runtime("internal", message: "Not used by this test.")
    }

    func importFiles(_ request: ImportFilesRequest, files: [FileHandle]) async throws(RuntimeWireError) -> ImportResult {
        lastSessionID = request.sessionID
        importCount += 1
        return ImportResult(
            contentURIs: ["content://io.apkrun.guest.files/import/notes"],
            disposition: .shared
        )
    }
}
