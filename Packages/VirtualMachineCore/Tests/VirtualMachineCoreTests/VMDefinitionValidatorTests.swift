import DiagnosticsCore
import DiagnosticsCoreTestSupport
import Foundation
import Testing
import VirtioDeviceCore
import VirtualMachineCoreTestSupport
import Virtualization

@testable import VirtualMachineCore

@Test func cpuValidationUsesTheHostAndFrameworkIntersection() {
    let builder = VMDefinitionBuilder()
    let validator = makeValidator(for: builder, activeCPUCount: 6)
    var definition = builder.build()
    definition.cpuCount = 7

    #expect(
        validator.findings(definition) == [
            .cpuCountOutOfRange(requested: 7, allowed: 2...6)
        ]
    )
}

@Test func cpuValidationRejectsAnEmptyHostAndFrameworkIntersection() {
    let builder = VMDefinitionBuilder()
    let validator = makeValidator(for: builder, activeCPUCount: 1)

    let failure = VMConfigurationFailure.cpuCountOutOfRange(requested: 2, allowed: nil)
    #expect(validator.findings(builder.build()) == [failure])
    #expect(
        failure.parameters == [
            "requested": .count(2),
            "allowed": .text("none"),
        ]
    )
}

@Test func configurationFailureListRetainsOrderedTypedItemParameters() {
    let failures: [VMConfigurationFailure] = [
        .cpuCountOutOfRange(requested: 6, allowed: 2...4),
        .diskMissing(role: "system"),
        .diskMissing(role: "userdata"),
    ]
    let aggregate = VMConfigurationFailure.configurationInvalid(failures)

    #expect(aggregate.parameters["items"] == .text("cpuCountOutOfRange,diskMissing,diskMissing"))
    #expect(
        aggregate.listItems == [
            ErrorListItem(
                selector: .errorCode("vm.cpuCountOutOfRange"),
                parameters: [
                    "requested": .count(6),
                    "allowed": .text("2…4"),
                ]
            ),
            ErrorListItem(
                selector: .errorCode("vm.diskMissing"),
                parameters: ["role": .text("system")]
            ),
            ErrorListItem(
                selector: .errorCode("vm.diskMissing"),
                parameters: ["role": .text("userdata")]
            ),
        ]
    )

    let hints = ErrorPresenter(locale: Locale(identifier: "en")).gui(aggregate).hints
    #expect(
        hints.map(\.code) == [
            "vm.cpuCountOutOfRange",
            "vm.diskMissing",
            "vm.diskMissing",
        ])
    #expect(
        hints.map(\.message) == [
            "Android can't use a CPU count of 6; the allowed range is 2…4.",
            "The system disk file is missing.",
            "The userdata disk file is missing.",
        ])
}

@Test func memoryValidationChecksAlignmentFrameworkBoundsAndHostCap() {
    let builder = VMDefinitionBuilder()
    let host = makeHost(for: builder, physicalMemoryBytes: 6 * 1_024 * 1_024 * 1_024)
    let validator = makeValidator(host: host)
    var definition = builder.build()
    definition.memorySize = 4 * 1_024 * 1_024 * 1_024 + 1

    #expect(
        validator.findings(definition) == [
            .memoryOutOfRange,
            .memoryExceedsHostCap(cap: 3 * 1_024 * 1_024 * 1_024),
        ]
    )

    definition.memorySize = 65 * 1_024 * 1_024 * 1_024
    #expect(validator.findings(definition).first == .memoryOutOfRange)
}

@Test func memoryValidationRejectsValuesBelowFrameworkMinimum() {
    let builder = VMDefinitionBuilder()
    let validator = makeValidator(
        host: makeHost(
            for: builder,
            minimumAllowedMemorySize: 4 * 1_024 * 1_024 * 1_024
        )
    )

    #expect(validator.findings(builder.build()) == [.memoryOutOfRange])
}

