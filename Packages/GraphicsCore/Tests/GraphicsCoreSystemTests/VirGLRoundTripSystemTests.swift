import CryptoKit
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

/// The target of the synthetic replay session: a 16 × 16 BGRA 2D texture, the arguments that `resourceCreate3D` builds.
private let syntheticTarget = VirGLResourceArguments(
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

/// The full-target upload of the synthetic session: 1024 bytes, with rows 64 bytes apart.
private let syntheticFullUpload = (0..<1024).map { UInt8(truncatingIfNeeded: $0 &* 7) }

/// The upload of the 4 × 4 box at (4, 4) of the synthetic session. The data starts at the box's first pixel and its
/// rows are 64 bytes apart, so 208 bytes cover it (`vrend_transfer_size`), as virglrenderer reads them.
private let syntheticBoxUpload = (0..<208).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) }

private let syntheticBox = VirGLTransfer(
    resourceID: 7,
    contextID: 0,
    level: 0,
    stride: 64,
    layerStride: 0,
    x: 4,
    y: 4,
    z: 0,
    width: 4,
    height: 4,
    depth: 1
)

/// The synthetic replay fixture, `Tests/Fixtures/graphics/synthetic-virgl-session.json` (M02-graphics.md #022 step 3).
/// It is synthetic: no Linux guest run has recorded the `kmscube` stream yet (IR-514).
private func syntheticFixtureURL() -> URL {
    // This file is Packages/GraphicsCore/Tests/GraphicsCoreSystemTests/VirGLRoundTripSystemTests.swift.
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 {
        root.deleteLastPathComponent()
    }
    return root.appendingPathComponent("Tests/Fixtures/graphics/synthetic-virgl-session.json")
}

