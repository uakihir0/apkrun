import Foundation
import Testing

@_spi(APKRunSessionBinding) @testable import RuntimeAPI

@Test func exportOfferAndAcceptRequestRoundTripWithoutSessionIdentity() throws {
    let offerID = UUID()
    let offer = ExportOffer(
        offerID: offerID,
        name: "report.pdf",
        size: 4096,
        type: "application/pdf"
    )
    let accept = AcceptExportRequest(offerID: offerID, fileIndex: 0)
    let cancel = AcceptExportRequest(offerID: offerID, fileIndex: nil)

    #expect(try exportRoundTrip(offer) == offer)
    #expect(try exportRoundTrip(accept) == accept)
    #expect(try exportRoundTrip(cancel) == cancel)

    let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(accept)) as? [String: Any])
    #expect(encoded["sessionID"] == nil)

    let injectedIdentity = Data(
        """
        {"offerID":"\(offerID.uuidString)","fileIndex":0,"sessionID":"00000000-0000-0000-0000-000000000001"}
        """.utf8
    )
    let decoded = try JSONDecoder().decode(AcceptExportRequest.self, from: injectedIdentity)
    #expect(decoded.offerID == offerID)
    #expect(decoded.fileIndex == 0)
    #expect(decoded.sessionID != UUID(uuidString: "00000000-0000-0000-0000-000000000001"))

    let sessionID = UUID()
    #expect(accept.bound(to: sessionID).sessionID == sessionID)
}

@Test func acceptExportSessionRequestRoundTripsTypedReplies() throws {
    let request = RuntimeAcceptExportSessionRequest(
        header: APIRequestHeader(clientKind: .wrapper),
        request: AcceptExportRequest(offerID: UUID(), fileIndex: nil)
    )
    let success = RuntimeAcceptExportSessionReply()
    let failure = RuntimeAcceptExportSessionReply(
        error: RuntimeWireError(
            domain: "integration",
            code: "integration.transferFailed",
            message: "The file could not be saved.",
            remediation: "Choose a destination and retry."
        )
    )

    #expect(try exportRoundTrip(request) == request)
    #expect(try exportRoundTrip(success) == success)
    #expect(try exportRoundTrip(failure) == failure)
}

private func exportRoundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(Value.self, from: data)
}
