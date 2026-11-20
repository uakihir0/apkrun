import APKStoreCore
import DiagnosticsCore
import Foundation

/// A condition that currently blocks a gentle install
/// ([update-system.md](docs/02-design/update-system.md) §7.1). Blocks
/// surface to the user as waiting reasons in `listUpdates` (§7.3).
public enum GentleGateBlock: String, Sendable, CaseIterable, Codable {
    /// GU1: the runtime is not `ready` (`suspended` counts only for a
    /// user-initiated update).
    case runtimeNotReady
    /// GU2 + GU3: an open AppSession in any state but `ended`, or a
    /// keepRunning task (`hasActiveUse` merges them, §7.5).
    case packageInUse
    /// GU4: the package's last session ended less than the quiet
    /// period ago.
    case sessionEndedRecently
    /// GU5, hint only: Android's constraint query reports unsatisfied.
    /// Checked for automatic installs only.
    case androidBusy
    /// GU6: another store transaction for the package is running or
    /// queued ahead.
    case storeTransactionActive
    /// GU7: the health check needs a DisplayPool slot and none is free.
    case noDisplaySlot
}

/// The outcome of evaluating §7.1 for one package.
public struct GentleGateEvaluation: Sendable, Equatable {
    /// The package the evaluation applies to.
    public let packageID: PackageID
    /// Every condition that blocks the install, in check order.
    public let blocks: [GentleGateBlock]

    /// Whether every §7.1 condition holds.
    public var isOpen: Bool { blocks.isEmpty }
}

/// The §7.1 gate with the §7.2 install queue.
///
/// `evaluate` runs the conditions at the §7.2 triggers (the caller
/// pumps `runtime.runtimeEvents` into `nextReadyPackage`), logs each
/// false condition in the `install` category, and admits installs one
/// at a time: user-initiated requests first, then longest waiting.
public actor GentleUpdateGate {
    private struct Request: Sendable, Equatable {
        let packageID: PackageID
        let userInitiated: Bool
        let enqueuedAt: ContinuousClock.Instant
    }

    private let runtime: any UpdateRuntimeAccess
    /// GU6: another store mutation for the package is in flight.
    private let storeBusy: @Sendable (PackageID) async -> Bool
    /// Whether the health check needs a display slot (`versionOnly` does not).
    private let requiresDisplaySlot: @Sendable (PackageID) async -> Bool
    /// GU7: a DisplayPool slot is free right now.
    private let displaySlotFree: @Sendable () async -> Bool
    private let now: @Sendable () -> ContinuousClock.Instant
    /// GU4: the quiet period after the last session ends (§7.1).
    private let quietPeriod: Duration
    nonisolated private let log: APKLogger

    private var queue: [Request] = []
    /// The package currently installing; installs serialize on it.
    private var installing: PackageID?
    /// The blocks of the last evaluation per package (§7.3 waiting reasons).
    private var lastBlocks: [PackageID: [GentleGateBlock]] = [:]

    /// Creates the gate. `storeBusy` answers GU6 (a store mutation for the
    /// package in flight), `requiresDisplaySlot`/`displaySlotFree` GU7, and
    /// `quietPeriod` GU4's settled session window (§7.1, 15 s).
    public init(
        runtime: any UpdateRuntimeAccess,
        storeBusy: @escaping @Sendable (PackageID) async -> Bool,
        requiresDisplaySlot: @escaping @Sendable (PackageID) async -> Bool = { _ in true },
        displaySlotFree: @escaping @Sendable () async -> Bool = { true },
        quietPeriod: Duration = .seconds(15),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.runtime = runtime
        self.storeBusy = storeBusy
        self.requiresDisplaySlot = requiresDisplaySlot
        self.displaySlotFree = displaySlotFree
        self.quietPeriod = quietPeriod
        self.now = now
        log = APKLogger(category: UpdateLogCategory.install)
    }

    /// Evaluates §7.1 for one package and remembers the result as its
    /// waiting reasons. Each false condition is logged in the `install`
    /// category.
    public func evaluate(
        _ packageID: PackageID,
        userInitiated: Bool = false
    ) async -> GentleGateEvaluation {
        var blocks: [GentleGateBlock] = []
        // GU1.
        switch await runtime.runtimeState {
        case .ready:
            break
        case .suspended where userInitiated:
            break
        default:
            blocks.append(.runtimeNotReady)
        }
        // GU2 + GU3.
        if await runtime.hasActiveUse(packageID) {
            blocks.append(.packageInUse)
        }
        // GU4. `nil` means the session ended long ago or never ran.
        if let lastEnd = await runtime.lastSessionEnd(packageID),
            now() < lastEnd + quietPeriod
        {
            blocks.append(.sessionEndedRecently)
        }
        // GU5, hint only, and never consulted for user-initiated updates
        // (§7.3). A definitive "unsatisfied" blocks; a failed query does
        // not (the access layer reports failures as satisfied).
        if !userInitiated, await !runtime.androidAllowsGentleInstall(packageID) {
            blocks.append(.androidBusy)
        }
        // GU6.
        if await storeBusy(packageID) {
            blocks.append(.storeTransactionActive)
        }
        // GU7.
        if await requiresDisplaySlot(packageID), await !displaySlotFree() {
            blocks.append(.noDisplaySlot)
        }
        for block in blocks {
            log.info(
                "gentle update blocked \(packageID.rawValue, .public): \(block.rawValue, .public)")
        }
        lastBlocks[packageID] = blocks
        return GentleGateEvaluation(packageID: packageID, blocks: blocks)
    }

    /// Requests admission for a staged install. When nothing is
    /// installing and the gate is open the package installs immediately
    /// and `true` is returned; otherwise the request waits in the queue.
    public func requestInstall(
        _ packageID: PackageID,
        userInitiated: Bool = false
    ) async -> Bool {
        if installing == nil,
            await evaluate(packageID, userInitiated: userInitiated).isOpen
        {
            installing = packageID
            queue.removeAll { $0.packageID == packageID }
            return true
        }
        if !queue.contains(where: { $0.packageID == packageID }) {
            queue.append(
                Request(packageID: packageID, userInitiated: userInitiated, enqueuedAt: now())
            )
        }
        return false
    }

    /// A §7.2 trigger fired: re-evaluates the queue and returns the next
    /// package admitted to install, or `nil` while the gate stays closed.
    /// User-initiated requests go first, then the longest waiting.
    public func nextReadyPackage() async -> PackageID? {
        guard installing == nil else { return nil }
        for request in queue.sorted(by: Self.queueOrder) {
            if await evaluate(request.packageID, userInitiated: request.userInitiated).isOpen {
                installing = request.packageID
                queue.removeAll { $0.packageID == request.packageID }
                return request.packageID
            }
        }
        return nil
    }

    /// Marks the running install finished and evaluates the queue.
    /// Returns the next admitted package, if any.
    @discardableResult
    public func finishInstall(_ packageID: PackageID) async -> PackageID? {
        if installing == packageID {
            installing = nil
        }
        return await nextReadyPackage()
    }

    /// Whether the package has a queued or running install.
    public func isWaiting(_ packageID: PackageID) -> Bool {
        installing == packageID || queue.contains { $0.packageID == packageID }
    }

    /// The blocks of the package's last evaluation (§7.3 waiting reasons).
    public func waitingReasons(_ packageID: PackageID) -> [GentleGateBlock] {
        lastBlocks[packageID] ?? []
    }

    private static func queueOrder(_ left: Request, _ right: Request) -> Bool {
        if left.userInitiated != right.userInitiated {
            return left.userInitiated
        }
        return left.enqueuedAt < right.enqueuedAt
    }
}
