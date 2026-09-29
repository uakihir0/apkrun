import Foundation

/// The host health checks owned by DiagnosticsCore.
public enum HostChecks {
    /// The check set required by diagnostics.md §7.3.
    public static let all: [any HealthCheck] = [
        HostHealthCheck(kind: .appleSilicon),
        HostHealthCheck(kind: .macOSVersion),
        HostHealthCheck(kind: .hypervisor),
        HostHealthCheck(kind: .appLocation),
        HostHealthCheck(kind: .appSignature),
        HostHealthCheck(kind: .componentVersions),
        HostHealthCheck(kind: .dataVolume),
        HostHealthCheck(kind: .memory),
        HostHealthCheck(kind: .runtimeRegistration),
    ]

    /// Registers every host check with a process-local registry.
    public static func register(in registry: HealthCheckRegistry) async throws {
        for check in all {
            try await registry.register(check)
        }
    }
}

private struct HostHealthCheck: HealthCheck {
    enum Kind: String, Sendable {
        case appleSilicon
        case macOSVersion
        case hypervisor
        case appLocation
        case appSignature
        case componentVersions
        case dataVolume
        case memory
        case runtimeRegistration
    }

    let kind: Kind

    var id: HealthCheckID {
        switch kind {
        case .runtimeRegistration:
            "apkrund.registration"
        default:
            "host.\(kind.rawValue)"
        }
    }

    var group: HealthGroup {
        kind == .runtimeRegistration ? .backgroundService
            : kind == .hypervisor ? .virtualization
            : .host
    }

    var requirement: HealthRequirement { .host }
    var cost: HealthCost { kind == .appSignature ? .deep : .quick }

    var title: LocalizedText {
        let fallback: String
        switch kind {
        case .appleSilicon: fallback = "Apple silicon"
        case .macOSVersion: fallback = "macOS version"
        case .hypervisor: fallback = "Virtualization"
        case .appLocation: fallback = "APKRun is in Applications"
        case .appSignature: fallback = "APKRun signature"
        case .componentVersions: fallback = "APKRun component versions"
        case .dataVolume: fallback = "APKRun data volume"
        case .memory: fallback = "Memory"
        case .runtimeRegistration: fallback = "Background service registration"
        }
        return LocalizedText(key: id, fallback: fallback)
    }

