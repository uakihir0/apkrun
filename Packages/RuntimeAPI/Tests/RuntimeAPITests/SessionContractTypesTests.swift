import Foundation
import Testing

@testable import RuntimeAPI

private func sessionRoundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(Value.self, from: data)
}

@Test func openSessionRequestAndControlReplyRoundTrip() throws {
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let request = OpenSessionRequest(
        header: APIRequestHeader(clientKind: .launcher),
        packageID: packageID,
        geometry: DisplayGeometry(
            pointSize: DisplayPointSize(width: 480, height: 850),
            backingScale: 2,
            zoom: 1.25
        ),
        screenSize: DisplayPointSize(width: 1_440, height: 900),
        launchTiming: LaunchTiming(processStart: 1_000, requestSent: 1_250)
    )
    let descriptor = SessionDescriptor(
        sessionID: UUID(),
        displayID: 3,
        windowPrefs: WindowPrefs(),
        inputPrefs: InputPrefs(),
        windowMode: .secondaryDisplay,
        state: .launching,
        surfaces: SurfaceSet(
            generation: 1,
            pixelSize: PixelSize(width: 960, height: 1_700),
            densityDpi: 320
        )
    )
    let success = OpenSessionControlReply(result: descriptor)
    let failure = OpenSessionControlReply(
        error: .runtime("displayPoolExhausted", message: "No display is available.")
    )

    #expect(try sessionRoundTrip(request) == request)
    #expect(try sessionRoundTrip(success) == success)
    #expect(try sessionRoundTrip(failure) == failure)
}

@Test func resizeSessionRequestAndControlRepliesRoundTrip() throws {
    let geometry = DisplayGeometry(
        pointSize: DisplayPointSize(width: 720, height: 1_200),
        backingScale: 2,
        zoom: 1.25
    )
    let request = ResizeSessionRequest(
        header: APIRequestHeader(clientKind: .launcher),
        geometry: geometry
    )
    let descriptor = SessionDescriptor(
        sessionID: UUID(uuidString: "f5e0ec04-c077-442e-b633-a737ad4fced5")!,
        displayID: 3,
        windowPrefs: WindowPrefs(zoom: 1.25),
        inputPrefs: InputPrefs(),
        windowMode: .secondaryDisplay,
        state: .running,
        surfaces: SurfaceSet(
            generation: 2,
            pixelSize: PixelSize(width: 1_800, height: 3_000),
            densityDpi: 400
        )
    )
    let applied = ResizeSessionControlReply(outcome: .applied, result: descriptor)
    let unchanged = ResizeSessionControlReply(outcome: .unchanged)
    let rejected = ResizeSessionControlReply(outcome: .rejected)
    let uncertain = ResizeSessionControlReply(outcome: .stateUncertain)
    let typedFailure = ResizeSessionControlReply(
        error: .runtime("displayModeUnsupported", message: "The requested size is unsupported.")
    )

    #expect(try sessionRoundTrip(request) == request)
    #expect(try sessionRoundTrip(applied) == applied)
    #expect(try sessionRoundTrip(unchanged) == unchanged)
    #expect(try sessionRoundTrip(rejected) == rejected)
    #expect(try sessionRoundTrip(uncertain) == uncertain)
    #expect(try sessionRoundTrip(typedFailure) == typedFailure)
}

@Test func restartAppRequestAndControlRepliesRoundTrip() throws {
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let sessionID = UUID(uuidString: "f5e0ec04-c077-442e-b633-a737ad4fced5")!
    let request = RestartAppRequest(
        header: APIRequestHeader(clientKind: .wrapper),
        sessionID: sessionID,
        packageID: packageID
    )
    let success = RestartAppControlReply()
    let failure = RestartAppControlReply(
        error: .runtime("launchFailed", message: "Android could not restart the app.")
    )

    #expect(try sessionRoundTrip(request) == request)
    #expect(try sessionRoundTrip(success) == success)
    #expect(try sessionRoundTrip(failure) == failure)
}

@Test func closeSessionRequestAndControlRepliesRoundTrip() throws {
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let request = CloseSessionRequest(
        header: APIRequestHeader(clientKind: .wrapper),
        sessionID: UUID(uuidString: "2A7782D8-E0EA-4A33-AF55-EA82A20B886A")!,
        packageID: packageID
    )
    let success = CloseSessionControlReply()
    let stopRequest = CloseSessionRequest(
        header: request.header,
        sessionID: request.sessionID,
        packageID: request.packageID,
        policy: .stop
    )
    let failure = CloseSessionControlReply(
        error: .runtime("guestAgentOperationFailed", message: "Android still reports tasks for this app.")
    )

    #expect(try sessionRoundTrip(request) == request)
    #expect(try sessionRoundTrip(stopRequest) == stopRequest)
    #expect(try sessionRoundTrip(success) == success)
    #expect(try sessionRoundTrip(failure) == failure)
}