@Test func kernelValidationRejectsMissingAndCompressedFiles() {
    let builder = VMDefinitionBuilder()
    let missingHost = makeHost(
        for: builder,
        fileProbes: [
            builder.kernelURL: .missing
        ]
    )
    #expect(
        makeValidator(host: missingHost).findings(builder.build()) == [
            .kernelMissing(builder.kernelURL)
        ]
    )

    let gzipHost = makeHost(
        for: builder,
        fileProbes: [
            builder.kernelURL: VMFileProbeFixture(
                first64Bytes: Data([0x1F, 0x8B])
            )
        ]
    )
    #expect(
        makeValidator(host: gzipHost).findings(builder.build()) == [
            .kernelNotUncompressedImage(detected: .gzip)
        ]
    )
}

@Test func initrdValidationChecksExistenceAndMaximumSize() {
    var builder = VMDefinitionBuilder()
    let initrdURL = URL(fileURLWithPath: "/fixtures/initrd")
    builder.initialRamdiskURL = initrdURL

    let missingHost = makeHost(for: builder)
    #expect(makeValidator(host: missingHost).findings(builder.build()) == [.initrdMissing])

    let oversizedHost = makeHost(
        for: builder,
        fileProbes: [
            initrdURL: VMFileProbeFixture(sizeBytes: 512 * 1_024 * 1_024 + 1)
        ]
    )
    #expect(
        makeValidator(host: oversizedHost).findings(builder.build()) == [.initrdTooLarge]
    )
}

@Test func commandLineValidationChecksASCIIAndByteLength() {
    let builder = VMDefinitionBuilder()
    var definition = builder.build()
    definition.boot = .linux(
        kernel: builder.kernelURL,
        initialRamdisk: nil,
        commandLine: String(repeating: "a", count: 2_049)
    )
    #expect(makeValidator(for: builder).findings(definition) == [.commandLineInvalid])

    definition.boot = .linux(
        kernel: builder.kernelURL,
        initialRamdisk: nil,
        commandLine: "console=hvc0 café"
    )
    #expect(makeValidator(for: builder).findings(definition) == [.commandLineInvalid])
}

@Test func diskValidationRejectsMissingAndAndroidSparseImages() {
    let builder = VMDefinitionBuilder()
    let diskURL = URL(fileURLWithPath: "/fixtures/userdata.img")
    var definition = builder.build()
    definition.disks = [
        DiskDefinition(url: diskURL, readOnly: false, role: "userdata")
    ]
    let missingHost = makeHost(for: builder)
    #expect(
        makeValidator(host: missingHost).findings(definition) == [
            .diskMissing(role: "userdata")
        ]
    )

    let sparseHost = makeHost(
        for: builder,
        fileProbes: [
            diskURL: VMFileProbeFixture(
                first64Bytes: Data([0x3A, 0xFF, 0x26, 0xED])
            )
        ]
    )
    #expect(
        makeValidator(host: sparseHost).findings(definition) == [
            .diskIsAndroidSparse(role: "userdata")
        ]
    )
}

@Test func diskValidationChecksReadabilityResolvedDuplicatesAndWritability() {
    let builder = VMDefinitionBuilder()
    let firstURL = URL(fileURLWithPath: "/fixtures/userdata-a.img")
    let secondURL = URL(fileURLWithPath: "/fixtures/userdata-b.img")
    let resolvedURL = URL(fileURLWithPath: "/fixtures/real-userdata.img")
    var definition = builder.build()
    definition.disks = [
        DiskDefinition(url: firstURL, readOnly: false, role: "first"),
        DiskDefinition(url: secondURL, readOnly: false, role: "second"),
    ]

    let unreadableHost = makeHost(
        for: builder,
        fileProbes: [
            firstURL: VMFileProbeFixture(isReadable: false),
            secondURL: VMFileProbeFixture(isReadable: false),
        ]
    )
    #expect(
        makeValidator(host: unreadableHost).findings(definition) == [
            .diskNotReadable(role: "first"),
            .diskNotReadable(role: "second"),
        ]
    )

    let duplicateHost = makeHost(
        for: builder,
        fileProbes: [
            firstURL: VMFileProbeFixture(resolvedFileURL: resolvedURL),
            secondURL: VMFileProbeFixture(resolvedFileURL: resolvedURL),
        ]
    )
    #expect(
        makeValidator(host: duplicateHost).findings(definition) == [
            .duplicateDisk(role: "second")
        ]
    )

    definition.disks = [
        DiskDefinition(url: firstURL, readOnly: false, role: "userdata")
    ]
    let unwritableHost = makeHost(
        for: builder,
        fileProbes: [
            firstURL: VMFileProbeFixture(isWritable: false)
        ]
    )
    #expect(
        makeValidator(host: unwritableHost).findings(definition) == [
            .diskNotWritable(role: "userdata")
        ]
    )
}

