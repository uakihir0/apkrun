import Foundation
import Testing
import VirtioDeviceCore
import VirtioDeviceCoreTestSupport

@testable import GraphicsCore

private let edidOnly = VirtioGPUProtocol.Feature.edid

private struct Exchange {
    /// The bytes written to the element. Empty when the element received no response.
    let written: [UInt8]
    /// How many times the element was completed. It must be exactly one.
    let completions: Int
}

/// Sends one request through a fresh context that has DRIVER_OK, then waits for configuration writes.
private func exchange(
    _ device: VirtioGPUDevice,
    request: [UInt8],
    queueIndex: Int = 0,
    writableByteCount: Int = 4096,
    features: UInt64 = edidOnly
) async -> Exchange {
    let element = FakeVirtioQueue(elements: [(readable: request, writableByteCount: writableByteCount)])
    let empty = FakeVirtioQueue(elements: [])
    let fake = FakeVirtioDeviceContext(
        queueCount: 2,
        configurationSpace: device.descriptor.configurationSpace,
        queues: queueIndex == 0 ? [element, empty] : [empty, element]
    )
    fake.setReady(true)
    device.deviceDidStart(context: fake.context, negotiatedFeatures: features)
    device.queueNotified(index: queueIndex, context: fake.context)
    await device.waitForConfigurationWrites()
    return Exchange(written: element.writtenBuffers[0], completions: element.completionCounts[0])
}

private func responseType(_ bytes: [UInt8]) -> UInt32? {
    guard bytes.count >= 4 else { return nil }
    return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
}

private func scanout(_ index: Int) throws -> ScanoutID {
    try #require(ScanoutID(rawValue: index))
}

/// A context with one control element per request. One notification drains all of them.
private func controlSession(
    _ device: VirtioGPUDevice,
    requests: [[UInt8]],
    features: UInt64 = edidOnly
) -> (fake: FakeVirtioDeviceContext, control: FakeVirtioQueue) {
    let control = FakeVirtioQueue(
        elements: requests.map { (readable: $0, writableByteCount: 4096) }
    )
    let fake = FakeVirtioDeviceContext(
        queueCount: 2,
        configurationSpace: device.descriptor.configurationSpace,
        queues: [control, FakeVirtioQueue(elements: [])]
    )
    fake.setReady(true)
    device.deviceDidStart(context: fake.context, negotiatedFeatures: features)
    return (fake, control)
}

/// The `events_read` value in the configuration bytes the guest sees.
private func eventsRead(_ fake: FakeVirtioDeviceContext) -> UInt32 {
    let bytes = Array(fake.configurationSpace)
    return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
}

private final class TraceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [VirtioGPUDevice.TraceRecord] = []

    func append(_ record: VirtioGPUDevice.TraceRecord) {
        lock.withLock { stored.append(record) }
    }

    var records: [VirtioGPUDevice.TraceRecord] {
        lock.withLock { stored }
    }
}

// MARK: - Identity and configuration

@Test func descriptorAdvertisesTheVirtioGPUIdentityWithEDIDOnly() {
    let descriptor = VirtioGPUDevice().descriptor
    #expect(descriptor.name == "virtio-gpu")
    #expect(descriptor.deviceID == 16)
    #expect(descriptor.pciClass == 0x03)
    #expect(descriptor.pciSubclass == 0x80)
    #expect(descriptor.queueCount == 2)
    #expect(descriptor.mandatoryFeatures == 0)
    #expect(descriptor.optionalFeatures == 1 << 1)
    #expect(descriptor.optionalFeatures & VirtioGPUProtocol.Feature.virgl == 0)
    #expect(descriptor.sharedMemoryRegions.isEmpty)
}

@Test func hostCapabilitiesNameTheFeaturesTheDeviceOffers() {
    // No renderer yet (#021), so the device offers EDID only. `virgl` is named only when the descriptor offers it.
    #expect(VirtioGPUDevice().hostCapabilities == ["edid"])
}

@Test func configurationSpaceHasSixteenLittleEndianBytes() {
    let bytes = Array(VirtioGPUDevice().descriptor.configurationSpace)
    // events_read = 0, events_clear = 0, num_scanouts = 16, num_capsets = 0.
    #expect(bytes == [0, 0, 0, 0, 0, 0, 0, 0, 16, 0, 0, 0, 0, 0, 0, 0])
    #expect(bytes.count == VirtioGPUProtocol.configurationByteCount)
}

// MARK: - Supported commands

