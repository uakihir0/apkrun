import Foundation
import RuntimeAPI
import Testing

@testable import apkrun

@Test func configurationCommandsParseListGetSetAndReset() async throws {
    let list = try await APKRunCommand.asyncParseAsRoot(["config", "list", "--json"])
    #expect((list as? ConfigListCommand)?.json == true)

    let get = try await APKRunCommand.asyncParseAsRoot(["config", "get", "runtime.cpuCount"])
    #expect((get as? ConfigGetCommand)?.key == "runtime.cpuCount")

    let set = try await APKRunCommand.asyncParseAsRoot([
        "config", "set", "runtime.cpuCount", "6", "--yes", "--json",
    ])
    #expect((set as? ConfigSetCommand)?.key == "runtime.cpuCount")
    #expect((set as? ConfigSetCommand)?.value == "6")
    #expect((set as? ConfigSetCommand)?.yes == true)
    #expect((set as? ConfigSetCommand)?.json == true)

    let reset = try await APKRunCommand.asyncParseAsRoot(["config", "reset", "runtime.cpuCount"])
    #expect((reset as? ConfigResetCommand)?.key == "runtime.cpuCount")
    #expect((reset as? ConfigResetCommand)?.all == false)

    let resetAll = try await APKRunCommand.asyncParseAsRoot(["config", "reset", "--all", "--yes"])
    #expect((resetAll as? ConfigResetCommand)?.key == nil)
    #expect((resetAll as? ConfigResetCommand)?.all == true)
    #expect((resetAll as? ConfigResetCommand)?.yes == true)
}

@Test func configurationSetParsesPrimitiveValuesAndValidatesEnumsAndRanges() throws {
    #expect(
        try ConfigurationCommandSupport.parse("on", for: entry("audio.output", value: .bool(true)))
            == .bool(true)
    )
    #expect(
        try ConfigurationCommandSupport.parse("off", for: entry("audio.output", value: .bool(true)))
            == .bool(false)
    )
    #expect(
        try ConfigurationCommandSupport.parse("6", for: entry("runtime.cpuCount", value: .integer(4)))
            == .integer(6)
    )
    #expect(
        try ConfigurationCommandSupport.parse(
            "16",
            for: entry("runtime.userdataGiB", value: .null, defaultValue: .null)
        ) == .integer(16)
    )
    #expect(
        try ConfigurationCommandSupport.parse(
            "beta",
            for: entry("maintenance.channel", value: .string("stable"))
        ) == .string("beta")
    )

    #expect(throws: RuntimeWireError.self) {
        try ConfigurationCommandSupport.parse("maybe", for: entry("audio.output", value: .bool(true)))
    }
    #expect(throws: RuntimeWireError.self) {
        try ConfigurationCommandSupport.parse("0", for: entry("display.maxSessions", value: .integer(8)))
    }
    #expect(throws: RuntimeWireError.self) {
        try ConfigurationCommandSupport.parse(
            "preview",
            for: entry("maintenance.channel", value: .string("stable"))
        )
    }
}

@Test func configurationSetConfirmsWritesThatMayReplaceClampedMachineValues() {
    #expect(
        ConfigurationCommandSupport.requiresSetConfirmation(
            entry("runtime.memoryGiB", value: .integer(4), isSet: true),
            value: .integer(4)
        )
    )
    #expect(
        !ConfigurationCommandSupport.requiresSetConfirmation(
            entry("audio.output", value: .bool(true), isSet: true),
            value: .bool(true)
        )
    )
    #expect(
        ConfigurationCommandSupport.requiresSetConfirmation(
            entry("audio.output", value: .bool(true), isSet: false),
            value: .bool(true)
        )
    )
}

@Test func configurationPatchUsesNestedRFC7396ObjectsAndResetAllKeepsSharedRoots() {
    let nested = ConfigurationCommandSupport.nestedPatch(
        for: "graphics.limits.maxContexts",
        value: .integer(128)
    )
    #expect(
        nested
            == .object([
                "graphics": .object([
                    "limits": .object(["maxContexts": .integer(128)])
                ])
            ]))

    let resetAll = ConfigurationCommandSupport.resetAllPatch(
        for: ConfigurationSnapshot(entries: [
            entry("runtime.cpuCount", value: .integer(6), isSet: true),
            entry("runtime.idleStopMinutes", value: .integer(60), isSet: false),
            entry("integrations.enabled.clipboard", value: .bool(false), isSet: true),
            entry("sharedFolders.roots", value: .array([]), isSet: true),
        ])
    )
    #expect(
        resetAll
            == .object([
                "integrations": .object([
                    "enabled": .object(["clipboard": .null])
                ]),
                "runtime": .object(["cpuCount": .null]),
            ]))
}

