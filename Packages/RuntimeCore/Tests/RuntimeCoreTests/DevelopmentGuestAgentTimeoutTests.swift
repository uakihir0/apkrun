import Testing

@testable import RuntimeCore

@Test func requiredGuestAgentConnectTimeoutMatchesRuntimeDesign() {
    #expect(DevelopmentGuestAgent.defaultConnectTimeout == .seconds(30))
}
