import Foundation
import IOSurface
import Metal
import Testing
import VirtioDeviceCore
import VirtioDeviceCoreTestSupport

@testable import GraphicsCore

// T1 (graphics.md §14, #24): the real virglrenderer and ANGLE, without a VM. The test uploads
// known pixels into two resources, flushes each to scanout 0, and reads back the pool IOSurface. It checks the
// orientation and the channel layout of the blit, and that the normal path left the host counters at zero. The
// readback is a test-only comparison of the surface contents. It does not use the production counters.

/// The built VirGL runtime cache, found from this file's location, or `nil` when it is not built.
private func presentRuntimeDirectory() -> String? {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<16 {
        let candidate = directory.appendingPathComponent("ThirdParty/out/virgl-runtime/current")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate.resolvingSymlinksInPath().path
        }
        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path {
            break
        }
        directory = parent
    }
    return nil
}

/// One BGRA pixel as the test compares it.
private struct BGRA: Equatable, CustomStringConvertible {
    let blue: UInt8
    let green: UInt8
    let red: UInt8
    let alpha: UInt8

    var description: String {
        "B\(blue) G\(green) R\(red) A\(alpha)"
    }
}

/// The pixel at (`x`, `y`) of a locked surface.
private func pixel(of surface: IOSurface, x: Int, y: Int) -> BGRA {
    let address = surface.baseAddress.advanced(by: y * surface.bytesPerRow + x * 4)
    let bytes = address.assumingMemoryBound(to: UInt8.self)
    return BGRA(blue: bytes[0], green: bytes[1], red: bytes[2], alpha: bytes[3])
}

/// The request that creates a `width` x `height` B8G8R8A8 2D resource that can be a scanout.
private func scanoutResource(id: UInt32, width: UInt32, height: UInt32) -> [UInt8] {
    gpuRequest(
        .resourceCreate3D,
        body: .resourceCreate3D(
            VirtioGPUResourceCreate3D(
                resourceID: id,
                target: 2,
                format: 1,
                bind: 2,
                width: width,
                height: height,
                depth: 1,
                arraySize: 1,
                lastLevel: 0,
                sampleCount: 0,
                flags: 0
            )
        )
    )
}

