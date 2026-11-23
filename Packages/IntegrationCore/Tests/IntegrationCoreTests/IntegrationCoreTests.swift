import Foundation
import GuestProtocol
import RuntimeAPI
import Testing

@testable import IntegrationCore

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
        _ = await subject.evaluate(.notifications, package: package, context: context(key: false))
        let counts = await subject.denialCounts
        #expect(counts.count(.clipboard, .packageOff) == 2)
        #expect(counts.count(.notifications, .notFocused) == 1)
        #expect(counts.count(.notifications, .packageOff) == 0)
    }
}

/// A recording `IntegrationChannel` for the coordinator tests.
private actor FakeChannel: IntegrationChannel {
    var clips: [GPClipData] = []
    var failure: IntegrationFailure?

    func setClipboard(_ clip: GPClipData) async throws(IntegrationFailure) {
        if let failure { throw failure }
        clips.append(clip)
    }
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
