import Foundation
import Testing

@testable import RuntimeAPI

private func sharedFolderRoundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
    try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
}

@Test func sharedFolderDTOsRoundTripAndUseBookmarksForRootCreation() throws {
    let header = APIRequestHeader(clientKind: .app)
    let folder = SharedFolder(
        id: "shared",
        name: "Shared",
        path: "~/Library/Application Support/APKRun/Shared",
        access: .readOnly,
        builtIn: true,
        availability: .available
    )
    let bookmark = Data([0, 1, 2, 253, 254, 255])
    let listRequest = RuntimeSharedFoldersControlRequest(header: header)
    let addRequest = RuntimeAddSharedFolderControlRequest(
        header: header,
        request: AddSharedFolderRequest(bookmark: bookmark)
    )
    let removeRequest = RuntimeRemoveSharedFolderControlRequest(
        header: header,
        request: SharedFolderRequest(id: folder.id)
    )
    let accessRequest = RuntimeSetSharedFolderAccessControlRequest(
        header: header,
        request: SetSharedFolderAccessRequest(id: folder.id, access: .readWrite)
    )
    #expect(APIVersion.current == APIVersion(major: 1, minor: 14))
    #expect(try sharedFolderRoundTrip(folder) == folder)
    #expect(try sharedFolderRoundTrip(AddSharedFolderRequest(bookmark: bookmark)).access == .readOnly)
    #expect(try sharedFolderRoundTrip(listRequest) == listRequest)
    #expect(try sharedFolderRoundTrip(addRequest) == addRequest)
    #expect(try sharedFolderRoundTrip(removeRequest) == removeRequest)
    #expect(try sharedFolderRoundTrip(accessRequest) == accessRequest)
    #expect(
        try sharedFolderRoundTrip(RuntimeSharedFoldersControlReply(result: [folder]))
            == RuntimeSharedFoldersControlReply(result: [folder])
    )
    #expect(
        try sharedFolderRoundTrip(RuntimeAddSharedFolderControlReply(result: folder))
            == RuntimeAddSharedFolderControlReply(result: folder)
    )
    #expect(
        try sharedFolderRoundTrip(RuntimeRemoveSharedFolderControlReply())
            == RuntimeRemoveSharedFolderControlReply()
    )
    #expect(
        try sharedFolderRoundTrip(RuntimeSetSharedFolderAccessControlReply(result: folder))
            == RuntimeSetSharedFolderAccessControlReply(result: folder)
    )

    let addJSON = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(addRequest)) as? [String: Any]
    )
    let requestJSON = try #require(addJSON["request"] as? [String: Any])
    #expect(requestJSON["bookmark"] != nil)
    #expect(requestJSON["path"] == nil)
}

@Test func sharedFolderAvailabilityValuesHaveStableWireNames() throws {
    let values: [SharedFolderAvailability] = [.available, .missing, .privacyDenied, .offline, .unknown]
    for value in values {
        #expect(try sharedFolderRoundTrip(value) == value)
    }
    #expect(try JSONEncoder().encode(SharedFolderAccess.readWrite) == Data("\"readWrite\"".utf8))
}

@Test func sharedFolderErrorRepliesRoundTrip() throws {
    let failure = RuntimeWireError(
        domain: "integration",
        code: "integration.folderRefused",
        message: "The selected folder cannot be shared.",
        remediation: "Select a folder outside protected system locations."
    )
    #expect(
        try sharedFolderRoundTrip(RuntimeAddSharedFolderControlReply(error: failure))
            == RuntimeAddSharedFolderControlReply(error: failure)
    )
    #expect(
        try sharedFolderRoundTrip(RuntimeRemoveSharedFolderControlReply(error: failure))
            == RuntimeRemoveSharedFolderControlReply(error: failure)
    )
    #expect(
        try sharedFolderRoundTrip(RuntimeSetSharedFolderAccessControlReply(error: failure))
            == RuntimeSetSharedFolderAccessControlReply(error: failure)
    )
}
