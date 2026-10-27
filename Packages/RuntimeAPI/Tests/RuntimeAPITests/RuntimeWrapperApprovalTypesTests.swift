import Foundation
import Testing

@testable import RuntimeAPI

private func wrapperApprovalRoundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(Value.self, from: data)
}

@Test func wrapperApprovalDTOsRoundTrip() throws {
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let signer = try #require(
        RuntimeWrapperSignerSummary(kind: .developerID, teamIdentifier: "ABCDE12345", notarized: true)
    )
    let teamSignedSigner = try #require(
        RuntimeWrapperSignerSummary(kind: .teamSigned, teamIdentifier: "ABCDE12345")
    )
    let futureSigner = try #require(
        RuntimeWrapperSignerSummary(
            kind: .unknown("futureCertificateClass"),
            teamIdentifier: "ABCDE12345",
            notarized: true
        )
    )
    let integrations = RuntimeWrapperIntegrationSummary(
        clipboard: true,
        notifications: false,
        links: true,
        files: false,
        sharedFolders: false,
        microphone: false
    )
    let approvalID = try #require(ApprovalID(wire: "3dfd9e1b-cc61-4e96-bcba-76f355b68c51"))
    let prompt = try #require(
        RuntimeWrapperApprovalPrompt(
            approvalID: approvalID,
            bundlePath: "/Applications/Hello Text.app",
            bundleID: "io.apkrun.android.io.apkrun.fixture.hellotext",
            packageID: packageID,
            displayName: "Hello Text",
            signer: signer,
            packageInstalled: true,
            installedVersion: "2.3 (203)",
            bundledVersion: "1.2.3",
            integrations: integrations,
            replacingBundlePath: "/Users/me/Applications/Hello Text.app"
        )
    )
    let brokerRequest = try #require(
        RuntimeWrapperApprovalBrokerRequest(
            bundlePath: "/Applications/Hello Text.app",
            bundleID: prompt.bundleID,
            packageID: packageID
        )
    )
    let decision = RuntimeWrapperApprovalDecisionControlRequest(
        header: APIRequestHeader(clientKind: .app),
        approvalID: prompt.approvalID,
        allow: true
    )
    let brokerReply = RuntimeWrapperApprovalBrokerReply(result: .approved)
    let decisionReply = RuntimeWrapperApprovalDecisionControlReply()

    #expect(try wrapperApprovalRoundTrip(brokerRequest) == brokerRequest)
    #expect(try wrapperApprovalRoundTrip(approvalID) == approvalID)
    #expect(try wrapperApprovalRoundTrip(signer) == signer)
    #expect(try wrapperApprovalRoundTrip(teamSignedSigner) == teamSignedSigner)
    #expect(try wrapperApprovalRoundTrip(futureSigner) == futureSigner)
    #expect(try wrapperApprovalRoundTrip(integrations) == integrations)
    #expect(try wrapperApprovalRoundTrip(prompt) == prompt)
    #expect(prompt.installedVersion == "2.3 (203)")
    #expect(try wrapperApprovalRoundTrip(decision) == decision)
    #expect(try wrapperApprovalRoundTrip(brokerReply) == brokerReply)
    #expect(try wrapperApprovalRoundTrip(decisionReply) == decisionReply)

    let rejected = RuntimeWrapperApprovalBrokerReply(
        error: RuntimeWireError(domain: "wrapper", code: "bundleInvalid", message: "The wrapper is invalid.")
    )
    #expect(try wrapperApprovalRoundTrip(rejected) == rejected)
}

