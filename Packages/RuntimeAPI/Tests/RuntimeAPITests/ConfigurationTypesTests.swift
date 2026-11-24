import Foundation
import Testing

@testable import RuntimeAPI

@Test func jsonValueRoundTripsNestedConfigurationValues() throws {
    let value: JSONValue = .object([
        "system": .object([
            "syncLocale": .bool(false),
            "syncTimeZone": .bool(true),
            "syncClockFormat": .bool(false),
        ]),
        "runtime": .object([
            "memoryGiB": .number(4),
            "label": .string("Android"),
            "values": .array([.null, .bool(true), .number(1.5), .string("x")]),
        ]),
    ])

    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

    #expect(decoded == value)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let system = try #require(object["system"] as? [String: Any])
    #expect(system["syncLocale"] as? Bool == false)
    #expect(system["syncTimeZone"] as? Bool == true)
}

@Test func configurationRequestsAndRepliesRoundTrip() throws {
    let header = APIRequestHeader(clientKind: .app)
    let patch = ConfigurationPatch(
        patch: .object([
            "system": .object([
                "syncLocale": .bool(false),
                "syncTimeZone": .null,
            ])
        ])
    )
    let update = RuntimeUpdateConfigurationControlRequest(header: header, patch: patch)
    let updateData = try JSONEncoder().encode(update)
    #expect(try JSONDecoder().decode(RuntimeUpdateConfigurationControlRequest.self, from: updateData) == update)

    let request = RuntimeConfigurationControlRequest(header: header)
    let requestData = try JSONEncoder().encode(request)
    #expect(try JSONDecoder().decode(RuntimeConfigurationControlRequest.self, from: requestData) == request)

    let snapshot = ConfigurationSnapshot(entries: [
        ConfigurationEntry(
            key: "system.syncLocale",
            value: .bool(false),
            defaultValue: .bool(true),
            isSet: true,
            applies: .live
        )
    ])
    let success = RuntimeUpdateConfigurationControlReply(result: snapshot)
    let successData = try JSONEncoder().encode(success)
    #expect(try JSONDecoder().decode(RuntimeUpdateConfigurationControlReply.self, from: successData) == success)

    let failure = RuntimeConfigurationControlReply(
        error: .runtime(
            "invalidSettingValue",
            message: "The value is invalid."
        ))
    let failureData = try JSONEncoder().encode(failure)
    #expect(try JSONDecoder().decode(RuntimeConfigurationControlReply.self, from: failureData) == failure)
}

@Test func unknownSettingAppliesValueDecodesToUnknown() throws {
    #expect(
        try JSONDecoder().decode(SettingApplies.self, from: Data(#""futureSettingLifecycle""#.utf8)) == .unknown
    )
}
