import CryptoKit
import Foundation
import GuestProtocol
import RuntimeAPI
import Testing

@testable import IntegrationCore

/// A real 1x1 PNG; inbound image clips are verified against the actual
/// bytes, so tests need decodable data, not filler.
private let testPNG = Data(
    base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)!

private func policy(
    packageValues: [String: String] = [:],
    globalsEnabled: [IntegrationKind: Bool] = [:],
    supported: Set<String> = ["clipboard.text.v1"]
) -> IntegrationPolicy {
    IntegrationPolicy(
        source: IntegrationSettingsSource(
            packageValue: { kind, _ in packageValues[kind.rawValue] },
            globalEnabled: { kind in globalsEnabled[kind] ?? true },
            supported: { capability in supported.contains(capability) }
        )
    )
}

private let package = RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext")!

private func context(session: Bool = true, key: Bool = true) -> IntegrationContext {
    IntegrationContext(hasSession: session, windowIsKey: key)
}

@Suite("IntegrationPolicy (desktop-integration.md §2.3)")
struct IntegrationPolicyTests {
    @Test func allowsOnDefaults() async {
        let subject = policy()
        let decision = await subject.evaluate(.clipboard, package: package, context: context())
        #expect(decision == .allow)
    }

    @Test func globalSwitchDeniesEveryPackage() async {
        let subject = policy(globalsEnabled: [.clipboard: false])
        let decision = await subject.evaluate(.clipboard, package: package, context: context())
        #expect(decision == .deny(.globallyOff))
    }

    @Test func packageOffDenies() async {
        let subject = policy(packageValues: ["clipboard": "false"])
        let decision = await subject.evaluate(.clipboard, package: package, context: context())
        #expect(decision == .deny(.packageOff))
    }

    @Test func missingCapabilityDeniesBeforeSessionChecks() async {
        let subject = policy(supported: [])
        let decision = await subject.evaluate(
            .clipboard,
            package: package,
            context: IntegrationContext(
                hasSession: false, windowIsKey: false,
                requiredCapability: "clipboard.text.v1")
        )
        #expect(decision == .deny(.notSupported))
    }

    @Test func sessionlessDenies() async {
        let subject = policy()
        let decision = await subject.evaluate(
            .clipboard, package: package, context: context(session: false))
        #expect(decision == .deny(.noSession))
    }

    @Test func unfocusedDenies() async {
        let subject = policy()
        let decision = await subject.evaluate(
            .clipboard, package: package, context: context(key: false))
        #expect(decision == .deny(.notFocused))
    }

    @Test func linksDefaultAsks() async {
        let subject = policy()
        let decision = await subject.evaluate(.links, package: package, context: context())
        #expect(decision == .ask)
    }

    @Test func sharedFoldersOffDenies() async {
        let subject = policy()
        let decision = await subject.evaluate(
            .sharedFolders, package: package, context: context())
        #expect(decision == .deny(.packageOff))
    }

    @Test func microphoneDefaultsOff() async {
        let subject = policy()
        let decision = await subject.evaluate(
            .microphone, package: package, context: context())
        #expect(decision == .deny(.packageOff))
    }

    @Test func denialsAreCountedPerKindAndReason() async {
        let subject = policy(packageValues: ["clipboard": "false"])
        _ = await subject.evaluate(.clipboard, package: package, context: context())
        _ = await subject.evaluate(.clipboard, package: package, context: context(key: false))
        // Notifications are event-driven and do not need a session or key
        // window (§5.3); a no-session deny uses a kind that needs one.
        _ = await subject.evaluate(.files, package: package, context: context(session: false))
        let counts = await subject.denialCounts
        #expect(counts.count(.clipboard, .packageOff) == 2)
        #expect(counts.count(.files, .noSession) == 1)
        #expect(counts.count(.notifications, .notFocused) == 0)
    }
}

/// A recording `IntegrationChannel` for the coordinator tests.
private actor FakeChannel: IntegrationChannel {
    var clips: [GPClipData] = []
    var failure: IntegrationFailure?
    var imagesSupported = false
    var uploads: [Data] = []
    var inbound: [UInt64: Data] = [:]

    func setClipboard(_ clip: GPClipData) async throws(IntegrationFailure) {
        if let failure { throw failure }
        clips.append(clip)
    }

    func supportsImages() async -> Bool { imagesSupported }

    func uploadClipboardImage(_ png: Data) async throws(IntegrationFailure) -> UInt64 {
        uploads.append(png)
        return UInt64(uploads.count)
    }

    func inboundTransfer(_ transferID: UInt64) async -> Data? { inbound[transferID] }

    func setImagesSupported(_ value: Bool) { imagesSupported = value }

    func setInbound(_ transferID: UInt64, data: Data) { inbound[transferID] = data }
}