@Test func getDisplayInfoMatchesTheGoldenResponse() async throws {
    let result = await exchange(
        VirtioGPUDevice(),
        request: try GraphicsFixtures.vector(named: "get-display-info"),
        writableByteCount: 408
    )
    #expect(result.written == (try GraphicsFixtures.vector(named: "ok-display-info")))
    #expect(result.completions == 1)
}

@Test func fencedGetDisplayInfoEchoesTheFenceInItsResponse() async throws {
    let result = await exchange(
        VirtioGPUDevice(),
        request: try GraphicsFixtures.vector(named: "get-display-info-fenced"),
        writableByteCount: 408
    )
    #expect(result.written == (try GraphicsFixtures.vector(named: "ok-display-info-fenced")))
}

@Test func getEDIDMatchesTheGoldenBlockForScanoutZero() async throws {
    let result = await exchange(
        VirtioGPUDevice(),
        request: try GraphicsFixtures.vector(named: "get-edid-scanout-0"),
        writableByteCount: 1056
    )
    #expect(result.written == (try GraphicsFixtures.vector(named: "ok-edid-scanout-0")))
    #expect(result.completions == 1)
}

@Test func getEDIDReturnsTheEnabledScanoutsMode() async throws {
    let device = VirtioGPUDevice()
    let scanout1 = try scanout(1)
    let mode = DisplayMode(widthPixels: 1920, heightPixels: 1080, refreshHz: 60, dotsPerInch: 160)
    try device.enableScanout(scanout1, mode: mode)

    let result = await exchange(
        device,
        request: VirtioGPUProtocol.encodeRequest(
            VirtioGPURequest(
                header: VirtioGPUControlHeader(type: VirtioGPUCommand.getEDID.rawValue),
                body: .getEDID(scanout: 1)
            )
        ),
        writableByteCount: 1056
    )
    let response = try VirtioGPUProtocol.decodeResponse(result.written)
    guard case .okEDID(let edid) = response.body else {
        Issue.record("expected OK_EDID")
        return
    }
    #expect(edid == (try GraphicsFixtures.edid(named: "scanout-01-1920x1080-60.edid")))
}

@Test func getEDIDWithoutNegotiatedEDIDIsAnErrorResponse() async throws {
    let result = await exchange(
        VirtioGPUDevice(),
        request: try GraphicsFixtures.vector(named: "get-edid-scanout-0"),
        writableByteCount: 1056,
        features: 0
    )
    #expect(responseType(result.written) == VirtioGPUErrorCode.unspec.rawValue)
}

@Test func getEDIDOutsideTheScanoutRangeIsAnInvalidScanoutError() async {
    let result = await exchange(
        VirtioGPUDevice(),
        request: VirtioGPUProtocol.encodeRequest(
            VirtioGPURequest(
                header: VirtioGPUControlHeader(type: VirtioGPUCommand.getEDID.rawValue),
                body: .getEDID(scanout: 16)
            )
        )
    )
    #expect(responseType(result.written) == VirtioGPUErrorCode.invalidScanoutID.rawValue)
    #expect(result.written.count == VirtioGPUProtocol.headerByteCount)
}

// MARK: - Error responses

@Test func everyOtherControlCommandGetsAnErrorResponse() async throws {
    let vectors = try GraphicsFixtures.virtioGPUVectors().filter { $0.direction == "request" && $0.queue == "control" }
    var checked = Set<UInt32>()
    for vector in vectors {
        let bytes = try vector.bytes
        let header = try VirtioGPUControlHeader(decodingFrom: bytes)
        if header.type == VirtioGPUCommand.getDisplayInfo.rawValue || header.type == VirtioGPUCommand.getEDID.rawValue {
            continue
        }
        let result = await exchange(VirtioGPUDevice(), request: bytes)
        #expect(responseType(result.written) == VirtioGPUErrorCode.unspec.rawValue, "\(vector.name)")
        #expect(result.completions == 1, "\(vector.name)")
        checked.insert(header.type)
    }
    // Every control-queue command except the two supported ones and the cursor commands.
    let controlCommands = VirtioGPUCommand.allCases.filter {
        ![.getDisplayInfo, .getEDID, .updateCursor, .moveCursor].contains($0)
    }
    #expect(checked == Set(controlCommands.map(\.rawValue)))
}

@Test func unknownCommandCodesGetAnErrorResponse() async {
    let bytes: [UInt8] = [0x99, 0x09, 0, 0] + [UInt8](repeating: 0, count: 20)
    let result = await exchange(VirtioGPUDevice(), request: bytes)
    #expect(responseType(result.written) == VirtioGPUErrorCode.unspec.rawValue)
}