@Test func productionDefinitionsRejectTestOnlyDiskSynchronization() {
    let builder = VMDefinitionBuilder()
    let diskURL = URL(fileURLWithPath: "/fixtures/userdata.img")
    var definition = builder.build()
    definition.disks = [
        DiskDefinition(
            url: diskURL,
            readOnly: false,
            synchronization: .none,
            role: "userdata"
        )
    ]
    let host = makeHost(for: builder, fileProbes: [diskURL: VMFileProbeFixture()])

    #expect(
        makeValidator(host: host).findings(definition) == [
            .diskSyncModeTestOnly(role: "userdata")
        ]
    )
}

@Test func onlyATestHostCanAllowUnsynchronizedDisks() {
    let builder = VMDefinitionBuilder()
    let diskURL = URL(fileURLWithPath: "/fixtures/userdata.img")
    var definition = builder.build()
    definition.disks = [
        DiskDefinition(
            url: diskURL,
            readOnly: false,
            synchronization: .none,
            role: "userdata"
        )
    ]
    let probes = [
        builder.kernelURL: VMFileProbeFixture(
            sizeBytes: 64,
            first64Bytes: validArm64KernelHeader
        ),
        diskURL: VMFileProbeFixture(),
    ]
    let productionHost = FakeVMHostEnvironment(fileProbes: probes)
    let testHost = FakeVMHostEnvironment(
        allowsTestOnlyDiskSync: true,
        fileProbes: probes
    )

    #expect(
        VMDefinitionValidator(
            host: productionHost,
            frameworkValidator: FakeFrameworkConfigurationValidator()
        ).findings(definition) == [.diskSyncModeTestOnly(role: "userdata")]
    )
    #expect(
        VMDefinitionValidator(
            host: testHost,
            frameworkValidator: FakeFrameworkConfigurationValidator()
        ).findings(definition).isEmpty
    )
}

@Test func diskIdentifierMustBeAtMostTwentyASCIICharacters() {
    let builder = VMDefinitionBuilder()
    let diskURL = URL(fileURLWithPath: "/fixtures/disk.img")
    var definition = builder.build()
    definition.disks = [
        DiskDefinition(
            url: diskURL,
            readOnly: true,
            identifier: String(repeating: "x", count: 21),
            role: "os"
        )
    ]
    let host = makeHost(for: builder, fileProbes: [diskURL: VMFileProbeFixture()])
    #expect(makeValidator(host: host).findings(definition) == [.diskIdentifierInvalid])

    definition.disks[0].identifier = "disk-é"
    #expect(makeValidator(host: host).findings(definition) == [.diskIdentifierInvalid])
}

@Test func consolePortZeroMustBeTheSystemConsole() {
    let builder = VMDefinitionBuilder()
    var definition = builder.build()
    definition.consolePorts = []
    #expect(makeValidator(for: builder).findings(definition) == [.missingSystemConsole])

    definition.consolePorts = [
        ConsolePortDefinition(role: .log(name: "boot"))
    ]
    #expect(makeValidator(for: builder).findings(definition) == [.missingSystemConsole])
}

