import CoreFoundation
import Foundation
import GraphicsCore
import IOSurface
import RuntimeCore
import Testing

@Test
func developmentDisplayReadsIssuedFrameSequenceBeforeReadyFrameRelay() throws {
    let mode = ResolvedDisplayMode(
        pixelSize: PixelSize(width: 640, height: 480),
        densityDpi: 160,
        renderScale: 1,
        zoom: 1,
        refreshHz: 60
    )
    let display = DevelopmentDisplay(mode: mode)
    defer { display.finish() }

    let surfaceProperties: [String: Any] = [
        kIOSurfaceWidth as String: mode.pixelSize.width,
        kIOSurfaceHeight as String: mode.pixelSize.height,
        kIOSurfaceBytesPerElement as String: 4,
        kIOSurfaceBytesPerRow as String: mode.pixelSize.width * 4,
        kIOSurfaceAllocSize as String: mode.pixelSize.width * mode.pixelSize.height * 4,
    ]
    let surface = try #require(IOSurfaceCreate(surfaceProperties as CFDictionary))
    let (frames, _) = AsyncStream.makeStream(of: ScanoutFrame.self)
    let pool = ScanoutPoolHandle(
        generation: 1,
        surfaces: [surface],
        frames: frames,
        latestIssuedFrameSequence: { 11 }
    )
    let scanout = try #require(ScanoutID(rawValue: 1))
    let lease = DisplayLease(
        leaseID: UUID(),
        session: .app(UUID()),
        scanout: scanout,
        androidDisplayID: 3,
        mode: mode,
        pool: pool
    )

    try display.attach(lease: lease)

    #expect(display.latestIssuedFrameSequence == 11)
}
