import Testing

@testable import IntegrationCore

@Suite("AudioPolicy")
struct AudioPolicyTests {
    @Test("Only packages with integrations.microphone=true are allowed")
    func enabledPackagesSelectsOnesWithTrue() {
        let set = AudioPolicy.enabledPackages(
            packageValues: [
                "com.example.on": "true",
                "com.example.off": "false",
                "com.example.unset": nil,
            ],
            globalEnabled: true
        )
        #expect(set == ["com.example.on"])
    }

    @Test("The global switch off empties the set")
    func globalSwitchOffDisablesAll() {
        let set = AudioPolicy.enabledPackages(
            packageValues: ["com.example.on": "true"],
            globalEnabled: false
        )
        #expect(set.isEmpty)
    }

    @Test("An empty set means no input stream is attached")
    func noPackagesMeansNoStream() {
        #expect(AudioPolicy.enabledPackages(packageValues: [:], globalEnabled: true).isEmpty)
    }
}