@Test func networkMACMustBeLocallyAdministeredUnicast() {
    let builder = VMDefinitionBuilder()
    var definition = builder.build()
    for address in ["00:00:00:00:00:01", "03:00:00:00:00:01", "not-a-mac"] {
        definition.network = .nat(macAddress: address)
        #expect(makeValidator(for: builder).findings(definition) == [.invalidMACAddress])
    }

    definition.network = .nat(macAddress: "02:00:00:00:00:01")
    #expect(makeValidator(for: builder).findings(definition).isEmpty)
}

@Test func machineIdentifierMustDecodeInVirtualizationFramework() {
    let builder = VMDefinitionBuilder()
    var definition = builder.build()
    definition.machineIdentifier = Data([0x01])
    #expect(
        makeValidator(for: builder).findings(definition) == [.machineIdentifierInvalid]
    )

    definition.machineIdentifier = MachineIdentity.newMachineIdentifier()
    #expect(makeValidator(for: builder).findings(definition).isEmpty)
}

@Test func customDevicesNeedANameAndAtLeastOneQueue() {
    let builder = VMDefinitionBuilder()
    let definition = builder.build()
    let invalidDevices: [any VirtioDeviceModel] = [
        TestVirtioDevice(name: "  ", queueCount: 1),
        TestVirtioDevice(name: "fixture", queueCount: 0),
    ]
    var invalidDefinition = definition
    invalidDefinition.customDevices = invalidDevices

    #expect(
        makeValidator(for: builder).findings(invalidDefinition) == [
            .customDeviceInvalid(name: "redacted", reason: "name must not be empty"),
            .customDeviceInvalid(name: "fixture", reason: "queue count must be at least one"),
        ]
    )
}

@Test func validationSnapshotsCustomDeviceDescriptorsAndRetainsModels() throws {
    let builder = VMDefinitionBuilder()
    let validator = makeValidator(for: builder)
    var definition = builder.build()
    var model: MutableTestVirtioDevice? = MutableTestVirtioDevice(name: "original")
    weak var weakModel = model
    definition.customDevices = [try #require(model)]

    let validated = try validator.validate(definition)
    definition.customDevices = []
    model?.setName("changed")

    let snapshotted = try #require(validated.definition.customDevices.first)
    #expect(snapshotted.descriptor.name == "original")
    model = nil
    #expect(weakModel != nil)
}

@Test func microphoneInputRequiresNonemptyBundleUsageDescription() {
    var builder = VMDefinitionBuilder()
    builder.sound = SoundDefinition(output: false, input: true)
    let definition = builder.build()

    #expect(makeValidator(for: builder).findings(definition) == [.microphoneUsageDescriptionMissing])

    let host = makeHost(for: builder, microphoneUsageDescription: "Use the microphone")
    #expect(makeValidator(host: host).findings(definition).isEmpty)
}

@Test func frameworkRejectionKeepsOnlyItsDomainAndNumericCode() {
    let builder = VMDefinitionBuilder()
    let rejection = UnderlyingError(domain: "VZErrorDomain", code: 42)
    let validator = makeValidator(
        for: builder,
        frameworkValidator: FakeFrameworkConfigurationValidator(rejection: rejection)
    )

    #expect(
        validator.findings(builder.build()) == [
            .frameworkRejected(underlying: rejection)
        ]
    )
}

@Test func adapterDescriptorRejectionMapsToCustomDeviceInvalid() {
    let builder = VMDefinitionBuilder()
    let validator = makeValidator(
        for: builder,
        frameworkValidator: FakeFrameworkConfigurationValidator(
            customDeviceFailure: .customDeviceInvalid(
                name: "fixture",
                reason: "shared memory region count exceeds the framework limit"
            )
        )
    )

    #expect(
        validator.findings(builder.build()) == [
            .customDeviceInvalid(
                name: "fixture",
                reason: "shared memory region count exceeds the framework limit"
            )
        ]
    )
}