private func coordinator(
    packageValues: [String: String] = [:],
    globalsEnabled: [IntegrationKind: Bool] = [:],
    supported: Set<String> = ["clipboard.text.v1"],
    channel: FakeChannel = FakeChannel()
) -> (ClipboardCoordinator, FakeChannel, CheckedContinuationBox) {
    let box = CheckedContinuationBox()
    let subject = ClipboardCoordinator(
        policy: policy(
            packageValues: packageValues, globalsEnabled: globalsEnabled,
            supported: supported),
        channel: channel
    ) { sessionID, packageID, item in
        await box.record(sessionID: sessionID, packageID: packageID, item: item)
    }
    return (subject, channel, box)
}

/// Collects the `onGuestClip` deliveries.
private actor CheckedContinuationBox {
    struct Delivery: Equatable {
        var sessionID: UUID
        var packageID: RuntimePackageID
        var item: ClipItem
    }

    var deliveries: [Delivery] = []

    func record(sessionID: UUID, packageID: RuntimePackageID, item: ClipItem) {
        deliveries.append(Delivery(sessionID: sessionID, packageID: packageID, item: item))
    }
}

private func item(_ text: String, sensitive: Bool = false) -> ClipItem {
    ClipItem(
        text: text,
        html: nil,
        sensitive: sensitive,
        digest: ClipboardCoordinator.digest(text: text)!,
        truncated: false
    )
}

private func guestClip(_ text: String, source: String = "") -> GPClipData {
    var clip = GPClipData()
    clip.origin = .guest
    clip.text = text
    clip.sourcePackage = source
    return clip
}

@Suite("ClipboardCoordinator (desktop-integration.md §4)")
struct ClipboardCoordinatorTests {
    @Test func pushAcksAndReachesTheChannel() async throws {
        let (subject, channel, _) = coordinator()
        let session = UUID()
        await subject.noteFocusChanged(sessionID: session, packageID: package, isKey: true)

        let ack = try await subject.push(sessionID: session, packageID: package, item: item("héllo 😀"))

        #expect(ack.seq == 1)
        let clips = await channel.clips
        #expect(clips.count == 1)
        #expect(clips[0].origin == .host)
        #expect(clips[0].text == "héllo 😀")
    }

