import Testing

@testable import GuestProtocol

@Test func versionCompatibilityFollowsTheSupportedMajors() {
    #expect(ProtocolVersion.supportedMajors == 1...1)
    #expect(ProtocolVersion.compatibility(of: ProtocolVersion(major: 1, minor: 0)) == .compatible)
    #expect(ProtocolVersion.compatibility(of: ProtocolVersion(major: 1, minor: 99)) == .compatible)
    #expect(ProtocolVersion.compatibility(of: ProtocolVersion(major: 0, minor: 9)) == .agentOlder)
    #expect(ProtocolVersion.compatibility(of: ProtocolVersion(major: 2, minor: 0)) == .agentNewer)
}

@Test func versionsOrderByMajorThenMinor() {
    let oneZero = ProtocolVersion(major: 1, minor: 0)
    let oneOne = ProtocolVersion(major: 1, minor: 1)
    let twoZero = ProtocolVersion(major: 2, minor: 0)
    #expect(oneZero < oneOne)
    #expect(oneOne < twoZero)
    #expect(ProtocolVersion.host == oneZero)
    #expect(oneOne.description == "1.1")
}

/// The capability strings of guest-protocol.md §5.3, in table order.
private let designCapabilities: Set<String> = [
    "core.v1", "display.v1", "launch.v1", "input.v1", "ime.v1", "packages.v1", "health.v1",
    "system.v1", "clipboard.text.v1", "clipboard.image.v1", "notifications.v1", "url.v1",
    "files.v1", "files.shared.v1", "locale.v1", "audio.v1", "diagnostics.v1", "bulk.v1",
    "store.install.v1", "store.metadata.v1", "store.icon.v1", "store.rollback.v1",
    "store.ownership.v1", "store.constraints.v1",
]

@Test func capabilityConstantsMatchTheDesignTable() {
    let names = Set(GuestCapability.allCases.map(\.rawValue))
    #expect(names == designCapabilities)
    #expect(GuestCapability.allCases.count == designCapabilities.count)
}

@Test func everyCapabilityHasTheAreaFeatureVersionForm() {
    for capability in GuestCapability.allCases {
        #expect(
            capability.rawValue.wholeMatch(of: /[a-z]+(\.[a-z]+)*\.v[0-9]+/) != nil,
            "\(capability.rawValue) is not <area>.<feature>.v<n>")
    }
}

@Test func negotiationEnablesOnlyAdvertisedSupportedCapabilities() {
    let enabled = CapabilityNegotiation.enabled(
        advertised: ["display.v1", "core.v1", "bogus.v9", "core.v1"],
        supported: [.core, .display, .launch])
    #expect(enabled == ["core.v1", "display.v1"])
}

@Test func negotiationOfNothingAdvertisedEnablesNothing() {
    #expect(CapabilityNegotiation.enabled(advertised: []).isEmpty)
}
