import Testing

@testable import RuntimeHost

@Test func devGPUProfilesMapToTheBundleProfiles() {
    #expect(DevGPUProfile.none.profile == .headless)
    #expect(DevGPUProfile.swiftshader.profile == .guestSwiftshader)
    #expect(DevGPUProfile.virgl.profile == .drmVirgl)
}

@Test func theGPUProfilesOfTheDevCommandAreSelectableByName() {
    // `virgl` is selectable from #23 on. Any other name is an invalid argument.
    #expect(DevGPUProfile(rawValue: "none") == DevGPUProfile.none)
    #expect(DevGPUProfile(rawValue: "swiftshader") == DevGPUProfile.swiftshader)
    #expect(DevGPUProfile(rawValue: "virgl") == DevGPUProfile.virgl)
    #expect(DevGPUProfile(rawValue: "drmVirgl") == nil)
}

@Test func devBootDefaultsToTheHeadlessProfile() {
    #expect(DevBootOptions().gpu == DevGPUProfile.none)
}

@Test func devBootUsesTheProductADBPortByDefaultAndSupportsAnOverride() {
    #expect(DevBootOptions.defaultADBHostPort == 6520)
    #expect(DevBootOptions().adbHostPort == DevBootOptions.defaultADBHostPort)
    #expect(DevBootOptions(adbHostPort: 49_321).adbHostPort == 49_321)
}