    @Test func pushWithoutKeyWindowIsRefused() async {
        let (subject, _, _) = coordinator()
        await #expect(throws: IntegrationFailure.self) {
            try await subject.push(sessionID: UUID(), packageID: package, item: item("x"))
        }
        await #expect(throws: IntegrationFailure.self) {
            try await subject.push(sessionID: UUID(), packageID: package, item: item("x"))
        }
    }

    @Test func guestClipReachesTheKeySession() async {
        let (subject, _, box) = coordinator()
        let session = UUID()
        await subject.noteFocusChanged(sessionID: session, packageID: package, isKey: true)

        await subject.guestChanged(guestClip("from android"))

        let deliveries = await box.deliveries
        #expect(deliveries.count == 1)
        #expect(deliveries[0].sessionID == session)
        #expect(deliveries[0].item.text == "from android")
    }

    @Test func guestClipWithoutKeyWindowIsDropped() async {
        let (subject, _, box) = coordinator()
        await subject.guestChanged(guestClip("unheard"))
        let deliveries = await box.deliveries
        #expect(deliveries.isEmpty)
    }

    @Test func guestClipWithClipboardOffIsDroppedAndCounted() async {
        let (subject, _, box) = coordinator(packageValues: ["clipboard": "false"])
        let session = UUID()
        await subject.noteFocusChanged(sessionID: session, packageID: package, isKey: true)

        await subject.guestChanged(guestClip("denied"))

        let deliveries = await box.deliveries
        #expect(deliveries.isEmpty)
    }

    @Test func guestClipFromAnotherPackageWithClipboardOffIsDropped() async {
        let other = RuntimePackageID(rawValue: "com.other.app")!
        let settings = IntegrationSettingsSource(
            packageValue: { _, packageID in packageID == other ? "false" : nil },
            globalEnabled: { _ in true },
            supported: { _ in true }
        )
        let box = CheckedContinuationBox()
        let subject = ClipboardCoordinator(
            policy: IntegrationPolicy(source: settings), channel: FakeChannel()
        ) { sessionID, packageID, item in
            await box.record(sessionID: sessionID, packageID: packageID, item: item)
        }
        let session = UUID()
        await subject.noteFocusChanged(sessionID: session, packageID: package, isKey: true)

        await subject.guestChanged(guestClip("foreign", source: other.rawValue))

        let deliveries = await box.deliveries
        #expect(deliveries.isEmpty)
    }

    @Test func guestClipFromAnotherClipboardPackageIsDelivered() async {
        let other = RuntimePackageID(rawValue: "com.other.clipallowed")!
        let settings = IntegrationSettingsSource(
            packageValue: { _, packageID in packageID == other ? "true" : nil },
            globalEnabled: { _ in true },
            supported: { _ in true }
        )
        let box = CheckedContinuationBox()
        let subject = ClipboardCoordinator(
            policy: IntegrationPolicy(source: settings), channel: FakeChannel()
        ) { sessionID, packageID, item in
            await box.record(sessionID: sessionID, packageID: packageID, item: item)
        }
        let session = UUID()
        await subject.noteFocusChanged(sessionID: session, packageID: package, isKey: true)

        await subject.guestChanged(guestClip("system dialog", source: other.rawValue))

        let deliveries = await box.deliveries
        #expect(deliveries.count == 1)
    }

    @Test func hostEchoIsDropped() async throws {
        let (subject, channel, box) = coordinator()
        let session = UUID()
        await subject.noteFocusChanged(sessionID: session, packageID: package, isKey: true)
        _ = try await subject.push(sessionID: session, packageID: package, item: item("same"))

        await subject.guestChanged(guestClip("same"))

        let deliveries = await box.deliveries
        #expect(deliveries.isEmpty)
        #expect(await channel.clips.count == 1)
    }

    @Test func oversizedHtmlIsRefused() async {
        let (subject, channel, _) = coordinator()
        let session = UUID()
        await subject.noteFocusChanged(sessionID: session, packageID: package, isKey: true)
        var tooBig = item("small")
        tooBig.html = String(repeating: "a", count: Int(ClipboardCoordinator.htmlByteLimit) + 1)

        await #expect(throws: IntegrationFailure.self) {
            try await subject.push(sessionID: session, packageID: package, item: tooBig)
        }
        #expect(await channel.clips.isEmpty)
    }

    @Test func digestIsNFCNormalized() {
        // U+0065 U+0301 vs U+00E9 digest to the same value (§4.4 signal 2).
        let decomposed = ClipboardCoordinator.digest(text: "e\u{301}")
        let composed = ClipboardCoordinator.digest(text: "\u{E9}")
        #expect(decomposed == composed)
    }
}

@Suite("Clipboard loop prevention (desktop-integration.md §4.4)")
struct ClipboardLoopTests {
    /// Round trip Mac → Android: the guest's ClipboardChanged for the clip the
    /// host just pushed carries the same text, and the digest guard drops it.
    @Test func pushedClipDoesNotComeBack() async throws {
        let (subject, channel, box) = coordinator()
        let session = UUID()
        await subject.noteFocusChanged(sessionID: session, packageID: package, isKey: true)

        _ = try await subject.push(sessionID: session, packageID: package, item: item("ping"))
        // The guest agent fires its listener for our own write (ClipboardBridge
        // skips it; if an old agent still publishes it, the digest guard drops it).
        var echo = GPClipData()
        echo.origin = .guest
        echo.text = "ping"
        await subject.guestChanged(echo)

        #expect(await box.deliveries.isEmpty)
        #expect(await channel.clips.count == 1)
    }

    /// Round trip Android → Mac: the clip written to the pasteboard carries the
    /// io.apkrun.clip-origin marker (PasteboardAdapter); a repeat of the same
    /// ClipboardChanged is not suppressed at the coordinator (the marker is the
    /// guard), but a second identical guest event is delivered only once by the
    /// adapter digest comparison.
    @Test func writtenClipDigestIsRecorded() async {
        let (subject, _, _) = coordinator()
        let session = UUID()
        let digest = ClipboardCoordinator.digest(text: "android clip")!

        await subject.noteWritten(
            sessionID: session,
            written: ClipboardWritten(changeCount: 7, digest: digest))

        let last = await subject.lastWrite
        #expect(last?.sessionID == session)
        #expect(last?.changeCount == 7)
        #expect(last?.digest == digest)
    }