@Test func sessionDescriptorAndSurfaceMetadataRoundTrip() throws {
    let pixelSize = PixelSize(width: 960, height: 1_700)
    let surfaces = SurfaceSet(generation: 7, pixelSize: pixelSize, densityDpi: 320)
    let progress = BootProgress(phase: .systemServer, fraction: 0.65, elapsedMs: 2_300, purpose: .normal)
    let descriptor = SessionDescriptor(
        sessionID: try #require(UUID(uuidString: "41f9ed7b-a123-4ebd-9a61-7a2be9465780")),
        displayID: 4,
        windowPrefs: WindowPrefs(resizable: false, alwaysOnTop: true, zoom: 1.25),
        inputPrefs: InputPrefs(
            escapeKey: .escape,
            secondaryClick: .longPress,
            scrollMode: .touchDrag,
            hover: false,
            sendCommandKey: true
        ),
        windowMode: .secondaryDisplay,
        state: .booting(progress),
        surfaces: surfaces
    )

    #expect(pixelSize == (try sessionRoundTrip(pixelSize)))
    #expect(surfaces.surfaceCount == 3)
    #expect(surfaces == (try sessionRoundTrip(surfaces)))
    #expect(descriptor == (try sessionRoundTrip(descriptor)))
}

@Test func surfaceSetRejectsWireCardinalityOtherThanThree() throws {
    let data = try JSONSerialization.data(
        withJSONObject: [
            "generation": 1,
            "surfaceCount": 2,
            "pixelSize": ["width": 640, "height": 960],
            "densityDpi": 240,
        ]
    )

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SurfaceSet.self, from: data)
    }
}

@Test func sessionPhasesAndEndReasonsRoundTripAndPreserveUnknownCases() throws {
    let wireError = WireError(domain: "runtime", code: "runtime.displayLost")
    let phases: [SessionPhase] = [
        .starting,
        .booting(BootProgress(phase: .kernel, elapsedMs: 80, purpose: .normal)),
        .waitingForPackage,
        .launching,
        .running,
        .ended(.error(wireError)),
        .unknown,
    ]
    let endReasons: [SessionEndReason] = [
        .userClosed,
        .appExited,
        .appCrashed,
        .runtimeStopped,
        .updating,
        .runtimeUpdating,
        .packageUninstalled,
        .error(wireError),
        .unknown,
    ]
    let decoder = JSONDecoder()

    #expect(try phases.map(sessionRoundTrip) == phases)
    #expect(try endReasons.map(sessionRoundTrip) == endReasons)
    #expect(try decoder.decode(SessionPhase.self, from: Data(#"{"futurePhase":{"token":1}}"#.utf8)) == .unknown)
    #expect(
        try decoder.decode(SessionEndReason.self, from: Data(#"{"futureReason":{"token":1}}"#.utf8)) == .unknown
    )
    #expect(try JSONEncoder().encode(SessionPhase.unknown) == Data(#"{"unknown":{}}"#.utf8))
    #expect(try JSONEncoder().encode(SessionEndReason.unknown) == Data(#"{"unknown":{}}"#.utf8))
}

@Test func sessionModesAndPreferenceMappingsPreserveUnknownValues() throws {
    let decoder = JSONDecoder()

    #expect(try sessionRoundTrip(SessionWindowMode.primaryDisplayCompatibility) == .primaryDisplayCompatibility)
    #expect(try sessionRoundTrip(InputPrefs()) == InputPrefs())
    #expect(try decoder.decode(SessionWindowMode.self, from: Data(#""futureMode""#.utf8)) == .unknown)
    #expect(try decoder.decode(EscapeKeyMapping.self, from: Data(#""futureEscape""#.utf8)) == .unknown)
    #expect(try decoder.decode(SecondaryClickMapping.self, from: Data(#""futureClick""#.utf8)) == .unknown)
    #expect(try decoder.decode(ScrollModeMapping.self, from: Data(#""futureScroll""#.utf8)) == .unknown)
}

@Test func frameAndSurfaceSessionMessagesRoundTrip() throws {
    let surfaceSet = SurfaceSet(
        generation: 8,
        pixelSize: PixelSize(width: 1_280, height: 800),
        densityDpi: 240
    )
    let messages = [
        FrameReady(generation: 8, surfaceIndex: 2, frameSeq: 9_007_199_254_740_999, presentationTime: 77)
    ]
    let displayed = FrameDisplayed(generation: 8, frameSeq: 9_007_199_254_740_999)
    let replaced = SurfacesReplaced(surfaceSet: surfaceSet)
    let visibility = VisibilityChanged(visible: false)

    #expect(try messages.map(sessionRoundTrip) == messages)
    #expect(try sessionRoundTrip(displayed) == displayed)
    #expect(try sessionRoundTrip(replaced) == replaced)
    #expect(try sessionRoundTrip(visibility) == visibility)
}
