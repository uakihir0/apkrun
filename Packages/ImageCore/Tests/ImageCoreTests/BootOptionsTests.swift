import ImageCore
import Testing

/// The developer ADB port of a boot (test-strategy §3.10). The product default is unchanged, and a test run
/// may give its own port (`0` asks the kernel for one).
@Test func bootOptionsUseTheProductADBPortByDefault() {
    #expect(BootOptions.defaultADBHostPort == 6520)
    #expect(BootOptions().adbHostPort == 6520)
    #expect(BootOptions(developerMode: true).adbHostPort == 6520)
}

@Test func bootOptionsCarryAnExplicitADBPort() {
    #expect(BootOptions(adbHostPort: 0).adbHostPort == 0)
    #expect(BootOptions(developerMode: true, adbHostPort: 49_321).adbHostPort == 49_321)
    #expect(BootOptions(adbHostPort: 6520) == BootOptions())
    #expect(BootOptions(adbHostPort: 49_321) != BootOptions())
}
