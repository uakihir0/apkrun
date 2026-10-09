import DiagnosticsCore
import DiagnosticsCoreTestSupport
import Foundation
import Testing
import VirtualMachineCore

@testable import ImageCore

@Test
func imageVersionParsesRendersAndOrdersOnTheTripleOnly() throws {
    let version = try #require(ImageVersion("2026.10.0-cf16373615-arm64"))
    #expect(version.description == "2026.10.0-cf16373615-arm64")
    #expect(version.shortForm == "2026.10.0")
    #expect(try #require(ImageVersion("2026.10.1-ar000123-arm64")) > version)
    #expect(try #require(ImageVersion("2026.09.9-cf1-arm64")) < version)
    let other = try #require(ImageVersion("2026.10.0-cf1-arm64"))
    #expect(!(other < version) && !(version < other) && other != version)
    for invalid in ["2026.10.00-cf1-arm64", "2026.13.0-cf1-arm64", "2026.10.0-cf1-x86", "2026.10.0"] {
        #expect(ImageVersion(invalid) == nil, "\(invalid) must be rejected")
    }
}

@Test
func bootconfigWriterMatchesTheSharedGoldenVectors() throws {
    let directory = repositoryRoot.appendingPathComponent("Images/tools/tests/fixtures/bootconfig")
    for name in ["empty", "one-key", "many-keys", "values-with-spaces", "exactly-16k"] {
        let source = try String(contentsOf: directory.appendingPathComponent("\(name).txt"), encoding: .ascii)
        let expected = try Data(contentsOf: directory.appendingPathComponent("\(name).bin"))
        let values = try BootconfigWriter.parse(source, layer: name)
        let entries = values.map { BootconfigEntry(key: $0.key, value: $0.value, layer: name) }
        let trailer = try BootconfigWriter.trailer(
            for: BootconfigWriter.serialize(entries),
            commandLine: "console=hvc0 bootconfig"
        )
        #expect(trailer == expected, "\(name) differs from the Python golden vector")
    }
}

@Test
func bootconfigWriterRejectsConflictsAndHonoursOverrides() throws {
    let vendor = BootconfigLayer(name: "vendor", values: ["androidboot.hardware": "cutf_cvm"])
    #expect(
        throws: BootconfigWriter.Failure.conflict(key: "androidboot.hardware", layerA: "vendor", layerB: "image")
    ) {
        try BootconfigWriter.merge([vendor, BootconfigLayer(name: "image", values: ["androidboot.hardware": "x"])])
    }
    let merged = try BootconfigWriter.merge([
        vendor,
        BootconfigLayer(name: "image", values: ["androidboot.hardware": "x"], overrides: ["androidboot.hardware"]),
        BootconfigLayer(name: "instance", values: ["androidboot.hardware": "x"]),
    ])
    #expect(merged == [BootconfigEntry(key: "androidboot.hardware", value: "x", layer: "image")])
    #expect(throws: BootconfigWriter.Failure.self) {
        try BootconfigWriter.trailer(for: Data(), commandLine: "console=hvc0")
    }
}

@Test
func androidBootPlannerBuildsTheHeadlessDefinitionAndInitrd() throws {
    let bundle = try FixtureBundle.make()
    defer { bundle.remove() }
    let paths = bundle.paths
    let instance = InstanceConfiguration(
        instanceID: try #require(UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301")),
        machineIdentifier: MachineIdentity.newMachineIdentifier(),
        macAddresses: ["02:00:00:00:00:01", "02:00:00:00:00:02"],
        sizing: InstanceSizing(cpuCount: 4, memoryBytes: 4 * 1024 * 1024 * 1024, userdataBytes: 1 << 30),
        imageVersion: bundle.image.version,
        userdataSchemaVersion: 1,
        userdataGeneration: UUID()
    )

    let plan = try AndroidBootPlanner(paths: paths).prepareBoot(
        image: bundle.image,
        instance: instance,
        options: BootOptions(gpuProfile: .headless, developerMode: true)
    )

    let definition = plan.definition
    #expect(definition.cpuCount == 4)
    #expect(definition.disks.map(\.readOnly) == [true, false])
    #expect(definition.disks.map(\.identifier) == ["apkrun-os", "apkrun-data"])
    #expect(definition.disks[1].url == paths.instanceDirectory.appendingPathComponent("userdata.img"))
    #expect(
        definition.networks
            == [
                .nat(macAddress: "02:00:00:00:00:01"),
                .nat(macAddress: "02:00:00:00:00:02"),
                .nat(macAddress: "02:15:b2:00:00:00"),
            ]
    )
    #expect(definition.vsockEnabled)
    #expect(definition.builtInDisplay == BuiltInDisplayDefinition(widthPixels: 720, heightPixels: 1280))
    #expect(definition.consolePorts.count == 20)
    #expect(definition.consolePorts[0].role == .systemConsole)
    #expect(definition.consolePorts[1].role == .service(name: "serial"))
    #expect(definition.consolePorts[2].role == .silent(name: "logcat"))
    #expect(definition.consolePorts[18].role == .service(name: "sensors_control"))
    guard case .linux(_, let initrd?, let commandLine) = definition.boot else {
        Issue.record("the plan must boot a Linux kernel with an initrd")
        return
    }
    #expect(commandLine == FixtureBundle.commandLine)
    #expect(initrd == paths.instanceInitrdFile)

    let values = Dictionary(uniqueKeysWithValues: plan.bootconfig.map { ($0.key, $0.value) })
    #expect(values["androidboot.boot_devices"] == "40000000.pci")
    #expect(values["androidboot.serialno"] == "APKRUN3F2504E04F")
    #expect(values["androidboot.ddr_size"] == "4096MB")
    #expect(values["androidboot.console"] == "hvc1")
    #expect(values["androidboot.hardware.egl"] == "angle")
    #expect(values["androidboot.apkrun.image"] == bundle.image.version.description)
    let layers = Dictionary(uniqueKeysWithValues: plan.bootconfig.map { ($0.key, $0.layer) })
    #expect(layers["androidboot.hardware"] == "vendor")
    #expect(layers["androidboot.boot_devices"] == "platform")

    let initrdBytes = try Data(contentsOf: initrd)
    #expect(initrdBytes.prefix(FixtureBundle.ramdisk.count) == FixtureBundle.ramdisk)
    #expect(initrdBytes.suffix(12) == Data("#BOOTCONFIG\n".utf8))
    let block = initrdBytes.dropFirst(FixtureBundle.ramdisk.count).dropLast(20)
    let text = String(decoding: block.filter { $0 != 0 }, as: UTF8.self)
    #expect(text.contains("androidboot.boot_devices = \"40000000.pci\"\n"))
    #expect(plan.bootconfigSHA256.count == 64)
}

