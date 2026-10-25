import Foundation
import Testing
@testable import RuntimeAPI

@Test func integrationStatusRoundTripsSettingAndPolicyMetadata() throws {
    let packageID = try #require(RuntimePackageID(rawValue: "com.example.app"))
    let status = IntegrationStatus(
        packageID: packageID,
        items: [
            IntegrationItemStatus(
                kind: .links,
                value: .string("ask"),
                source: .recommended,
                decision: .deny(.notSupported(capability: "url.v1")),
                support: .unsupported(capability: "url.v1"),
                macPermission: .unknown
            ),
            IntegrationItemStatus(
                kind: .sharedFolders,
                value: .string("readOnly"),
                source: .user,
                decision: .allow,
                support: .supported
            ),
        ],
        microphoneNeedsRestart: true
    )

    let encoded = try JSONEncoder().encode(status)
    #expect(try JSONDecoder().decode(IntegrationStatus.self, from: encoded) == status)
}

@Test func integrationDecisionUnknownKindIsForwardCompatible() throws {
    let value = try JSONDecoder().decode(
        WireIntegrationDecision.self,
        from: Data(#"{"kind":"futureDecision"}"#.utf8)
    )
    #expect(value == .unknown)
}

@Test func jsonValuePreservesNestedSettings() throws {
    let value: JSONValue = .object([
        "enabled": .bool(true),
        "rules": .array([.string("readOnly"), .null]),
        "priority": .number(2),
    ])
    let encoded = try JSONEncoder().encode(value)
    #expect(try JSONDecoder().decode(JSONValue.self, from: encoded) == value)
}
