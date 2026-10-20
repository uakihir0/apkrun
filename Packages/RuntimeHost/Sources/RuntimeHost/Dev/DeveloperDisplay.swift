import CoreGraphics
import Foundation
import IOSurface
import RuntimeCore

/// An immutable display surface pool and the geometry it represents.
public struct DeveloperSurfaceSet: @unchecked Sendable {
    /// The pool generation.
    public let generation: UInt64
    /// The surfaces in buffer order.
    public let surfaces: [IOSurface]
    /// The pixel width.
    public let pixelWidth: Int
    /// The pixel height.
    public let pixelHeight: Int
    /// The window content size in points.
    public let contentSize: CGSize
    /// The rendering scale in pixels per point.
    public let renderScale: CGFloat
    /// The requested zoom.
    public let zoom: Double

    init(_ surfaceSet: DevelopmentSurfaceSet) {
        generation = surfaceSet.generation
        surfaces = surfaceSet.surfaces
        pixelWidth = surfaceSet.pixelWidth
        pixelHeight = surfaceSet.pixelHeight
        contentSize = surfaceSet.contentSize
        renderScale = CGFloat(surfaceSet.mode.renderScale)
        zoom = surfaceSet.mode.zoom
    }
}

/// An event of the developer display: the pool's surfaces once, then each frame that is ready to show.
public enum DeveloperDisplayEvent: @unchecked Sendable {
    /// The presenter is attached and its initial surface pool is ready.
    case attached(surfaceSet: DeveloperSurfaceSet)
    /// A new scanout pool replaced the previous generation.
    case surfacesReplaced(surfaceSet: DeveloperSurfaceSet)
    /// Buffer `bufferIndex` of `generation` is ready to show as frame `sequence`.
    case frameReady(generation: UInt64, bufferIndex: Int, sequence: UInt64)
}

/// A geometry request the embedded display could not apply.
public enum DeveloperDisplayResizeFailure: Error, Equatable, Sendable {
    /// The requested point size, backing scale, or zoom cannot be resolved.
    case geometry(DisplayGeometryResolverFailure)
    /// The guest display or its render pool could not be reconfigured.
    case displayUnavailable
    /// The prior host or guest mode could not be restored after a rejected resize.
    case modeRestoreFailed(hostModeRestored: Bool, guestModeRestored: Bool)
}

/// The counters of the developer display (graphics.md §7), as the CLI reads them.
public struct DeveloperDisplayStatistics: Equatable, Sendable {
    /// Frames the GPU has finished blitting.
    public var framesPresented: UInt64
    /// Frames replaced before they were shown.
    public var droppedFrames: UInt64
    /// Waits on a blit that exceeded the stall timeout.
    public var presentStalls: UInt64
    /// Blits that failed. Their frames are not shown.
    public var failedBlits: UInt64
    /// GPU-to-CPU readbacks made by the host. Must stay zero on the normal path.
    public var hostReadbacks: UInt64
    /// CPU copies of pixel data. Must stay zero on the drmVirgl path.
    public var cpuPixelCopies: UInt64
}

/// The development window's connection to one embedded scanout (runtime-api.md §15, #24, #30).
///
/// The CLI reads a boot presenter or a leased pool through this type, because it may not import RuntimeCore or
/// GraphicsCore. The window reports displayed frames back through `frameDisplayed`.
public final class DeveloperDisplay: @unchecked Sendable {
    /// The resolved geometry of the window's Android display.
    public var mode: ResolvedDisplayMode { core.mode }
    /// The latest pool, available for reconciliation if a bounded frame stream drops its replacement event.
    public var currentSurfaceSet: DeveloperSurfaceSet? {
        core.currentSurfaceSet.map(DeveloperSurfaceSet.init)
    }
    /// Whether this display has a presenter-backed resize path.
    public var supportsWindowResize: Bool { core.supportsWindowResize }
    /// The backing scale used to size the initial native window.
    public var backingScale: CGFloat {
        windowFrameLock.withLock { backingScaleValue }
    }
    /// The display's pixel width, which is the scanout's mode.
    public var pixelWidth: Int { mode.pixelSize.width }
    /// The display's pixel height.
    public var pixelHeight: Int { mode.pixelSize.height }
    /// The events, in order, until the boot ends.
    public let events: AsyncStream<DeveloperDisplayEvent>

    /// The RuntimeCore display that the boot attaches to its GPU device.
    let core: DevelopmentDisplay
    private let windowFrameLock = NSLock()
    private var windowFrameCommitCountValue: UInt64 = 0
    private var backingScaleValue: CGFloat

