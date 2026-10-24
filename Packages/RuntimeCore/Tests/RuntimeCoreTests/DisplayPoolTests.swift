import CoreGraphics
import Foundation
import GraphicsCore
import Testing

@testable import RuntimeCore

@Test
func displayPoolAllocatesCorrelatedDisplayAndReleasesItAfterRemoval() async throws {
    let guest = FakeDisplayControlChannel()
    let scanouts = FakeScanoutController(guest: guest)
    let pool = DisplayPool(scanouts: scanouts, guest: guest)
    let session = SessionID.app(UUID())
    let lease = try await pool.acquire(
        for: session,
        configuration: DisplayConfiguration(
            geometry: DisplayGeometry(pointSize: CGSize(width: 480, height: 850), backingScale: 2)
        )
    )

    #expect(lease.session == session)
    #expect(lease.scanout.rawValue == 1)
    #expect(lease.androidDisplayID == 1)
    #expect(lease.mode.pixelSize == PixelSize(width: 960, height: 1700))
    #expect(lease.mode.densityDpi == 320)
    #expect((await pool.snapshot())[0].state == .allocated(session))
    let appliedPolicies = guest.policySnapshot()
    #expect(appliedPolicies == [DisplayPolicyCall(displayID: 1, densityDPI: 320, imePolicy: .local)])

    #expect(await pool.release(lease) == .released)

    #expect((await pool.snapshot())[0].state == .free)
    #expect(
        scanouts.detachedGenerations
            == [DetachCall(scanout: 1, generation: lease.pool.generation)]
    )
    #expect(scanouts.disabledScanouts == [1])
}

@Test
func displayPoolForwardsVisibilityOnlyForTheCurrentLease() async throws {
    let guest = FakeDisplayControlChannel()
    let scanouts = FakeScanoutController(guest: guest)
    let pool = DisplayPool(scanouts: scanouts, guest: guest)
    let lease = try await pool.acquire(
        for: .app(UUID()),
        configuration: DisplayConfiguration(
            geometry: DisplayGeometry(pointSize: CGSize(width: 480, height: 850), backingScale: 1)
        )
    )

    await pool.visibilityChanged(true, for: lease)
    await pool.visibilityChanged(false, for: lease)
    #expect(
        scanouts.visibilityChanges
            == [VisibilityCall(scanout: 1, visible: true), VisibilityCall(scanout: 1, visible: false)]
    )

    #expect(await pool.release(lease) == .released)
    await pool.visibilityChanged(true, for: lease)
    #expect(scanouts.visibilityChanges.count == 2)
}

@Test
func displayPoolEnforcesTheSoftAppSessionLimit() async throws {
    let guest = FakeDisplayControlChannel()
    let scanouts = FakeScanoutController(guest: guest)
    let pool = DisplayPool(
        scanouts: scanouts,
        guest: guest,
        limits: DisplayPoolLimits(maxSessions: 1, attachTimeout: .milliseconds(20))
    )
    let configuration = DisplayConfiguration(
        geometry: DisplayGeometry(pointSize: CGSize(width: 480, height: 850), backingScale: 1)
    )
    _ = try await pool.acquire(for: .app(UUID()), configuration: configuration)

    do {
        _ = try await pool.acquire(for: .app(UUID()), configuration: configuration)
        Issue.record("The second app session unexpectedly acquired a display.")
    } catch {
        #expect(error == .exhausted(maxSessions: 1))
    }
    #expect(scanouts.configuredScanouts == [1])
}

