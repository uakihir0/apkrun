import DiagnosticsCore
import Foundation
import Virtualization

/// Registers the health checks owned by VirtualMachineCore.
public enum VMHealthChecks {
    /// Adds virtualization capability and controller-state checks to a registry.
    public static func register(
        in registry: HealthCheckRegistry,
        controller: VMController,
        virtualizationSupported: @escaping @Sendable () -> Bool = {
            VZVirtualMachine.isSupported
        }
    ) async throws {
        try await registry.register(
            VirtualizationSupportedHealthCheck(isSupported: virtualizationSupported)
        )
        try await registry.register(
            VMStateHealthCheck(state: { await controller.state })
        )
    }
}

private struct VirtualizationSupportedHealthCheck: HealthCheck {
    let isSupported: @Sendable () -> Bool

    var id: HealthCheckID { "vm.virtualizationSupported" }
    var group: HealthGroup { .virtualization }
    var requirement: HealthRequirement { .host }
    var cost: HealthCost { .quick }
    var title: LocalizedText {
        LocalizedText(key: id, fallback: "Virtualization support")
    }

    func run(_ context: HealthContext) async -> HealthResult {
        let supported = isSupported()
        let failure = VMFailure.virtualizationUnavailable
        return HealthResult(
            id: id,
            group: group,
            state: supported ? .pass : .failure,
            title: title,
            detail: supported
                ? "Virtualization.framework is supported."
                : "Virtualization.framework is not supported on this Mac.",
            error: supported ? nil : errorInfo(for: failure),
            measuredAt: context.clock.now
        )
    }
}

private struct VMStateHealthCheck: HealthCheck {
    let state: @Sendable () async -> VMState

    var id: HealthCheckID { "vm.state" }
    var group: HealthGroup { .virtualization }
    var requirement: HealthRequirement { .daemon }
    var cost: HealthCost { .quick }
    var title: LocalizedText {
        LocalizedText(key: id, fallback: "Virtual machine state")
    }

    func run(_ context: HealthContext) async -> HealthResult {
        let currentState = await state()
        guard case .failed(let failure) = currentState else {
            return HealthResult(
                id: id,
                group: group,
                state: .pass,
                title: title,
                detail: "The virtual machine is \(currentState.healthLabel).",
                measuredAt: context.clock.now
            )
        }

        return HealthResult(
            id: id,
            group: group,
            state: .failure,
            title: title,
            detail: "The virtual machine failed.",
            error: errorInfo(for: failure),
            measuredAt: context.clock.now
        )
    }
}

extension VMState {
    fileprivate var healthLabel: String {
        switch self {
        case .stopped: "stopped"
        case .starting: "starting"
        case .running: "running"
        case .paused: "paused"
        case .stopping: "stopping"
        case .failed: "failed"
        }
    }
}

private func errorInfo(for error: any APKRunError) -> ErrorInfo {
    let code = error.qualifiedCode
    let entry = ErrorCatalog.entry(for: code) ?? ErrorCatalog.unknownEntry
    let message = LocalizedText(
        key: code,
        parameters: error.parameters,
        fallback: entry.message?["en"] ?? ErrorCatalog.unknownEntry.message?["en"]
            ?? "APKRun couldn't complete the operation."
    )
    let remediation = entry.remediation?["en"].map {
        LocalizedText(key: "\(code).remediation", fallback: $0)
    }
    return ErrorInfo(
        code: code,
        message: message,
        remediation: remediation,
        action: entry.action
    )
}