    /// Creates a display from the initial native window geometry.
    public convenience init(
        pointSize: CGSize,
        backingScale: CGFloat,
        zoom: Double = 1
    ) throws(DisplayGeometryResolverFailure) {
        let mode = try DisplayGeometryResolver.resolve(
            DisplayGeometry(pointSize: pointSize, backingScale: Double(backingScale), zoom: zoom)
        )
        self.init(mode: mode, backingScale: backingScale)
    }

    /// Creates a fixed-density display for existing embedded test clients.
    public convenience init(pixelWidth: Int, pixelHeight: Int) {
        let mode = ResolvedDisplayMode(
            pixelSize: PixelSize(width: pixelWidth, height: pixelHeight),
            densityDpi: 160,
            renderScale: 1,
            zoom: 1,
            refreshHz: 60
        )
        self.init(mode: mode, backingScale: 1)
    }

    private init(mode: ResolvedDisplayMode, backingScale: CGFloat) {
        backingScaleValue = backingScale
        let core = DevelopmentDisplay(mode: mode)
        self.core = core
        let (stream, continuation) = AsyncStream<DeveloperDisplayEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        events = stream
        Task {
            for await event in core.events {
                switch event {
                case .attached(let surfaceSet):
                    continuation.yield(.attached(surfaceSet: DeveloperSurfaceSet(surfaceSet)))
                case .surfacesReplaced(let surfaceSet):
                    continuation.yield(.surfacesReplaced(surfaceSet: DeveloperSurfaceSet(surfaceSet)))
                case .frameReady(let generation, let bufferIndex, let sequence):
                    continuation.yield(
                        .frameReady(generation: generation, bufferIndex: bufferIndex, sequence: sequence)
                    )
                }
            }
            continuation.finish()
        }
    }

    /// The number of frames committed by the native window (display-and-windowing.md §5.2).
    ///
    /// This advances from the window's Core Animation transaction completion callback, unlike
    /// `statistics.framesPresented`, which counts completed GPU blits.
    public var windowFrameCommitCount: UInt64 {
        windowFrameLock.withLock { windowFrameCommitCountValue }
    }

    /// Reconfigures scanout 0 after the window geometry settles.
    public func resize(
        pointSize: CGSize,
        backingScale: CGFloat,
        zoom: Double
    ) async throws(DeveloperDisplayResizeFailure) {
        let mode: ResolvedDisplayMode
        do throws(DisplayGeometryResolverFailure) {
            mode = try DisplayGeometryResolver.resolve(
                DisplayGeometry(pointSize: pointSize, backingScale: Double(backingScale), zoom: zoom)
            )
        } catch {
            throw .geometry(error)
        }
        guard mode != self.mode || backingScale != self.backingScale else {
            return
        }
        do throws(DevelopmentDisplayReconfigurationFailure) {
            try await core.reconfigure(to: mode)
        } catch {
            switch error {
            case .modeRestorationFailed(let hostModeRestored, let guestModeRestored):
                throw .modeRestoreFailed(
                    hostModeRestored: hostModeRestored,
                    guestModeRestored: guestModeRestored
                )
            case .graphics, .guestRejectedMode:
                throw .displayUnavailable
            }
        }
        windowFrameLock.withLock {
            backingScaleValue = backingScale
        }
    }

    /// Connects a leased secondary scanout's IOSurface pool to this window.
    public func attach(lease: DisplayLease) throws {
        try core.attach(lease: lease)
    }

    /// Returns a pool while a frame from that generation may still be in flight.
    public func surfaceSet(generation: UInt64) -> DeveloperSurfaceSet? {
        core.surfaceSet(generation: generation).map(DeveloperSurfaceSet.init)
    }

    /// The window has displayed frame `sequence` (display-and-windowing.md §5.2).
    public func frameDisplayed(generation: UInt64, sequence: UInt64) {
        windowFrameLock.withLock { windowFrameCommitCountValue &+= 1 }
        core.frameDisplayed(generation: generation, sequence: sequence)
    }

    /// Compatibility for development tests that acknowledge the initial generation.
    public func frameDisplayed(sequence: UInt64) {
        frameDisplayed(generation: 1, sequence: sequence)
    }

    /// The counters so far, or `nil` before the boot has attached the display.
    public var statistics: DeveloperDisplayStatistics? {
        guard let counters = core.statistics else {
            return nil
        }
        return DeveloperDisplayStatistics(
            framesPresented: counters.framesPresented,
            droppedFrames: counters.droppedFrames,
            presentStalls: counters.presentStalls,
            failedBlits: counters.failedBlits,
            hostReadbacks: counters.hostReadbacks,
            cpuPixelCopies: counters.cpuPixelCopies
        )
    }

    /// Ends the events. The boot calls it when it ends.
    func finish() {
        core.finish()
    }
}
