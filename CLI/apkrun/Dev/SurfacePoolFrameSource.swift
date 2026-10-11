#if APKRUN_EMBEDDED_RUNTIME
    import IOSurface
    import RuntimeHost
    import WindowingCore

    /// Adapts the developer display's frames to the window's `FrameSource` (graphics.md §6.2, display-and-windowing.md
    /// §5.3, #023). It lives in the embedded CLI, because neither WindowingCore nor the CLI may import GraphicsCore.
    /// The window reports each displayed frame back through the display.
    final class SurfacePoolFrameSource: FrameSource, @unchecked Sendable {
        // UNCHECKED-SENDABLE: the surfaces are created once by the presenter and only read here. The stream is
        // Sendable, and the continuation is used from the main actor only.
        let surfaces: [IOSurface]
        let generation: UInt64
        let pixelWidth: Int
        let pixelHeight: Int
        let frames: AsyncStream<FrameSourceEvent>
        private let continuation: AsyncStream<FrameSourceEvent>.Continuation
        private let display: DeveloperDisplay

        /// Creates the source for the pool `surfaces` of `generation`, which `display` presents.
        init(surfaces: [IOSurface], generation: UInt64, display: DeveloperDisplay) {
            self.surfaces = surfaces
            self.generation = generation
            pixelWidth = display.pixelWidth
            pixelHeight = display.pixelHeight
            self.display = display
            let (stream, continuation) = AsyncStream<FrameSourceEvent>.makeStream(
                bufferingPolicy: .bufferingNewest(8)
            )
            frames = stream
            self.continuation = continuation
        }

        /// Passes a ready frame to the window. Other events are not frames, so they are ignored.
        func ingest(_ event: DeveloperDisplayEvent) {
            guard case .frameReady(let generation, let bufferIndex, let sequence) = event else {
                return
            }
            continuation.yield(.frameReady(generation: generation, bufferIndex: bufferIndex, sequence: sequence))
        }

        /// The window has displayed `sequence`. The display frees the buffers it no longer needs.
        func frameDisplayed(sequence: UInt64) {
            display.frameDisplayed(sequence: sequence)
        }

        /// Ends the frames, when the boot ends.
        func finish() {
            continuation.finish()
        }
    }
#endif
