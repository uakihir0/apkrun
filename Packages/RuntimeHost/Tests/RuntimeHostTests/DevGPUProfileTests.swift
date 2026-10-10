import Testing

@testable import RuntimeHost

@Test func devGPUProfilesMapToTheBundleProfiles() {
    #expect(DevGPUProfile.none.profile == .headless)
    #expect(DevGPUProfile.swiftshader.profile == .guestSwiftshader)
    #expect(DevGPUProfile.virgl.profile == .drmVirgl)
}

@Test func theGPUProfilesOfTheDevCommandAreSelectableByName() {
    // `virgl` is selectable from #022 on. Any other name is an invalid argument.
    #expect(DevGPUProfile(rawValue: "none") == DevGPUProfile.none)
    #expect(DevGPUProfile(rawValue: "swiftshader") == DevGPUProfile.swiftshader)
    #expect(DevGPUProfile(rawValue: "virgl") == DevGPUProfile.virgl)
    #expect(DevGPUProfile(rawValue: "drmVirgl") == nil)
}

@Test func devBootDefaultsToTheHeadlessProfile() {
    #expect(DevBootOptions().gpu == DevGPUProfile.none)
}