@Test func cursorQueueCommandsGetErrorResponses() async throws {
    let updateCursor = await exchange(
        VirtioGPUDevice(),
        request: try GraphicsFixtures.vector(named: "update-cursor"),
        queueIndex: VirtioGPUProtocol.cursorQueueIndex
    )
    #expect(responseType(updateCursor.written) == VirtioGPUErrorCode.unspec.rawValue)

    let displayInfo = await exchange(
        VirtioGPUDevice(),
        request: try GraphicsFixtures.vector(named: "get-display-info"),
        queueIndex: VirtioGPUProtocol.cursorQueueIndex
    )
    #expect(responseType(displayInfo.written) == VirtioGPUErrorCode.invalidParameter.rawValue)
    #expect(displayInfo.completions == 1)
}

@Test func aRequestShorterThanTheHeaderGetsNoResponseButIsCompleted() async {
    let result = await exchange(VirtioGPUDevice(), request: [1, 2, 3])
    #expect(result.written.isEmpty)
    #expect(result.completions == 1)
}

@Test func aRequestLargerThanFourMebibytesGetsAnInvalidParameterError() async {
    let limit = VirtioGPUProtocol.Limits.maximumRequestByteCount
    var request = [UInt8](repeating: 0, count: limit + 1)
    request[0] = 0x00
    request[1] = 0x01
    let result = await exchange(VirtioGPUDevice(), request: request)
    #expect(responseType(result.written) == VirtioGPUErrorCode.invalidParameter.rawValue)
    #expect(result.completions == 1)
}

@Test func aResponseThatDoesNotFitIsReplacedByAnErrorHeaderOrDropped() async throws {
    let request = try GraphicsFixtures.vector(named: "get-display-info")
    let headerOnly = await exchange(VirtioGPUDevice(), request: request, writableByteCount: 100)
    #expect(responseType(headerOnly.written) == VirtioGPUErrorCode.invalidParameter.rawValue)
    #expect(headerOnly.written.count == VirtioGPUProtocol.headerByteCount)

    let tooSmall = await exchange(VirtioGPUDevice(), request: request, writableByteCount: 10)
    #expect(tooSmall.written.isEmpty)
    #expect(tooSmall.completions == 1)
}

@Test func traceObserverSeesTheRequestAndItsResponse() async throws {
    let box = TraceBox()
    let device = VirtioGPUDevice(traceObserver: { box.append($0) })
    let request = try GraphicsFixtures.vector(named: "get-display-info")
    _ = await exchange(device, request: request, writableByteCount: 408)

    let records = box.records
    #expect(records.count == 1)
    #expect(records.first?.queueIndex == 0)
    #expect(records.first?.request == request)
    #expect(records.first?.response == (try GraphicsFixtures.vector(named: "ok-display-info")))
}

// MARK: - Display events (graphics.md §4.3)

@Test func aChangeBeforeDriverOKIsWrittenWhenTheGuestStarts() async throws {
    let device = VirtioGPUDevice()
    try device.enableScanout(try scanout(1), mode: .testDefault)
    let session = controlSession(device, requests: [])
    await device.waitForConfigurationWrites()
    #expect(eventsRead(session.fake) == VirtioGPUProtocol.Event.display)
}

@Test func getDisplayInfoReportsTheChangeAndClearsEventsRead() async throws {
    let device = VirtioGPUDevice()
    try device.enableScanout(try scanout(1), mode: .testDefault)
    let session = controlSession(
        device,
        requests: [try GraphicsFixtures.vector(named: "get-display-info")]
    )
    device.queueNotified(index: 0, context: session.fake.context)
    await device.waitForConfigurationWrites()

    #expect(eventsRead(session.fake) == 0)
    let response = try VirtioGPUProtocol.decodeResponse(session.control.writtenBuffers[0])
    guard case .okDisplayInfo(let modes) = response.body else {
        Issue.record("expected OK_DISPLAY_INFO")
        return
    }
    #expect(modes[1].enabled == 1)
    #expect(modes[1].rect.width == 1024)
    #expect(modes[0].enabled == 1)
    #expect(session.control.completionCounts[0] == 1)
}