@Test(
    .enabled(
        if: MTLCreateSystemDefaultDevice() != nil,
        "This host does not provide a Metal device."
    )
)
func aFlushOfTheVirGLRendererPresentsTheGuestPixelsInOrderWithTheirOrientation() async throws {
    guard let runtime = presentRuntimeDirectory() else {
        Issue.record("The built VirGL runtime cache is unavailable.")
        return
    }
    #expect(setenv("APKRUN_VIRGL_RUNTIME_PATH", runtime, 1) == 0)

    let width = 8
    let height = 4
    // Two BGRA colors. Red is B 0, G 0, R 255. Blue is B 255, G 0, R 0.
    let red: [UInt8] = [0, 0, 255, 255]
    let blue: [UInt8] = [255, 0, 0, 255]
    // The first resource has red on the top two rows and blue below. The second is the reverse.
    let redPixels = (0..<(width * height)).flatMap { index in index < 2 * width ? red : blue }
    let bluePixels = (0..<(width * height)).flatMap { index in index < 2 * width ? blue : red }
    let guest = SeededGuestBackend(queues: [FakeVirtioQueue(elements: []), FakeVirtioQueue(elements: [])])
    let context = VirtioDeviceContext(backend: guest, generation: 0)
    guest.seed(address: 0x1000, bytes: redPixels)
    guest.seed(address: 0x2000, bytes: bluePixels)

    let device = try VirtioGPUDevice.virgl()
    defer { device.deviceWillStop() }
    let scanout = try #require(ScanoutID(rawValue: 0))
    let presenter = try device.attachPresenter(scanout, width: width, height: height)
    let fullRect = VirtioGPURect(x: 0, y: 0, width: UInt32(width), height: UInt32(height))

    func backed(id: UInt32, address: UInt64) -> [[UInt8]] {
        [
            scanoutResource(id: id, width: UInt32(width), height: UInt32(height)),
            gpuRequest(
                .resourceAttachBacking,
                body: .resourceAttachBacking(
                    resourceID: id,
                    entries: [VirtioGPUMemoryEntry(address: address, length: UInt32(width * height * 4))]
                )
            ),
            gpuRequest(
                .transferToHost3D,
                body: .transferToHost3D(
                    VirtioGPUTransfer3D(
                        box: gpuBox(width: UInt32(width), height: UInt32(height)),
                        offset: 0,
                        resourceID: id,
                        level: 0,
                        stride: 0,
                        layerStride: 0
                    )
                )
            ),
        ]
    }
    func flush(_ id: UInt32) -> [UInt8] {
        gpuRequest(.resourceFlush, body: .resourceFlush(rect: fullRect, resourceID: id))
    }
    func setScanout(_ id: UInt32) -> [UInt8] {
        gpuRequest(.setScanout, body: .setScanout(rect: fullRect, scanoutID: 0, resourceID: id))
    }

    let first = FakeVirtioQueue(
        elements: (backed(id: 3, address: 0x1000) + [setScanout(3), flush(3)]).map {
            (readable: $0, writableByteCount: 4096)
        }
    )
    guest.replaceQueues([first, FakeVirtioQueue(elements: [])])
    device.queueNotified(index: 0, context: context)
    try await eventually { presenter.statistics.framesPresented == 1 }
    var frames = presenter.frames.makeAsyncIterator()
    let firstFrame = await frames.next()
    guard case .frameReady(_, let firstIndex, let firstSequence, _) = firstFrame else {
        Issue.record("The first flush produced no frame.")
        return
    }
    #expect(firstSequence == 1)

    // The second resource replaces the first on the scanout, and its flush is the newest frame.
    let second = FakeVirtioQueue(
        elements: (backed(id: 4, address: 0x2000) + [setScanout(4), flush(4)]).map {
            (readable: $0, writableByteCount: 4096)
        }
    )
    guest.replaceQueues([second, FakeVirtioQueue(elements: [])])
    device.queueNotified(index: 0, context: context)
    try await eventually { presenter.statistics.framesPresented == 2 }
    let secondFrame = await frames.next()
    guard case .frameReady(_, let secondIndex, let secondSequence, _) = secondFrame else {
        Issue.record("The second flush produced no frame.")
        return
    }
    #expect(secondSequence == 2)

    // The surface contents match the guest's pixels, row for row. Row 0 is the top row, as in the guest.
    for (index, expectedBase) in [(firstIndex, redPixels), (secondIndex, bluePixels)] {
        let surface = presenter.surfaces[index]
        #expect(surface.lock(options: .readOnly, seed: nil) == KERN_SUCCESS)
        defer { _ = surface.unlock(options: .readOnly, seed: nil) }
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let expected = BGRA(
                    blue: expectedBase[offset],
                    green: expectedBase[offset + 1],
                    red: expectedBase[offset + 2],
                    alpha: expectedBase[offset + 3]
                )
                #expect(pixel(of: surface, x: x, y: y) == expected, "pixel (\(x), \(y)) of buffer \(index)")
            }
        }
    }
    #expect(pixel(of: presenter.surfaces[firstIndex], x: 0, y: 0) == BGRA(blue: 0, green: 0, red: 255, alpha: 255))
    #expect(pixel(of: presenter.surfaces[secondIndex], x: 0, y: 0) == BGRA(blue: 255, green: 0, red: 0, alpha: 255))

    // The present path is a GPU blit: no pixel reached the host in a CPU copy or a readback (graphics.md §7).
    #expect(device.statistics.hostReadbacks == 0)
    #expect(device.statistics.cpuPixelCopies == 0)
    #expect(presenter.statistics.droppedFrames == 0)
}
