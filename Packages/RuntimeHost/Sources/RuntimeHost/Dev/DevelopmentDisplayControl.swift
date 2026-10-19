import Foundation
import RuntimeAPI
import RuntimeCore

/// A command-facing view of one virtio-gpu display slot.
///
/// This value deliberately exposes no RuntimeCore or GraphicsCore types to command-line clients.
public struct DevelopmentDisplayRecord: Sendable, Equatable {
    /// The virtio-gpu scanout index.
    public let scanout: Int
    /// The slot's current lifecycle state.
    public let state: String
    /// Android's logical display ID when attached.
    public let androidDisplayID: Int32?
    /// Active pixel width, if the slot has a resolved mode.
    public let widthPixels: Int?
    /// Active pixel height, if the slot has a resolved mode.
    public let heightPixels: Int?
    /// Android density in dots per inch, if the slot has a resolved mode.
    public let densityDPI: Int?
    /// Estimated memory for the slot's three IOSurface buffers.
    public let estimatedSurfaceBytes: Int64

    init(_ snapshot: DisplaySlotSnapshot) {
        scanout = snapshot.scanout
        state =
            switch snapshot.state {
            case .free: "free"
            case .attaching: "attaching"
            case .allocated: "allocated"
            case .releasing: "releasing"
            case .faulted: "faulted"
            }
        androidDisplayID = snapshot.androidDisplayID
        widthPixels = snapshot.mode?.pixelSize.width
        heightPixels = snapshot.mode?.pixelSize.height
        densityDPI = snapshot.mode?.densityDpi
        estimatedSurfaceBytes = snapshot.estimatedSurfaceBytes
    }

    init(lease: DisplayLease) {
        scanout = lease.scanout.rawValue
        state = "allocated"
        androidDisplayID = lease.androidDisplayID
        widthPixels = lease.mode.pixelSize.width
        heightPixels = lease.mode.pixelSize.height
        densityDPI = lease.mode.densityDpi
        estimatedSurfaceBytes =
            Int64(lease.mode.pixelSize.width)
            * Int64(lease.mode.pixelSize.height) * 4 * 3
    }
}

/// Result of releasing one development-owned display.
public enum DevelopmentDisplayRemovalResult: Sendable, Equatable {
    /// The requested scanout was not acquired in this CLI session.
    case notOwned
    /// Android confirmed that the display was removed.
    case removed
    /// Android did not confirm removal; the scanout remains quarantined.
    case quarantined(androidDisplayID: Int32)
    /// The lease became stale before it could be released.
    case staleLease
}

