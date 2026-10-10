import Foundation
import Metal
import Testing

@testable import RuntimeCore

// T1: the drmVirgl device of a boot with the real VirGL renderer. It needs a Metal device and the built VirGL runtime
// (ThirdParty/out/virgl-runtime/current), and it starts no VM. Without either, the tests are skipped with the reason.

/// The built VirGL runtime cache of this checkout, or `nil` when `ThirdParty/out` has not been built.
///
/// The debug renderer looks for the cache next to its executable, and the Swift Testing runner is not inside the
/// checkout. So each test names the cache with `APKRUN_VIRGL_RUNTIME_PATH`, as the GraphicsCore tests do.
private let builtVirglRuntime: String? = {
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
}()

/// Points the renderer at the built runtime cache, or fails the test when the cache is missing.
private func useBuiltVirglRuntime() throws {
    let runtime = try #require(builtVirglRuntime)
    #expect(setenv("APKRUN_VIRGL_RUNTIME_PATH", runtime, 1) == 0)
}

// One process admits one virglrenderer instance (graphics.md §5.2), so the tests of this suite run one at a time.
@Suite(
    .serialized,
    .enabled(
        if: MTLCreateSystemDefaultDevice() != nil && builtVirglRuntime != nil,
        "This host needs a Metal device and the built VirGL runtime (ThirdParty/out/virgl-runtime/current)."
    )
)
struct AndroidGraphicsDevicesRendererTests {
    @Test func drmVirglProfileAttachesTheVirglDeviceOfTheDesign() throws {
        try useBuiltVirglRuntime()
        let devices = try AndroidGraphicsDevices.devices(for: .drmVirgl, requiredHostCapabilities: ["virgl", "edid"])
        let device = try #require(devices.first)
        defer { device.deviceWillStop() }
        #expect(devices.count == 1)
        // VIRTIO_GPU_F_VIRGL and VIRTIO_GPU_F_EDID (graphics.md §4.1), and num_capsets = 2 in the last word of the
        // 16-byte configuration space (graphics.md §4.2).
        #expect(device.hostCapabilities == ["edid", "virgl"])
        let configuration = device.descriptor.configurationSpace
        #expect(configuration.count == 16)
        #expect(configuration.subdata(in: 12..<16) == Data([2, 0, 0, 0]))
        #expect(device.statistics.hostReadbacks == 0)
    }

    @Test func aReleasedVirglDeviceLetsTheNextBootStartItsRenderer() throws {
        // A boot that fails after the device is made drops it, and the renderer shuts down with it. The next boot must
        // be able to start a renderer in the same process.
        try useBuiltVirglRuntime()
        _ = try AndroidGraphicsDevices.devices(for: .drmVirgl, requiredHostCapabilities: ["virgl", "edid"])
        let next = try AndroidGraphicsDevices.devices(for: .drmVirgl, requiredHostCapabilities: ["virgl", "edid"])
        #expect(next.count == 1)
        next.first?.deviceWillStop()
    }
}
