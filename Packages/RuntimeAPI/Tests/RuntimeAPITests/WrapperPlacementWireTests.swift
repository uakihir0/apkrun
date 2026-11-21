import Foundation
import Testing

@testable import RuntimeAPI

private func placementRoundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(Value.self, from: data)
}

/// T0 of #57: DTO round trips of `placeStagedWrapper` (runtime-api.md §10.3).
@Test func placeStagedWrapperRequestAndReplyRoundTrip() throws {
    let request = RuntimePlaceStagedWrapperControlRequest(
        header: APIRequestHeader(
            apiVersion: APIVersion(major: 1, minor: 21),
            operationID: UUID(),
            clientKind: .cli
        ),
        stagingToken: "tok-1",
        finalURL: URL(fileURLWithPath: "/Users/x/Desktop/HelloText.app"),
        bookmark: "Ym9va21hcms="
    )
    #expect(try placementRoundTrip(request) == request)

    let reply = RuntimePlaceStagedWrapperControlReply(
        error: RuntimeWireError(
            domain: "wrapper",
            code: "wrapper.stagingExpired",
            message: "The prepared Mac app is no longer available.",
            parameters: ["stagingToken": "tok-1"]
        )
    )
    #expect(try placementRoundTrip(reply) == reply)
}