@Test
func androidBootPlannerKeepsSerialSilentOutsideDeveloperMode() throws {
    let bundle = try FixtureBundle.make()
    defer { bundle.remove() }
    let ports = AndroidBootPlanner.consolePorts(
        bundle.image.manifest.consolePorts,
        options: BootOptions(gpuProfile: .headless, captureLogcat: true)
    )
    #expect(ports[1].role == .silent(name: "serial"))
    #expect(ports[2].role == .log(name: "logcat"))
}

@Test
func instanceStoreProvisionsLoadsAndDetectsAMissingDisk() async throws {
    let bundle = try FixtureBundle.make()
    defer { bundle.remove() }
    let store = InstanceStore(paths: bundle.paths, diagnostics: .testing())
    #expect(try await store.load(image: bundle.image) == nil)

    let sizing = InstanceSizing(cpuCount: 2, memoryBytes: 2 << 30, userdataBytes: 64 * 1024 * 1024)
    let created = try await store.provision(image: bundle.image, sizing: sizing)
    #expect(created.macAddresses.count == 2)
    #expect(try await store.load(image: bundle.image) == created)

    try await store.markFirstBootSettingsApplied()
    #expect(try await store.load(image: bundle.image)?.firstBootSettingsApplied == true)

    try FileManager.default.removeItem(at: bundle.paths.instanceDirectory.appendingPathComponent("userdata.img"))
    await #expect(throws: ImageFailure.instanceMissing) {
        _ = try await store.load(image: bundle.image)
    }
}

@Test
func developmentImageChecksFileSizes() throws {
    let bundle = try FixtureBundle.make()
    defer { bundle.remove() }
    #expect(try DevelopmentImage.load(directory: bundle.image.root) == bundle.image)

    try Data([1, 2, 3]).write(to: bundle.image.root.appendingPathComponent("boot/cmdline.txt"))
    #expect(throws: ImageFailure.hashMismatch(file: "boot/cmdline.txt")) {
        _ = try DevelopmentImage.load(directory: bundle.image.root)
    }
}

private var repositoryRoot: URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 {
        url.deleteLastPathComponent()
    }
    return url
}

/// A small unsigned bundle with the layout's console ports and GPU profiles.
private struct FixtureBundle {
    static let commandLine = "console=hvc0 bootconfig"
    static let ramdisk = Data("fixture-ramdisk".utf8)

