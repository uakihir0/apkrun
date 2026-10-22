import RuntimeCore
import Testing

@testable import RuntimeHost

@Test func runtimePrebootPolicyOnlyStartsAtLoginWhenTheBootLoopGuardAllowsIt() throws {
    let atLogin = try RuntimeIdleSettings(startPolicy: .atLogin)
    let onDemand = try RuntimeIdleSettings()

    #expect(
        RuntimePrebootPolicy.shouldPreboot(
            settings: atLogin,
            bootLoopBlocked: false,
            powerSource: .externalPower
        )
    )
    #expect(
        !RuntimePrebootPolicy.shouldPreboot(
            settings: onDemand,
            bootLoopBlocked: false,
            powerSource: .externalPower
        )
    )
    #expect(
        !RuntimePrebootPolicy.shouldPreboot(
            settings: atLogin,
            bootLoopBlocked: true,
            powerSource: .externalPower
        )
    )
}

@Test func runtimePrebootPolicySkipsLowBatteryButAllowsUnknownPowerState() throws {
    let settings = try RuntimeIdleSettings(startPolicy: .atLogin)

    #expect(
        !RuntimePrebootPolicy.shouldPreboot(
            settings: settings,
            bootLoopBlocked: false,
            powerSource: .battery(percentage: 29)
        )
    )
    #expect(
        RuntimePrebootPolicy.shouldPreboot(
            settings: settings,
            bootLoopBlocked: false,
            powerSource: .battery(percentage: 30)
        )
    )
    #expect(
        RuntimePrebootPolicy.shouldPreboot(
            settings: settings,
            bootLoopBlocked: false,
            powerSource: .unavailable
        )
    )
}
