import Foundation
import Testing

@testable import RuntimeAPI

@Test func runtimeInfoRequestRoundTripsDetailFlags() throws {
    let request = RuntimeInfoRequest(resources: true, displays: false)
    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(RuntimeInfoRequest.self, from: data)

    #expect(decoded == request)
    #expect(try JSONDecoder().decode(RuntimeInfoRequest.self, from: Data("{}".utf8)) == RuntimeInfoRequest())
}

@Test func runtimeInfoOmitsUnrequestedInventories() throws {
    let info = RuntimeInfo(
        status: runtimeInfoStatus(),
        sizing: RuntimeSizing(cpuCount: 4, memoryGiB: 6, userdataGiB: nil),
        displayPoolSize: 3
    )
    let data = try JSONEncoder().encode(info)
    let decoded = try JSONDecoder().decode(RuntimeInfo.self, from: data)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let sizing = try #require(object["sizing"] as? [String: Any])

    #expect(decoded == info)
    #expect(sizing["userdataGiB"] == nil)
    #expect(object["resources"] == nil)
    #expect(object["displays"] == nil)
}

@Test func runtimeInfoRoundTripsRequestedInventories() throws {
    let displayID = try #require(DisplayID(rawValue: "8b5d9703-7b10-4ec5-b126-88c950f81bd8"))
    let sessionID = UUID(uuidString: "ea9bf3b2-0520-4ed7-a5ab-13cda15bc481")!
    let info = RuntimeInfo(
        status: runtimeInfoStatus(),
        sizing: RuntimeSizing(cpuCount: 4, memoryGiB: 6, userdataGiB: 32),
        displayPoolSize: 3,
        resources: ResourceUsage(
            daemonPhysicalFootprintBytes: 4_194_304,
            guestMemoryUsedBytes: 2_147_483_648,
            graphicsMemoryBytes: 33_554_432,
            daemonCPUPercent: 12.5
        ),
        displays: [
            RuntimeDisplaySlotSnapshot(slot: 0, state: .reserved, androidDisplayID: 0),
            RuntimeDisplaySlotSnapshot(
                slot: 1,
                state: .allocated(sessionID),
                displayID: displayID,
                androidDisplayID: 2,
                pixelSize: PixelSize(width: 1920, height: 1080),
                densityDpi: 240
            ),
        ]
    )
    let data = try JSONEncoder().encode(info)
    let decoded = try JSONDecoder().decode(RuntimeInfo.self, from: data)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let displays = try #require(object["displays"] as? [[String: Any]])
    let reservedState = try #require(displays[0]["state"] as? [String: Any])
    let state = try #require(displays[1]["state"] as? [String: Any])
    let allocatedPayload = try #require(state["allocated"] as? [String: String])

    #expect(decoded == info)
    #expect(object["resources"] != nil)
    #expect(object["displays"] != nil)
    #expect(reservedState["reserved"] != nil)
    #expect(allocatedPayload["_0"] == sessionID.uuidString)
}

@Test func runtimeInfoSessionSummaryRoundTripsOptionalPointSize() throws {
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let displayID = try #require(DisplayID(rawValue: "8b5d9703-7b10-4ec5-b126-88c950f81bd8"))
    let expected = SessionSummary(
        sessionID: UUID(uuidString: "ea9bf3b2-0520-4ed7-a5ab-13cda15bc481")!,
        packageID: packageID,
        displayName: "Hello Text",
        state: .running,
        displayID: displayID,
        clientKind: .wrapper,
        openedAt: Date(timeIntervalSince1970: 1_800_000_000),
        windowMode: .secondaryDisplay,
        recording: false,
        pointSize: CGSize(width: 1280, height: 720)
    )
    let data = try JSONEncoder().encode(expected)
    let decoded = try JSONDecoder().decode(SessionSummary.self, from: data)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let pointSize = try #require(object["pointSize"] as? [String: Double])

    #expect(decoded == expected)
    #expect(pointSize == ["width": 1280, "height": 720])
}

@Test func optionalSessionPointSizeAndFutureDisplayStatesDecodeSafely() throws {
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let summary = SessionSummary(
        sessionID: UUID(uuidString: "ea9bf3b2-0520-4ed7-a5ab-13cda15bc481")!,
        packageID: packageID,
        displayName: "Hello Text",
        state: .running,
        clientKind: .launcher,
        openedAt: Date(timeIntervalSince1970: 1_800_000_000),
        windowMode: .primaryDisplayCompatibility,
        recording: false
    )
    let encodedSummary = try JSONEncoder().encode(summary)
    let summaryObject = try #require(try JSONSerialization.jsonObject(with: encodedSummary) as? [String: Any])
    let unknownDisplayState = Data(#"{"futureState":{}}"#.utf8)
    let unknownWindowMode = Data(#""futureMode""#.utf8)

    #expect(summaryObject["pointSize"] == nil)
    #expect(try JSONDecoder().decode(SessionSummary.self, from: encodedSummary) == summary)
    #expect(try JSONDecoder().decode(WireDisplayState.self, from: unknownDisplayState) == .unknown)
    #expect(try JSONDecoder().decode(RuntimeAndroidWindowMode.self, from: unknownWindowMode) == .unknown)
    #expect(throws: (any Error).self) {
        try JSONEncoder().encode(WireDisplayState.unknown)
    }
    #expect(throws: (any Error).self) {
        try JSONEncoder().encode(RuntimeAndroidWindowMode.unknown)
    }
}

private func runtimeInfoStatus() -> RuntimeHostStatus {
    RuntimeHostStatus(
        hostState: "running",
        runtimeState: "ready",
        bootProgress: nil,
        startupFailureStep: nil,
        startupFailureCode: nil,
        crashLoopActive: false,
        daemonPID: 42,
        imageVersion: "2026.10.0-cf16373615-arm64"
    )
}