    /// Alternating copies between two sessions: each push has its own seq, no
    /// clip crosses without the matching key window.
    @Test func twoSessionsDoNotCrossClips() async throws {
        let other = RuntimePackageID(rawValue: "io.apkrun.fixture.other")!
        let settings = IntegrationSettingsSource(
            packageValue: { _, _ in "true" },
            globalEnabled: { _ in true },
            supported: { _ in true }
        )
        let box = CheckedContinuationBox()
        let channel = FakeChannel()
        let subject = ClipboardCoordinator(
            policy: IntegrationPolicy(source: settings), channel: channel
        ) { sessionID, packageID, item in
            await box.record(sessionID: sessionID, packageID: packageID, item: item)
        }
        let sessionA = UUID()
        let sessionB = UUID()

        await subject.noteFocusChanged(sessionID: sessionA, packageID: package, isKey: true)
        _ = try await subject.push(sessionID: sessionA, packageID: package, item: item("a"))
        await subject.noteFocusChanged(sessionID: sessionA, packageID: package, isKey: false)
        await subject.noteFocusChanged(sessionID: sessionB, packageID: other, isKey: true)
        _ = try await subject.push(sessionID: sessionB, packageID: other, item: item("b"))

        // A clip copied in B's app reaches B's window, not A's.
        await subject.guestChanged(guestClip("b clip", source: other.rawValue))

        let deliveries = await box.deliveries
        #expect(deliveries.count == 1)
        #expect(deliveries[0].sessionID == sessionB)
        #expect(await channel.clips.count == 2)
        #expect(await channel.clips[0].seq == 1)
        #expect(await channel.clips[1].seq == 2)
    }
}

