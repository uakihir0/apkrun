import CryptoKit
import Darwin
import DiagnosticsCore
import Foundation
import VirtualMachineCore

/// Builds the per-boot initrd and the Android `VMDefinition` (android-image.md §6, §9).
///
/// ImageCore never starts a VM: RuntimeCore hands the plan's definition to
/// `VMController` after adding the GraphicsCore device where the profile needs it.
public struct AndroidBootPlanner: Sendable {
    /// The longest kernel command line VM validation accepts (vm.md §3).
    static let maximumCommandLineLength = 2048

    private let platform: VZPlatformProfile
    private let paths: APKRunPaths

    /// Creates a planner for one platform profile and data root.
    public init(platform: VZPlatformProfile = .macOS27, paths: APKRunPaths) {
        self.platform = platform
        self.paths = paths
    }

    /// Regenerates `Runtime/instance/boot/initrd.img` and returns the boot plan.
    public func prepareBoot(
        image: InstalledImage,
        instance: InstanceConfiguration,
        options: BootOptions
    ) throws(ImageFailure) -> AndroidBootPlan {
        let manifest = image.manifest
        guard let profile = manifest.gpuProfiles[options.gpuProfile.rawValue] else {
            throw .manifestInvalid(
                path: "manifest.json",
                reason: "the bundle has no \(options.gpuProfile.rawValue) GPU profile"
            )
        }
        let commandLine = try readCommandLine(image)
        let bootconfigText = try readText(image, manifest.boot.bootconfig.path)
        let entries: [BootconfigEntry]
        do throws(BootconfigWriter.Failure) {
            let sections = try BootconfigWriter.parseSections(bootconfigText)
            entries = try BootconfigWriter.merge([
                BootconfigLayer(name: "vendor", values: sections.vendor),
                BootconfigLayer(
                    name: "image",
                    values: sections.image,
                    overrides: Set(manifest.boot.bootconfigOverrides)
                ),
                BootconfigLayer(
                    name: "gpu:\(options.gpuProfile.rawValue)",
                    values: profile.bootconfig,
                    overrides: Set(profile.overrides)
                ),
                BootconfigLayer(name: "platform", values: ["androidboot.boot_devices": platform.bootDevices]),
                BootconfigLayer(name: "instance", values: instanceLayer(image, instance, options)),
            ])
        } catch {
            throw error.imageFailure
        }
        let block = BootconfigWriter.serialize(entries)
        let trailer: Data
        do throws(BootconfigWriter.Failure) {
            trailer = try BootconfigWriter.trailer(for: block, commandLine: commandLine)
        } catch {
            throw error.imageFailure
        }
        let initrd = try writeInitrd(ramdisk: image.url(of: manifest.boot.ramdisk.path), trailer: trailer)

        let wifiMAC = try Self.virtWifiMAC(entries)
        var disks = manifest.disks.map { disk in
            DiskDefinition(
                url: image.url(of: disk.path),
                readOnly: true,
                caching: .automatic,
                synchronization: .full,
                identifier: disk.identifier,
                role: disk.role
            )
        }
        disks += manifest.templates.map { template in
            DiskDefinition(
                url: paths.instanceDirectory.appendingPathComponent(
                    URL(fileURLWithPath: template.path).lastPathComponent
                ),
                readOnly: false,
                caching: .automatic,
                synchronization: .full,
                identifier: template.identifier,
                role: template.role
            )
        }
        let definition = VMDefinition(
            label: "APKRun Android (\(image.version.description))",
            cpuCount: instance.sizing.cpuCount,
            memorySize: instance.sizing.memoryBytes,
            machineIdentifier: instance.machineIdentifier,
            boot: .linux(
                kernel: image.url(of: manifest.boot.kernel.path),
                initialRamdisk: initrd,
                commandLine: commandLine
            ),
            disks: disks,
            networks: (instance.macAddresses + [wifiMAC]).map { .nat(macAddress: $0) },
            vsockEnabled: true,
            consolePorts: Self.consolePorts(manifest.consolePorts, options: options),
            entropy: true,
            memoryBalloon: true,
            sound: options.soundOutput || options.microphone
                ? SoundDefinition(output: options.soundOutput, input: options.microphone) : nil,
            builtInDisplay: options.gpuProfile == .headless
                ? BuiltInDisplayDefinition(
                    widthPixels: platform.headlessDisplay.widthPixels,
                    heightPixels: platform.headlessDisplay.heightPixels
                ) : nil
        )
        let digest = SHA256.hash(data: block).map { String(format: "%02x", $0) }.joined()
        return AndroidBootPlan(
            definition: definition,
            bootconfig: entries,
            bootconfigSHA256: digest,
            bootRecordID: UUID()
        )
    }

