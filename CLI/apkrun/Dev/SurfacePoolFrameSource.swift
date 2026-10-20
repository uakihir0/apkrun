#if APKRUN_EMBEDDED_RUNTIME
    import IOSurface
    import Foundation
    import RuntimeHost
    import WindowingCore

    /// Adapts the developer display's frames to the window's `FrameSource` (graphics.md §6.2, display-and-windowing.md
    /// §5.3, #24). It lives in the embedded CLI, because neither WindowingCore nor the CLI may import GraphicsCore.
    /// The window reports each displayed frame back through the display.
    final class SurfacePoolFrameSource: FrameSource, @unchecked Sendable {
        // UNCHECKED-SENDABLE: the surfaces are created once by the presenter and only read here. The stream is
        // Sendable, and the continuation is used from the main actor only.
        private let lock = NSLock()
        private var sets: [UInt64: FrameSurfaceSet]
        private var current: FrameSurfaceSet
        let frames: AsyncStream<FrameSourceEvent>
        private let continuation: AsyncStream<FrameSourceEvent>.Continuation
        private let display: DeveloperDisplay

        /// Creates the source for the pool `surfaces` of `generation`, which `display` presents.
        init(surfaceSet: DeveloperSurfaceSet, display: DeveloperDisplay) {
            self.display = display
            let initial = Self.makeFrameSurfaceSet(surfaceSet)
            current = initial
            sets = [initial.generation: initial]
            let (stream, continuation) = AsyncStream<FrameSourceEvent>.makeStream(
                bufferingPolicy: .bufferingNewest(8)
            )
            frames = stream
            self.continuation = continuation
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

        /// Passes a ready frame to the window. Other events are not frames, so they are ignored.
        func ingest(_ event: DeveloperDisplayEvent) {
            switch event {
            case .attached(let surfaceSet), .surfacesReplaced(let surfaceSet):
                replaceSurfaceSet(surfaceSet)
            case .frameReady(let generation, let bufferIndex, let sequence):
                if surfaceSet(generation: generation) == nil,
                    let recovered = display.surfaceSet(generation: generation)
                {
                    replaceSurfaceSet(recovered, publish: false)
                }
                continuation.yield(.frameReady(generation: generation, bufferIndex: bufferIndex, sequence: sequence))
            }
        }

        /// The window has displayed `sequence` from `generation`; that pool's buffers may be reused.
        func frameDisplayed(generation: UInt64, sequence: UInt64) {
            display.frameDisplayed(generation: generation, sequence: sequence)
            if generation == currentSurfaceSet.generation {
                lock.withLock { sets = sets.filter { $0.key >= generation } }
            }
        }

        /// Ends the frames, when the boot ends.
        func finish() {
            continuation.finish()
        }

        private func replaceSurfaceSet(_ surfaceSet: DeveloperSurfaceSet, publish: Bool = true) {
            let frameSet = Self.makeFrameSurfaceSet(surfaceSet)
            let isNewGeneration = lock.withLock { () -> Bool in
                guard frameSet.generation > current.generation else { return false }
                sets[frameSet.generation] = frameSet
                current = frameSet
                return true
            }
            guard isNewGeneration else { return }
            if publish {
                continuation.yield(.surfacesReplaced(generation: frameSet.generation))
            }
            retireOldSurfaceSets(after: frameSet.generation)
        }

        /// Bounds retention when a replacement generation never produces a frame for the window to commit.
        private func retireOldSurfaceSets(after generation: UInt64) {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                lock.withLock {
                    guard current.generation == generation else { return }
                    sets = sets.filter { $0.key >= generation }
                }
            }
        }

        private static func makeFrameSurfaceSet(_ surfaceSet: DeveloperSurfaceSet) -> FrameSurfaceSet {
            FrameSurfaceSet(
                generation: surfaceSet.generation,
                surfaces: surfaceSet.surfaces,
                pixelWidth: surfaceSet.pixelWidth,
                pixelHeight: surfaceSet.pixelHeight,
                contentSize: surfaceSet.contentSize,
                contentsScale: surfaceSet.renderScale,
                zoom: surfaceSet.zoom
            )
        }
    }
#endif
