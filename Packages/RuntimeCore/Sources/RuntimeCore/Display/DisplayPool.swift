import DiagnosticsCore
import Foundation
import GraphicsCore

/// A system operation allowed to lease a display without a user window.
public enum SystemDisplayUse: Sendable, Hashable {
    /// Verifies the Android setup after first-run provisioning.
    case setupVerification
    /// Verifies a staged image migration before commit.
    case migrationCheck
    /// Runs an update health check for the package identifier.
    case updateHealthCheck(packageID: String)
}

/// The pixel dimensions reported by Android for one logical display.
public struct GuestDisplaySize: Sendable, Equatable {
    /// Active width in pixels.
    public var width: Int
    /// Active height in pixels.
    public var height: Int

    /// Creates an Android display size.
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Product identity reported by Android for a physical display.
public struct GuestDisplayProductInfo: Sendable, Equatable {
    /// Three-character PNP manufacturer identifier.
    public var manufacturerPnpID: String
    /// EDID product code.
    public var productID: Int32

    /// Creates product identity.
    public init(manufacturerPnpID: String, productID: Int32) {
        self.manufacturerPnpID = manufacturerPnpID
        self.productID = productID
    }
}

/// A display snapshot reported by the Guest Agent.
public struct GuestDisplaySnapshot: Sendable, Equatable {
    /// Android's logical display ID.
    public var displayID: Int32
    /// Stable Android display identifier, when available.
    public var uniqueID: String
    /// The reported pixel mode.
    public var mode: GuestDisplaySize
    /// Android's logical density.
    public var densityDPI: Int
    /// EDID-derived product identity, when Android exposes it.
    public var product: GuestDisplayProductInfo?

    /// Creates a guest display snapshot.
    public init(
        displayID: Int32,
        uniqueID: String = "",
        mode: GuestDisplaySize,
        densityDPI: Int,
        product: GuestDisplayProductInfo? = nil
    ) {
        self.displayID = displayID
        self.uniqueID = uniqueID
        self.mode = mode
        self.densityDPI = densityDPI
        self.product = product
    }
}

/// Events used by DisplayPool to correlate a scanout with Android's display ID.
public enum GuestDisplayEvent: Sendable, Equatable {
    /// A physical scanout became a logical Android display.
    case added(GuestDisplaySnapshot)
    /// One logical Android display changed mode, density, or state.
    case changed(GuestDisplaySnapshot)
    /// Android removed a logical display.
    case removed(displayID: Int32)
    /// The Guest Agent finished clearing tasks from one display.
    case tasksCleared(displayID: Int32)
}

/// Failures while communicating with Android's display manager.
public enum DisplayControlFailure: Error, Sendable, Equatable {
    /// The Guest Agent is not connected.
    case unavailable
    /// The operation was rejected or did not complete.
    case operationFailed
}

/// The Guest Agent operations needed to allocate and release physical displays.
public protocol DisplayControlChannel: Sendable {
    /// A stream dedicated to display events. One DisplayPool owns its iterator.
    var displayEvents: AsyncStream<GuestDisplayEvent> { get }

    /// The current display inventory before a scanout change.
    func displaySnapshot() async -> [GuestDisplaySnapshot]

    /// Applies Android's per-display density and local IME policy.
    func setDisplayPolicy(_ displayID: Int32, densityDPI: Int, imePolicy: GuestDisplayIMEPolicy)
        async throws(DisplayControlFailure)

    /// Removes every task from a display and publishes `tasksCleared`.
    func clearDisplay(_ displayID: Int32) async throws(DisplayControlFailure)
}

/// The IME placement used by a display lease.
public enum GuestDisplayIMEPolicy: Sendable, Equatable {
    /// Keep the IME on the same display as the app.
    case local
    /// Fall back to the primary display.
    case fallbackDisplay
    /// Do not show an IME for this display.
    case hide
}

/// The geometry and mode used to create one display lease.
public struct DisplayConfiguration: Sendable, Equatable {
    /// The native window geometry.
    public var geometry: DisplayGeometry
    /// The Android display mode.
    public var mode: AndroidWindowMode

