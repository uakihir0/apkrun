import Darwin
import Foundation
import Metal
import Testing

@testable import GraphicsCore

/// Records the fences that virglrenderer retires, from its render thread.
private final class FenceLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UInt32] = []

    func append(_ fence: UInt32) {
        lock.withLock { stored.append(fence) }
    }

    var values: [UInt32] {
        lock.withLock { stored }
    }
}

/// The development VirGL runtime, found from the test source, or `nil` when it has not been built.
private func runtimeDirectory() -> String? {
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

private func box(width: UInt32, height: UInt32) -> VirGLTransfer {
    VirGLTransfer(
        resourceID: 7,
        contextID: 0,
        level: 0,
        stride: width * 4,
        layerStride: 0,
        x: 0,
        y: 0,
        z: 0,
        width: width,
        height: height,
        depth: 1
    )
}

extension VirGLRendererSuite {
    @Test(
        .enabled(
            if: MTLCreateSystemDefaultDevice() != nil,
            "This host does not provide a Metal device."
        )
    )
    func virglRoundTripsATextureUploadAndRetiresAFence() throws {
        guard let runtime = runtimeDirectory() else {
            Issue.record("The built VirGL runtime cache is unavailable.")
            return
        }
        #expect(setenv("APKRUN_VIRGL_RUNTIME_PATH", runtime, 1) == 0)

        let fences = FenceLog()
        let renderer = try VirGLRenderer(onFenceCompleted: { fences.append($0) })
        defer { try? renderer.destroy() }

        try renderer.createContext(id: 1, name: "round-trip")
        try renderer.createResource(
            VirGLResourceArguments(
                resourceID: 7,
                target: 2,
                format: 1,
                bind: 2,
                width: 16,
                height: 16,
                depth: 1,
                arraySize: 1,
                lastLevel: 0,
                sampleCount: 0,
                flags: 0
            )
        )
        try renderer.attachResource(context: 1, resource: 7)

        var pattern = (0..<(16 * 16 * 4)).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        try renderer.transferWrite(box(width: 16, height: 16), data: &pattern)
        var readBack = [UInt8](repeating: 0, count: 16 * 16 * 4)
        try renderer.transferRead(box(width: 16, height: 16), into: &readBack)
        #expect(readBack == pattern)

        try renderer.createFence(id: 1, context: 0)
        for _ in 0..<2_000 where fences.values.isEmpty {
            renderer.poll()
            usleep(1_000)
        }
        #expect(fences.values == [1])

        try renderer.detachResource(context: 1, resource: 7)
        try renderer.destroyContext(id: 1)
    }

    @Test(
        .enabled(
            if: MTLCreateSystemDefaultDevice() != nil,
            "This host does not provide a Metal device."
        )
    )
    func aRecordedSessionReplaysOntoAFreshRenderer() throws {
        guard let runtime = runtimeDirectory() else {
            Issue.record("The built VirGL runtime cache is unavailable.")
            return
        }
        #expect(setenv("APKRUN_VIRGL_RUNTIME_PATH", runtime, 1) == 0)

        let recorder = VirGLRecorder()
        let first = RecordingVirGLEngine(wrapping: try VirGLRenderer(onFenceCompleted: { _ in }), recorder: recorder)
        try first.createContext(id: 1, name: "record")
        try first.createResource(
            VirGLResourceArguments(
                resourceID: 7,
                target: 2,
                format: 1,
                bind: 2,
                width: 16,
                height: 16,
                depth: 1,
                arraySize: 1,
                lastLevel: 0,
                sampleCount: 0,
                flags: 0
            )
        )
        try first.attachResource(context: 1, resource: 7)
        var pattern = (0..<(16 * 16 * 4)).map { UInt8(truncatingIfNeeded: $0 &* 13) }
        try first.transferWrite(box(width: 16, height: 16), data: &pattern)
        try first.destroy()

        let recording = try VirGLRecording.decoded(from: try recorder.recording.encoded())
        let fresh = try VirGLRenderer(onFenceCompleted: { _ in })
        #expect(replay(recording, onto: fresh) == nil)
        var readBack = [UInt8](repeating: 0, count: 16 * 16 * 4)
        try fresh.transferRead(box(width: 16, height: 16), into: &readBack)
        #expect(readBack == pattern)
        try fresh.destroy()
    }

    #if APKRUN_TEST_READBACK
        @Test(
            .enabled(
                if: MTLCreateSystemDefaultDevice() != nil,
                "This host does not provide a Metal device."
            )
        )
        func theTestOnlyReadbackReturnsTheResourceBytes() throws {
            guard let runtime = runtimeDirectory() else {
                Issue.record("The built VirGL runtime cache is unavailable.")
                return
            }
            #expect(setenv("APKRUN_VIRGL_RUNTIME_PATH", runtime, 1) == 0)

            let renderer = try VirGLRenderer(onFenceCompleted: { _ in })
            defer { try? renderer.destroy() }
            try renderer.createResource(
                VirGLResourceArguments(
                    resourceID: 7,
                    target: 2,
                    format: 1,
                    bind: 2,
                    width: 4,
                    height: 4,
                    depth: 1,
                    arraySize: 1,
                    lastLevel: 0,
                    sampleCount: 0,
                    flags: 0
                )
            )
            var pattern = (0..<64).map { UInt8($0) }
            try renderer.transferWrite(box(width: 4, height: 4), data: &pattern)
            let readBack = try renderer.readResourceForTest(box(width: 4, height: 4), byteCount: 64)
            #expect(readBack == pattern)
            renderer.unrefResource(id: 7)
        }
    #endif
}
