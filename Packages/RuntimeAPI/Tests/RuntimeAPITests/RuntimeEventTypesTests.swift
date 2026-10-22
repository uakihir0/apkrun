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

    #expect(APIVersion.current == APIVersion(major: 1, minor: 15))
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

@Test func packageChangesAndEnvelopesRoundTrip() throws {
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let summary = RuntimePackageSummary(
        packageID: packageID,
        displayName: "Hello Text",
        versionCode: 7,
        state: .installed
    )
    let changes: [PackageChange] = [
        .installed(summary),
        .updated(summary, from: 6),
        .removed(packageID, keptData: true),
    ]
    let envelopes = changes.enumerated().map { index, change in
        EventEnvelope(
            topic: .packages,
            seq: UInt64(index + 1),
            time: now,
            payload: .packages(change)
        )
    }

    #expect(try changes.map(eventRoundTrip) == changes)
    #expect(try envelopes.map(eventRoundTrip) == envelopes)
    #expect(
        try JSONDecoder().decode(
            PackageChange.self,
            from: Data(#"{"rolledBack":{"_0":{},"from":7}}"#.utf8)
        ) == .unknown
    )
    #expect(throws: EncodingError.self) {
        try JSONEncoder().encode(PackageChange.unknown)
    }
}

@Test func runtimeChangesAndEventEnvelopesRoundTrip() throws {
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let displayID = try #require(DisplayID(rawValue: "8b5d9703-7b10-4ec5-b126-88c950f81bd8"))
    let operationID = OperationID()
    let imageVersion = try #require(ImageVersion("2026.10.0-cf16373615-arm64"))
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let nestedError = WireError(domain: "runtime", code: "runtime.hostFailed", parameters: ["name": .text("VM")])
    let error = WireError(
        domain: "runtime",
        code: "runtime.bootFailed",
        parameters: ["attempts": .count(3), "file": .fileName("boot.log"), "elapsed": .durationMs(1_250)],
        listItems: [
            WireErrorListItem(
                selector: .variant(code: "runtime.bootFailed", key: "guest"),
                parameters: ["size": .bytes(512)]
            )
        ],
        cause: WireErrorBox(nestedError),
        underlying: WireUnderlyingError(domain: "VZErrorDomain", code: 9),
        context: ErrorContext(operationID: operationID, packageID: packageID, displayID: displayID)
    )
    let bootProgress = BootProgress(
        phase: .agentsConnecting,
        fraction: 0.9,
        elapsedMs: 12_345,
        purpose: .imageUpdate(
            from: try #require(ImageVersion("2026.09.9-cf16373615-arm64")),
            to: imageVersion
        )
    )
    let changes: [RuntimeChange] = [
        .stateChanged(.stopped),
        .stateChanged(.booting(.kernel)),
        .stateChanged(.ready),
        .stateChanged(.suspended),
        .stateChanged(.stopping(.user)),
        .stateChanged(.failed(error)),
        .bootProgress(bootProgress),
        .bootLoopGuardChanged(nil),
        .bootLoopGuardChanged(BootLoopGuardStatus(failures: 3, windowStartedAt: now, tripped: true)),
        .provisioningChanged(.notStarted),
        .provisioningChanged(.checkingHost),
        .provisioningChanged(.installingImage(fraction: 0.5)),
        .provisioningChanged(.creatingInstance),
        .provisioningChanged(.firstBoot(.systemServer, fraction: 0.75)),
        .provisioningChanged(.installingAgents),
        .provisioningChanged(.verifying),
        .provisioningChanged(.complete),
        .provisioningChanged(.failed(step: .installingImage, error: error)),
        .configurationChanged(keys: ["runtime.idleSuspendMinutes", "graphics.safeMode"]),
        .idleChanged(
            IdleStatus(
                activities: [ActivityKind(rawValue: "storeOperation"), ActivityKind(rawValue: "cli")],
                idleSince: now,
                suspendAt: now.addingTimeInterval(60),
                stopAt: now.addingTimeInterval(300)
            )
        ),
        .agentsChanged([
            AgentConnection(agent: .guest, state: .connected, protocolVersion: "1.2", required: true),
            AgentConnection(agent: .store, state: .unresponsive, required: false),
            AgentConnection(agent: .unknown, state: .unknown, required: false),
        ]),
        .developerModeChanged(true),
        .developerModeChanged(false),
    ]
    let envelopes = changes.enumerated().map { index, change in
        EventEnvelope(topic: .runtime, seq: UInt64(index + 1), time: now, payload: .runtime(change))
    }

    #expect(try changes.map(eventRoundTrip) == changes)
    #expect(try envelopes.map(eventRoundTrip) == envelopes)
    #expect(try eventRoundTrip(error) == error)
    #expect(try eventRoundTrip(WireErrorBox(error)).value == error)

    let encodedEnvelope =
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(envelopes[18]))
        as? [String: Any]
    let encodedPayload = encodedEnvelope?["payload"] as? [String: Any]
    let encodedRuntime = encodedPayload?["runtime"] as? [String: Any]
    let encodedChange = encodedRuntime?["_0"] as? [String: Any]
    let encodedConfiguration = encodedChange?["configurationChanged"] as? [String: Any]
    #expect(encodedConfiguration?["keys"] as? [String] == ["runtime.idleSuspendMinutes", "graphics.safeMode"])
    #expect(encodedConfiguration?["_0"] == nil)

    let encodedError = try JSONSerialization.jsonObject(with: JSONEncoder().encode(error)) as? [String: Any]
    let encodedCause = encodedError?["cause"] as? [String: Any]
    #expect(encodedCause?["code"] as? String == nestedError.code)
    #expect(encodedCause?["value"] == nil)
}

