import CoreGraphics
import IOSurface

/// The IOSurfaces of one scanout and the state of each buffer (graphics.md §6.3, display-and-windowing.md §5.2).
///
/// Each surface is BGRA8 with bytes per row aligned to 64, tagged sRGB, and not global. Only the presenter touches
/// a pool, and it does so under its own lock, so the pool itself holds no lock.
final class SurfacePool {
    /// The number of buffers. Three buffers give the steady state of one displayed, one offered, and one rendering.
    static let bufferCount = 3

    /// The pool's generation. It changes on every reallocation.
    let generation: UInt64
    let pixelWidth: Int
    let pixelHeight: Int
    let surfaces: [IOSurface]
    private(set) var states: PresentBufferStates

    private init(pixelWidth: Int, pixelHeight: Int, generation: UInt64, surfaces: [IOSurface]) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.generation = generation
        self.surfaces = surfaces
        states = PresentBufferStates(bufferCount: surfaces.count)
    }

    /// The bytes per row that a surface of `pixelWidth` pixels uses: 4 bytes per BGRA pixel, aligned to 64.
    static func bytesPerRow(pixelWidth: Int) -> Int {
        (pixelWidth * 4 + 63) / 64 * 64
    }

    /// Allocates the surfaces. Returns `nil` when the system refuses one.
    static func make(pixelWidth: Int, pixelHeight: Int, generation: UInt64 = 1) -> SurfacePool? {
        guard pixelWidth > 0, pixelHeight > 0 else {
            return nil
        }
        // The color space is the serialized sRGB profile, as kIOSurfaceColorSpace expects (display-and-windowing.md §5.4).
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)?.copyPropertyList()
        var surfaces: [IOSurface] = []
        for _ in 0..<bufferCount {
            var properties: [IOSurfacePropertyKey: Any] = [
                .width: pixelWidth,
                .height: pixelHeight,
                .bytesPerElement: 4,
                .bytesPerRow: bytesPerRow(pixelWidth: pixelWidth),
                .pixelFormat: UInt32(0x4247_5241),  // 'BGRA'
            ]
            if let colorSpace {
                properties[IOSurfacePropertyKey(rawValue: kIOSurfaceColorSpace as String)] = colorSpace
            }
            guard let surface = IOSurface(properties: properties) else {
                return nil
            }
            surfaces.append(surface)
        }
        return SurfacePool(pixelWidth: pixelWidth, pixelHeight: pixelHeight, generation: generation, surfaces: surfaces)
    }

    /// Takes a free buffer for rendering. WindowServer may still read a buffer, so `IOSurfaceIsInUse` skips it.
    func acquire() -> Int? {
        states.acquire { index in
            surfaces[index].isInUse
        }
    }

    /// The buffer's blit finished, so `sequence` is offered.
    func markReady(_ index: Int, sequence: UInt64) {
        states.markReady(index, sequence: sequence)
    }

    /// The buffer's blit failed, so the buffer is free again.
    func abandon(_ index: Int) {
        states.abandon(index)
    }

    /// The consumer displayed `sequence`. Returns how many buffers became free.
    @discardableResult
    func consumerDisplayed(upTo sequence: UInt64) -> Int {
        states.consumerDisplayed(upTo: sequence)
    }

    /// True when some buffer is free, which `acquire` may still refuse while WindowServer holds it.
    var hasFreeBuffer: Bool {
        states.hasFreeBuffer
    }
}