@Test func aChangeDuringAnInFlightQueryKeepsEventsReadSet() async throws {
    let device = VirtioGPUDevice()
    let session = controlSession(
        device,
        requests: [try GraphicsFixtures.vector(named: "get-display-info")]
    )
    // The change lands after the snapshot. The guest therefore receives the old table
    // and must be told to ask again.
    let other = try scanout(1)
    device.displayInfoSnapshotHook = {
        do {
            try device.enableScanout(other, mode: .testDefault)
        } catch {
            Issue.record("enableScanout failed inside the hook")
        }
    }
    device.queueNotified(index: 0, context: session.fake.context)
    await device.waitForConfigurationWrites()

    #expect(eventsRead(session.fake) == VirtioGPUProtocol.Event.display)
    let response = try VirtioGPUProtocol.decodeResponse(session.control.writtenBuffers[0])
    guard case .okDisplayInfo(let modes) = response.body else {
        Issue.record("expected OK_DISPLAY_INFO")
        return
    }
    #expect(modes[1].enabled == 0)
}

@Test func aRejectedModeChangesNothingAndSendsNoEvent() async throws {
    let device = VirtioGPUDevice()
    let invalid = DisplayMode(widthPixels: 5000, heightPixels: 768, refreshHz: 60, dotsPerInch: 160)
    #expect(throws: GraphicsFailure.modeUnsupported(mode: invalid)) {
        try device.enableScanout(try scanout(1), mode: invalid)
    }
    #expect(device.scanoutTable.displayGeneration == 0)
    let session = controlSession(device, requests: [])
    await device.waitForConfigurationWrites()
    #expect(eventsRead(session.fake) == 0)
}

@Test func resetKeepsTheHostScanoutsAndClearsEventsReadForTheNextGeneration() async throws {
    let device = VirtioGPUDevice()
    let other = try scanout(1)
    let session = controlSession(device, requests: [])
    try device.enableScanout(other, mode: .testDefault)
    await device.waitForConfigurationWrites()
    #expect(eventsRead(session.fake) == VirtioGPUProtocol.Event.display)

    session.fake.reset()
    device.deviceWillReset()
    session.fake.setReady(true)
    device.deviceDidStart(context: session.fake.context, negotiatedFeatures: edidOnly)
    await device.waitForConfigurationWrites()

    #expect(eventsRead(session.fake) == 0)
    #expect(device.scanoutTable.state(of: other).isEnabled)
}

@Test func disablingAScanoutSendsAnEventToo() async throws {
    let device = VirtioGPUDevice()
    let session = controlSession(device, requests: [])
    device.disableScanout(try scanout(0))
    await device.waitForConfigurationWrites()
    #expect(eventsRead(session.fake) == VirtioGPUProtocol.Event.display)
    #expect(device.scanoutTable.enabledScanouts.isEmpty)
}

// MARK: - Guest error log rate limit

@Test func guestErrorLogsAreLimitedToTenPerSecondAndCountTheRest() {
    var limiter = GuestErrorRateLimiter(maximumPerWindow: 10)
    for _ in 0..<10 {
        #expect(limiter.admit(at: 0) == .log(suppressedCount: 0))
    }
    for _ in 0..<5 {
        #expect(limiter.admit(at: 500_000_000) == .suppress)
    }
    #expect(limiter.admit(at: 1_000_000_000) == .log(suppressedCount: 5))
    #expect(limiter.admit(at: 1_200_000_000) == .log(suppressedCount: 0))
}

@Test func theHotplugSpikeEnablesScanoutOneAfterTheFirstDriverOK() async throws {
    let device = VirtioGPUDevice(hotplugSpikeDelay: .milliseconds(1))
    #expect(device.scanoutTable.state(of: try scanout(1)).isEnabled == false)
    let session = controlSession(device, requests: [])
    await device.waitForConfigurationWrites()

    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !device.scanoutTable.state(of: try scanout(1)).isEnabled, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(device.scanoutTable.state(of: try scanout(1)).isEnabled)
    await device.waitForConfigurationWrites()
    #expect(eventsRead(session.fake) == VirtioGPUProtocol.Event.display)
}

@Test func deviceAnswersTheCapturedDisplayAndEDIDRequestsLikeTheLinuxDriverSaw() async throws {
    var replayed = 0
    for record in try GraphicsFixtures.linuxDriverTrace() {
        guard let response = record.response else { continue }
        let request = try GraphicsFixtures.hexBytes(record.request)
        let header = try VirtioGPUControlHeader(decodingFrom: request)
        guard
            header.type == VirtioGPUCommand.getDisplayInfo.rawValue || header.type == VirtioGPUCommand.getEDID.rawValue
        else { continue }
        let expected = try GraphicsFixtures.hexBytes(response)
        let result = await exchange(VirtioGPUDevice(), request: request, writableByteCount: expected.count)
        #expect(result.written == expected, "\(record.request.prefix(16))")
        replayed += 1
    }
    #expect(replayed == 17)
}