@Test func vzAdapterDescriptorFailureMapsToCustomDeviceInvalid() {
    let builder = VMDefinitionBuilder()
    var definition = builder.build()
    definition.customDevices = [
        TestVirtioDevice(
            name: "overlapping-features",
            queueCount: 1,
            mandatoryFeatures: 1 << 5,
            optionalFeatures: 1 << 5
        )
    ]
    let validator = VMDefinitionValidator(
        host: makeHost(for: builder),
        frameworkValidator: VZFrameworkConfigurationValidator()
    )

    #expect(
        validator.findings(definition) == [
            .customDeviceInvalid(
                name: "overlapping-features",
                reason: "mandatory and optional features overlap"
            )
        ]
    )
}

@Test func frameworkValidationIsSkippedWhenLocalRulesFail() {
    let builder = VMDefinitionBuilder()
    var definition = builder.build()
    definition.machineIdentifier = Data([0x01])
    let validator = makeValidator(
        for: builder,
        frameworkValidator: FakeFrameworkConfigurationValidator(
            rejection: UnderlyingError(domain: "VZErrorDomain", code: 42)
        )
    )

    #expect(validator.findings(definition) == [.machineIdentifierInvalid])
}

@Test func findingsLogsOnlyTheSanitizedSummaryToTheVMConfigurationCategory() {
    let builder = VMDefinitionBuilder()
    let diskURL = URL(fileURLWithPath: "/private/customer/userdata.img")
    var definition = builder.build()
    definition.disks = [
        DiskDefinition(url: diskURL, readOnly: false, role: "userdata")
    ]
    definition.consolePorts.append(
        ConsolePortDefinition(role: .service(name: "../private/customer"))
    )
    definition.customDevices = [TestVirtioDevice(name: "private/customer", queueCount: 1)]
    let host = makeHost(for: builder, fileProbes: [diskURL: VMFileProbeFixture()])
    let sink = RecordingLogSink()
    let logger = APKLogger(category: VMLogCategory.config, sink: sink)
    let validator = VMDefinitionValidator(
        host: host,
        frameworkValidator: FakeFrameworkConfigurationValidator(),
        logger: logger
    )

    #expect(validator.findings(definition).isEmpty)
    let entry = sink.entries.first
    #expect(entry?.subsystem == .vm)
    #expect(entry?.category == "config")
    #expect(entry?.publicMessage.contains("VM definition summary:") == true)
    #expect(entry?.publicMessage.contains("userdata.img") == true)
    #expect(entry?.publicMessage.contains("\"role\":\"userdata\"") == true)
    #expect(entry?.publicMessage.contains("\"readOnly\":false") == true)
    #expect(entry?.publicMessage.contains("\"caching\":\"automatic\"") == true)
    #expect(entry?.publicMessage.contains("\"synchronization\":\"full\"") == true)
    #expect(entry?.publicMessage.contains("/private/customer") == false)
    #expect(entry?.publicMessage.contains("redacted") == true)
}

@Test func validationCollectsFlatFailuresInRuleOrderAndThrowsSingleFailuresDirectly() {
    let builder = VMDefinitionBuilder()
    var definition = builder.build()
    definition.cpuCount = 20
    definition.memorySize += 1
    definition.boot = .linux(
        kernel: builder.kernelURL,
        initialRamdisk: nil,
        commandLine: "console=hvc0 café"
    )
    let validator = makeValidator(for: builder)
    let expected: [VMConfigurationFailure] = [
        .cpuCountOutOfRange(requested: 20, allowed: 2...8),
        .memoryOutOfRange,
        .commandLineInvalid,
    ]

    #expect(validator.findings(definition) == expected)
    do {
        _ = try validator.validate(definition)
        Issue.record("Expected validation to throw the collected failures.")
    } catch {
        #expect(error == .configurationInvalid(expected))
    }

    definition.cpuCount = 2
    definition.memorySize = 3 * 1_024 * 1_024 * 1_024
    definition.boot = .linux(
        kernel: URL(fileURLWithPath: "/fixtures/missing-Image"),
        initialRamdisk: nil,
        commandLine: "console=hvc0"
    )
    do {
        _ = try validator.validate(definition)
        Issue.record("Expected one validation failure.")
    } catch {
        #expect(error == .kernelMissing(URL(fileURLWithPath: "/fixtures/missing-Image")))
    }
}