@Test
func displayPoolLeasesPrimaryCompatibilityDisplayExclusivelyAndRestoresDensity() async throws {
    let guest = FakeDisplayControlChannel()
    guest.emit(
        .changed(
            GuestDisplaySnapshot(
                displayID: 0,
                mode: GuestDisplaySize(width: 960, height: 1700),
                densityDPI: 420
            )
        )
    )
    let scanouts = FakeScanoutController(guest: guest)
    let (frames, _) = AsyncStream<ScanoutFrame>.makeStream()
    let primaryPool = ScanoutPoolHandle(generation: 1, surfaces: [], frames: frames)
    let pool = DisplayPool(
        scanouts: scanouts,
        guest: guest,
        primaryPool: primaryPool,
        limits: DisplayPoolLimits(maxSessions: 1)
    )
    let primaryConfiguration = DisplayConfiguration(
        geometry: DisplayGeometry(pointSize: CGSize(width: 480, height: 850), backingScale: 2),
        mode: .primaryDisplayCompatibility
    )
    let primary = try await pool.acquire(for: .app(UUID()), configuration: primaryConfiguration)

    #expect(primary.scanout.rawValue == 0)
    #expect(primary.androidDisplayID == 0)
    #expect(primary.pool.generation == primaryPool.generation)
    #expect(scanouts.configuredScanouts.isEmpty)
    #expect(guest.policySnapshot() == [DisplayPolicyCall(displayID: 0, densityDPI: 320, imePolicy: .local)])

    await #expect(throws: DisplayPoolFailure.primaryDisplayBusy) {
        try await pool.acquire(for: .app(UUID()), configuration: primaryConfiguration)
    }
    await #expect(
        throws: DisplayPoolFailure.exhausted(maxSessions: 1)
    ) {
        try await pool.acquire(
            for: .app(UUID()),
            configuration: DisplayConfiguration(
                geometry: DisplayGeometry(pointSize: CGSize(width: 480, height: 850), backingScale: 1)
            )
        )
    }

    #expect(await pool.release(primary) == .released)
    #expect(
        guest.policySnapshot()
            == [
                DisplayPolicyCall(displayID: 0, densityDPI: 320, imePolicy: .local),
                DisplayPolicyCall(displayID: 0, densityDPI: 420, imePolicy: .local),
            ]
    )
}

@Test
func displayPoolSerializesConcurrentAttachesAndKeepsDisplayIDsDistinct() async throws {
    let guest = FakeDisplayControlChannel()
    let scanouts = FakeScanoutController(guest: guest)
    let pool = DisplayPool(scanouts: scanouts, guest: guest)
    let configuration = DisplayConfiguration(
        geometry: DisplayGeometry(pointSize: CGSize(width: 480, height: 850), backingScale: 1)
    )

    async let first = pool.acquire(for: .app(UUID()), configuration: configuration)
    async let second = pool.acquire(for: .app(UUID()), configuration: configuration)
    let leases = try await [first, second]

    #expect(Set(leases.map(\.scanout.rawValue)).count == 2)
    #expect(Set(leases.map(\.androidDisplayID)).count == 2)
    #expect(Set(scanouts.configuredScanouts).count == 2)
    await pool.release(leases[0])
    await pool.release(leases[1])
    #expect((await pool.snapshot()).allSatisfy { $0.state == .free })
}

@Test
func displayPoolIgnoresAStaleLeaseAfterReconfiguration() async throws {
    let guest = FakeDisplayControlChannel()
    let scanouts = FakeScanoutController(guest: guest)
    let pool = DisplayPool(scanouts: scanouts, guest: guest)
    let session = SessionID.app(UUID())
    let lease = try await pool.acquire(
        for: session,
        configuration: DisplayConfiguration(
            geometry: DisplayGeometry(pointSize: CGSize(width: 480, height: 850), backingScale: 1)
        )
    )
    let replacement = try await pool.reconfigure(
        lease,
        geometry: DisplayGeometry(pointSize: CGSize(width: 640, height: 960), backingScale: 1)
    )

    #expect(replacement.pool.generation != lease.pool.generation)
    await pool.release(lease)
    #expect((await pool.snapshot())[0].state == .allocated(session))
    #expect(scanouts.disabledScanouts.isEmpty)

    await pool.release(replacement)
    #expect((await pool.snapshot())[0].state == .free)
    #expect(
        scanouts.detachedGenerations
            == [DetachCall(scanout: 1, generation: replacement.pool.generation)]
    )
}