private func imageItem(
    text: String? = nil,
    png: Data = testPNG,
    width: Int = 4,
    height: Int = 4
) -> ClipItem {
    let image = ClipImage(png: png, pixelWidth: width, pixelHeight: height)
    // The combined digest of ClipboardCoordinator.item(for:) — text plus
    // the image digest — so a pushed item and its echo compare equal.
    let digest: RuntimeSHA256Digest?
    if let imageDigest = ClipboardCoordinator.digest(imageBytes: png) {
        var hasher = SHA256()
        hasher.update(data: Data((text ?? "").utf8))
        hasher.update(data: Data(imageDigest.rawValue.utf8))
        digest = RuntimeSHA256Digest(
            rawValue: "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined())
    } else {
        digest = ClipboardCoordinator.digest(text: text ?? "")
    }
    return ClipItem(
        text: text,
        image: image,
        digest: digest ?? ClipboardCoordinator.digest(text: text ?? "")!,
        truncated: false
    )
}

@Suite("Clipboard images and HTML (desktop-integration.md §4.4, #81)")
struct ClipboardImageTests {
    @Test func anImageUploadsOnTheBulkChannelBeforeTheClip() async throws {
        let channel = FakeChannel()
        await channel.setImagesSupported(true)
        let box = CheckedContinuationBox()
        let subject = ClipboardCoordinator(
            policy: policy(), channel: channel
        ) { sessionID, packageID, item in
            await box.record(sessionID: sessionID, packageID: packageID, item: item)
        }
        let session = UUID()
        await subject.noteFocusChanged(sessionID: session, packageID: package, isKey: true)

        let png = Data([9, 8, 7])
        let ack = try await subject.push(
            sessionID: session, packageID: package, item: imageItem(text: "cap", png: png))

        #expect(ack.droppedImageTooLarge == false)
        #expect(await channel.uploads == [png])
        let clips = await channel.clips
        #expect(clips.count == 1)
        #expect(clips[0].hasImage)
        #expect(clips[0].image.transferID == 1)
        #expect(clips[0].image.mimeType == "image/png")
        #expect(clips[0].text == "cap")
    }

    @Test func htmlTravelsWithItsText() async throws {
        let (subject, channel, _) = coordinator()
        let session = UUID()
        await subject.noteFocusChanged(sessionID: session, packageID: package, isKey: true)
        var clip = item("bold")
        clip.html = "<b>bold</b>"

        _ = try await subject.push(sessionID: session, packageID: package, item: clip)

        #expect(await channel.clips[0].html == "<b>bold</b>")
        #expect(await channel.clips[0].text == "bold")
    }

    @Test func anOversizedImageIsDroppedButTheTextGoes() async throws {
        let channel = FakeChannel()
        await channel.setImagesSupported(true)
        let box = CheckedContinuationBox()
        let subject = ClipboardCoordinator(
            policy: policy(), channel: channel
        ) { sessionID, packageID, item in
            await box.record(sessionID: sessionID, packageID: packageID, item: item)
        }
        let session = UUID()
        await subject.noteFocusChanged(sessionID: session, packageID: package, isKey: true)
        let big = imageItem(
            text: "the caption survives",
            png: Data(
                repeating: 0xFF,
                count: Int(ClipboardCoordinator.imageByteLimit) + 1))

        let ack = try await subject.push(sessionID: session, packageID: package, item: big)

        #expect(ack.droppedImageTooLarge == true)
        #expect(await channel.uploads.isEmpty)
        let clips = await channel.clips
        #expect(clips.count == 1)
        #expect(clips[0].hasImage == false)
        #expect(clips[0].text == "the caption survives")
    }

    @Test func anOversizedImagePixelCountIsDropped() async throws {
        let channel = FakeChannel()
        await channel.setImagesSupported(true)
        let box = CheckedContinuationBox()
        let subject = ClipboardCoordinator(
            policy: policy(), channel: channel
        ) { sessionID, packageID, item in
            await box.record(sessionID: sessionID, packageID: packageID, item: item)
        }
        let session = UUID()
        await subject.noteFocusChanged(sessionID: session, packageID: package, isKey: true)
        let wide = imageItem(text: "t", width: ClipboardCoordinator.imagePixelLimit + 1)

        let ack = try await subject.push(sessionID: session, packageID: package, item: wide)

        #expect(ack.droppedImageTooLarge == true)
        #expect(await channel.clips[0].hasImage == false)
    }

    @Test func anOversizedImageAloneIsRefused() async {
        let channel = FakeChannel()
        await channel.setImagesSupported(true)
        let box = CheckedContinuationBox()
        let subject = ClipboardCoordinator(
            policy: policy(), channel: channel
        ) { sessionID, packageID, item in
            await box.record(sessionID: sessionID, packageID: packageID, item: item)
        }
        let session = UUID()
        await subject.noteFocusChanged(sessionID: session, packageID: package, isKey: true)
        let big = imageItem(
            png: Data(
                repeating: 0xFF,
                count: Int(ClipboardCoordinator.imageByteLimit) + 1))

        await #expect(throws: IntegrationFailure.self) {
            try await subject.push(sessionID: session, packageID: package, item: big)
        }
        #expect(await channel.clips.isEmpty)
    }

    @Test func anImageClipWithoutTheCapabilityAnswersUnsupported() async {
        let (subject, channel, _) = coordinator()
        let session = UUID()
        await subject.noteFocusChanged(sessionID: session, packageID: package, isKey: true)

        await #expect(throws: IntegrationFailure.self) {
            try await subject.push(
                sessionID: session, packageID: package, item: imageItem())
        }
        #expect(await channel.clips.isEmpty)
    }

    @Test func aMixedClipWithoutTheCapabilityStillSendsItsText() async throws {
        let (subject, channel, _) = coordinator()
        let session = UUID()
        await subject.noteFocusChanged(sessionID: session, packageID: package, isKey: true)

        let ack = try await subject.push(
            sessionID: session, packageID: package,
            item: imageItem(text: "text without the image"))

        #expect(ack.droppedImageTooLarge == false)
        let clips = await channel.clips
        #expect(clips.count == 1)
        #expect(clips[0].hasImage == false)
        #expect(clips[0].text == "text without the image")
    }

    @Test func aGuestImageResolvesThroughTheInboundTransfer() async throws {
        let channel = FakeChannel()
        let box = CheckedContinuationBox()
        let subject = ClipboardCoordinator(
            policy: policy(), channel: channel
        ) { sessionID, packageID, item in
            await box.record(sessionID: sessionID, packageID: packageID, item: item)
        }
        let session = UUID()
        await subject.noteFocusChanged(sessionID: session, packageID: package, isKey: true)
        let png = testPNG
        await channel.setInbound(3, data: png)
        var clip = guestClip("")
        clip.image.transferID = 3
        clip.image.width = 2
        clip.image.height = 2
        clip.image.mimeType = "image/png"

        await subject.guestChanged(clip)

        let deliveries = await box.deliveries
        #expect(deliveries.count == 1)
        #expect(deliveries[0].item.image?.png == png)
        // The announced 2x2 is not trusted: the item carries the PNG's real size.
        #expect(deliveries[0].item.image?.pixelWidth == 1)
    }

    @Test func aGuestImageClipWithoutItsBytesStillDeliversTheText() async {
        let channel = FakeChannel()
        let box = CheckedContinuationBox()
        let subject = ClipboardCoordinator(
            policy: policy(), channel: channel
        ) { sessionID, packageID, item in
            await box.record(sessionID: sessionID, packageID: packageID, item: item)
        }
        let session = UUID()
        await subject.noteFocusChanged(sessionID: session, packageID: package, isKey: true)
        var clip = guestClip("note with a lost image")
        clip.image.transferID = 5
        clip.image.mimeType = "image/png"

        await subject.guestChanged(clip)

        let deliveries = await box.deliveries
        #expect(deliveries.count == 1)
        #expect(deliveries[0].item.text == "note with a lost image")
        #expect(deliveries[0].item.image == nil)
    }

    @Test func aPushedImageDoesNotComeBack() async throws {
        let channel = FakeChannel()
        await channel.setImagesSupported(true)
        let box = CheckedContinuationBox()
        let subject = ClipboardCoordinator(
            policy: policy(), channel: channel
        ) { sessionID, packageID, item in
            await box.record(sessionID: sessionID, packageID: packageID, item: item)
        }
        let session = UUID()
        await subject.noteFocusChanged(sessionID: session, packageID: package, isKey: true)
        let png = testPNG
        _ = try await subject.push(
            sessionID: session, packageID: package, item: imageItem(png: png))
        // The guest echoes the clip it just wrote: same image bytes.
        var echo = GPClipData()
        echo.origin = .guest
        echo.image.transferID = 1
        echo.image.mimeType = "image/png"
        await channel.setInbound(1, data: png)

        await subject.guestChanged(echo)

        #expect(await box.deliveries.isEmpty)
    }

    @Test func aDifferentImageWithTheSameTextIsNotAnEcho() async throws {
        let channel = FakeChannel()
        let box = CheckedContinuationBox()
        let subject = ClipboardCoordinator(
            policy: policy(), channel: channel
        ) { sessionID, packageID, item in
            await box.record(sessionID: sessionID, packageID: packageID, item: item)
        }
        let session = UUID()
        await subject.noteFocusChanged(sessionID: session, packageID: package, isKey: true)
        _ = try await subject.push(
            sessionID: session, packageID: package,
            item: imageItem(text: "same caption", png: testPNG))
        // The guest then copies a different image under the same text.
        let otherPNG = Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        )!
        var copy = GPClipData()
        copy.origin = .guest
        copy.text = "same caption"
        copy.image.transferID = 7
        copy.image.mimeType = "image/png"
        await channel.setInbound(7, data: otherPNG)

        await subject.guestChanged(copy)

        let deliveries = await box.deliveries
        #expect(deliveries.count == 1)
        #expect(deliveries[0].item.image?.png == otherPNG)
    }

    @Test func aNonPNGInboundImageIsDroppedNotTrusted() async {
        let channel = FakeChannel()
        let box = CheckedContinuationBox()
        let subject = ClipboardCoordinator(
            policy: policy(), channel: channel
        ) { sessionID, packageID, item in
            await box.record(sessionID: sessionID, packageID: packageID, item: item)
        }
        let session = UUID()
        await subject.noteFocusChanged(sessionID: session, packageID: package, isKey: true)
        await channel.setInbound(9, data: Data([0x00, 0x01, 0x02]))
        var clip = guestClip("text survives a bad image")
        clip.image.transferID = 9
        clip.image.width = 1
        clip.image.height = 1
        clip.image.mimeType = "image/png"

        await subject.guestChanged(clip)

        let deliveries = await box.deliveries
        #expect(deliveries.count == 1)
        #expect(deliveries[0].item.text == "text survives a bad image")
        #expect(deliveries[0].item.image == nil)
    }
}
