#if APKRUN_EMBEDDED_RUNTIME && APKRUN_TEST_READBACK
    import IOSurface
    import RuntimeHost
    import WindowingCore

    /// The test-only tearing check of graphics.md §12 #023 (step 5): each frame that the display makes ready is read
    /// from its pool buffer, and the pure red and pure blue pixels are counted.
    ///
    /// DEBUG-READBACK: this exists only in builds with the TestReadback trait, and the CLI reads the buffer with an
    /// IOSurface lock. It never changes the device counters `hostReadbacks` and `cpuPixelCopies`, which stay 0. Remove
    /// it with the TestReadback trait when the tearing check moves to a different test seam.
    @MainActor
    final class TearingSampler {
        /// The frames that were read.
        private(set) var frames = 0
        /// The frames with pure red pixels and no pure blue pixel.
        private(set) var redFrames = 0
        /// The frames with pure blue pixels and no pure red pixel.
        private(set) var blueFrames = 0
        /// The frames with both colours, which is a tear in the alternating-colour mode.
        private(set) var mixedFrames = 0
        /// The buffers that could not be locked or read.
        private(set) var unreadable = 0

        /// Reads the buffer of a frame that is ready to show. Other events are ignored.
        func observe(_ event: DeveloperDisplayEvent, surfaces: [IOSurface]) {
            guard case .frameReady(_, let bufferIndex, _) = event else {
                return
            }
            guard surfaces.indices.contains(bufferIndex) else {
                unreadable += 1
                return
            }
            let surface = surfaces[bufferIndex]
            guard IOSurfaceLock(surface, .readOnly, nil) == kIOReturnSuccess else {
                unreadable += 1
                return
            }
            defer {
                IOSurfaceUnlock(surface, .readOnly, nil)
            }
            let baseOrNil: UnsafeMutableRawPointer? = IOSurfaceGetBaseAddress(surface)
            guard let base = baseOrNil else {
                unreadable += 1
                return
            }
            let census = FrameColourCensus.census(
                of: UnsafeRawPointer(base),
                width: IOSurfaceGetWidth(surface),
                height: IOSurfaceGetHeight(surface),
                bytesPerRow: IOSurfaceGetBytesPerRow(surface)
            )
            frames += 1
            if census.isMixed {
                mixedFrames += 1
            } else if census.red > 0 {
                redFrames += 1
            } else if census.blue > 0 {
                blueFrames += 1
            }
        }

        /// The counts for the statistics line. They are cumulative from the boot, like the device counters.
        var summary: String {
            "framesSampled \(frames)  redFrames \(redFrames)  blueFrames \(blueFrames)  mixedFrames \(mixedFrames)  "
                + "unreadable \(unreadable)"
        }
    }
#endif
