import Testing

@testable import RuntimeHost

@Test func devGPUProfilesMapToTheBundleProfiles() {
    #expect(DevGPUProfile.none.profile == .headless)
    #expect(DevGPUProfile.swiftshader.profile == .guestSwiftshader)
}

@Test func onlyTheGPUProfilesOfThisBuildAreSelectable() {
    // `virgl` waits for the VirGL renderer (#022), so `--gpu virgl` is an invalid argument.
    #expect(DevGPUProfile(rawValue: "none") == DevGPUProfile.none)
    #expect(DevGPUProfile(rawValue: "swiftshader") == DevGPUProfile.swiftshader)
    #expect(DevGPUProfile(rawValue: "virgl") == nil)
}

@Test func devBootDefaultsToTheHeadlessProfile() {
    #expect(DevBootOptions().gpu == DevGPUProfile.none)
}