@Test func successfulValidationPersistsAGeneratedMachineIdentifier() throws {
    let builder = VMDefinitionBuilder()
    let validated = try makeValidator(for: builder).validate(builder.build())

    #expect(validated.definition.machineIdentifier != nil)
    #expect(
        VZGenericMachineIdentifier(
            dataRepresentation: validated.definition.machineIdentifier!
        ) != nil
    )
}

@Test func virtualMachineErrorsConformToTheCatalogAndExposeOnlyDeclaredParameters() {
    let failures: [any APKRunError] = [
        VMConfigurationFailure.cpuCountOutOfRange(requested: 9, allowed: 2...8),
        VMConfigurationFailure.memoryOutOfRange,
        VMConfigurationFailure.memoryExceedsHostCap(cap: 8 * 1_024 * 1_024 * 1_024),
        VMConfigurationFailure.kernelMissing(URL(fileURLWithPath: "/private/customer/Image")),
        VMConfigurationFailure.kernelNotUncompressedImage(detected: .gzip),
        VMConfigurationFailure.initrdMissing,
        VMConfigurationFailure.initrdTooLarge,
        VMConfigurationFailure.commandLineInvalid,
        VMConfigurationFailure.diskMissing(role: "userdata"),
        VMConfigurationFailure.diskIsAndroidSparse(role: "userdata"),
        VMConfigurationFailure.duplicateDisk(role: "userdata"),
        VMConfigurationFailure.diskNotReadable(role: "userdata"),
        VMConfigurationFailure.diskNotWritable(role: "userdata"),
        VMConfigurationFailure.diskSyncModeTestOnly(role: "userdata"),
        VMConfigurationFailure.diskIdentifierInvalid,
        VMConfigurationFailure.missingSystemConsole,
        VMConfigurationFailure.invalidMACAddress,
        VMConfigurationFailure.machineIdentifierInvalid,
        VMConfigurationFailure.customDeviceInvalid(name: "fixture", reason: "bad descriptor"),
        VMConfigurationFailure.diskMissing(role: "/private/customer"),
        VMConfigurationFailure.customDeviceInvalid(
            name: "/private/customer",
            reason: "/private/customer"
        ),
        VMConfigurationFailure.microphoneUsageDescriptionMissing,
        VMConfigurationFailure.frameworkRejected(
            underlying: UnderlyingError(domain: "VZErrorDomain", code: 1)
        ),
        VMConfigurationFailure.configurationInvalid([
            .kernelMissing(URL(fileURLWithPath: "/private/Image"))
        ]),
        VMFailure.invalidTransition(from: .stopped, to: .starting),
        VMFailure.startFailed(
            underlying: VZErrorInfo(domain: "VZErrorDomain", code: 2, description: "private path")
        ),
        VMFailure.stoppedWithError(
            underlying: VZErrorInfo(domain: "VZErrorDomain", code: 3, description: "private path")
        ),
        VMFailure.pauseFailed(
            underlying: VZErrorInfo(domain: "VZErrorDomain", code: 4, description: "private path")
        ),
        VMFailure.resumeFailed(
            underlying: VZErrorInfo(domain: "VZErrorDomain", code: 5, description: "private path")
        ),
        VMFailure.stopTimedOut,
        VMFailure.vsockDeviceNotConfigured,
        VMFailure.vsockDeviceUnavailable,
        VMFailure.vsockConnectFailed(
            port: 7000,
            underlying: VZErrorInfo(domain: "VZErrorDomain", code: 6, description: "private path")
        ),
        VMFailure.vsockPortNotListening(port: 7000),
        VMFailure.vsockConnectTimedOut(port: 7000),
        VMFailure.virtualizationUnavailable,
    ]

    #expect(VMFailure.networkAttachmentLost.qualifiedCode == "vm.networkAttachmentLost")
    #expect(VMFailure.consoleLogWriteFailed.qualifiedCode == "vm.consoleLogWriteFailed")
    for failure in failures {
        let entry = ErrorCatalog.entry(for: failure.qualifiedCode)
        #expect(entry != nil)
        #expect(Set(failure.parameters.keys).isSubset(of: entry?.parameters ?? []))
        for parameter in failure.parameters.values {
            switch parameter {
            case .text(let value), .fileName(let value):
                #expect(!value.contains("/private"))
            case .bytes, .count, .duration:
                break
            }
        }
    }
}

