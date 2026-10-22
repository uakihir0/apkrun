import Foundation
import Testing

@testable import RuntimeAPI

private func roundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(Value.self, from: data)
}

@Test func jsonValueEncodesAndDecodesNestedJSON() throws {
    let decimalOne = try #require(Decimal(string: "1.0"))
    let value: JSONValue = .object([
        "enabled": .bool(false),
        "limits": .array([.integer(1), .number(1.25), .null]),
        "label": .string("beta"),
        "nested": .object(["nullable": .null]),
    ])

    #expect(try roundTrip(value) == value)
    #expect(try roundTrip(JSONValue.null) == .null)
    #expect(try roundTrip(JSONValue.integer(Int64.max)) == .integer(Int64.max))
    #expect(try roundTrip(JSONValue.number(decimalOne)) == .number(1.0))

    let decodedFutureApplies = try JSONDecoder().decode(
        SettingApplies.self,
        from: Data(#""afterTheNextGalaxy""#.utf8)
    )
    #expect(decodedFutureApplies == .unknown)
}

@Test func configurationDTOsRoundTrip() throws {
    let entry = ConfigurationEntry(
        key: "runtime.memoryGiB",
        value: .integer(6),
        defaultValue: .integer(4),
        isSet: true,
        applies: .runtimeRestart
    )
    let snapshot = ConfigurationSnapshot(entries: [entry])
    let header = APIRequestHeader(clientKind: .cli)
    let getRequest = RuntimeConfigurationControlRequest(header: header)
    let updateRequest = RuntimeUpdateConfigurationControlRequest(
        header: header,
        patch: ConfigurationPatch(patch: .object(["runtime": .object(["memoryGiB": .integer(6)])]))
    )
    let getReply = RuntimeConfigurationControlReply(result: snapshot)
    let updateReply = RuntimeUpdateConfigurationControlReply(result: snapshot)

    #expect(try roundTrip(entry) == entry)
    #expect(try roundTrip(snapshot) == snapshot)
    #expect(try roundTrip(getRequest) == getRequest)
    #expect(try roundTrip(updateRequest) == updateRequest)
    #expect(try roundTrip(getReply) == getReply)
    #expect(try roundTrip(updateReply) == updateReply)

    let failure = RuntimeWireError.runtime(
        "malformedRequest",
        message: "The configuration patch is invalid.",
        remediation: "Use a valid settings key and value."
    )
    #expect(try roundTrip(RuntimeConfigurationControlReply(error: failure)).error == failure)
    #expect(try roundTrip(RuntimeUpdateConfigurationControlReply(error: failure)).error == failure)
}

@Test func configurationPatchKeepsNestedMergePatchShapeAndNullResets() throws {
    let patch = ConfigurationPatch(
        patch: .object([
            "runtime": .object([
                "idleSuspendMinutes": .integer(0),
                "memoryGiB": .null,
            ]),
            "maintenance": .object(["channel": .string("beta")]),
        ])
    )
    let encoded = try JSONEncoder().encode(patch)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let patchObject = try #require(object["patch"] as? [String: Any])
    let runtime = try #require(patchObject["runtime"] as? [String: Any])
    let maintenance = try #require(patchObject["maintenance"] as? [String: Any])

    #expect(runtime["idleSuspendMinutes"] as? Int == 0)
    #expect(runtime["memoryGiB"] is NSNull)
    #expect(maintenance["channel"] as? String == "beta")
    #expect(try JSONDecoder().decode(ConfigurationPatch.self, from: encoded) == patch)
}