@Test func wrapperApprovalEventsRoundTripAndPreserveUnknownKinds() throws {
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let signer = try #require(RuntimeWrapperSignerSummary(kind: .adHoc))
    let approvalID = try #require(ApprovalID(wire: "a9d8b3e1-a8aa-42d2-b690-d8e47a09484b"))
    let prompt = try #require(
        RuntimeWrapperApprovalPrompt(
            approvalID: approvalID,
            bundlePath: "/Applications/Hello Text.app",
            bundleID: "io.apkrun.android.io.apkrun.fixture.hellotext",
            packageID: packageID,
            displayName: "Hello Text",
            signer: signer,
            packageInstalled: false,
            integrations: RuntimeWrapperIntegrationSummary(
                clipboard: false,
                notifications: false,
                links: false,
                files: false,
                sharedFolders: false,
                microphone: false
            )
        )
    )
    let requested = WrapperChange.approvalRequested(prompt)
    let resolved = WrapperChange.approvalResolved(prompt.approvalID)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let envelopes = [
        EventEnvelope(topic: .wrappers, seq: 1, time: now, payload: .wrappers(requested)),
        EventEnvelope(topic: .wrappers, seq: 2, time: now, payload: .wrappers(resolved)),
    ]

    #expect(try wrapperApprovalRoundTrip(requested) == requested)
    #expect(try wrapperApprovalRoundTrip(resolved) == resolved)
    #expect(try envelopes.map(wrapperApprovalRoundTrip) == envelopes)

    let futureEvent = Data(#"{"approvalRevoked":{"_0":"3dfd9e1b-cc61-4e96-bcba-76f355b68c51"}}"#.utf8)
    #expect(try JSONDecoder().decode(WrapperChange.self, from: futureEvent) == .unknown)
    #expect(
        try JSONDecoder().decode(RuntimeWrapperApprovalOutcome.self, from: Data(#""futureOutcome""#.utf8)) == .unknown)
    #expect(throws: EncodingError.self) {
        try JSONEncoder().encode(RuntimeWrapperApprovalOutcome.unknown)
    }
    #expect(
        try JSONDecoder().decode(
            EventPayload.self,
            from: Data(#"{"wrappers":{"_0":{"approvalRevoked":{"_0":"3dfd9e1b-cc61-4e96-bcba-76f355b68c51"}}}}"#.utf8)
        ) == .wrappers(.unknown)
    )
}

@Test func wrapperApprovalDTOsRejectMalformedAndOversizedInputs() throws {
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    #expect(
        RuntimeWrapperApprovalBrokerRequest(
            bundlePath: "relative/Hello.app",
            bundleID: "io.apkrun.android.fixture",
            packageID: packageID
        ) == nil
    )
    #expect(
        RuntimeWrapperApprovalBrokerRequest(
            bundlePath: "/Applications/Hello.app",
            bundleID: "io.apkrun.android.fixture_",
            packageID: packageID
        ) == nil
    )
    #expect(
        RuntimeWrapperApprovalBrokerRequest(
            bundlePath: "/" + String(repeating: "a", count: 4_096),
            bundleID: "io.apkrun.android.fixture",
            packageID: packageID
        ) == nil
    )
    #expect(RuntimeWrapperSignerSummary(kind: .developerID, teamIdentifier: "lowercase", notarized: true) == nil)
    #expect(RuntimeWrapperSignerSummary(kind: .developerID, teamIdentifier: "SHORT", notarized: nil) == nil)
    #expect(RuntimeWrapperSignerSummary(kind: .developerID, teamIdentifier: "ABCDE12345", notarized: nil) == nil)
    #expect(RuntimeWrapperSignerSummary(kind: .teamSigned, teamIdentifier: "ABCDE12345") != nil)
    #expect(RuntimeWrapperSignerSummary(kind: .teamSigned, teamIdentifier: "ABCDE12345", notarized: false) == nil)
    #expect(RuntimeWrapperSignerSummary(kind: .unknown("futureCertificateClass")) != nil)
    #expect(RuntimeWrapperSignerSummary(kind: .unknown("futureCertificateClass"), teamIdentifier: "invalid") == nil)
    #expect(RuntimeWrapperSignerSummary(kind: .adHoc, teamIdentifier: "ABCDE12345") == nil)
    #expect(
        RuntimeWrapperApprovalPrompt(
            approvalID: ApprovalID(),
            bundlePath: "/Applications/Hello.app",
            bundleID: "io.apkrun.android.fixture",
            packageID: packageID,
            displayName: "   ",
            signer: try #require(RuntimeWrapperSignerSummary(kind: .adHoc)),
            packageInstalled: false,
            integrations: RuntimeWrapperIntegrationSummary(
                clipboard: false,
                notifications: false,
                links: false,
                files: false,
                sharedFolders: false,
                microphone: false
            )
        ) == nil
    )

    let invalidRequest = Data(
        #"{"bundlePath":"relative/Hello.app","bundleID":"io.apkrun.android.fixture","packageID":"io.apkrun.fixture.hellotext"}"#
            .utf8
    )
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(RuntimeWrapperApprovalBrokerRequest.self, from: invalidRequest)
    }
    let invalidSigner = Data(#"{"kind":"adHoc","teamIdentifier":"ABCDE12345"}"#.utf8)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(RuntimeWrapperSignerSummary.self, from: invalidSigner)
    }
}