@Test
func displayPoolKeepsTheRequestedDensityWhenGuestReportsFallbackDensity() async throws {
    let guest = FakeDisplayControlChannel()
    let scanouts = FakeScanoutController(guest: guest)
    let pool = DisplayPool(scanouts: scanouts, guest: guest)
    let lease = try await pool.acquire(
        for: .app(UUID()),
        configuration: DisplayConfiguration(
            geometry: DisplayGeometry(pointSize: CGSize(width: 480, height: 850), backingScale: 2)
        )
    )

    #expect(lease.mode.densityDpi == 320)
    #expect(guest.policySnapshot().first?.densityDPI == 320)
    await pool.release(lease)
}

@Test
func displayPoolUsesTheReportedModeWhenProductIdentityMatches() async throws {
    let guest = FakeDisplayControlChannel()
    let scanouts = FakeScanoutController(
        guest: guest,
        reportedSize: GuestDisplaySize(width: 800, height: 1280)
    )
    let pool = DisplayPool(scanouts: scanouts, guest: guest)
    let lease = try await pool.acquire(
        for: .app(UUID()),
        configuration: DisplayConfiguration(
            geometry: DisplayGeometry(pointSize: CGSize(width: 480, height: 850), backingScale: 2)
        )
    )

    #expect(lease.androidDisplayID == 1)
    #expect(lease.mode.pixelSize == PixelSize(width: 800, height: 1280))
    await pool.release(lease)
}

@Test
func displayPoolDoesNotConfirmResizeFromASupersededDisplayEvent() async throws {
    let guest = FakeDisplayControlChannel()
    let scanouts = FakeScanoutController(
        guest: guest,
        reconfigureFollowupSize: GuestDisplaySize(width: 600, height: 900)
    )
    let pool = DisplayPool(
        scanouts: scanouts,
        guest: guest,
        limits: DisplayPoolLimits(
            removalTimeout: .milliseconds(20),
            reconfigureTimeout: .milliseconds(20)
        )
    )
    let session = SessionID.app(UUID())
    let lease = try await pool.acquire(
        for: session,
        configuration: DisplayConfiguration(
            geometry: DisplayGeometry(pointSize: CGSize(width: 480, height: 850), backingScale: 1)
        )
    )

    await #expect(throws: DisplayPoolFailure.reconfigureFailed(stateUncertain: false)) {
        try await pool.reconfigure(
            lease,
            geometry: DisplayGeometry(pointSize: CGSize(width: 640, height: 960), backingScale: 1)
        )
    }
    #expect((await pool.snapshot())[0].state == .allocated(session))
    #expect((await pool.snapshot())[0].mode?.pixelSize == PixelSize(width: 480, height: 850))
    #expect(await pool.release(lease) == .released)
}

@Test
func displayPoolUsesUniqueProductlessDisplayAtItsReportedMode() async throws {
    let guest = FakeDisplayControlChannel()
    let scanouts = FakeScanoutController(
        guest: guest,
        reportedSize: GuestDisplaySize(width: 800, height: 1280),
        includeProductInfo: false
    )
    let pool = DisplayPool(
        scanouts: scanouts,
        guest: guest,
        limits: DisplayPoolLimits(attachTimeout: .milliseconds(20), removalTimeout: .milliseconds(20))
    )

    let lease = try await pool.acquire(
        for: .app(UUID()),
        configuration: DisplayConfiguration(
            geometry: DisplayGeometry(pointSize: CGSize(width: 480, height: 850), backingScale: 2)
        )
    )
    #expect(lease.mode.pixelSize == PixelSize(width: 800, height: 1280))
    #expect(await pool.release(lease) == .released)
}

@Test
func displayPoolDoesNotSelectAProductlessDisplayAfterRemoval() async {
    let guest = FakeDisplayControlChannel()
    let scanouts = FakeScanoutController(
        guest: guest,
        includeProductInfo: false,
        removeBeforeAttachTimeout: true
    )
    let pool = DisplayPool(
        scanouts: scanouts,
        guest: guest,
        limits: DisplayPoolLimits(attachTimeout: .milliseconds(20), removalTimeout: .milliseconds(20))
    )

    await #expect(throws: DisplayPoolFailure.attachFailed(scanout: 2)) {
        try await pool.acquire(
            for: .app(UUID()),
            configuration: DisplayConfiguration(
                geometry: DisplayGeometry(pointSize: CGSize(width: 480, height: 850), backingScale: 1)
            )
        )
    }
    #expect(scanouts.configuredScanouts == [1, 2])
    #expect((await pool.snapshot()).allSatisfy { if case .allocated = $0.state { false } else { true } })
}