private func makeValidator(
    for builder: VMDefinitionBuilder,
    activeCPUCount: Int = 8,
    frameworkValidator: any FrameworkConfigurationValidator = FakeFrameworkConfigurationValidator()
) -> VMDefinitionValidator {
    makeValidator(
        host: makeHost(for: builder, activeCPUCount: activeCPUCount),
        frameworkValidator: frameworkValidator
    )
}

private func makeValidator(
    host: FakeVMHostEnvironment,
    frameworkValidator: any FrameworkConfigurationValidator = FakeFrameworkConfigurationValidator()
) -> VMDefinitionValidator {
    VMDefinitionValidator(host: host, frameworkValidator: frameworkValidator)
}

private func makeHost(
    for builder: VMDefinitionBuilder,
    activeCPUCount: Int = 8,
    physicalMemoryBytes: UInt64 = 16 * 1_024 * 1_024 * 1_024,
    minimumAllowedMemorySize: UInt64 = 1 * 1_024 * 1_024 * 1_024,
    microphoneUsageDescription: String? = nil,
    fileProbes: [URL: VMFileProbeFixture] = [:]
) -> FakeVMHostEnvironment {
    var probes = fileProbes
    if probes[builder.kernelURL] == nil {
        probes[builder.kernelURL] = VMFileProbeFixture(
            sizeBytes: 64,
            first64Bytes: validArm64KernelHeader
        )
    }
    return FakeVMHostEnvironment(
        activeProcessorCount: activeCPUCount,
        physicalMemoryBytes: physicalMemoryBytes,
        minimumAllowedMemorySize: minimumAllowedMemorySize,
        microphoneUsageDescription: microphoneUsageDescription,
        fileProbes: probes
    )
}

private let validArm64KernelHeader: Data = {
    var bytes = Data(repeating: 0, count: 64)
    bytes.replaceSubrange(0x38..<0x3C, with: [0x41, 0x52, 0x4D, 0x64])
    return bytes
}()

private final class TestVirtioDevice: VirtioDeviceModel, Sendable {
    let descriptor: VirtioDeviceDescriptor

    init(
        name: String,
        queueCount: UInt16,
        mandatoryFeatures: UInt64 = 0,
        optionalFeatures: UInt64 = 0
    ) {
        descriptor = VirtioDeviceDescriptor(
            name: name,
            deviceID: 1,
            pciClass: 0,
            pciSubclass: 0,
            queueCount: queueCount,
            mandatoryFeatures: mandatoryFeatures,
            optionalFeatures: optionalFeatures
        )
    }
}

private final class MutableTestVirtioDevice: VirtioDeviceModel, @unchecked Sendable {
    private let lock = NSLock()
    private var storedDescriptor: VirtioDeviceDescriptor

    var descriptor: VirtioDeviceDescriptor {
        lock.lock()
        defer { lock.unlock() }
        return storedDescriptor
    }

    init(name: String) {
        storedDescriptor = VirtioDeviceDescriptor(
            name: name,
            deviceID: 1,
            pciClass: 0,
            pciSubclass: 0,
            queueCount: 1,
            mandatoryFeatures: 0,
            optionalFeatures: 0
        )
    }

    func setName(_ name: String) {
        lock.lock()
        storedDescriptor.name = name
        lock.unlock()
    }
}