@Test func configurationResetRequiresOneTargetAndProtectsSharedFolderRoots() throws {
    #expect(
        try ConfigurationCommandSupport.resetTarget(key: "runtime.cpuCount", all: false)
            == .key("runtime.cpuCount")
    )
    #expect(try ConfigurationCommandSupport.resetTarget(key: nil, all: true) == .all)
    #expect(throws: CLIFailure.self) {
        try ConfigurationCommandSupport.resetTarget(key: nil, all: false)
    }
    #expect(throws: CLIFailure.self) {
        try ConfigurationCommandSupport.resetTarget(key: "runtime.cpuCount", all: true)
    }
    #expect(throws: RuntimeWireError.self) {
        try ConfigurationCommandSupport.requireResettable("sharedFolders.roots")
    }
}

@Test func configurationHumanOutputSortsEntriesAndExplainsApplyTiming() throws {
    let snapshot = ConfigurationSnapshot(entries: [
        entry(
            "runtime.cpuCount",
            value: .integer(6),
            defaultValue: .integer(4),
            isSet: true,
            applies: .runtimeRestart
        ),
        entry(
            "maintenance.channel",
            value: .string("stable"),
            defaultValue: .string("stable"),
            isSet: false,
            applies: .live
        ),
    ])

    let listing = ConfigurationCommandOutput.list(snapshot)
    let maintenanceIndex = try #require(listing.range(of: "maintenance.channel"))
    let cpuIndex = try #require(listing.range(of: "runtime.cpuCount"))
    #expect(maintenanceIndex.lowerBound < cpuIndex.lowerBound)
    #expect(listing.contains("KEY"))
    #expect(listing.contains("VALUE"))
    #expect(listing.contains("DEFAULT"))
    #expect(listing.contains("APPLIES"))

    let detail = ConfigurationCommandOutput.detail(snapshot.entries[0])
    #expect(detail.contains("Set: yes"))
    #expect(detail.contains("Applies: runtime restart"))

    let updated = ConfigurationCommandOutput.updated(key: "runtime.cpuCount", in: snapshot)
    #expect(updated.contains("Set runtime.cpuCount to 6."))
    #expect(updated.contains("Applies after restarting Android."))
    #expect(
        ConfigurationCommandOutput.setConfirmation(snapshot.entries[0], value: .integer(8))
            == "Set runtime.cpuCount to 8. Applies after restarting Android."
    )
    #expect(
        ConfigurationCommandOutput.resetConfirmation(snapshot.entries[0])
            == "Reset runtime.cpuCount to 4. Applies after restarting Android."
    )
}

@Test func storedOnlySettingsExplainThatTheyDoNotAffectThisVersion() {
    let setting = entry(
        "runtime.idleSuspendMinutes",
        value: .integer(10),
        isSet: false,
        applies: .storedOnly
    )

    #expect(ConfigurationCommandOutput.detail(setting).contains("Applies: stored only"))
    #expect(
        ConfigurationCommandOutput.setConfirmation(setting, value: .integer(15))
            == "Set runtime.idleSuspendMinutes to 15. Saved, but not applied by this APKRun version."
    )
}

@Test func configurationJSONOutputUsesStableResultEnvelope() throws {
    let snapshot = ConfigurationSnapshot(entries: [
        entry("runtime.cpuCount", value: .integer(4), defaultValue: .integer(4), isSet: false)
    ])
    let rendered = try ConfigurationCommandOutput.json(snapshot)

    #expect(rendered.contains("\"schemaVersion\""))
    #expect(rendered.contains("\"result\""))
    #expect(rendered.contains("\"defaultValue\""))
    #expect(rendered.contains("\"runtime.cpuCount\""))
    #expect(try ConfigurationCommandOutput.json(snapshot) == rendered)
}

private func entry(
    _ key: String,
    value: JSONValue,
    defaultValue: JSONValue? = nil,
    isSet: Bool = false,
    applies: SettingApplies = .live
) -> ConfigurationEntry {
    ConfigurationEntry(
        key: key,
        value: value,
        defaultValue: defaultValue ?? value,
        isSet: isSet,
        applies: applies
    )
}