    /// Creates a display configuration.
    public init(geometry: DisplayGeometry, mode: AndroidWindowMode = .secondaryDisplay) {
        self.geometry = geometry
        self.mode = mode
    }
}

/// An Android window's display policy.
public enum AndroidWindowMode: Sendable, Equatable {
    /// Allocate one of scanouts 1...15.
    case secondaryDisplay
    /// Use primary display 0. This mode is reserved for #30 integration.
    case primaryDisplayCompatibility
}

/// Display lifecycle faults retained in a slot snapshot.
public enum DisplayFault: Sendable, Equatable {
    /// Android did not announce a new display within five seconds.
    case attachTimedOut
    /// Android did not remove a display after the scanout was disabled.
    case releaseTimedOut
    /// GraphicsCore could not configure or create a pool for this scanout.
    case graphics(GraphicsFailure)
    /// The Guest Agent could not finish a display operation.
    case guestAgentUnavailable
    /// A failed mode change could not restore the display state, so its lease is quarantined.
    case reconfigurationUncertain
}

/// Result of releasing one display lease.
public enum DisplayReleaseResult: Sendable, Equatable {
    /// Android confirmed that the display was removed.
    case released
    /// The display was not removed before the deadline and its scanout stays quarantined.
    case quarantined(androidDisplayID: Int32)
    /// The lease no longer identifies the current slot allocation.
    case staleLease
}

/// The state of one display slot.
public enum DisplaySlotState: Sendable, Equatable {
    /// The scanout is disabled and has no lease.
    case free
    /// The scanout is enabled and Android is attaching it.
    case attaching(SessionID)
    /// Android owns the display and the session owns the lease.
    case allocated(SessionID)
    /// Tasks are being cleared and the scanout is being disabled.
    case releasing(SessionID)
    /// The slot is quarantined until a reset succeeds or Android restarts.
    case faulted(DisplayFault)
}

/// A diagnostic snapshot of one slot.
public struct DisplaySlotSnapshot: Sendable, Equatable {
    /// The virtio-gpu scanout index.
    public var scanout: Int
    /// Current lifecycle state.
    public var state: DisplaySlotState
    /// Android's logical display ID, if attached.
    public var androidDisplayID: Int32?
    /// Last resolved mode.
    public var mode: ResolvedDisplayMode?
    /// Incremented on every successful allocation.
    public var generation: UInt64
    /// Estimated IOSurface memory for a three-buffer pool.
    public var estimatedSurfaceBytes: Int64

    /// Creates a diagnostic snapshot.
    public init(
        scanout: Int,
        state: DisplaySlotState,
        androidDisplayID: Int32?,
        mode: ResolvedDisplayMode?,
        generation: UInt64,
        estimatedSurfaceBytes: Int64
    ) {
        self.scanout = scanout
        self.state = state
        self.androidDisplayID = androidDisplayID
        self.mode = mode
        self.generation = generation
        self.estimatedSurfaceBytes = estimatedSurfaceBytes
    }
}

/// A user-visible or internal failure from display allocation.
public enum DisplayPoolFailure: Error, Sendable, Equatable {
    /// No hardware slot is free or the app-session soft limit was reached.
    case exhausted(maxSessions: Int)
    /// Android did not attach a display after the one retry.
    case attachFailed(scanout: Int)
    /// The lease does not identify the currently allocated generation.
    case staleLease
    /// The requested window geometry cannot be expressed as an EDID mode.
    case invalidGeometry(DisplayGeometryResolverFailure)
    /// A mode change failed; true means rollback did not restore the prior display state.
    case reconfigureFailed(stateUncertain: Bool)
    /// The Guest Agent operation failed.
    case guest(DisplayControlFailure)
    /// GraphicsCore failed to configure a scanout or create a surface pool.
    case graphics(GraphicsFailure)
    /// Display 0 is already reserved by another compatibility session.
    case primaryDisplayBusy
    /// Display 0 has no presenter that can back a compatibility window.
    case primaryDisplayUnavailable

    /// The stable runtime error code used by diagnostics and API adapters.
    public var code: String {
        switch self {
        case .exhausted: "displayPoolExhausted"
        case .attachFailed: "displayAttachFailed"
        case .staleLease: "internal"
        case .invalidGeometry: "displayGeometryInvalid"
        case .reconfigureFailed: "displayReconfigureFailed"
        case .primaryDisplayBusy: "primaryDisplayBusy"
        case .primaryDisplayUnavailable: "displayAttachFailed"
        case .guest(.unavailable): "guestAgentUnavailable"
        case .guest(.operationFailed): "guestAgentOperationFailed"
        case .graphics(let failure): failure.code
        }
    }
}

/// A successful allocation of one Android display and its frame pool.
public struct DisplayLease: Sendable {
    /// Identifies this allocation independently of later generations.
    public let leaseID: UUID
    /// The session holding the display.
    public let session: SessionID
    /// The virtio-gpu scanout index.
    public let scanout: ScanoutID
    /// Android's logical display ID.
    public let androidDisplayID: Int32
    /// The resolved Android mode.
    public let mode: ResolvedDisplayMode
    /// The fresh IOSurface pool for this lease, exposed through RuntimeCore's session API.
    public let sessionPool: DisplaySessionPool
    /// The GraphicsCore pool used internally for lifecycle management.
    let pool: ScanoutPoolHandle

