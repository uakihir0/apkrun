import Testing

@testable import RuntimeCore

@Test func headlessProfileAttachesNoGraphicsDevice() throws {
    // VZ's own 2D device is the DRM device of the headless profile (graphics.md §9).
    #expect(try AndroidGraphicsDevices.devices(for: .headless, requiredHostCapabilities: []).isEmpty)
}

@Test func guestSwiftshaderProfileAttachesOneVirtioGPUDevice() throws {
    let devices = try AndroidGraphicsDevices.devices(for: .guestSwiftshader, requiredHostCapabilities: ["edid"])
    #expect(devices.count == 1)
}

@Test func drmVirglProfileIsRefusedWhileTheDeviceLacksVirgl() {
    do {
        _ = try AndroidGraphicsDevices.devices(for: .drmVirgl, requiredHostCapabilities: ["virgl", "edid"])
        Issue.record("drmVirgl needs VIRTIO_GPU_F_VIRGL, which the device does not offer before #022.")
    } catch {
        #expect(error == .gpuProfileUnavailable(profile: "drmVirgl"))
    }
}

@Test func aProfileTheBundleDoesNotListIsRefused() {
    do {
        _ = try AndroidGraphicsDevices.devices(for: .guestSwiftshader, requiredHostCapabilities: nil)
        Issue.record("A profile that the bundle does not list cannot be booted.")
    } catch {
        #expect(error == .gpuProfileUnavailable(profile: "guestSwiftshader"))
    }
}
