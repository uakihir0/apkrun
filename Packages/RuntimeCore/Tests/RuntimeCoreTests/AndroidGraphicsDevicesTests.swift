import GraphicsCore
import Testing

@testable import RuntimeCore

@Test func headlessProfileAttachesNoGraphicsDevice() throws {
    // VZ's own 2D device is the DRM device of the headless profile (graphics.md §9).
    #expect(try AndroidGraphicsDevices.devices(for: .headless, requiredHostCapabilities: []).isEmpty)
}

@Test func guestSwiftshaderProfileAttachesOneVirtioGPUDevice() throws {
    let devices = try AndroidGraphicsDevices.devices(for: .guestSwiftshader, requiredHostCapabilities: ["edid"])
    #expect(devices.count == 1)
    #expect(devices.first?.hostCapabilities == ["edid"])
}

@Test func drmVirglProfileStartsNoRendererWhenTheBundleDoesNotListIt() {
    var starts = 0
    do {
        _ = try AndroidGraphicsDevices.devices(for: .drmVirgl, requiredHostCapabilities: nil) {
            () throws(GraphicsFailure) -> VirtioGPUDevice in
            starts += 1
            return VirtioGPUDevice()
        }
        Issue.record("A profile that the bundle does not list cannot be booted.")
    } catch {
        #expect(error == .gpuProfileUnavailable(profile: "drmVirgl"))
    }
    #expect(starts == 0, "An unlisted profile must not start a renderer.")
}

@Test func drmVirglRendererFailureEndsTheBootAsAGraphicsFailure() {
    let failure = GraphicsFailure.rendererInitFailed(stage: .virgl, detail: "test renderer")
    do {
        _ = try AndroidGraphicsDevices.devices(for: .drmVirgl, requiredHostCapabilities: ["virgl", "edid"]) {
            () throws(GraphicsFailure) -> VirtioGPUDevice in
            throw failure
        }
        Issue.record("A renderer that fails to start must end the boot.")
    } catch {
        #expect(error == .graphics(failure))
    }
}

@Test func drmVirglRefusesADeviceThatLacksAFeatureTheBundleRequires() {
    // An EDID-only device stands in for a renderer whose device did not offer VIRTIO_GPU_F_VIRGL.
    do {
        _ = try AndroidGraphicsDevices.devices(for: .drmVirgl, requiredHostCapabilities: ["virgl", "edid"]) {
            () throws(GraphicsFailure) -> VirtioGPUDevice in
            VirtioGPUDevice()
        }
        Issue.record("drmVirgl needs VIRTIO_GPU_F_VIRGL, and the device must offer it.")
    } catch {
        #expect(error == .gpuProfileUnavailable(profile: "drmVirgl"))
    }
}

@Test func guestSwiftshaderIsRefusedForAFeatureItsDeviceDoesNotOffer() {
    // The two-dimensional device has no renderer, so a bundle that requires VIRGL for it is refused.
    do {
        _ = try AndroidGraphicsDevices.devices(for: .guestSwiftshader, requiredHostCapabilities: ["virgl"])
        Issue.record("The two-dimensional device does not offer VIRTIO_GPU_F_VIRGL.")
    } catch {
        #expect(error == .gpuProfileUnavailable(profile: "guestSwiftshader"))
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
