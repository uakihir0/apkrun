import Foundation
import ImageCore
import RuntimeAPI
import RuntimeCore
import Testing

@testable import RuntimeHost

@Test
func configuredInstanceSizingUsesCurrentRuntimeSettingsOnBoot() {
    let snapshot = ConfigurationSnapshot(entries: [
        ConfigurationEntry(
            key: "runtime.cpuCount",
            value: .integer(6),
            defaultValue: .integer(4),
            isSet: true,
            applies: .runtimeRestart
        ),
        ConfigurationEntry(
            key: "runtime.memoryGiB",
            value: .integer(8),
            defaultValue: .integer(4),
            isSet: true,
            applies: .runtimeRestart
        ),
        ConfigurationEntry(
            key: "runtime.userdataGiB",
            value: .integer(48),
            defaultValue: .integer(32),
            isSet: true,
            applies: .provisioning
        ),
    ])

    #expect(
        RuntimeHost.instanceSizing(from: snapshot)
            == .some(
                InstanceSizing(
                    cpuCount: 6,
                    memoryBytes: 8 * 1_073_741_824,
                    userdataBytes: 48 * 1_073_741_824
                )
            )
    )
}

@Test
func configuredInstanceSizingPreservesUserdataForAnExistingInstance() {
    let snapshot = ConfigurationSnapshot(entries: [
        ConfigurationEntry(
            key: "runtime.cpuCount",
            value: .integer(6),
            defaultValue: .integer(4),
            isSet: true,
            applies: .runtimeRestart
        ),
        ConfigurationEntry(
            key: "runtime.memoryGiB",
            value: .integer(8),
            defaultValue: .integer(4),
            isSet: true,
            applies: .runtimeRestart
        ),
        ConfigurationEntry(
            key: "runtime.userdataGiB",
            value: .integer(48),
            defaultValue: .integer(32),
            isSet: true,
            applies: .provisioning
        ),
    ])

    #expect(
        RuntimeHost.instanceSizing(from: snapshot, preservingUserdataBytes: 32 * 1_073_741_824)
            == .some(
                InstanceSizing(
                    cpuCount: 6,
                    memoryBytes: 8 * 1_073_741_824,
                    userdataBytes: 32 * 1_073_741_824
                )
            )
    )
}

@Test
func configuredInstanceSizingRejectsUnavailableUserdataForNewInstances() throws {
    let snapshot = ConfigurationSnapshot(entries: [
        ConfigurationEntry(
            key: "runtime.cpuCount",
            value: .integer(4),
            defaultValue: .integer(4),
            isSet: false,
            applies: .runtimeRestart
        ),
        ConfigurationEntry(
            key: "runtime.memoryGiB",
            value: .integer(4),
            defaultValue: .integer(4),
            isSet: false,
            applies: .runtimeRestart
        ),
        ConfigurationEntry(
            key: "runtime.userdataGiB",
            value: .null,
            defaultValue: .null,
            isSet: false,
            applies: .provisioning
        ),
    ])

    #expect(RuntimeHost.instanceSizing(from: snapshot) == nil)
    #expect(
        RuntimeHost.instanceSizing(from: snapshot, preservingUserdataBytes: 32 * 1_073_741_824)
            == .some(InstanceSizing.default)
    )
    #expect(throws: ImageFailure.self) {
        try RuntimeHost.provisioningSizing(
            from: snapshot,
            settingsFile: FileManager.default.temporaryDirectory.appendingPathComponent("settings.json")
        )
    }
}

@Test
func runtimeExecutionSettingsApplyConfiguredBootTimeoutsAndDisplayLimit() {
    let snapshot = ConfigurationSnapshot(entries: [
        ConfigurationEntry(
            key: "runtime.bootTimeoutSeconds",
            value: .integer(240),
            defaultValue: .integer(180),
            isSet: true,
            applies: .nextBoot
        ),
        ConfigurationEntry(
            key: "runtime.firstBootTimeoutSeconds",
            value: .integer(1200),
            defaultValue: .integer(900),
            isSet: true,
            applies: .nextBoot
        ),
        ConfigurationEntry(
            key: "display.maxSessions",
            value: .integer(12),
            defaultValue: .integer(8),
            isSet: true,
            applies: .live
        ),
    ])

    #expect(
        RuntimeExecutionSettings(snapshot: snapshot)
            == RuntimeExecutionSettings(
                bootTimeouts: BootTimeouts(
                    whole: .seconds(240),
                    firstBoot: .seconds(1200),
                    stall: .seconds(90),
                    firstBootStall: .seconds(600)
                ),
                maxDisplaySessions: 12
            )
    )
}

@Test
func runtimeExecutionSettingsUseDocumentedDefaultsWhenValuesAreAbsent() {
    let settings = RuntimeExecutionSettings(snapshot: ConfigurationSnapshot(entries: []))

    #expect(settings == .default)
}
