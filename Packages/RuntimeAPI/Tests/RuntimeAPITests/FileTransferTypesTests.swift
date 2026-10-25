import Foundation
import Testing

@testable import RuntimeAPI

private func fileTransferRoundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(Value.self, from: data)
}

@Test func importFileRequestsAndResultsRoundTrip() throws {
    let request = ImportFilesRequest(
        files: [
            ImportFileInfo(fileIndex: 0, name: "notes.txt", size: 2048, uti: "public.plain-text"),
            ImportFileInfo(fileIndex: 1, name: "photo.png", size: 8192, uti: "public.png"),
        ],
        target: .shareToApp
    )
    let result = ImportResult(
        contentURIs: [
            "content://io.apkrun.guest.files/import/notes",
            "content://io.apkrun.guest.files/import/photo",
        ],
        disposition: .shared
    )
    let header = APIRequestHeader(clientKind: .wrapper)
    let sessionRequest = RuntimeImportFilesSessionRequest(header: header, request: request)
    let sessionReply = RuntimeImportFilesSessionReply(result: result)

    #expect(try fileTransferRoundTrip(request) == request)
    #expect(try fileTransferRoundTrip(result) == result)
    #expect(try fileTransferRoundTrip(sessionRequest) == sessionRequest)
    #expect(try fileTransferRoundTrip(sessionReply) == sessionReply)
    let encodedRequest = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(sessionRequest)) as? [String: Any]
    )
    let encodedImport = try #require(encodedRequest["request"] as? [String: Any])
    #expect(encodedImport["sessionID"] == nil)
    #expect(
        try fileTransferRoundTrip(
            RuntimeImportFilesSessionReply(
                error: RuntimeWireError(
                    domain: "integration",
                    code: "integration.transferFailed",
                    message: "Files could not be transferred.",
                    remediation: "Try sharing them again."
                )
            )
        ).error?.code == "integration.transferFailed"
    )
}
