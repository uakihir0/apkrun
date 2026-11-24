import Foundation
import Testing

@testable import RuntimeAPI

private func sessionRoundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(Value.self, from: data)
}

private func openSessionRequest() -> OpenSessionRequest {
    OpenSessionRequest(
        packageID: RuntimePackageID(rawValue: "io.apkrun.hellotext")!,
        geometry: SessionDisplayGeometry(
            pointSize: SessionSize(width: 480, height: 850),
            backingScale: 2,
            zoom: 1
        ),
        screenSize: SessionSize(width: 1440, height: 900),
        launchTiming: SessionLaunchTiming(processStart: 1_000, requestSent: 1_100)
    )
}

private func sessionDescriptor(generation: UInt32 = 4) -> SessionDescriptor {
    SessionDescriptor(
        sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        displayID: DisplayID(rawValue: "00000000-0000-0000-0000-000000000002")!,
        windowPrefs: WindowPrefs(resizable: true, alwaysOnTop: false, zoom: 1.25),
        inputPrefs: InputPrefs(
            escapeKey: .back,
            secondaryClick: .longPress,
            scrollMode: .touchDrag,
            hover: true,
            sendCommandKey: false
        ),
        windowMode: .secondaryDisplay,
        state: .booting(
            BootProgress(phase: .systemServer, fraction: 0.6, elapsedMs: 1_250, purpose: .normal)
        ),
        surfaces: SurfaceSet(
            generation: generation,
            pixelSize: SessionPixelSize(width: 960, height: 1_700),
            densityDpi: 320
        )
    )
}

@Test func openSessionRequestAndDescriptorRoundTrip() throws {
    let request = RuntimeOpenSessionControlRequest(
        header: APIRequestHeader(clientKind: .launcher),
        request: openSessionRequest()
    )
    let descriptor = sessionDescriptor()
    let success = RuntimeOpenSessionControlReply(result: descriptor)
    let failure = RuntimeOpenSessionControlReply(
        error: .runtime(
            "displayAttachFailed",
            message: "The Android display could not be attached.",
            remediation: "Close another Android app window and retry."
        )
    )

    #expect(try sessionRoundTrip(request) == request)
    #expect(try sessionRoundTrip(descriptor) == descriptor)
    #expect(try sessionRoundTrip(success) == success)
    #expect(try sessionRoundTrip(failure) == failure)
    #expect(SurfaceSet.surfaceCount == 3)
}

@Test func sessionFrameMessagesAndPoolReplacementRoundTrip() throws {
    let frame = FrameReadyMessage(
        generation: 4,
        surfaceIndex: 2,
        frameSeq: 987,
        presentationTime: 123_456_789
    )
    let replacement = SurfacesReplacedMessage(surfaceSet: sessionDescriptor(generation: 5).surfaces)
    let displayed = FrameDisplayedMessage(generation: 5, frameSeq: 988)
    let hidden = VisibilityChangedMessage(visible: false)
    let shown = VisibilityChangedMessage(visible: true)

    #expect(try sessionRoundTrip(frame) == frame)
    #expect(try sessionRoundTrip(replacement) == replacement)
    #expect(try sessionRoundTrip(displayed) == displayed)
    #expect(try sessionRoundTrip(hidden) == hidden)
    #expect(try sessionRoundTrip(shown) == shown)
}

@Test func unknownSessionStateAndPreferencesRemainForwardCompatible() throws {
    let phase = try JSONDecoder().decode(SessionPhase.self, from: Data(#"{"kind":"futurePhase"}"#.utf8))
    let mode = try JSONDecoder().decode(AndroidWindowMode.self, from: Data(#""futureMode""#.utf8))
    let mapping = try JSONDecoder().decode(EscapeKeyMapping.self, from: Data(#""futureKey""#.utf8))

    #expect(phase == .unknown)
    #expect(mode == .unknown)
    #expect(mapping == .unknown)
}

@Test func sessionXPCKeepsSurfacesAndTheListenerEndpointAsDirectParameters() throws {
    let requestSelector = #selector(RuntimeControlXPC.openSession(_:reply:))
    let frameSelector = #selector(RuntimeSessionEventSink.frameReady(_:))
    let replacementSelector = #selector(RuntimeSessionEventSink.surfacesReplaced(_:surfaces:))
    let displayedSelector = #selector(RuntimeSessionXPC.frameDisplayed(_:))
    let visibilitySelector = #selector(RuntimeSessionXPC.visibilityChanged(_:))

    #expect(requestSelector == NSSelectorFromString("openSession:reply:"))
    #expect(frameSelector == NSSelectorFromString("frameReady:"))
    #expect(replacementSelector == NSSelectorFromString("surfacesReplaced:surfaces:"))
    #expect(displayedSelector == NSSelectorFromString("frameDisplayed:"))
    #expect(visibilitySelector == NSSelectorFromString("visibilityChanged:"))
}
