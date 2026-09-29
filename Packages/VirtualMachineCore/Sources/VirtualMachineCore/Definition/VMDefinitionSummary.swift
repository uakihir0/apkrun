import Foundation
import VirtioDeviceCore

/// A path-reduced, device-free projection suitable for diagnostics and logs.
public struct VMDefinitionSummary: Codable, Equatable, Sendable {
    /// Configured guest CPU count.
    public let cpuCount: Int

    /// Guest memory size in bytes.
    public let memorySizeBytes: UInt64

    /// Whether a machine identifier was supplied.
    public let hasMachineIdentifier: Bool

    /// Path-reduced Linux boot details.
    public let boot: BootSummary

    /// Path-reduced disk details.
    public let disks: [DiskSummary]

    /// Whether a network adapter is configured.
    public let networkEnabled: Bool

    /// Whether vsock is enabled.
    public let vsockEnabled: Bool

    /// Console port roles in device order.
    public let consolePorts: [ConsolePortSummary]

    /// Whether the built-in entropy device is enabled.
    public let entropyEnabled: Bool

    /// Whether the memory balloon is enabled.
    public let memoryBalloonEnabled: Bool

    /// Optional sound stream selection.
    public let sound: SoundSummary?

    /// Names of custom virtio devices, without retaining their model objects.
    public let customDeviceNames: [String]

    /// Creates a diagnostic projection without full paths, command-line text, or identities.
    public init(definition: VMDefinition) {
        cpuCount = definition.cpuCount
        memorySizeBytes = definition.memorySize
        hasMachineIdentifier = definition.machineIdentifier != nil
        switch definition.boot {
        case .linux(let kernel, let initialRamdisk, let commandLine):
            boot = BootSummary(
                kernelFileName: kernel.lastPathComponent,
                initialRamdiskFileName: initialRamdisk?.lastPathComponent,
                commandLineByteCount: commandLine.utf8.count
            )
        }
        disks = definition.disks.map {
            DiskSummary(
                fileName: $0.url.lastPathComponent,
                role: VMDiagnosticToken.sanitize($0.role),
                readOnly: $0.readOnly,
                caching: $0.caching,
                synchronization: $0.synchronization
            )
        }
        networkEnabled = definition.network != nil
        vsockEnabled = definition.vsockEnabled
        consolePorts = definition.consolePorts.map(ConsolePortSummary.init)
        entropyEnabled = definition.entropy
        memoryBalloonEnabled = definition.memoryBalloon
        sound = definition.sound.map(SoundSummary.init)
        customDeviceNames = definition.customDevices.map {
            VMDiagnosticToken.sanitize($0.descriptor.name)
        }
    }

    /// Path-reduced Linux boot metadata.
    public struct BootSummary: Codable, Equatable, Sendable {
        /// Basename of the kernel file.
        public let kernelFileName: String

        /// Basename of the optional initrd file.
        public let initialRamdiskFileName: String?

        /// Command-line size in bytes, without its contents.
        public let commandLineByteCount: Int
    }

    /// Path-reduced disk metadata.
    public struct DiskSummary: Codable, Equatable, Sendable {
        /// Basename of the disk image.
        public let fileName: String

        /// Stable diagnostic role.
        public let role: String

        /// Whether the guest receives a read-only disk.
        public let readOnly: Bool

        /// Disk caching mode.
        public let caching: DiskCaching

        /// Disk synchronization mode.
        public let synchronization: DiskSync
    }

    /// Codable projection of a console port's role.
    public enum ConsolePortSummary: Codable, Equatable, Sendable {
        /// The primary system console.
        case systemConsole

        /// A named output log.
        case log(name: String)

        /// A named discarded output.
        case silent(name: String)

        /// A named host-side service port.
        case service(name: String)

        fileprivate init(_ port: ConsolePortDefinition) {
            switch port.role {
            case .systemConsole:
                self = .systemConsole
            case .log(let name):
                self = .log(name: VMDiagnosticToken.sanitize(name))
            case .silent(let name):
                self = .silent(name: VMDiagnosticToken.sanitize(name))
            case .service(let name):
                self = .service(name: VMDiagnosticToken.sanitize(name))
            }
        }
    }

    /// Whether host audio input and output are enabled.
    public struct SoundSummary: Codable, Equatable, Sendable {
        /// Whether host audio output is enabled.
        public let output: Bool

        /// Whether host microphone input is enabled.
        public let input: Bool

        fileprivate init(_ sound: SoundDefinition) {
            output = sound.output
            input = sound.input
        }
    }
}