@Test
func displayPoolPreservesGuestFailureAndDoesNotRetryItOnAnotherSlot() async throws {
    let guest = FakeDisplayControlChannel(failPolicy: true)
    let scanouts = FakeScanoutController(guest: guest)
    let pool = DisplayPool(
        scanouts: scanouts,
        guest: guest,
        limits: DisplayPoolLimits(attachTimeout: .milliseconds(20), removalTimeout: .milliseconds(20))
    )

    await #expect(throws: DisplayPoolFailure.guest(.operationFailed)) {
        try await pool.acquire(
            for: .app(UUID()),
            configuration: DisplayConfiguration(
                geometry: DisplayGeometry(pointSize: CGSize(width: 480, height: 850), backingScale: 1)
            )
        )
    }
    #expect(scanouts.configuredScanouts == [1])
    for _ in 0..<10 {
        if (await pool.snapshot()).first?.state == .free {
            break
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect((await pool.snapshot()).first?.state == .free)
}

@Test
func displayPoolKeepsAReleaseTimeoutQuarantinedUntilTheGuestRestarts() async throws {
    let guest = FakeDisplayControlChannel()
    let scanouts = FakeScanoutController(guest: guest, removeOnDisable: false)
    let pool = DisplayPool(
        scanouts: scanouts,
        guest: guest,
        limits: DisplayPoolLimits(
            clearTimeout: .milliseconds(10),
            removalTimeout: .milliseconds(10)
        )
    )
    let lease = try await pool.acquire(
        for: .app(UUID()),
        configuration: DisplayConfiguration(
            geometry: DisplayGeometry(pointSize: CGSize(width: 480, height: 850), backingScale: 1)
        )
    )

    #expect(await pool.release(lease) == .quarantined(androidDisplayID: lease.androidDisplayID))
    try await Task.sleep(for: .milliseconds(60))

    let faulted = try #require((await pool.snapshot()).first)
    #expect(faulted.state == .faulted(.releaseTimedOut))
    #expect(faulted.androidDisplayID == lease.androidDisplayID)
    #expect(scanouts.configuredScanouts == [1])
    #expect(await pool.release(lease) == .staleLease)

    await pool.guestRestarted()
    #expect((await pool.snapshot()).first?.state == .free)
}

@Test
func displayPoolQuarantinesAResizeWhenHostRollbackFails() async throws {
    let guest = FakeDisplayControlChannel(failPolicyCalls: [2])
    let scanouts = FakeScanoutController(guest: guest, configurationFailureCalls: [3])
    let pool = DisplayPool(
        scanouts: scanouts,
        guest: guest,
        limits: DisplayPoolLimits(maxSessions: 1, removalTimeout: .milliseconds(20))
    )
    let session = SessionID.app(UUID())
    let configuration = DisplayConfiguration(
        geometry: DisplayGeometry(pointSize: CGSize(width: 480, height: 850), backingScale: 1)
    )
    let lease = try await pool.acquire(
        for: session,
        configuration: configuration
    )

    await #expect(throws: DisplayPoolFailure.reconfigureFailed(stateUncertain: true)) {
        try await pool.reconfigure(
            lease,
            geometry: DisplayGeometry(pointSize: CGSize(width: 640, height: 960), backingScale: 1)
        )
    }
    #expect((await pool.snapshot())[0].state == .faulted(.reconfigurationUncertain))
    await #expect(throws: DisplayPoolFailure.staleLease) {
        try await pool.acquire(for: session, configuration: configuration)
    }
    await #expect(throws: DisplayPoolFailure.exhausted(maxSessions: 1)) {
        try await pool.acquire(for: .app(UUID()), configuration: configuration)
    }
    #expect(await pool.release(lease) == .quarantined(androidDisplayID: lease.androidDisplayID))
    #expect((await pool.snapshot())[0].state == .faulted(.reconfigurationUncertain))
    await pool.guestRestarted()
    #expect((await pool.snapshot())[0].state == .free)
}