    var image: InstalledImage
    var paths: APKRunPaths
    var directory: URL

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func make() throws -> FixtureBundle {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-boot-planner-\(UUID().uuidString)", isDirectory: true)
        let root = directory.appendingPathComponent("bundle", isDirectory: true)
        for name in ["boot", "disks", "templates"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        let layoutURL = repositoryRoot.appendingPathComponent("Images/tools/layouts/cuttlefish-phone-arm64.json")
        let layout = try JSONDecoder().decode(Layout.self, from: Data(contentsOf: layoutURL))
        let bootconfig =
            "[vendor]\nandroidboot.hardware = \"cutf_cvm\"\n[image]\n"
            + layout.bootconfig.image.sorted { $0.key < $1.key }.map { "\($0.key) = \"\($0.value)\"\n" }.joined()
        let template = try provisionFixtureTemplate()
        let files: [(String, Data)] = [
            ("boot/kernel", Data(repeating: 0, count: 64)),
            ("boot/ramdisk.img", ramdisk),
            ("boot/bootconfig.txt", Data(bootconfig.utf8)),
            ("boot/cmdline.txt", Data(commandLine.utf8)),
            ("disks/os.img", Data(repeating: 0, count: 4096)),
            ("templates/userdata.img", template),
        ]
        var entries: [String: RuntimeImageManifest.FileEntry] = [:]
        for (path, data) in files {
            try data.write(to: root.appendingPathComponent(path))
            entries[path] = .init(path: path, size: UInt64(data.count), sha256: "")
        }
        let version = try #require(ImageVersion("2026.10.0-cf16373615-arm64"))
        let manifest = RuntimeImageManifest(
            schemaVersion: 1,
            imageVersion: version,
            kind: .stock,
            provenance: .object([:]),
            guest: .object([:]),
            boot: .init(
                kernel: try #require(entries["boot/kernel"]),
                ramdisk: try #require(entries["boot/ramdisk.img"]),
                bootconfig: try #require(entries["boot/bootconfig.txt"]),
                cmdline: try #require(entries["boot/cmdline.txt"]),
                kernelPageSize: 4096,
                bootconfigOverrides: []
            ),
            disks: [
                .init(
                    role: "os", path: "disks/os.img", readOnly: true, identifier: "apkrun-os",
                    logicalSize: 4096, userdataStrategy: nil, partitions: []
                )
            ],
            templates: [
                .init(
                    role: "userdata", path: "templates/userdata.img", readOnly: false,
                    identifier: "apkrun-data", logicalSize: UInt64(template.count),
                    userdataStrategy: .blankFormattable, partitions: []
                )
            ],
            consolePorts: layout.consolePorts,
            gpuProfiles: layout.gpuProfiles,
            requirements: .object([:]),
            userdata: .object(["schemaVersion": .number(1)]),
            compatibility: .object([:]),
            legal: nil,
            files: files.compactMap { entries[$0.0] }
        )
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("manifest.json"))
        let paths = APKRunPaths(
            allowingHomeOverride: true,
            environment: ["APKRUN_HOME": directory.appendingPathComponent("home").path]
        )
        return FixtureBundle(
            image: InstalledImage(version: version, root: root, manifest: manifest),
            paths: paths,
            directory: directory
        )
    }

    /// The layout file fields the fixture copies.
    private struct Layout: Decodable {
        struct Bootconfig: Decodable {
            var image: [String: String]
        }
        var bootconfig: Bootconfig
        var consolePorts: [RuntimeImageManifest.ConsolePort]
        var gpuProfiles: [String: RuntimeImageManifest.GPUProfile]
    }

    /// The "before" disk of the shared GPT provisioning fixture.
    private static func provisionFixtureTemplate() throws -> Data {
        struct Fixture: Decodable {
            struct Disk: Decodable {
                var size: Int
                var sectors: [String: String]
            }
            var before: Disk
        }
        let url = repositoryRoot.appendingPathComponent("Images/tools/tests/fixtures/gpt/provision.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        var bytes = [UInt8](repeating: 0, count: fixture.before.size)
        for (lba, base64) in fixture.before.sectors {
            let sector = try [UInt8](#require(Data(base64Encoded: base64)))
            let offset = try #require(Int(lba)) * 512
            bytes.replaceSubrange(offset..<(offset + 512), with: sector)
        }
        return Data(bytes)
    }
}

private let builtBundle = repositoryRoot.appendingPathComponent("Images/work/16373615/bundle")

@Test(.enabled(if: FileManager.default.fileExists(atPath: builtBundle.appendingPathComponent("manifest.json").path)))
func theBuiltStockBundleLoadsAndPlansAHeadlessBoot() throws {
    let image = try DevelopmentImage.load(directory: builtBundle)
    #expect(image.version.description == "2026.10.0-cf16373615-arm64")
    #expect(image.manifest.consolePorts.count == 20)
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-built-bundle-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": home.path])
    let instance = InstanceConfiguration(
        instanceID: UUID(),
        machineIdentifier: MachineIdentity.newMachineIdentifier(),
        macAddresses: [MachineIdentity.newMACAddress(), MachineIdentity.newMACAddress()],
        sizing: .default,
        imageVersion: image.version,
        userdataSchemaVersion: 1,
        userdataGeneration: UUID()
    )

    let plan = try AndroidBootPlanner(paths: paths).prepareBoot(
        image: image,
        instance: instance,
        options: BootOptions(gpuProfile: .headless, developerMode: true)
    )

    let keys = Set(plan.bootconfig.map(\.key))
    #expect(keys.contains("androidboot.vbmeta.digest"))
    #expect(keys.contains("androidboot.hardware.egl"))
    #expect(plan.definition.networks.count == 3)
    #expect(BootconfigWriter.serialize(plan.bootconfig).count < 4096)
}
