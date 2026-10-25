import Foundation
import Testing

@testable import RuntimeAPI

private func fileTransferRoundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(Value.self, from: data)
}

@Test func importFileRequestsAndResultsRoundTrip() throws {
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellofiles"))
    let displayID = try #require(DisplayID(rawValue: "f19b7331-f940-4ce6-91d1-a0f979d08f3f"))
    let request = ImportFilesRequest(
        packageID: packageID,
        displayID: displayID,
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
    let header = APIRequestHeader(clientKind: .launcher)
    let controlRequest = RuntimeImportFilesControlRequest(header: header, request: request)
    let controlReply = RuntimeImportFilesControlReply(result: result)

    #expect(try fileTransferRoundTrip(request) == request)
    #expect(try fileTransferRoundTrip(result) == result)
    #expect(try fileTransferRoundTrip(controlRequest) == controlRequest)
    #expect(try fileTransferRoundTrip(controlReply) == controlReply)
    #expect(
        try fileTransferRoundTrip(
            RuntimeImportFilesControlReply(
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
