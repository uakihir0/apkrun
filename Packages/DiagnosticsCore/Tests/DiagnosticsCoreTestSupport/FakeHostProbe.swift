import DiagnosticsCore
import Foundation

/// Configurable host facts for deterministic health-check tests.
public actor FakeHostProbe: HostProbe {
    public struct State: Sendable {
        public var supportsAppleSilicon: Bool
        public var macOSVersion: HostOSVersion
        public var supportsHypervisor: Bool
        public var applicationIsInApplications: Bool
        public var applicationSignatureIsValid: Bool
        public var componentBuilds: HostComponentBuilds
        public var dataVolumeInfo: HostVolumeInfo
        public var physicalMemoryBytes: UInt64
        public var runtimeRegistration: HostRuntimeRegistration

        public init(
            supportsAppleSilicon: Bool = true,
            macOSVersion: HostOSVersion = HostOSVersion(major: 27, minor: 0),
            supportsHypervisor: Bool = true,
            applicationIsInApplications: Bool = true,
            applicationSignatureIsValid: Bool = true,
            componentBuilds: HostComponentBuilds = HostComponentBuilds(
                daemon: BuildInfo.current.buildNumber,
                cli: BuildInfo.current.buildNumber,
                launcher: BuildInfo.current.buildNumber
            ),
            dataVolumeInfo: HostVolumeInfo = HostVolumeInfo(
                isAPFS: true,
                availableBytes: 20 * 1_024 * 1_024 * 1_024
            ),
            physicalMemoryBytes: UInt64 = 16 * 1_024 * 1_024 * 1_024,
            runtimeRegistration: HostRuntimeRegistration = .enabled
        ) {
            self.supportsAppleSilicon = supportsAppleSilicon
            self.macOSVersion = macOSVersion
            self.supportsHypervisor = supportsHypervisor
            self.applicationIsInApplications = applicationIsInApplications
            self.applicationSignatureIsValid = applicationSignatureIsValid
            self.componentBuilds = componentBuilds
            self.dataVolumeInfo = dataVolumeInfo
            self.physicalMemoryBytes = physicalMemoryBytes
            self.runtimeRegistration = runtimeRegistration
        }
    }

    private var state: State
    private var requestedLabels: [String] = []

    public init(state: State = State()) {
        self.state = state
    }

    public func update(_ state: State) {
        self.state = state
    }

    public func labelsRequested() -> [String] {
        requestedLabels
    }

    public func supportsAppleSilicon() async -> Bool {
        state.supportsAppleSilicon
    }

    public func macOSVersion() async -> HostOSVersion {
        state.macOSVersion
    }

    public func supportsHypervisor() async -> Bool {
        state.supportsHypervisor
    }

    public func applicationIsInApplications() async -> Bool {
        state.applicationIsInApplications
    }

    public func applicationSignatureIsValid() async -> Bool {
        state.applicationSignatureIsValid
    }

    public func componentBuilds() async -> HostComponentBuilds {
        state.componentBuilds
    }

    public func dataVolumeInfo(at path: URL) async -> HostVolumeInfo {
        state.dataVolumeInfo
    }

    public func physicalMemoryBytes() async -> UInt64 {
        state.physicalMemoryBytes
    }

    public func runtimeRegistration(label: String) async -> HostRuntimeRegistration {
        requestedLabels.append(label)
        return state.runtimeRegistration
    }
}