    /// Layer 4 (§6.2): serial, density, memory, developer console, and the APKRun keys.
    private func instanceLayer(
        _ image: InstalledImage,
        _ instance: InstanceConfiguration,
        _ options: BootOptions
    ) -> [String: String] {
        var values = [
            "androidboot.serialno": instance.serialNumber,
            "androidboot.lcd_density": String(options.displayDensity),
            "androidboot.ddr_size": "\(instance.sizing.memoryBytes / (1024 * 1024))MB",
            "androidboot.apkrun.instance": instance.instanceID.uuidString.lowercased(),
            "androidboot.apkrun.devmode": options.developerMode ? "1" : "0",
            "androidboot.apkrun.image": image.version.description,
        ]
        if options.developerMode {
            values["androidboot.console"] = "hvc1"
            values["androidboot.serialconsole"] = "1"
        }
        return values
    }

    /// The manifest's default roles, changed by name for developer mode and log capture (§7.1).
    static func consolePorts(
        _ ports: [RuntimeImageManifest.ConsolePort],
        options: BootOptions
    ) -> [ConsolePortDefinition] {
        ports.sorted { $0.index < $1.index }.map { port in
            if port.name == "serial", options.developerMode {
                return ConsolePortDefinition(role: .service(name: port.name))
            }
            if port.name == "logcat", options.captureLogcat {
                return ConsolePortDefinition(role: .log(name: port.name))
            }
            switch port.role {
            case .systemConsole: return ConsolePortDefinition(role: .systemConsole)
            case .log: return ConsolePortDefinition(role: .log(name: port.name))
            case .silent: return ConsolePortDefinition(role: .silent(name: port.name))
            case .service: return ConsolePortDefinition(role: .service(name: port.name))
            }
        }
    }

    /// `setup_wifi` gives eth2 `02:XX:YY:00:00:00` from `androidboot.wifi_mac_prefix`
    /// (android-image.md §7.4), and vmnet drops frames from a MAC it did not assign.
    static func virtWifiMAC(_ entries: [BootconfigEntry]) throws(ImageFailure) -> String {
        guard let text = entries.first(where: { $0.key == "androidboot.wifi_mac_prefix" })?.value,
            let prefix = UInt16(text)
        else {
            throw .manifestInvalid(
                path: "boot/bootconfig.txt",
                reason: "androidboot.wifi_mac_prefix must be a 16-bit number"
            )
        }
        return String(format: "02:%02x:%02x:00:00:00", prefix >> 8, prefix & 0xFF)
    }

    private func readCommandLine(_ image: InstalledImage) throws(ImageFailure) -> String {
        let commandLine = try readText(image, image.manifest.boot.cmdline.path)
            .trimmingCharacters(in: .newlines)
        guard commandLine.utf8.count <= Self.maximumCommandLineLength else {
            throw .cmdlineTooLong(length: commandLine.utf8.count)
        }
        return commandLine
    }

    private func readText(_ image: InstalledImage, _ path: String) throws(ImageFailure) -> String {
        guard let data = try? Data(contentsOf: image.url(of: path)) else {
            throw .missingFile(file: path)
        }
        guard let text = String(data: data, encoding: .ascii) else {
            throw .manifestInvalid(path: path, reason: "must be ASCII")
        }
        return text
    }

    /// `clonefile`s the ramdisk, appends the trailer, syncs, and renames (§6.3 steps 2-3).
    private func writeInitrd(ramdisk: URL, trailer: Data) throws(ImageFailure) -> URL {
        let directory = paths.bootDirectory
        let final = paths.instanceInitrdFile
        let temporary = final.appendingPathExtension("tmp")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw .cloneFailed(underlying: UnderlyingError(domain: "NSCocoaErrorDomain", code: (error as NSError).code))
        }
        unlink(temporary.path)
        if clonefile(ramdisk.path, temporary.path, 0) != 0 {
            // Not APFS, or a different volume: a copy is fine for a 20 MB file.
            do {
                try FileManager.default.copyItem(at: ramdisk, to: temporary)
            } catch {
                throw .cloneFailed(underlying: UnderlyingError(domain: NSPOSIXErrorDomain, code: Int(errno)))
            }
        }
        let descriptor = open(temporary.path, O_WRONLY | O_APPEND | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw .cloneFailed(underlying: UnderlyingError(domain: NSPOSIXErrorDomain, code: Int(errno)))
        }
        defer { close(descriptor) }
        let written = trailer.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return write(descriptor, base, raw.count)
        }
        guard written == trailer.count, fsync(descriptor) == 0, rename(temporary.path, final.path) == 0 else {
            throw .cloneFailed(underlying: UnderlyingError(domain: NSPOSIXErrorDomain, code: Int(errno)))
        }
        return final
    }
}
