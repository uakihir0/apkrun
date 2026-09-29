import DiagnosticsCore
import Foundation

/// A stable, path-conscious failure found while validating a VM definition.
public enum VMConfigurationFailure: APKRunError, Equatable {
    case cpuCountOutOfRange(requested: Int, allowed: ClosedRange<Int>?)
    case memoryOutOfRange
    case memoryExceedsHostCap(cap: UInt64)
    case kernelMissing(URL)
    case kernelNotUncompressedImage(detected: KernelImageFormat)
    case initrdMissing
    case initrdTooLarge
    case commandLineInvalid
    case diskMissing(role: String)
    case diskIsAndroidSparse(role: String)
    case duplicateDisk(role: String)
    case diskNotReadable(role: String)
    case diskNotWritable(role: String)
    case diskSyncModeTestOnly(role: String)
    case diskIdentifierInvalid
    case missingSystemConsole
    case invalidMACAddress
    case machineIdentifierInvalid
    case customDeviceInvalid(name: String, reason: String)
    case microphoneUsageDescriptionMissing
    case frameworkRejected(underlying: UnderlyingError)
    case configurationInvalid([VMConfigurationFailure])

    /// The error catalog domain owned by VirtualMachineCore.
    public static let domain: ErrorDomain = .vm

    /// The stable catalog code for this validation failure.
    public var code: String {
        switch self {
        case .cpuCountOutOfRange:
            "cpuCountOutOfRange"
        case .memoryOutOfRange:
            "memoryOutOfRange"
        case .memoryExceedsHostCap:
            "memoryExceedsHostCap"
        case .kernelMissing:
            "kernelMissing"
        case .kernelNotUncompressedImage:
            "kernelNotUncompressedImage"
        case .initrdMissing:
            "initrdMissing"
        case .initrdTooLarge:
            "initrdTooLarge"
        case .commandLineInvalid:
            "commandLineInvalid"
        case .diskMissing:
            "diskMissing"
        case .diskIsAndroidSparse:
            "diskIsAndroidSparse"
        case .duplicateDisk:
            "duplicateDisk"
        case .diskNotReadable:
            "diskNotReadable"
        case .diskNotWritable:
            "diskNotWritable"
        case .diskSyncModeTestOnly:
            "diskSyncModeTestOnly"
        case .diskIdentifierInvalid:
            "diskIdentifierInvalid"
        case .missingSystemConsole:
            "missingSystemConsole"
        case .invalidMACAddress:
            "invalidMACAddress"
        case .machineIdentifierInvalid:
            "machineIdentifierInvalid"
        case .customDeviceInvalid:
            "customDeviceInvalid"
        case .microphoneUsageDescriptionMissing:
            "microphoneUsageDescriptionMissing"
        case .frameworkRejected:
            "frameworkRejected"
        case .configurationInvalid:
            "configurationInvalid"
        }
    }

    /// Safe values associated with the error code, excluding host file paths.
    public var parameters: [String: ErrorParameter] {
        switch self {
        case .cpuCountOutOfRange(let requested, let allowed):
            [
                "requested": .count(requested),
                "allowed": .text(
                    allowed.map { "\($0.lowerBound)…\($0.upperBound)" } ?? "none"
                ),
            ]
        case .memoryExceedsHostCap(let cap):
            ["cap": .bytes(Int64(clamping: cap))]
        case .kernelNotUncompressedImage(let detected):
            ["detected": .text(detected.rawValue)]
        case .diskMissing(let role),
            .diskIsAndroidSparse(let role),
            .duplicateDisk(let role),
            .diskNotReadable(let role),
            .diskNotWritable(let role),
            .diskSyncModeTestOnly(let role):
            ["role": .text(VMDiagnosticToken.sanitize(role))]
        case .customDeviceInvalid(let name, let reason):
            [
                "name": .text(VMDiagnosticToken.sanitize(name)),
                "reason": .text(VMDiagnosticToken.sanitize(reason)),
            ]
        case .configurationInvalid(let failures):
            ["items": .text(failures.map(\.code).joined(separator: ","))]
        case .memoryOutOfRange,
            .kernelMissing,
            .initrdMissing,
            .initrdTooLarge,
            .commandLineInvalid,
            .diskIdentifierInvalid,
            .missingSystemConsole,
            .invalidMACAddress,
            .machineIdentifierInvalid,
            .microphoneUsageDescriptionMissing,
            .frameworkRejected:
            [:]
        }
    }

    /// The path-free Virtualization.framework error, when validation was rejected.
    public var underlying: UnderlyingError? {
        guard case .frameworkRejected(let underlying) = self else {
            return nil
        }
        return underlying
    }
}

/// The header format detected in the first bytes of a Linux kernel image.
public enum KernelImageFormat: String, Equatable, Sendable {
    /// The uncompressed arm64 Linux `Image` format.
    case arm64Image

    /// A gzip-compressed kernel image.
    case gzip

    /// An lz4-compressed kernel image.
    case lz4

    /// An EFI zboot image.
    case zboot

    /// An unsupported or unrecognized kernel image.
    case unknown
}
