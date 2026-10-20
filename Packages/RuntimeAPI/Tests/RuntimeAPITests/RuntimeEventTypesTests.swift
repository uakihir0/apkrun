import Foundation
import Testing

@testable import RuntimeAPI

private func eventRoundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(Value.self, from: data)
}

@Test func eventTopicsAndSubscriptionDTOsRoundTrip() throws {
    let header = APIRequestHeader(clientKind: .cli)
    let topics: [EventTopic] = [
        .runtime, .sessions, .packages, .updates, .operations, .health, .maintenance, .wrappers, .integrations,
    ]
    let subscribe = RuntimeSubscribeControlRequest(header: header, topics: [.operations, .packages])
    let unsubscribe = RuntimeUnsubscribeControlRequest(header: header, topics: [.operations])

    #expect(APIVersion.current == APIVersion(major: 1, minor: 9))
    #expect(try topics.map(eventRoundTrip) == topics)
    #expect(try eventRoundTrip(subscribe) == subscribe)
    #expect(try eventRoundTrip(unsubscribe) == unsubscribe)
    #expect(
        try eventRoundTrip(RuntimeSubscribeControlReply(result: [.operations, .packages]))
            == RuntimeSubscribeControlReply(result: [.operations, .packages])
    )
    let subscribeError = RuntimeWireError.runtime(
        "notAuthorized",
        message: "Not authorized.",
        remediation: "Reconnect."
    )
    #expect(
        try eventRoundTrip(RuntimeSubscribeControlReply(error: subscribeError))
            == RuntimeSubscribeControlReply(error: subscribeError)
    )
    #expect(try eventRoundTrip(RuntimeUnsubscribeControlReply()) == RuntimeUnsubscribeControlReply())
    #expect(
        try eventRoundTrip(
            RuntimeUnsubscribeControlReply(
                error: .runtime("notAuthorized", message: "Not authorized.", remediation: "Reconnect.")
            )
        )
            == RuntimeUnsubscribeControlReply(
                error: .runtime("notAuthorized", message: "Not authorized.", remediation: "Reconnect.")
            )
    )
}

@Test func operationEventsAndEnvelopesRoundTrip() throws {
    let operationID = OperationID()
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let summary = RuntimePackageSummary(
        packageID: packageID, displayName: "Hello Text", versionCode: 7, state: .installed)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let progress = OperationProgress(fraction: 0.5, stage: "installing", bytes: 512, totalBytes: 1_024)
    let running = OperationSnapshot(
        operationID: operationID,
        kind: .install,
        packageID: packageID,
        clientKind: .cli,
        startedAt: now,
        progress: progress
    )
    let finished = OperationResult.succeeded(.package(summary))
    let operationEvents: [OperationEvent] = [
        .started(running),
        .progress(operationID, progress),
        .finished(operationID, finished),
    ]
    let envelopes = [
        EventEnvelope(
            topic: .operations,
            seq: 1,
            time: now,
            operationID: operationID,
            payload: .operations(.started(running))
        ),
        EventEnvelope(
            topic: .operations,
            seq: 2,
            time: now,
            operationID: operationID,
            payload: .operations(.progress(operationID, progress))
        ),
        EventEnvelope(
            topic: .operations,
            seq: 3,
            time: now,
            operationID: operationID,
            payload: .operations(.finished(operationID, finished))
        ),
        EventEnvelope(topic: .packages, seq: 4, time: now, payload: .resyncRequired(.packages)),
    ]

    #expect(try operationEvents.map(eventRoundTrip) == operationEvents)
    #expect(try envelopes.map(eventRoundTrip) == envelopes)
    #expect(try eventRoundTrip(envelopes) == envelopes)
}

@Test func eventPayloadAndOperationEventPreserveFutureCasesAsUnknown() throws {
    let decoder = JSONDecoder()
    let futureWithoutPayload = Data(#"{"futureCase":{}}"#.utf8)
    let futureWithPayload = Data(#"{"futureCase":{"value":1}}"#.utf8)
    let futureScalarPayload = Data(#"{"futureCase":"new-tag"}"#.utf8)

    #expect(try decoder.decode(EventPayload.self, from: futureWithoutPayload) == .unknown)
    #expect(try decoder.decode(EventPayload.self, from: futureWithPayload) == .unknown)
    #expect(try decoder.decode(EventPayload.self, from: futureScalarPayload) == .unknown)
    #expect(try decoder.decode(OperationEvent.self, from: futureWithoutPayload) == .unknown)
    #expect(try decoder.decode(OperationEvent.self, from: futureWithPayload) == .unknown)
    #expect(try decoder.decode(OperationEvent.self, from: futureScalarPayload) == .unknown)
    #expect(throws: EncodingError.self) {
        try JSONEncoder().encode(EventPayload.unknown)
    }
    #expect(throws: EncodingError.self) {
        try JSONEncoder().encode(OperationEvent.unknown)
    }
}