/// Keeps development display leases inside RuntimeHost, the approved bridge to RuntimeCore for the CLI.
///
/// The CLI can acquire, inspect, and release leases without importing RuntimeCore.
public actor DevelopmentDisplayControl {
    private let pool: DisplayPool
    private var leases: [Int: DisplayLease] = [:]
    private var stopped = false

    init(pool: DisplayPool) {
        self.pool = pool
    }

    /// Acquires a virtual display with the requested pixel dimensions and density.
    public func add(width: Int, height: Int, densityDPI: Int) async throws(RuntimeWireError)
        -> DevelopmentDisplayRecord
    {
        guard !stopped else {
            throw .runtime(
                "internal",
                message: "The Android virtual display pool has stopped.",
                remediation: "Run `apkrun dev displays` again."
            )
        }
        guard width >= 640, height >= 800, (120...640).contains(densityDPI) else {
            throw .runtime(
                "displayGeometryInvalid",
                message: "The requested virtual display size or density is out of range.",
                remediation: "Use a size of at least 640x800 and a density from 120 through 640 dpi."
            )
        }
        let scale = Double(densityDPI) / 160
        let geometry = DisplayGeometry(
            pointSize: CGSize(width: Double(width) / scale, height: Double(height) / scale),
            backingScale: scale
        )
        let resolvedMode: ResolvedDisplayMode
        do {
            resolvedMode = try DisplayGeometryResolver.resolve(geometry)
        } catch {
            throw .runtime(
                "displayGeometryInvalid",
                message: "The requested virtual display geometry is not supported.",
                remediation:
                    "Choose an even pixel size supported at 60 Hz, with enough points for the requested density."
            )
        }
        guard resolvedMode.pixelSize.width == width,
            resolvedMode.pixelSize.height == height,
            resolvedMode.densityDpi == densityDPI
        else {
            throw .runtime(
                "displayGeometryInvalid",
                message: "Android's display timing cannot use the exact requested size and density.",
                remediation:
                    "Choose an even pixel size supported at 60 Hz and a density that preserves the minimum Android content size."
            )
        }

        do throws(DisplayPoolFailure) {
            let lease = try await pool.acquire(
                for: .app(UUID()),
                configuration: DisplayConfiguration(geometry: geometry)
            )
            leases[lease.scanout.rawValue] = lease
            return DevelopmentDisplayRecord(lease: lease)
        } catch {
            throw Self.runtimeError(for: error)
        }
    }

    /// Returns a point-in-time snapshot of every secondary scanout slot.
    public func list() async -> [DevelopmentDisplayRecord] {
        await pool.snapshot().map(DevelopmentDisplayRecord.init)
    }

    /// Releases a display acquired by this command and reports whether Android confirmed removal.
    public func remove(scanout: Int) async -> DevelopmentDisplayRemovalResult {
        guard let lease = leases.removeValue(forKey: scanout) else {
            return .notOwned
        }
        switch await pool.release(lease) {
        case .released:
            return .removed
        case .quarantined(let displayID):
            return .quarantined(androidDisplayID: displayID)
        case .staleLease:
            return .staleLease
        }
    }

    /// Releases every display lease acquired by this command.
    public func releaseAll() async {
        guard !stopped else {
            return
        }
        stopped = true
        let outstanding = Array(leases.values)
        leases.removeAll()
        for lease in outstanding {
            await pool.release(lease)
        }
    }

    private static func runtimeError(for failure: DisplayPoolFailure) -> RuntimeWireError {
        switch failure {
        case .exhausted(let maxSessions):
            .runtime(
                failure.code,
                message: "No virtual display slot is available (limit: \(maxSessions)).",
                remediation: "Remove a display or close another Android app window, then try again."
            )
        case .attachFailed:
            .runtime(
                failure.code,
                message: "Android did not attach the virtual display.",
                remediation: "Restart Android, then run `apkrun dev displays` again."
            )
        case .staleLease:
            .runtime(
                "internal",
                message: "The display request used an expired lease.",
                remediation: "Run `list` and retry with a free scanout."
            )
        case .invalidGeometry:
            .runtime(
                "displayGeometryInvalid",
                message: "The requested size and density cannot be expressed as an Android display mode.",
                remediation: "Choose a size supported at 60 Hz and a density from 120 through 640 dpi."
            )
        case .reconfigureFailed(let stateUncertain):
            .runtime(
                failure.code,
                message: "Android did not confirm the requested display mode.",
                remediation: stateUncertain
                    ? "Restart Android before reusing this display."
                    : "The previous display mode was restored. Try the resize again."
            )
        case .guest(.unavailable):
            .runtime(
                "guestAgentUnavailable",
                message: "The Android Guest Agent is unavailable.",
                remediation: "Boot Android with the development Guest Agent, then retry."
            )
        case .guest(.operationFailed):
            .runtime(
                "guestAgentOperationFailed",
                message: "The Android Guest Agent could not apply the display policy.",
                remediation: "Check the Guest Agent connection, then retry."
            )
        case .graphics(let failure):
            RuntimeWireError(
                domain: "graphics",
                code: "graphics.\(failure.code)",
                message: "The host GPU could not configure the virtual display.",
                remediation: "Check virgl support and run `apkrun dev displays` again."
            )
        case .primaryDisplayBusy:
            .runtime(
                "primaryDisplayBusy",
                message: "Another app is already using the compatibility window mode.",
                remediation: "Close that app or switch it to the standard secondary display mode."
            )
        case .primaryDisplayUnavailable:
            .runtime(
                "displayAttachFailed",
                message: "The compatibility display has no active graphics presenter.",
                remediation: "Start Android with the primary development window, then retry."
            )
        }
    }
}
