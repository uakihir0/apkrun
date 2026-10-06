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
        try await registry.register(
            VMNetworkHealthCheck(
                hasNetworkAttachment: { await controller.hasNetworkAttachment },
                attachmentError: { await controller.networkAttachmentError }
            )
        )
        try await registry.register(
            VMConsoleWriterHealthCheck(hasFailed: {
                await controller.consoleLogWriterHasFailed()
            })
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

private struct VMNetworkHealthCheck: HealthCheck {
    let hasNetworkAttachment: @Sendable () async -> Bool
    let attachmentError: @Sendable () async -> VZErrorInfo?

    var id: HealthCheckID { "vm.network" }
    var group: HealthGroup { .virtualization }
    var requirement: HealthRequirement { .runningRuntime }
    var cost: HealthCost { .quick }
    var title: LocalizedText {
        LocalizedText(key: id, fallback: "VM network")
    }

    func run(_ context: HealthContext) async -> HealthResult {
        guard await hasNetworkAttachment() else {
            return HealthResult(
                id: id,
                group: group,
                state: .pass,
                title: title,
                detail: "No VM network attachment is configured.",
                measuredAt: context.clock.now
            )
        }

        guard let error = await attachmentError() else {
            return HealthResult(
                id: id,
                group: group,
                state: .pass,
                title: title,
                detail: "The VM network attachment is connected.",
                measuredAt: context.clock.now
            )
        }

        let failure = VMFailure.networkAttachmentLost
        return HealthResult(
            id: id,
            group: group,
            state: .warning,
            title: title,
            detail: "The VM network attachment disconnected "
                + "(VZ domain \(error.domain), code \(error.code)).",
            error: errorInfo(for: failure),
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

private struct VMConsoleWriterHealthCheck: HealthCheck {
    let hasFailed: @Sendable () async -> Bool

    var id: HealthCheckID { "vm.consoleWriter" }
    var group: HealthGroup { .virtualization }
    var requirement: HealthRequirement { .daemon }
    var cost: HealthCost { .quick }
    var title: LocalizedText {
        LocalizedText(key: id, fallback: "VM console log")
    }

    func run(_ context: HealthContext) async -> HealthResult {
        let failed = await hasFailed()
        let failure = VMFailure.consoleLogWriteFailed
        return HealthResult(
            id: id,
            group: group,
            state: failed ? .warning : .pass,
            title: title,
            detail: failed
                ? "The guest console log could not be fully saved."
                : "The guest console log writer is available.",
            error: failed ? errorInfo(for: failure) : nil,
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
