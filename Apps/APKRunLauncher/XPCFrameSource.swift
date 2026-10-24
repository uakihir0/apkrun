import AppKit
import Dispatch
import Foundation
import IOSurface
import RuntimeAPI
import RuntimeClient
import WindowingCore

/// An invalid descriptor or surface array received while opening or resizing a session.
enum XPCFrameSourceError: Error, Equatable {
    case invalidSurfaceCount(expected: Int, actual: Int)
    case invalidSurfaceSize(index: Int)
    case invalidDensity
    case nonIncreasingGeneration
}

/// Adapts the runtime's XPC session messages to WindowingCore's frame source.
///
/// XPC callbacks may arrive while AppKit is drawing or handling input. A single queued main-queue drain delivers the
/// newest frame and coalesces superseded frames before they reach the window. Surface replacement metadata is stored
/// before its event is queued, so a following frame can safely imply a dropped replacement notification.
final class XPCFrameSource: FrameSource, @unchecked Sendable {
    private let lock = NSLock()
    private var sets: [UInt64: FrameSurfaceSet]
    private var current: FrameSurfaceSet
    private var coalescer = FrameEventCoalescer()

    let frames: AsyncStream<FrameSourceEvent>
    private let continuation: AsyncStream<FrameSourceEvent>.Continuation
    private let onFrameDisplayed: @Sendable (FrameDisplayed) -> Void
    private let onVisibilityChanged: @Sendable (VisibilityChanged) -> Void

    /// Creates the source from the descriptor and the three IOSurfaces returned by `openSession`.
    init(
        descriptor: SessionDescriptor,
        surfaces: [IOSurface],
        onFrameDisplayed: @escaping @Sendable (FrameDisplayed) -> Void,
        onVisibilityChanged: @escaping @Sendable (VisibilityChanged) -> Void
    ) throws {
        let initial = try Self.makeFrameSurfaceSet(
            metadata: descriptor.surfaces,
            surfaces: surfaces,
            windowPrefs: descriptor.windowPrefs
        )
        current = initial
        sets = [initial.generation: initial]
        self.onFrameDisplayed = onFrameDisplayed
        self.onVisibilityChanged = onVisibilityChanged
        let made = AsyncStream.makeStream(
            of: FrameSourceEvent.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        frames = made.stream
        continuation = made.continuation
    }

    var currentSurfaceSet: FrameSurfaceSet {
        lock.withLock { current }
    }

    var surfaces: [IOSurface] { currentSurfaceSet.surfaces }
    var generation: UInt64 { currentSurfaceSet.generation }
    var pixelWidth: Int { currentSurfaceSet.pixelWidth }
    var pixelHeight: Int { currentSurfaceSet.pixelHeight }

    func surfaceSet(generation: UInt64) -> FrameSurfaceSet? {
        lock.withLock { sets[generation] }
    }

    /// Installs a replacement pool before queuing its notification to the window.
    func surfacesReplaced(_ message: SurfacesReplaced, surfaces: [IOSurface], windowPrefs: WindowPrefs) throws {
        let replacement = try Self.makeFrameSurfaceSet(
            metadata: message.surfaceSet,
            surfaces: surfaces,
            windowPrefs: windowPrefs
        )
        let shouldSchedule = try lock.withLock { () throws -> Bool in
            guard replacement.generation > current.generation else {
                throw XPCFrameSourceError.nonIncreasingGeneration
            }
            sets[replacement.generation] = replacement
            current = replacement
            return coalescer.enqueue(.surfacesReplaced(generation: replacement.generation))
        }
        scheduleDrainIfNeeded(shouldSchedule)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(1)) { [weak self] in
            self?.releasePools(olderThan: replacement.generation)
        }
    }

