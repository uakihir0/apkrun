import DiagnosticsCore
import Foundation
import VirtualMachineCore

/// Owns `Runtime/instance/`: provisioning, loading, and Reset Android (android-image.md §5).
///
/// This first cut (#012) covers `load`, `provision`, `resetAndroid`, and the
/// first-boot settings flag. Recovery points arrive with #058.
public actor InstanceStore {
    private let paths: APKRunPaths
    private let provisioner: InstanceDiskProvisioner
    private let logger: APKLogger

    /// Creates a store for the instance under `paths.instanceDirectory`.
    public init(paths: APKRunPaths, diagnostics: DiagnosticsContext) {
        self.init(paths: paths, diagnostics: diagnostics, provisioner: InstanceDiskProvisioner())
    }

    init(paths: APKRunPaths, diagnostics: DiagnosticsContext, provisioner: InstanceDiskProvisioner) {
        self.paths = paths
        self.provisioner = provisioner
        logger = APKLogger(category: ImageLogCategory.instance, sink: diagnostics.logSink)
    }

    /// The instance disk for a manifest template: `Runtime/instance/<file name of path>`.
    public nonisolated func diskURL(for template: RuntimeImageManifest.Disk) -> URL {
        paths.instanceDirectory.appendingPathComponent(
            URL(fileURLWithPath: template.path).lastPathComponent
        )
    }

    /// Reads `instance.json`; `nil` when there is no instance yet.
    public func load(image: InstalledImage) throws(ImageFailure) -> InstanceConfiguration? {
        let infoFile = paths.instanceInfoFile
        guard FileManager.default.fileExists(atPath: infoFile.path) else {
            return nil
        }
        let configuration: InstanceConfiguration
        do {
            configuration = try JSONDecoder().decode(
                InstanceConfiguration.self,
                from: Data(contentsOf: infoFile)
            )
        } catch {
            throw .instanceCorrupt(reason: "instance.json does not decode")
        }
        for template in image.manifest.templates {
            let url = diskURL(for: template)
            guard
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                let size = (attributes[.size] as? NSNumber)?.uint64Value
            else {
                throw .instanceMissing
            }
            let expected =
                template.userdataStrategy == .blankFormattable
                ? configuration.sizing.userdataBytes : template.logicalSize
            guard size == expected else {
                throw .instanceCorrupt(reason: "\(template.role) disk size \(size) is not \(expected)")
            }
        }
        return configuration
    }

    /// Creates a new instance from the image's templates (§5.1).
    public func provision(
        image: InstalledImage,
        sizing: InstanceSizing
    ) throws(ImageFailure) -> InstanceConfiguration {
        let configuration = InstanceConfiguration(
            instanceID: UUID(),
            machineIdentifier: MachineIdentity.newMachineIdentifier(),
            macAddresses: [MachineIdentity.newMACAddress(), MachineIdentity.newMACAddress()],
            sizing: sizing,
            imageVersion: image.version,
            userdataSchemaVersion: Self.userdataSchemaVersion(of: image),
            userdataGeneration: UUID()
        )
        try removeInstance(image: image)
        do {
            try FileManager.default.createDirectory(
                at: paths.instanceDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw .cloneFailed(underlying: UnderlyingError(domain: "NSCocoaErrorDomain", code: (error as NSError).code))
        }
        for template in image.manifest.templates {
            let grow = template.userdataStrategy == .blankFormattable ? sizing.userdataBytes : nil
            try provisioner.provision(
                template: image.url(of: template.path),
                destination: diskURL(for: template),
                role: template.role,
                instance: configuration.instanceID,
                growTo: grow
            )
        }
        try write(configuration)
        logger.notice(
            "Provisioned Android instance \(configuration.instanceID.uuidString, .hashed) for image \(image.version.description, .public)"
        )
        return configuration
    }

    /// Deletes the instance disks and provisions a fresh instance ("Reset Android").
    public func resetAndroid(
        image: InstalledImage,
        sizing: InstanceSizing
    ) throws(ImageFailure) -> InstanceConfiguration {
        try provision(image: image, sizing: sizing)
    }

    /// Records that the first-boot settings ran (android-image.md §7.6).
    public func markFirstBootSettingsApplied() throws(ImageFailure) {
        guard
            let data = try? Data(contentsOf: paths.instanceInfoFile),
            var configuration = try? JSONDecoder().decode(InstanceConfiguration.self, from: data)
        else {
            throw .instanceMissing
        }
        configuration.firstBootSettingsApplied = true
        try write(configuration)
    }

    private func removeInstance(image: InstalledImage) throws(ImageFailure) {
        // instance.json goes first, so an interruption never leaves a record without disks.
        try? FileManager.default.removeItem(at: paths.instanceInfoFile)
        for template in image.manifest.templates {
            try? FileManager.default.removeItem(at: diskURL(for: template))
        }
        try? FileManager.default.removeItem(at: paths.bootDirectory)
    }

    private func write(_ configuration: InstanceConfiguration) throws(ImageFailure) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(configuration)
            let temporary = paths.instanceInfoFile.appendingPathExtension("tmp")
            try data.write(to: temporary, options: .atomic)
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize()
            try handle.close()
            _ = try FileManager.default.replaceItemAt(paths.instanceInfoFile, withItemAt: temporary)
        } catch {
            throw .cloneFailed(underlying: UnderlyingError(domain: "NSCocoaErrorDomain", code: (error as NSError).code))
        }
    }

    private static func userdataSchemaVersion(of image: InstalledImage) -> Int {
        guard case .object(let userdata) = image.manifest.userdata,
            case .number(let version)? = userdata["schemaVersion"]
        else {
            return 1
        }
        return Int(version)
    }
}
