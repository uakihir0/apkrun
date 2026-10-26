import Foundation
import GraphicsCore
import IOSurface

/// One completed frame that is ready for an app-session window to display.
public struct DisplaySessionFrame: Equatable, Sendable {
    /// The display generation that owns the frame's surface.
    public let generation: UInt64
    /// The index of the surface within the generation's pool.
    public let bufferIndex: Int
    /// The sequence used to acknowledge this frame to GraphicsCore.
    public let sequence: UInt64
    /// The presenter's monotonic presentation timestamp.
    public let presentationTime: UInt64

}

/// The session-facing view of a display lease's IOSurface generation.
///
/// RuntimeCore keeps GraphicsCore's scanout handle behind this facade. A caller creates one frame stream for the
/// generation and acknowledges a frame after its surface has been committed by the window.
public struct DisplaySessionPool: @unchecked Sendable {
    /// The scanout generation represented by these surfaces.
    public let generation: UInt64
    /// The IOSurfaces in buffer order.
    public let surfaces: [IOSurface]

    private let sourceFrames: AsyncStream<ScanoutFrame>
    private let acknowledgeFrame: @Sendable (UInt64) -> Void

    init(scanoutPool: ScanoutPoolHandle) {
        generation = scanoutPool.generation
        surfaces = scanoutPool.surfaces
        sourceFrames = scanoutPool.frames
        acknowledgeFrame = { sequence in
            scanoutPool.frameDisplayed(sequence: sequence)
        }
    }

    /// Returns the completed frames for this generation.
    ///
    /// Call once per display lease. The stream ends when its GraphicsCore source stream ends or the caller cancels.
    public func makeFrameStream() -> AsyncStream<DisplaySessionFrame> {
        let sourceFrames = self.sourceFrames
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let relay = Task.detached {
                for await frame in sourceFrames {
                    guard !Task.isCancelled else {
                        break
                    }
                    switch frame {
                    case .frameReady(let generation, let bufferIndex, let sequence, let presentationTime):
                        continuation.yield(
                            DisplaySessionFrame(
                                generation: generation,
                                bufferIndex: bufferIndex,
                                sequence: sequence,
                                presentationTime: presentationTime
                            )
                        )
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                relay.cancel()
            }
        }
    }

    /// Makes a buffer reusable after its frame is committed by the window.
    public func frameDisplayed(sequence: UInt64) {
        acknowledgeFrame(sequence)
    }
}