/// The renderer calls of the synthetic session, recorded on `engine`. It uses only the calls of the existing helpers.
private func recordSyntheticSession(on engine: any VirGLEngine) throws -> VirGLRecording {
    let recorder = VirGLRecorder()
    let session = RecordingVirGLEngine(wrapping: engine, recorder: recorder)
    try session.createContext(id: 1, name: "synthetic-scanout")
    try session.createResource(syntheticTarget)
    try session.attachResource(context: 1, resource: 7)
    var fullUpload = syntheticFullUpload
    try session.transferWrite(box(width: 16, height: 16), data: &fullUpload)
    var boxUpload = syntheticBoxUpload
    try session.transferWrite(syntheticBox, data: &boxUpload)
    try session.createFence(id: 1, context: 1)
    return recorder.recording
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// The SHA-256 of `Tests/Fixtures/graphics/synthetic-virgl-session.json`. Changing the fixture changes this value, so a
/// fixture that is replaced without the generator fails the check.
private let syntheticFixtureSHA256 = "5a3ffaea5130102d90b28456975512f9fd8359f8693c334519109cdb6380fd21"

#if APKRUN_TEST_READBACK
    /// The SHA-256 of the scanout that the synthetic session must produce. It was computed from the recorded transfers
    /// with a separate script that applies the box rule of `expectedSyntheticScanout`, and it is pinned here (IR-515).
    private let syntheticScanoutSHA256 = "41172b76173b4dd26e522abf890495d98aff5f9d2cc601ee617d48b4b7343b86"

    /// The environment variable that names the `kmscube` recording of the development Linux run (M02-graphics.md #022
    /// step 3). The recording is 24.6 MiB, so it is not in the repository, and the test skips without the variable.
    private let kmscubeRecordingVariable = "APKRUN_TEST_KMSCUBE_RECORDING"

    /// The SHA-256 of the `kmscube` recording that the Linux run wrote (IR-812). The run's command is in the IR entry.
    private let kmscubeRecordingSHA256 = "0f7010c7bd0e10228900420859a1d8d035fe47be2733a40d656b71886c0df46a"

    /// The positions of the 61 calls that the renderer rejects on replay. They are exactly the `submit` calls of the
    /// recording, the SUBMIT_3D of the kmscube context (IR-813). The live run logged 61 renderer failures too (IR-605).
    /// The test pins them, so a change in either direction is visible. It does not claim that the renderer draws.
    private let kmscubeReplayFailures: [Int] = [
        16, 21, 23, 25, 27, 29, 31, 33, 35, 37, 39, 41, 43, 45, 47, 49, 51, 53, 55, 57, 59, 61, 63, 65, 67, 69,
        71, 73, 75, 77, 79, 81, 83, 85, 87, 89, 91, 93, 95, 97, 99, 101, 103, 105, 107, 109, 111, 113, 115, 117,
        119, 121, 123, 125, 127, 129, 131, 133, 135, 137, 139,
    ]

    /// The largest difference that a replayed byte may have from the expected byte. The synthetic session has no
    /// rasterization, so its uploads must match exactly (IR-516).
    private let syntheticScanoutTolerance = 0

    /// The image that the recorded transfers produce, by the box rule of virglrenderer's `read_transfer_data`: data row
    /// `r` starts `r * stride` bytes into the data, and pixel `c` of that row starts `c * 4` bytes in.
    private func expectedSyntheticScanout(from recording: VirGLRecording) -> [UInt8] {
        let rowBytes = 16 * 4
        var image = [UInt8](repeating: 0, count: rowBytes * 16)
        for operation in recording.operations {
            guard case .transferWrite(let transfer, let data) = operation else { continue }
            for row in 0..<Int(transfer.height) {
                for column in 0..<Int(transfer.width) {
                    for channel in 0..<4 {
                        let destination =
                            (Int(transfer.y) + row) * rowBytes + (Int(transfer.x) + column) * 4 + channel
                        image[destination] = data[row * Int(transfer.stride) + column * 4 + channel]
                    }
                }
            }
        }
        return image
    }
#endif

extension VirGLRendererSuite {
    @Test(
        .enabled(
            if: MTLCreateSystemDefaultDevice() != nil
                && ProcessInfo.processInfo.environment["APKRUN_REGENERATE_FIXTURES"] == "1",
            "Set APKRUN_REGENERATE_FIXTURES=1 to rewrite the synthetic replay fixture from its generator."
        )
    )
    func regenerateTheSyntheticReplayFixture() throws {
        guard let runtime = runtimeDirectory() else {
            Issue.record("The built VirGL runtime cache is unavailable.")
            return
        }
        #expect(setenv("APKRUN_VIRGL_RUNTIME_PATH", runtime, 1) == 0)

        let renderer = try VirGLRenderer(onFenceCompleted: { _ in })
        defer { try? renderer.destroy() }
        try recordSyntheticSession(on: renderer).encoded().write(to: syntheticFixtureURL(), options: .atomic)
    }

    @Test(
        .enabled(
            if: MTLCreateSystemDefaultDevice() != nil,
            "This host does not provide a Metal device."
        )
    )
    func theSyntheticReplayFixtureIsWhatItsGeneratorRecords() throws {
        guard let runtime = runtimeDirectory() else {
            Issue.record("The built VirGL runtime cache is unavailable.")
            return
        }
        #expect(setenv("APKRUN_VIRGL_RUNTIME_PATH", runtime, 1) == 0)

        let renderer = try VirGLRenderer(onFenceCompleted: { _ in })
        defer { try? renderer.destroy() }
        let generated = try recordSyntheticSession(on: renderer).encoded()
        let fixture = try Data(contentsOf: syntheticFixtureURL())
        #expect(fixture == generated)
        #expect(sha256Hex(fixture) == syntheticFixtureSHA256)
    }

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
        #expect(replay(recording, onto: fresh).isEmpty)
        var readBack = [UInt8](repeating: 0, count: 16 * 16 * 4)
        try fresh.transferRead(box(width: 16, height: 16), into: &readBack)
        #expect(readBack == pattern)
        try fresh.destroy()
    }

    @Test(
        .enabled(
            if: MTLCreateSystemDefaultDevice() != nil,
            "This host does not provide a Metal device."
        )
    )
    func aFenceAboveThirtyOneBitsRetires() throws {
        guard let runtime = runtimeDirectory() else {
            Issue.record("The built VirGL runtime cache is unavailable.")
            return
        }
        #expect(setenv("APKRUN_VIRGL_RUNTIME_PATH", runtime, 1) == 0)
        let fences = FenceLog()
        let renderer = try VirGLRenderer(onFenceCompleted: { fences.append($0) })
        defer { try? renderer.destroy() }
        try renderer.createFence(id: 0x8000_0001, context: 0)
        for _ in 0..<2_000 where fences.values.isEmpty {
            renderer.poll()
            usleep(1_000)
        }
        #expect(fences.values == [0x8000_0001])
    }

    #if APKRUN_TEST_READBACK
        @Test(
            .enabled(
                if: MTLCreateSystemDefaultDevice() != nil,
                "This host does not provide a Metal device."
            )
        )
        func theSyntheticSessionReplaysOnTheDeviceAndItsScanoutMatches() throws {
            guard let runtime = runtimeDirectory() else {
                Issue.record("The built VirGL runtime cache is unavailable.")
                return
            }
            #expect(setenv("APKRUN_VIRGL_RUNTIME_PATH", runtime, 1) == 0)

            let device = try VirtioGPUDevice.virgl()
            defer { device.deviceWillStop() }
            let recording = try VirGLRecording.decoded(from: Data(contentsOf: syntheticFixtureURL()))
            #expect(device.replayRecordingForTest(recording).isEmpty)

            let expected = expectedSyntheticScanout(from: recording)
            #expect(sha256Hex(Data(expected)) == syntheticScanoutSHA256)
            let scanout = try device.readResourceForTest(box(width: 16, height: 16), byteCount: expected.count)
            #expect(scanout.count == expected.count)
            let mismatches = zip(scanout, expected).filter { abs(Int($0) - Int($1)) > syntheticScanoutTolerance }.count
            #expect(mismatches == 0)
            #expect(sha256Hex(Data(scanout)) == syntheticScanoutSHA256)

            // The replay and the test-only readback leave the normal-path counters at zero (graphics.md §7).
            let counters = device.statistics
            #expect(counters.hostReadbacks == 0)
            #expect(counters.guestReadbacks == 0)
        }

        @Test(
            .enabled(
                if: MTLCreateSystemDefaultDevice() != nil
                    && ProcessInfo.processInfo.environment[kmscubeRecordingVariable] != nil,
                "Set APKRUN_TEST_KMSCUBE_RECORDING to the kmscube recording (M02-graphics.md #022 step 3)."
            )
        )
        func theKmscubeSessionReplaysOnTheDeviceWithoutHostReadbacks() throws {
            guard let runtime = runtimeDirectory() else {
                Issue.record("The built VirGL runtime cache is unavailable.")
                return
            }
            #expect(setenv("APKRUN_VIRGL_RUNTIME_PATH", runtime, 1) == 0)

            let path = try #require(ProcessInfo.processInfo.environment[kmscubeRecordingVariable])
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            #expect(sha256Hex(data) == kmscubeRecordingSHA256)
            let recording = try VirGLRecording.decoded(from: data)

            let device = try VirtioGPUDevice.virgl()
            defer { device.deviceWillStop() }
            let failures = device.replayRecordingForTest(recording)
            #expect(failures.map(\.index) == kmscubeReplayFailures)
            #expect(
                failures.allSatisfy { failure in
                    if case .submit = recording.operations[failure.index] { return true }
                    return false
                })

            // The replay runs through the device's renderer. The normal-path counters must stay at zero (graphics.md §7).
            let counters = device.statistics
            #expect(counters.hostReadbacks == 0)
            #expect(counters.guestReadbacks == 0)
        }

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