    func run(_ context: HealthContext) async -> HealthResult {
        switch kind {
        case .appleSilicon:
            return await booleanResult(
                context,
                probe: { await $0.supportsAppleSilicon() },
                detail: "Apple silicon is available.",
                error: hostRequirementError(
                    item: "appleSilicon",
                    remediation: "APKRun needs a Mac with Apple silicon."
                )
            )
        case .macOSVersion:
            let version = await context.hostProbe.macOSVersion()
            let passes = version >= HostOSVersion(major: 27, minor: 0)
            return result(
                context,
                state: passes ? .pass : .failure,
                detail: "macOS \(version)",
                error: passes ? nil : hostRequirementError(
                    item: "macOSVersion",
                    remediation: "Update macOS."
                )
            )
        case .hypervisor:
            return await booleanResult(
                context,
                probe: { await $0.supportsHypervisor() },
                detail: "Virtualization is available.",
                error: hostRequirementError(
                    item: "virtualization",
                    remediation: "Virtualization is not available on this Mac (APKRun can't run inside a virtual machine)."
                )
            )
        case .appLocation:
            return await booleanResult(
                context,
                probe: { await $0.applicationIsInApplications() },
                detail: "APKRun is in an Applications folder.",
                error: diagnosticError(
                    code: "diagnostics.appNotInApplications",
                    message: "APKRun isn't in the Applications folder.",
                    remediation: "Move APKRun to the Applications folder."
                )
            )
        case .appSignature:
            return await booleanResult(
                context,
                probe: { await $0.applicationSignatureIsValid() },
                detail: "The app signature and nested code are valid.",
                error: diagnosticError(
                    code: "diagnostics.appSignatureInvalid",
                    message: "APKRun's app was modified or is damaged.",
                    remediation: "Reinstall APKRun.",
                    action: .openDownloadsPage
                )
            )
        case .componentVersions:
            let builds = await context.hostProbe.componentBuilds()
            guard let mismatch = builds.firstMismatch(from: context.buildInfo.buildNumber) else {
                return result(
                    context,
                    state: .pass,
                    detail: "All components use build \(context.buildInfo.buildNumber)."
                )
            }
            return result(
                context,
                state: .failure,
                detail: "\(mismatch.component) uses build \(mismatch.foundBuild).",
                error: diagnosticError(
                    code: "diagnostics.componentVersionMismatch",
                    message: "Parts of APKRun have different versions (\(mismatch.foundBuild)).",
                    remediation: "Reinstall APKRun.",
                    parameters: ["build": .text(mismatch.foundBuild)],
                    action: .openDownloadsPage
                )
            )
        case .dataVolume:
            let volume = await context.hostProbe.dataVolumeInfo(at: context.paths.dataRoot)
            guard volume.isAPFS else {
                return result(
                    context,
                    state: .failure,
                    detail: "APKRun's data is not on an APFS volume.",
                    error: hostRequirementError(
                        item: "apfsVolume",
                        remediation: "Move APKRun's data to an APFS volume."
                    )
                )
            }
            let minimumBytes: Int64 = 10 * 1_024 * 1_024 * 1_024
            guard volume.availableBytes < minimumBytes else {
                return result(
                    context,
                    state: .pass,
                    detail: "\(ByteCountFormatter.string(fromByteCount: volume.availableBytes, countStyle: .file)) available."
                )
            }
            return result(
                context,
                state: .warning,
                detail: "\(ByteCountFormatter.string(fromByteCount: volume.availableBytes, countStyle: .file)) available.",
                error: diagnosticError(
                    code: "diagnostics.lowDiskSpace",
                    message: "Only \(ByteCountFormatter.string(fromByteCount: volume.availableBytes, countStyle: .file)) is free on the disk with APKRun's data.",
                    remediation: "Free up space. System Settings → Storage shows what APKRun uses.",
                    parameters: ["available": .bytes(volume.availableBytes)],
                    action: .openStorageSettings
                )
            )
        case .memory:
            let memory = await context.hostProbe.physicalMemoryBytes()
            let minimumBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024
            let memoryText = ByteCountFormatter.string(
                fromByteCount: Int64(clamping: memory),
                countStyle: .memory
            )
            guard memory < minimumBytes else {
                return result(context, state: .pass, detail: "\(memoryText) physical memory.")
            }
            return result(
                context,
                state: .warning,
                detail: "\(memoryText) physical memory.",
                error: diagnosticError(
                    code: "diagnostics.lowMemory",
                    message: "This Mac has \(memoryText) of memory.",
                    remediation: "APKRun works best with 16 GB or more.",
                    parameters: ["memory": .bytes(Int64(clamping: memory))]
                )
            )
        case .runtimeRegistration:
            let label = context.buildInfo.launchAgentLabel
            let registration = await context.hostProbe.runtimeRegistration(label: label)
            switch registration {
            case .enabled:
                return result(
                    context,
                    state: .pass,
                    detail: "LaunchAgent \(label) is registered."
                )
            case .requiresApproval:
                return result(
                    context,
                    state: .failure,
                    detail: "LaunchAgent \(label) needs approval.",
                    error: serviceUnavailableError(
                        reason: "requiresApproval",
                        message: "APKRun's background service is turned off in Login Items.",
                        remediation: "Allow APKRun in System Settings → General → Login Items & Extensions.",
                        action: .openLoginItemsSettings
                    )
                )
            case .notRegistered:
                return result(
                    context,
                    state: .failure,
                    detail: "LaunchAgent \(label) is not registered.",
                    error: serviceUnavailableError(
                        reason: "notRegistered",
                        message: "APKRun's background service is not set up.",
                        remediation: "Open APKRun to finish setup."
                    )
                )
            }
        }
    }

    private func booleanResult(
        _ context: HealthContext,
        probe: @Sendable (any HostProbe) async -> Bool,
        detail: String,
        error: ErrorInfo
    ) async -> HealthResult {
        let passes = await probe(context.hostProbe)
        return result(
            context,
            state: passes ? .pass : .failure,
            detail: detail,
            error: passes ? nil : error
        )
    }

    private func result(
        _ context: HealthContext,
        state: HealthState,
        detail: String? = nil,
        error: ErrorInfo? = nil
    ) -> HealthResult {
        HealthResult(
            id: id,
            group: group,
            state: state,
            title: title,
            detail: detail,
            error: error,
            measuredAt: context.clock.now
        )
    }
}

private func hostRequirementError(item: String, remediation: String) -> ErrorInfo {
    ErrorInfo(
        code: "runtime.hostRequirementsNotMet",
        message: LocalizedText(
            key: "runtime.hostRequirementsNotMet",
            parameters: ["items": .text(item)],
            fallback: "APKRun can't run on this Mac."
        ),
        remediation: LocalizedText(
            key: "runtime.hostRequirementsNotMet.\(item)",
            fallback: remediation
        ),
        action: item == "apfsVolume" ? .openStorageSettings : RemediationAction.none
    )
}

private func serviceUnavailableError(
    reason: String,
    message: String,
    remediation: String,
    action: RemediationAction = .none
) -> ErrorInfo {
    ErrorInfo(
        code: "runtime.serviceUnavailable",
        message: LocalizedText(
            key: "runtime.serviceUnavailable.\(reason)",
            parameters: ["reason": .text(reason)],
            fallback: message
        ),
        remediation: LocalizedText(
            key: "runtime.serviceUnavailable.\(reason).remediation",
            fallback: remediation
        ),
        action: action
    )
}

private func diagnosticError(
    code: String,
    message: String,
    remediation: String,
    parameters: [String: ErrorParameter] = [:],
    action: RemediationAction = .none
) -> ErrorInfo {
    ErrorInfo(
        code: code,
        message: LocalizedText(key: code, parameters: parameters, fallback: message),
        remediation: LocalizedText(
            key: "\(code).remediation",
            parameters: parameters,
            fallback: remediation
        ),
        action: action
    )
}