@Test func eventPayloadAndOperationEventPreserveFutureCasesAsUnknown() throws {
    let decoder = JSONDecoder()
    let futureWithoutPayload = Data(#"{"futureCase":{}}"#.utf8)
    let futureWithPayload = Data(#"{"futureCase":{"value":1}}"#.utf8)
    let futureScalarPayload = Data(#"{"futureCase":"new-tag"}"#.utf8)
    let futureRuntimeChange = Data(#"{"runtime":{"_0":{"futureChange":{"value":1}}}}"#.utf8)
    let futureRuntimeScalar = Data(#"{"runtime":{"_0":{"futureChange":"new-tag"}}}"#.utf8)
    let futureRuntimeState = Data(#"{"stateChanged":{"_0":{"futureState":{}}}}"#.utf8)

    #expect(try decoder.decode(EventPayload.self, from: futureWithoutPayload) == .unknown)
    #expect(try decoder.decode(EventPayload.self, from: futureWithPayload) == .unknown)
    #expect(try decoder.decode(EventPayload.self, from: futureScalarPayload) == .unknown)
    #expect(try decoder.decode(OperationEvent.self, from: futureWithoutPayload) == .unknown)
    #expect(try decoder.decode(OperationEvent.self, from: futureWithPayload) == .unknown)
    #expect(try decoder.decode(OperationEvent.self, from: futureScalarPayload) == .unknown)
    #expect(try decoder.decode(RuntimeChange.self, from: futureWithoutPayload) == .unknown)
    #expect(try decoder.decode(RuntimeChange.self, from: futureWithPayload) == .unknown)
    #expect(try decoder.decode(RuntimeChange.self, from: futureScalarPayload) == .unknown)
    #expect(try decoder.decode(EventPayload.self, from: futureRuntimeChange) == .runtime(.unknown))
    #expect(try decoder.decode(EventPayload.self, from: futureRuntimeScalar) == .runtime(.unknown))
    #expect(
        try decoder.decode(RuntimeChange.self, from: futureRuntimeState)
            == .stateChanged(.unknown)
    )
    #expect(throws: EncodingError.self) {
        try JSONEncoder().encode(EventPayload.unknown)
    }
    #expect(throws: EncodingError.self) {
        try JSONEncoder().encode(OperationEvent.unknown)
    }
    #expect(throws: EncodingError.self) {
        try JSONEncoder().encode(RuntimeChange.unknown)
    }
}

@Test func nestedEventEnumsPreserveFutureValuesAndFileNamesStayPathFree() throws {
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()

    #expect(try decoder.decode(BootPhase.self, from: Data(#""futureBootPhase""#.utf8)) == .unknown)
    #expect(try decoder.decode(WireStopReason.self, from: Data(#""futureStopReason""#.utf8)) == .unknown)
    #expect(
        try decoder.decode(BootPurpose.self, from: Data(#"{"futurePurpose":{"value":1}}"#.utf8))
            == .unknown
    )
    #expect(
        try decoder.decode(WireProvisioningState.self, from: Data(#"{"futureProvisioning":{"value":1}}"#.utf8))
            == .unknown
    )
    #expect(
        try decoder.decode(ProvisioningStep.self, from: Data(#""futureProvisioningStep""#.utf8)) == .unknown
    )
    #expect(try decoder.decode(AgentKind.self, from: Data(#""futureAgent""#.utf8)) == .unknown)
    #expect(
        try decoder.decode(AgentConnectionState.self, from: Data(#""futureAgentState""#.utf8)) == .unknown
    )
    #expect(
        try decoder.decode(WireErrorParameter.self, from: Data(#"{"futureParameter":{"value":1}}"#.utf8))
            == .unknown
    )
    #expect(
        try decoder.decode(
            WireErrorListItemSelector.self,
            from: Data(#"{"futureSelector":{"value":1}}"#.utf8)
        ) == .unknown
    )
    #expect(try eventRoundTrip(WireErrorParameter.unknown) == .unknown)
    #expect(try eventRoundTrip(WireErrorListItemSelector.unknown) == .unknown)

    let wireError = WireError(domain: "runtime", code: "runtime.unknown", parameters: [:])
    let futureValues: [RuntimeChange] = [
        .stateChanged(.booting(.unknown)),
        .stateChanged(.stopping(.unknown)),
        .bootProgress(BootProgress(phase: .unknown, elapsedMs: 0, purpose: .unknown)),
        .provisioningChanged(.unknown),
        .provisioningChanged(.failed(step: .unknown, error: wireError)),
        .agentsChanged([AgentConnection(agent: .unknown, state: .unknown, required: false)]),
    ]
    #expect(try futureValues.map(eventRoundTrip) == futureValues)

    let futureProvisioningChange = Data(#"{"provisioningChanged":{"_0":{"futureStep":{"value":1}}}}"#.utf8)
    #expect(
        try decoder.decode(RuntimeChange.self, from: futureProvisioningChange)
            == .provisioningChanged(.unknown)
    )

    let decodedFileName = try decoder.decode(
        WireErrorParameter.self,
        from: Data(#"{"fileName":{"_0":"/private/var/log/boot.log"}}"#.utf8)
    )
    #expect(decodedFileName == .fileName("boot.log"))
    let encodedFileName =
        try JSONSerialization.jsonObject(
            with: encoder.encode(WireErrorParameter.fileName("/private/var/log/boot.log"))
        ) as? [String: [String: String]]
    #expect(encodedFileName?["fileName"]?["_0"] == "boot.log")
}
