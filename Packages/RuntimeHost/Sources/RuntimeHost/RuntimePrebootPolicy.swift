import CoreFoundation
import IOKit.ps
import RuntimeCore

enum RuntimePowerSourceState: Equatable {
    case externalPower
    case battery(percentage: Int)
    case unavailable
}

enum RuntimePrebootPolicy {
    static func shouldPreboot(
        settings: RuntimeIdleSettings,
        bootLoopBlocked: Bool,
        powerSource: RuntimePowerSourceState
    ) -> Bool {
        guard settings.startPolicy == .atLogin, !bootLoopBlocked else {
            return false
        }
        if case .battery(let percentage) = powerSource, percentage < 30 {
            return false
        }
        return true
    }

    static func currentPowerSourceState() -> RuntimePowerSourceState {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as? [CFTypeRef] ?? []
        var batteryPercentages: [Int] = []

        for source in sources {
            guard
                let unmanagedDescription = IOPSGetPowerSourceDescription(info, source),
                let description = unmanagedDescription.takeUnretainedValue() as? [String: Any],
                let state = description[kIOPSPowerSourceStateKey as String] as? String
            else {
                continue
            }
            if state == kIOPSACPowerValue as String {
                return .externalPower
            }
            guard state == kIOPSBatteryPowerValue as String,
                let current = description[kIOPSCurrentCapacityKey as String] as? Int,
                let maximum = description[kIOPSMaxCapacityKey as String] as? Int,
                maximum > 0
            else {
                continue
            }
            batteryPercentages.append(max(0, min(100, current * 100 / maximum)))
        }

        guard let percentage = batteryPercentages.min() else {
            return .unavailable
        }
        return .battery(percentage: percentage)
    }
}