    /// Applies a buffered session message, recovering a dropped replacement notification from a frame.
    func receive(_ message: RuntimeSessionMessage) {
        switch message {
        case .surfacesReplaced(let replacement, let surfaces, let windowPrefs):
            try? surfacesReplaced(replacement, surfaces: surfaces, windowPrefs: windowPrefs)
        case .frameReady(let frame):
            if UInt64(frame.surfaceSet.generation) > generation {
                try? surfacesReplaced(
                    SurfacesReplaced(surfaceSet: frame.surfaceSet),
                    surfaces: frame.surfaces,
                    windowPrefs: frame.windowPrefs
                )
            }
            frameReady(frame.message)
        }
    }

    /// Queues a frame callback. The timestamp is the daemon's `mach_absolute_time` at GPU completion.
    func frameReady(_ message: FrameReady) {
        let shouldSchedule = lock.withLock { () -> Bool in
            guard
                let set = sets[UInt64(message.generation)],
                set.surfaces.indices.contains(message.surfaceIndex)
            else {
                return false
            }
            return coalescer.enqueue(
                .frameReady(
                    generation: UInt64(message.generation),
                    bufferIndex: message.surfaceIndex,
                    sequence: message.frameSeq,
                    presentationTime: message.presentationTime
                )
            )
        }
        scheduleDrainIfNeeded(shouldSchedule)
    }

    /// Reports a frame after Core Animation commits it to the window layer.
    func frameDisplayed(generation: UInt64, sequence: UInt64) {
        guard let generation = UInt32(exactly: generation) else { return }
        onFrameDisplayed(FrameDisplayed(generation: generation, frameSeq: sequence))
        lock.withLock {
            guard UInt64(generation) == current.generation else { return }
            sets = sets.filter { $0.key >= UInt64(generation) }
        }
    }

    /// Reports an AppKit visibility transition to the session connection.
    func visibilityChanged(_ visible: Bool) {
        onVisibilityChanged(VisibilityChanged(visible: visible))
    }

    private func scheduleDrainIfNeeded(_ shouldSchedule: Bool) {
        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let event = self.lock.withLock { self.coalescer.takePending() }
            if let event {
                self.continuation.yield(event)
            }
        }
    }

    private func releasePools(olderThan generation: UInt64) {
        lock.withLock {
            sets = sets.filter { $0.key >= generation }
        }
    }

    private static func makeFrameSurfaceSet(
        metadata: SurfaceSet,
        surfaces: [IOSurface],
        windowPrefs: WindowPrefs
    ) throws -> FrameSurfaceSet {
        guard surfaces.count == SurfaceSet.requiredSurfaceCount else {
            throw XPCFrameSourceError.invalidSurfaceCount(
                expected: SurfaceSet.requiredSurfaceCount,
                actual: surfaces.count
            )
        }
        guard metadata.pixelSize.width > 0, metadata.pixelSize.height > 0,
            metadata.densityDpi > 0, windowPrefs.zoom.isFinite, windowPrefs.zoom > 0
        else {
            throw XPCFrameSourceError.invalidDensity
        }
        for (index, surface) in surfaces.enumerated()
        where IOSurfaceGetWidth(surface) != metadata.pixelSize.width
            || IOSurfaceGetHeight(surface) != metadata.pixelSize.height
        {
            throw XPCFrameSourceError.invalidSurfaceSize(index: index)
        }

        // The resolver defines densityDpi = 160 * renderScale * zoom. Reconstructing renderScale this way keeps the
        // IOSurface's logical point size consistent with the guest's applied display density.
        let renderScale = Double(metadata.densityDpi) / (160 * windowPrefs.zoom)
        guard renderScale.isFinite, renderScale > 0 else {
            throw XPCFrameSourceError.invalidDensity
        }
        let contentSize = CGSize(
            width: Double(metadata.pixelSize.width) / renderScale,
            height: Double(metadata.pixelSize.height) / renderScale
        )
        return FrameSurfaceSet(
            generation: UInt64(metadata.generation),
            surfaces: surfaces,
            pixelWidth: metadata.pixelSize.width,
            pixelHeight: metadata.pixelSize.height,
            contentSize: contentSize,
            contentsScale: CGFloat(renderScale),
            zoom: windowPrefs.zoom
        )
    }
}