    /// Creates a display lease.
    init(
        leaseID: UUID,
        session: SessionID,
        scanout: ScanoutID,
        androidDisplayID: Int32,
        mode: ResolvedDisplayMode,
        pool: ScanoutPoolHandle
    ) {
        self.leaseID = leaseID
        self.session = session
        self.scanout = scanout
        self.androidDisplayID = androidDisplayID
        self.mode = mode
        self.pool = pool
        sessionPool = DisplaySessionPool(scanoutPool: pool)
    }
}

/// Limits and deadlines for the display pool.
public struct DisplayPoolLimits: Sendable, Equatable {
    /// The soft app-session limit. System display uses do not count toward it.
    public var maxSessions: Int
    /// Time to wait for Android's `DisplayAdded`.
    public var attachTimeout: Duration
    /// Time to wait for Android's `TasksCleared`.
    public var clearTimeout: Duration
    /// Time to wait for Android's `DisplayRemoved`.
    public var removalTimeout: Duration
    /// Time to wait for Android to confirm a requested display mode.
    public var reconfigureTimeout: Duration
    /// Faults after which a scanout stays quarantined until the next guest restart.
    public var faultsBeforeQuarantine: Int

    /// Creates limits, clamping the soft limit to available scanouts.
    public init(
        maxSessions: Int = 8,
        attachTimeout: Duration = .seconds(5),
        clearTimeout: Duration = .seconds(5),
        removalTimeout: Duration = .seconds(3),
        reconfigureTimeout: Duration = .seconds(3),
        faultsBeforeQuarantine: Int = 3
    ) {
        self.maxSessions = min(15, max(1, maxSessions))
        self.attachTimeout = max(.milliseconds(1), attachTimeout)
        self.clearTimeout = max(.milliseconds(1), clearTimeout)
        self.removalTimeout = max(.milliseconds(1), removalTimeout)
        self.reconfigureTimeout = max(.milliseconds(1), reconfigureTimeout)
        self.faultsBeforeQuarantine = max(1, faultsBeforeQuarantine)
    }
}

/// Events published as pool slots change state.
public enum DisplayPoolEvent: Sendable, Equatable {
    /// One slot changed lifecycle state.
    case slotChanged(DisplaySlotSnapshot)
}

/// Owns scanouts 1...15 and their mapping to Android logical displays.
///
/// A single operation gate serializes attachment and release so Android's display events can be correlated with one
/// scanout at a time. Each successful lease gets a fresh surface pool.
public actor DisplayPool {
    private struct Slot {
        let scanout: ScanoutID
        var state: DisplaySlotState = .free
        var ownerSession: SessionID?
        var androidDisplayID: Int32?
        var mode: ResolvedDisplayMode?
        var pool: ScanoutPoolHandle?
        var leaseID: UUID?
        var generation: UInt64 = 0
        var faultsThisBoot = 0
    }

    private let scanouts: any ScanoutController
    private let guest: any DisplayControlChannel
    private let limits: DisplayPoolLimits
    private let primaryPool: ScanoutPoolHandle?
    private let logger = APKLogger(category: RuntimeLogCategory.sessions)
    private let displayEvents: DisplayEventInbox
    private let eventContinuation: AsyncStream<DisplayPoolEvent>.Continuation
    private var slots: [Slot]
    private var primaryLease: DisplayLease?
    private var primaryPreviousDensityDPI: Int?
    private var operationActive = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    /// Slot-state events for diagnostics.
    public nonisolated let events: AsyncStream<DisplayPoolEvent>

    /// Creates a pool for the VM's GPU device and Guest Agent.
    public init(
        scanouts: any ScanoutController,
        guest: any DisplayControlChannel,
        primaryPool: ScanoutPoolHandle? = nil,
        limits: DisplayPoolLimits = DisplayPoolLimits()
    ) {
        self.scanouts = scanouts
        self.guest = guest
        self.primaryPool = primaryPool
        self.limits = limits
        displayEvents = DisplayEventInbox(guest.displayEvents)
        slots = (1..<16).compactMap { value in
            guard let scanout = ScanoutID(rawValue: value) else { return nil }
            return Slot(scanout: scanout)
        }
        let stream = AsyncStream<DisplayPoolEvent>.makeStream(bufferingPolicy: .bufferingNewest(128))
        events = stream.stream
        eventContinuation = stream.continuation
    }

    /// Acquires the lowest free pool slot for one app or system session.
    public func acquire(
        for session: SessionID,
        configuration: DisplayConfiguration
    ) async throws(DisplayPoolFailure) -> DisplayLease {
        await acquireOperationPermit()
        defer { releaseOperationPermit() }

        guard !slots.contains(where: { $0.leaseID != nil && $0.ownerSession == session }),
            primaryLease?.session != session
        else {
            throw .staleLease
        }
        if case .primaryDisplayCompatibility = configuration.mode, primaryLease != nil {
            throw .primaryDisplayBusy
        }
        if case .app = session,
            activeAppSessionCount >= limits.maxSessions
        {
            throw .exhausted(maxSessions: limits.maxSessions)
        }
        let resolvedMode: ResolvedDisplayMode
        do {
            resolvedMode = try DisplayGeometryResolver.resolve(configuration.geometry)
        } catch {
            throw .invalidGeometry(error)
        }

        if case .primaryDisplayCompatibility = configuration.mode {
            return try await acquirePrimary(for: session, mode: resolvedMode)
        }

        let before = await guest.displaySnapshot()
        let existingIDs = Set(before.map(\.displayID))
        for attempt in 0..<2 {
            guard let slotIndex = slots.firstIndex(where: { $0.state == .free }) else {
                throw .exhausted(maxSessions: limits.maxSessions)
            }
            let scanout = slots[slotIndex].scanout
            let leaseID = UUID()
            slots[slotIndex].generation &+= 1
            slots[slotIndex].leaseID = leaseID
            slots[slotIndex].ownerSession = session
            slots[slotIndex].mode = resolvedMode
            slots[slotIndex].state = .attaching(session)
            publish(slotIndex)

            do throws(DisplayPoolFailure) {
                do throws(GraphicsFailure) {
                    try scanouts.configure(scanout, mode: Self.graphicsMode(for: resolvedMode))
                } catch {
                    throw .graphics(error)
                }
                guard
                    let display = await waitForDisplay(
                        scanout: scanout,
                        existingIDs: existingIDs,
                        requestedSize: resolvedMode.pixelSize,
                        timeout: limits.attachTimeout
                    )
                else {
                    throw .attachFailed(scanout: scanout.rawValue)
                }
                slots[slotIndex].androidDisplayID = display.displayID
                do throws(DisplayControlFailure) {
                    try await guest.setDisplayPolicy(
                        display.displayID,
                        densityDPI: resolvedMode.densityDpi,
                        imePolicy: .local
                    )
                } catch {
                    throw .guest(error)
                }

                let actualWidth = display.mode.width > 0 ? display.mode.width : resolvedMode.pixelSize.width
                let actualHeight = display.mode.height > 0 ? display.mode.height : resolvedMode.pixelSize.height
                if actualWidth != resolvedMode.pixelSize.width || actualHeight != resolvedMode.pixelSize.height {
                    logger.warning(
                        "Android display mode differed from scanout \(scanout.rawValue, .public); using its reported size"
                    )
                }
                let leaseMode = Self.mode(
                    resolvedMode,
                    pixelWidth: actualWidth,
                    pixelHeight: actualHeight,
                    densityDPI: resolvedMode.densityDpi
                )
                let pool: ScanoutPoolHandle
                do throws(GraphicsFailure) {
                    pool = try scanouts.attach(scanout, width: actualWidth, height: actualHeight)
                } catch {
                    throw .graphics(error)
                }
                slots[slotIndex].androidDisplayID = display.displayID
                slots[slotIndex].mode = leaseMode
                slots[slotIndex].pool = pool
                slots[slotIndex].state = .allocated(session)
                publish(slotIndex)
                return DisplayLease(
                    leaseID: leaseID,
                    session: session,
                    scanout: scanout,
                    androidDisplayID: display.displayID,
                    mode: leaseMode,
                    pool: pool
                )
            } catch {
                slots[slotIndex].leaseID = nil
                slots[slotIndex].ownerSession = nil
                slots[slotIndex].pool = nil
                slots[slotIndex].faultsThisBoot += 1
                let fault: DisplayFault
                switch error {
                case .attachFailed:
                    fault = .attachTimedOut
                case .guest:
                    fault = .guestAgentUnavailable
                case .graphics(let failure):
                    fault = .graphics(failure)
                case .exhausted, .staleLease, .invalidGeometry, .primaryDisplayBusy,
                    .primaryDisplayUnavailable:
                    fault = .attachTimedOut
                case .reconfigureFailed(let stateUncertain):
                    fault = stateUncertain ? .reconfigurationUncertain : .attachTimedOut
                }
                slots[slotIndex].state = .faulted(fault)
                publish(slotIndex)
                scanouts.disable(scanout)
                scheduleFaultReset(slotIndex)
                guard attempt == 0, case .attachFailed = error else {
                    throw error
                }
                logger.warning(
                    "display attach failed on scanout \(scanout.rawValue, .public); retrying once on another slot"
                )
            }
        }
        throw .attachFailed(scanout: 1)
    }

    /// Reconfigures an allocated display with the #68 mode-confirmation sequence.
    public func reconfigure(
        _ lease: DisplayLease,
        geometry: DisplayGeometry
    ) async throws(DisplayPoolFailure) -> DisplayLease {
        await acquireOperationPermit()
        defer { releaseOperationPermit() }
        guard let slotIndex = slotIndex(for: lease), let oldMode = slots[slotIndex].mode,
            let displayID = slots[slotIndex].androidDisplayID
        else {
            throw .staleLease
        }
        let nextMode: ResolvedDisplayMode
        do {
            nextMode = try DisplayGeometryResolver.resolve(geometry)
        } catch {
            throw .invalidGeometry(error)
        }
        let nextGraphicsMode = Self.graphicsMode(for: nextMode)
        do throws(GraphicsFailure) {
            try scanouts.configure(lease.scanout, mode: nextGraphicsMode)
        } catch {
            let restored = await restorePreviousMode(
                scanout: lease.scanout,
                mode: oldMode,
                displayID: displayID
            )
            if !restored {
                quarantineUncertainReconfiguration(slotIndex, lease: lease)
                throw .reconfigureFailed(stateUncertain: true)
            }
            throw .graphics(error)
        }
        guard
            let changed = await waitForDisplayChange(
                scanout: lease.scanout,
                currentDisplayID: displayID,
                requestedSize: nextMode.pixelSize,
                timeout: limits.reconfigureTimeout
            )
        else {
            let restored = await restorePreviousMode(
                scanout: lease.scanout,
                mode: oldMode,
                displayID: displayID
            )
            if !restored {
                quarantineUncertainReconfiguration(slotIndex, lease: lease)
            }
            throw .reconfigureFailed(stateUncertain: !restored)
        }
        do {
            try await guest.setDisplayPolicy(changed.displayID, densityDPI: nextMode.densityDpi, imePolicy: .local)
        } catch {
            let restored = await restorePreviousMode(
                scanout: lease.scanout,
                mode: oldMode,
                displayID: displayID
            )
            if !restored {
                quarantineUncertainReconfiguration(slotIndex, lease: lease)
                throw .reconfigureFailed(stateUncertain: true)
            }
            throw .guest(error)
        }
        let pool: ScanoutPoolHandle
        do throws(GraphicsFailure) {
            pool = try scanouts.reconfigure(
                lease.scanout,
                mode: nextGraphicsMode,
                width: nextMode.pixelSize.width,
                height: nextMode.pixelSize.height
            )
        } catch {
            let restored = await restorePreviousMode(
                scanout: lease.scanout,
                mode: oldMode,
                displayID: displayID
            )
            if !restored {
                quarantineUncertainReconfiguration(slotIndex, lease: lease)
                throw .reconfigureFailed(stateUncertain: true)
            }
            throw .graphics(error)
        }
        slots[slotIndex].androidDisplayID = changed.displayID
        slots[slotIndex].mode = nextMode
        slots[slotIndex].pool = pool
        publish(slotIndex)
        return DisplayLease(
            leaseID: lease.leaseID,
            session: lease.session,
            scanout: lease.scanout,
            androidDisplayID: changed.displayID,
            mode: nextMode,
            pool: pool
        )
    }

    /// Forwards session window visibility only while the lease still owns its generation.
    public func visibilityChanged(_ visible: Bool, for lease: DisplayLease) {
        guard slotIndex(for: lease) != nil else {
            return
        }
        scanouts.visibilityChanged(lease.scanout, visible: visible)
    }

    /// Releases a lease. Failures are retained as a slot fault and never escape to close callers.
    @discardableResult
    public func release(_ lease: DisplayLease) async -> DisplayReleaseResult {
        await acquireOperationPermit()
        defer { releaseOperationPermit() }
        if lease.scanout.rawValue == 0 {
            guard let current = primaryLease, current.leaseID == lease.leaseID,
                current.session == lease.session
            else {
                logger.warning("ignored a stale primary display lease release")
                return .staleLease
            }
            if let previousDensity = primaryPreviousDensityDPI {
                do throws(DisplayControlFailure) {
                    try await guest.setDisplayPolicy(0, densityDPI: previousDensity, imePolicy: .local)
                } catch {
                    logger.warning("primary display policy could not be restored after compatibility mode")
                    return .quarantined(androidDisplayID: 0)
                }
            }
            primaryLease = nil
            primaryPreviousDensityDPI = nil
            logger.info(
                "released primary compatibility display lease=\(lease.leaseID.uuidString, .public) session=\(String(describing: lease.session), .public)"
            )
            return .released
        }
        guard let slotIndex = slotIndex(for: lease, allowingUncertainReconfiguration: true),
            let displayID = slots[slotIndex].androidDisplayID
        else {
            logger.warning("ignored a stale display lease release")
            return .staleLease
        }
        if slots[slotIndex].state == .faulted(.reconfigurationUncertain) {
            scanouts.detachPool(lease.scanout, generation: lease.pool.generation)
            scanouts.disable(lease.scanout)
            slots[slotIndex].leaseID = nil
            slots[slotIndex].ownerSession = nil
            slots[slotIndex].pool = nil
            publish(slotIndex)
            logger.warning(
                "scanout \(lease.scanout.rawValue, .public) stays quarantined until Android restarts after an uncertain resize"
            )
            return .quarantined(androidDisplayID: displayID)
        }
        slots[slotIndex].state = .releasing(lease.session)
        publish(slotIndex)
        scanouts.detachPool(lease.scanout, generation: lease.pool.generation)
        do {
            try await guest.clearDisplay(displayID)
            _ = await waitForEvent(timeout: limits.clearTimeout) { event in
                if case .tasksCleared(let clearedID) = event { return clearedID == displayID }
                return false
            }
        } catch {
            logger.warning("Android tasks did not clear from display \(displayID, .public) before release")
        }
        scanouts.disable(lease.scanout)
        let removed = await waitForDisplayRemoval(displayID, timeout: limits.removalTimeout)
        slots[slotIndex].leaseID = nil
        slots[slotIndex].ownerSession = nil
        slots[slotIndex].pool = nil
        if removed {
            slots[slotIndex].androidDisplayID = nil
            slots[slotIndex].mode = nil
            slots[slotIndex].state = .free
        } else {
            // Keep the Android identity while quarantined so a reset can still wait for this
            // display to disappear before making its scanout available again.
            slots[slotIndex].state = .faulted(.releaseTimedOut)
        }
        publish(slotIndex)
        if !removed {
            logger.warning(
                "Android did not confirm display \(displayID, .public) removal; scanout \(lease.scanout.rawValue, .public) stays faulted"
            )
            scheduleFaultReset(slotIndex)
            return .quarantined(androidDisplayID: displayID)
        }
        return .released
    }

    /// Returns a stable snapshot of every hardware slot.
    public func snapshot() -> [DisplaySlotSnapshot] {
        slots.map(Self.snapshot)
    }

    /// Clears boot-local fault counts after Android restarts and retries quarantined scanouts.
    public func guestRestarted() async {
        await acquireOperationPermit()
        defer { releaseOperationPermit() }
        primaryLease = nil
        primaryPreviousDensityDPI = nil
        for index in slots.indices {
            guard case .faulted = slots[index].state else { continue }
            slots[index].faultsThisBoot = 0
            scanouts.disable(slots[index].scanout)
            slots[index].state = .free
            slots[index].leaseID = nil
            slots[index].ownerSession = nil
            slots[index].pool = nil
            slots[index].androidDisplayID = nil
            slots[index].mode = nil
            publish(index)
        }
    }

    private var activeAppSessionCount: Int {
        let secondaryCount = slots.reduce(into: 0) { count, slot in
            if slot.leaseID != nil, case .app? = slot.ownerSession {
                count += 1
            }
        }
        let primaryCount: Int
        if let primaryLease, case .app = primaryLease.session {
            primaryCount = 1
        } else {
            primaryCount = 0
        }
        return secondaryCount + primaryCount
    }

    private func acquirePrimary(
        for session: SessionID,
        mode: ResolvedDisplayMode
    ) async throws(DisplayPoolFailure) -> DisplayLease {
        guard case .app = session else {
            throw .primaryDisplayUnavailable
        }
        guard primaryLease == nil else {
            throw .primaryDisplayBusy
        }
        guard let primaryPool,
            let scanout = ScanoutID(rawValue: 0)
        else {
            throw .primaryDisplayUnavailable
        }
        guard let display = await guest.displaySnapshot().first(where: { $0.displayID == 0 }) else {
            throw .primaryDisplayUnavailable
        }
        guard display.mode.width == mode.pixelSize.width, display.mode.height == mode.pixelSize.height else {
            throw .primaryDisplayUnavailable
        }
        do throws(DisplayControlFailure) {
            try await guest.setDisplayPolicy(0, densityDPI: mode.densityDpi, imePolicy: .local)
        } catch {
            throw .guest(error)
        }
        let lease = DisplayLease(
            leaseID: UUID(),
            session: session,
            scanout: scanout,
            androidDisplayID: 0,
            mode: mode,
            pool: primaryPool
        )
        primaryPreviousDensityDPI = display.densityDPI
        primaryLease = lease
        logger.info(
            "leased primary compatibility display session=\(String(describing: session), .public) density=\(mode.densityDpi, .public) dpi"
        )
        return lease
    }

    private func slotIndex(for lease: DisplayLease) -> Int? {
        slotIndex(for: lease, allowingUncertainReconfiguration: false)
    }

    private func slotIndex(for lease: DisplayLease, allowingUncertainReconfiguration: Bool) -> Int? {
        guard let index = slots.firstIndex(where: { $0.scanout == lease.scanout }),
            slots[index].leaseID == lease.leaseID,
            slots[index].pool?.generation == lease.pool.generation
        else {
            return nil
        }
        switch slots[index].state {
        case .allocated(let session) where session == lease.session:
            break
        case .faulted(.reconfigurationUncertain) where allowingUncertainReconfiguration:
            break
        default:
            return nil
        }
        return index
    }

    private func restorePreviousMode(
        scanout: ScanoutID,
        mode: ResolvedDisplayMode,
        displayID: Int32
    ) async -> Bool {
        do throws(GraphicsFailure) {
            try scanouts.configure(scanout, mode: Self.graphicsMode(for: mode))
        } catch {
            return false
        }
        guard
            let restored = await waitForDisplayState(
                scanout: scanout,
                currentDisplayID: displayID,
                requestedSize: mode.pixelSize,
                timeout: limits.reconfigureTimeout
            ),
            restored.displayID == displayID
        else {
            return false
        }
        do throws(DisplayControlFailure) {
            try await guest.setDisplayPolicy(displayID, densityDPI: mode.densityDpi, imePolicy: .local)
        } catch {
            return false
        }
        return true
    }

    private func quarantineUncertainReconfiguration(_ slotIndex: Int, lease: DisplayLease) {
        slots[slotIndex].state = .faulted(.reconfigurationUncertain)
        scanouts.detachPool(lease.scanout, generation: lease.pool.generation)
        scanouts.disable(lease.scanout)
        publish(slotIndex)
    }

    private func waitForDisplayState(
        scanout: ScanoutID,
        currentDisplayID: Int32,
        requestedSize: PixelSize,
        timeout: Duration
    ) async -> GuestDisplaySnapshot? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let displays = await guest.displaySnapshot()
            if let display = displays.first(where: {
                ($0.displayID == currentDisplayID
                    || ($0.product?.manufacturerPnpID == "APK"
                        && $0.product?.productID == Int32(scanout.rawValue)))
                    && $0.mode.width == requestedSize.width
                    && $0.mode.height == requestedSize.height
            }) {
                return display
            }
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else {
                break
            }
            _ = await nextGuestEvent(timeout: min(remaining, .milliseconds(100)))
        }
        return nil
    }

    private func waitForDisplay(
        scanout: ScanoutID,
        existingIDs: Set<Int32>,
        requestedSize: PixelSize,
        timeout: Duration
    ) async -> GuestDisplaySnapshot? {
        var missingProductCandidates: [Int32: GuestDisplaySnapshot] = [:]
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let remaining = deadline - ContinuousClock.now
            guard let event = await nextGuestEvent(timeout: remaining) else { break }
            let display: GuestDisplaySnapshot
            switch event {
            case .added(let added), .changed(let added):
                display = added
            case .removed(let displayID):
                missingProductCandidates.removeValue(forKey: displayID)
                continue
            case .tasksCleared:
                continue
            }
            guard !existingIDs.contains(display.displayID) else { continue }
            if let product = display.product {
                if product.manufacturerPnpID == "APK", product.productID == Int32(scanout.rawValue) {
                    return display
                }
                missingProductCandidates.removeValue(forKey: display.displayID)
                continue
            }
            missingProductCandidates[display.displayID] = display
        }
        guard missingProductCandidates.count == 1, let candidate = missingProductCandidates.values.first else {
            return nil
        }
        if candidate.mode.width != requestedSize.width || candidate.mode.height != requestedSize.height {
            logger.warning(
                "Android omitted product info; using the unique display mode reported for scanout \(scanout.rawValue, .public)"
            )
        } else {
            logger.warning(
                "Android omitted product info; correlated scanout \(scanout.rawValue, .public) by unique mode"
            )
        }
        return candidate
    }

    private func waitForDisplayChange(
        scanout: ScanoutID,
        currentDisplayID: Int32,
        requestedSize: PixelSize,
        timeout: Duration
    ) async -> GuestDisplaySnapshot? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let remaining = deadline - ContinuousClock.now
            guard let event = await nextGuestEvent(timeout: remaining) else { return nil }
            let display: GuestDisplaySnapshot
            switch event {
            case .changed(let changed):
                display = changed
            case .added(let added):
                guard added.product?.manufacturerPnpID == "APK",
                    added.product?.productID == Int32(scanout.rawValue)
                else {
                    continue
                }
                display = added
            case .removed, .tasksCleared:
                continue
            }
            guard
                display.displayID == currentDisplayID
                    || (display.product?.manufacturerPnpID == "APK"
                        && display.product?.productID == Int32(scanout.rawValue)),
                display.mode.width == requestedSize.width,
                display.mode.height == requestedSize.height
            else {
                continue
            }
            let snapshots = await guest.displaySnapshot()
            guard
                let current = snapshots.first(where: {
                    ($0.displayID == currentDisplayID
                        || ($0.product?.manufacturerPnpID == "APK"
                            && $0.product?.productID == Int32(scanout.rawValue)))
                        && $0.mode.width == requestedSize.width
                        && $0.mode.height == requestedSize.height
                })
            else {
                continue
            }
            return current
        }
        return nil
    }

    private func waitForEvent(
        timeout: Duration,
        matches: (GuestDisplayEvent) -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let remaining = deadline - ContinuousClock.now
            guard let event = await nextGuestEvent(timeout: remaining) else { return false }
            if matches(event) { return true }
        }
        return false
    }

    private func nextGuestEvent(timeout: Duration) async -> GuestDisplayEvent? {
        let inbox = displayEvents
        return await withTaskGroup(of: GuestDisplayEvent?.self) { group in
            group.addTask { await inbox.next() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let event = await group.next() ?? nil
            group.cancelAll()
            return event
        }
    }

    private func scheduleFaultReset(_ index: Int) {
        guard slots[index].faultsThisBoot < limits.faultsBeforeQuarantine else { return }
        Task { [weak self] in
            await self?.resetFaultedSlot(index)
        }
    }

    private func resetFaultedSlot(_ index: Int) async {
        await acquireOperationPermit()
        defer { releaseOperationPermit() }
        guard slots.indices.contains(index),
            slots[index].faultsThisBoot < limits.faultsBeforeQuarantine,
            case .faulted = slots[index].state
        else {
            return
        }
        let scanout = slots[index].scanout
        let displayID = slots[index].androidDisplayID
        scanouts.detachPool(scanout, generation: slots[index].pool?.generation)
        scanouts.disable(scanout)
        if let displayID {
            let removed = await waitForDisplayRemoval(displayID, timeout: limits.removalTimeout)
            guard removed else { return }
        }
        slots[index].state = .free
        slots[index].leaseID = nil
        slots[index].ownerSession = nil
        slots[index].pool = nil
        slots[index].androidDisplayID = nil
        slots[index].mode = nil
        publish(index)
    }

    private func waitForDisplayRemoval(_ displayID: Int32, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !(await guest.displaySnapshot().contains(where: { $0.displayID == displayID })) {
                return true
            }
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { break }
            if let event = await nextGuestEvent(timeout: min(remaining, .milliseconds(100))),
                case .removed(let removedID) = event,
                removedID == displayID
            {
                return true
            }
        }
        return !(await guest.displaySnapshot().contains(where: { $0.displayID == displayID }))
    }

    private func acquireOperationPermit() async {
        guard operationActive else {
            operationActive = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperationPermit() {
        guard !operationWaiters.isEmpty else {
            operationActive = false
            return
        }
        operationWaiters.removeFirst().resume()
    }

    private func publish(_ index: Int) {
        eventContinuation.yield(.slotChanged(Self.snapshot(slots[index])))
    }

    private static func snapshot(_ slot: Slot) -> DisplaySlotSnapshot {
        let mode = slot.mode
        let bytes: Int64
        if let mode {
            bytes = Int64(mode.pixelSize.width) * Int64(mode.pixelSize.height) * 4 * 3
        } else {
            bytes = 0
        }
        return DisplaySlotSnapshot(
            scanout: slot.scanout.rawValue,
            state: slot.state,
            androidDisplayID: slot.androidDisplayID,
            mode: mode,
            generation: slot.generation,
            estimatedSurfaceBytes: bytes
        )
    }

    private static func graphicsMode(for mode: ResolvedDisplayMode) -> DisplayMode {
        DisplayMode(
            widthPixels: mode.pixelSize.width,
            heightPixels: mode.pixelSize.height,
            refreshHz: mode.refreshHz,
            dotsPerInch: mode.densityDpi
        )
    }

    private static func mode(
        _ mode: ResolvedDisplayMode,
        pixelWidth: Int,
        pixelHeight: Int,
        densityDPI: Int
    ) -> ResolvedDisplayMode {
        ResolvedDisplayMode(
            pixelSize: PixelSize(width: pixelWidth, height: pixelHeight),
            densityDpi: densityDPI,
            renderScale: mode.renderScale,
            zoom: mode.zoom,
            refreshHz: mode.refreshHz
        )
    }
}

private actor DisplayEventInbox {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<GuestDisplayEvent?, Never>
    }

    private let capacity = 256
    private var buffered: [GuestDisplayEvent] = []
    private var waiters: [Waiter] = []
    private var isFinished = false

    init(_ stream: AsyncStream<GuestDisplayEvent>) {
        Task { [weak self] in
            for await event in stream {
                await self?.receive(event)
            }
            await self?.finish()
        }
    }

    func next() async -> GuestDisplayEvent? {
        if !buffered.isEmpty {
            return buffered.removeFirst()
        }
        if isFinished || Task.isCancelled {
            return nil
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func receive(_ event: GuestDisplayEvent) {
        if !waiters.isEmpty {
            waiters.removeFirst().continuation.resume(returning: event)
            return
        }
        buffered.append(event)
        if buffered.count > capacity {
            buffered.removeFirst(buffered.count - capacity)
        }
    }

    private func finish() {
        isFinished = true
        for waiter in waiters {
            waiter.continuation.resume(returning: nil)
        }
        waiters.removeAll()
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: nil)
    }
}