final class FakeDisplayControlChannel: DisplayControlChannel, @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<GuestDisplayEvent>.Continuation
    private var displays: [Int32: GuestDisplaySnapshot] = [
        0: GuestDisplaySnapshot(
            displayID: 0,
            mode: GuestDisplaySize(width: 1080, height: 2400),
            densityDPI: 420
        )
    ]
    private var policies: [DisplayPolicyCall] = []
    private let failPolicyCalls: Set<Int>
    private var policyAttemptCount = 0

    let displayEvents: AsyncStream<GuestDisplayEvent>

    init(failPolicy: Bool = false, failPolicyCalls: Set<Int> = []) {
        self.failPolicyCalls = failPolicy ? failPolicyCalls.union([1]) : failPolicyCalls
        let (stream, continuation) = AsyncStream.makeStream(
            of: GuestDisplayEvent.self,
            bufferingPolicy: .bufferingNewest(128)
        )
        displayEvents = stream
        self.continuation = continuation
    }

    func displaySnapshot() async -> [GuestDisplaySnapshot] {
        lock.withLock { Array(displays.values) }
    }

    func setDisplayPolicy(
        _ displayID: Int32,
        densityDPI: Int,
        imePolicy: GuestDisplayIMEPolicy
    ) async throws(DisplayControlFailure) {
        let shouldFail = lock.withLock { () -> Bool in
            policyAttemptCount += 1
            return failPolicyCalls.contains(policyAttemptCount)
        }
        if shouldFail {
            throw .operationFailed
        }
        lock.withLock {
            policies.append(DisplayPolicyCall(displayID: displayID, densityDPI: densityDPI, imePolicy: imePolicy))
        }
    }

    func clearDisplay(_ displayID: Int32) async throws(DisplayControlFailure) {
        emit(.tasksCleared(displayID: displayID))
    }

    func policySnapshot() -> [DisplayPolicyCall] {
        lock.withLock { policies }
    }

    func emit(_ event: GuestDisplayEvent) {
        lock.withLock {
            switch event {
            case .added(let display), .changed(let display):
                displays[display.displayID] = display
            case .removed(let displayID):
                displays[displayID] = nil
            case .tasksCleared:
                break
            }
            continuation.yield(event)
        }
    }
}

struct DisplayPolicyCall: Equatable, Sendable {
    let displayID: Int32
    let densityDPI: Int
    let imePolicy: GuestDisplayIMEPolicy
}

private struct DetachCall: Equatable, Sendable {
    let scanout: Int
    let generation: UInt64?
}

private struct VisibilityCall: Equatable, Sendable {
    let scanout: Int
    let visible: Bool
}

final class FakeScanoutController: ScanoutController, @unchecked Sendable {
    private let lock = NSLock()
    private let guest: FakeDisplayControlChannel
    private let removeOnDisable: Bool
    private let reportedSize: GuestDisplaySize?
    private let includeProductInfo: Bool
    private let removeBeforeAttachTimeout: Bool
    private let reconfigureFollowupSize: GuestDisplaySize?
    private let configurationFailureCalls: Set<Int>
    private var displayIDs: [Int: Int32] = [:]
    private var nextDisplayID: Int32 = 1
    private var generations: [Int: UInt64] = [:]
    private var configured: [Int] = []
    private var disabled: [Int] = []
    private var detached: [DetachCall] = []
    private var visibility: [VisibilityCall] = []
    private var configurationAttemptCount = 0

    init(
        guest: FakeDisplayControlChannel,
        removeOnDisable: Bool = true,
        reportedSize: GuestDisplaySize? = nil,
        includeProductInfo: Bool = true,
        removeBeforeAttachTimeout: Bool = false,
        reconfigureFollowupSize: GuestDisplaySize? = nil,
        configurationFailureCalls: Set<Int> = []
    ) {
        self.guest = guest
        self.removeOnDisable = removeOnDisable
        self.reportedSize = reportedSize
        self.includeProductInfo = includeProductInfo
        self.removeBeforeAttachTimeout = removeBeforeAttachTimeout
        self.reconfigureFollowupSize = reconfigureFollowupSize
        self.configurationFailureCalls = configurationFailureCalls
    }

