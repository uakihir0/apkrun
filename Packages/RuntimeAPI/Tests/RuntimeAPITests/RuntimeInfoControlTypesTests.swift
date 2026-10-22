import Foundation
import Testing

@testable import RuntimeAPI

@Test func runtimeInfoControlDTOsRoundTripRequestsAndReplies() throws {
    let request = RuntimeInfoControlRequest(
        header: controlHeader(),
        request: RuntimeInfoRequest(resources: true, displays: true)
    )
    let requestData = try JSONEncoder().encode(request)
    let decodedRequest = try JSONDecoder().decode(RuntimeInfoControlRequest.self, from: requestData)
    let requestObject = try #require(try JSONSerialization.jsonObject(with: requestData) as? [String: Any])
    let requestPayload = try #require(requestObject["request"] as? [String: Bool])
    #expect(decodedRequest == request)
    #expect(requestPayload == ["resources": true, "displays": true])

    let info = runtimeInfoFixture()
    let success = RuntimeInfoControlReply(result: info)
    let decodedSuccess = try roundTrip(success)
    let successObject = try #require(
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(success)) as? [String: Any]
    )
    #expect(decodedSuccess == success)
    #expect(successObject["result"] != nil)
    #expect(successObject["error"] == nil)

    let error = RuntimeWireError.runtime(
        "hostUnavailable",
        message: "The runtime status is not available.",
        remediation: "Open APKRun and try again."
    )
    let failure = RuntimeInfoControlReply(error: error)
    let decodedFailure = try roundTrip(failure)
    let failureObject = try #require(
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(failure)) as? [String: Any]
    )
    #expect(decodedFailure == failure)
    #expect(failureObject["result"] == nil)
    #expect(failureObject["error"] != nil)
}

@Test func runtimeInfoControlReplyRequiresExactlyOneOutcome() throws {
    let successData = try JSONEncoder().encode(RuntimeInfoControlReply(result: runtimeInfoFixture()))
    let successObject = try #require(try JSONSerialization.jsonObject(with: successData) as? [String: Any])
    var bothOutcomes = successObject
    bothOutcomes["error"] = [
        "domain": "runtime",
        "code": "runtime.hostUnavailable",
        "message": "The runtime status is not available.",
    ]

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(
            RuntimeInfoControlReply.self,
            from: JSONSerialization.data(withJSONObject: bothOutcomes)
        )
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(
            RuntimeInfoControlReply.self,
            from: Data(#"{"result":null,"error":null}"#.utf8)
        )
    }
}

@Test func listSessionsControlDTOsRoundTripRequestsAndReplies() throws {
    let request = RuntimeListSessionsControlRequest(header: controlHeader())
    let requestData = try JSONEncoder().encode(request)
    let decodedRequest = try JSONDecoder().decode(RuntimeListSessionsControlRequest.self, from: requestData)
    let requestObject = try #require(try JSONSerialization.jsonObject(with: requestData) as? [String: Any])
    #expect(decodedRequest == request)
    #expect(requestObject["header"] != nil)
    #expect(requestObject["result"] == nil)

    let sessions = [try sessionSummaryFixture()]
    let success = RuntimeListSessionsControlReply(result: sessions)
    let decodedSuccess = try roundTrip(success)
    let successObject = try #require(
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(success)) as? [String: Any]
    )
    #expect(decodedSuccess == success)
    #expect(successObject["result"] is [[String: Any]])
    #expect(successObject["error"] == nil)

    let empty = RuntimeListSessionsControlReply(result: [])
    #expect(try roundTrip(empty) == empty)
    let failure = RuntimeListSessionsControlReply(error: runtimeInfoFailure())
    #expect(try roundTrip(failure) == failure)
}

@Test func listSessionsControlReplyRequiresExactlyOneOutcome() throws {
    let successData = try JSONEncoder().encode(
        RuntimeListSessionsControlReply(result: [try sessionSummaryFixture()])
    )
    let successObject = try #require(try JSONSerialization.jsonObject(with: successData) as? [String: Any])
    var bothOutcomes = successObject
    bothOutcomes["error"] = [
        "domain": "runtime",
        "code": "runtime.hostUnavailable",
        "message": "The session list is not available.",
    ]

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(
            RuntimeListSessionsControlReply.self,
            from: JSONSerialization.data(withJSONObject: bothOutcomes)
        )
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(
            RuntimeListSessionsControlReply.self,
            from: Data(#"{"result":null,"error":null}"#.utf8)
        )
    }
}

private func roundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
    try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
}

private func controlHeader() -> APIRequestHeader {
    APIRequestHeader(
        operationID: UUID(uuidString: "4ac39dbb-66ca-4800-b8f9-14a2018cc8ee")!,
        clientKind: .cli
    )
}

private func runtimeInfoFixture() -> RuntimeInfo {
    RuntimeInfo(
        status: RuntimeHostStatus(
            hostState: "running",
            runtimeState: "ready",
            bootProgress: nil,
            startupFailureStep: nil,
            startupFailureCode: nil,
            crashLoopActive: false,
            daemonPID: 42,
            imageVersion: "2026.10.0-cf16373615-arm64"
        ),
        sizing: RuntimeSizing(cpuCount: 4, memoryGiB: 6, userdataGiB: 32),
        displayPoolSize: 3,
        resources: ResourceUsage(daemonPhysicalFootprintBytes: 4_194_304),
        displays: []
    )
}

private func sessionSummaryFixture() throws -> SessionSummary {
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    return SessionSummary(
        sessionID: UUID(uuidString: "ea9bf3b2-0520-4ed7-a5ab-13cda15bc481")!,
        packageID: packageID,
        displayName: "Hello Text",
        state: .running,
        clientKind: .wrapper,
        openedAt: Date(timeIntervalSince1970: 1_800_000_000),
        windowMode: .secondaryDisplay,
        recording: false
    )
}

private func runtimeInfoFailure() -> RuntimeWireError {
    RuntimeWireError.runtime(
        "hostUnavailable",
        message: "The session list is not available.",
        remediation: "Open APKRun and try again."
    )
}