    var configuredScanouts: [Int] {
        lock.withLock { configured }
    }

    var disabledScanouts: [Int] {
        lock.withLock { disabled }
    }

    fileprivate var visibilityChanges: [VisibilityCall] {
        lock.withLock { visibility }
    }

    fileprivate var detachedGenerations: [DetachCall] {
        lock.withLock { detached }
    }

    func configure(_ scanout: ScanoutID, mode: DisplayMode) throws(GraphicsFailure) {
        let result = lock.withLock { () -> (Int32, Bool, Bool, Int) in
            configured.append(scanout.rawValue)
            configurationAttemptCount += 1
            guard !configurationFailureCalls.contains(configurationAttemptCount) else {
                return (0, false, true, configurationAttemptCount)
            }
            if let displayID = displayIDs[scanout.rawValue] {
                return (displayID, true, false, configurationAttemptCount)
            }
            let displayID = nextDisplayID
            nextDisplayID += 1
            displayIDs[scanout.rawValue] = displayID
            return (displayID, false, false, configurationAttemptCount)
        }
        guard !result.2 else { throw .configUpdateFailed(detail: "scripted configuration failure") }
        let size = reportedSize ?? GuestDisplaySize(width: mode.widthPixels, height: mode.heightPixels)
        let display = GuestDisplaySnapshot(
            displayID: result.0,
            uniqueID: "fake-scanout-\(scanout.rawValue)",
            mode: size,
            densityDPI: 213,
            product: includeProductInfo
                ? GuestDisplayProductInfo(manufacturerPnpID: "APK", productID: Int32(scanout.rawValue))
                : nil
        )
        guest.emit(result.1 ? .changed(display) : .added(display))
        if result.3 == 2, let reconfigureFollowupSize {
            let followup = GuestDisplaySnapshot(
                displayID: display.displayID,
                uniqueID: display.uniqueID,
                mode: reconfigureFollowupSize,
                densityDPI: display.densityDPI,
                product: display.product
            )
            guest.emit(.changed(followup))
        }
        if removeBeforeAttachTimeout {
            Task {
                try? await Task.sleep(for: .milliseconds(5))
                guest.emit(.removed(displayID: result.0))
            }
        }
    }

    func disable(_ scanout: ScanoutID) {
        let displayID = lock.withLock { () -> Int32? in
            disabled.append(scanout.rawValue)
            defer { displayIDs[scanout.rawValue] = nil }
            return displayIDs[scanout.rawValue]
        }
        if removeOnDisable, let displayID {
            guest.emit(.removed(displayID: displayID))
        }
    }

    func attach(
        _ scanout: ScanoutID,
        width: Int,
        height: Int
    ) throws(GraphicsFailure) -> ScanoutPoolHandle {
        makePool(scanout)
    }

    func reconfigure(
        _ scanout: ScanoutID,
        mode: DisplayMode,
        width: Int,
        height: Int
    ) throws(GraphicsFailure) -> ScanoutPoolHandle {
        makePool(scanout)
    }

    func detachPool(_ scanout: ScanoutID, generation: UInt64?) {
        lock.withLock { detached.append(DetachCall(scanout: scanout.rawValue, generation: generation)) }
    }

    func visibilityChanged(_ scanout: ScanoutID, visible: Bool) {
        lock.withLock {
            visibility.append(VisibilityCall(scanout: scanout.rawValue, visible: visible))
        }
    }

    private func makePool(_ scanout: ScanoutID) -> ScanoutPoolHandle {
        let generation = lock.withLock { () -> UInt64 in
            let next = (generations[scanout.rawValue] ?? 0) + 1
            generations[scanout.rawValue] = next
            return next
        }
        let (frames, continuation) = AsyncStream.makeStream(of: ScanoutFrame.self)
        continuation.finish()
        return ScanoutPoolHandle(generation: generation, surfaces: [], frames: frames)
    }
}
