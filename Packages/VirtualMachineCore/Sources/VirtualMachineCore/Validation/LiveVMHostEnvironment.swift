import Darwin
import Foundation
import Virtualization

/// Reads current host limits and local file attributes for VM validation.
struct LiveVMHostEnvironment: VMHostEnvironment {
    var activeProcessorCount: Int {
        ProcessInfo.processInfo.activeProcessorCount
    }

    var physicalMemoryBytes: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    var minimumAllowedCPUCount: Int {
        Int(VZVirtualMachineConfiguration.minimumAllowedCPUCount)
    }

    var maximumAllowedCPUCount: Int {
        Int(VZVirtualMachineConfiguration.maximumAllowedCPUCount)
    }

    var minimumAllowedMemorySize: UInt64 {
        VZVirtualMachineConfiguration.minimumAllowedMemorySize
    }

    var maximumAllowedMemorySize: UInt64 {
        VZVirtualMachineConfiguration.maximumAllowedMemorySize
    }

    var microphoneUsageDescription: String? {
        Bundle.main.infoDictionary?["NSMicrophoneUsageDescription"] as? String
    }

    func probeFile(at url: URL) -> VMFileProbe {
        let fileManager = FileManager.default
        guard url.isFileURL, fileManager.fileExists(atPath: url.path) else {
            return VMFileProbe(
                exists: false,
                isRegularFile: false,
                sizeBytes: nil,
                first64Bytes: Data(),
                isReadable: false,
                isWritable: false,
                resolvedFileURL: nil
            )
        }

        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let attributes = try? fileManager.attributesOfItem(atPath: resolvedURL.path)
        let isRegularFile = attributes?[.type] as? FileAttributeType == .typeRegular
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value
        var first64Bytes = Data()
        var isReadable = false
        var isWritable = false

        if isRegularFile {
            let readDescriptor = open(resolvedURL.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
            if readDescriptor >= 0 {
                defer {
                    close(readDescriptor)
                }
                var header = [UInt8](repeating: 0, count: 64)
                let bytesRead = header.withUnsafeMutableBytes { buffer in
                    pread(readDescriptor, buffer.baseAddress, buffer.count, 0)
                }
                if bytesRead >= 0 {
                    first64Bytes = Data(header.prefix(bytesRead))
                    isReadable = true
                }
            }

            let writeDescriptor = open(resolvedURL.path, O_WRONLY | O_CLOEXEC | O_NONBLOCK)
            if writeDescriptor >= 0 {
                isWritable = true
                close(writeDescriptor)
            }
        }

        return VMFileProbe(
            exists: true,
            isRegularFile: isRegularFile,
            sizeBytes: fileSize,
            first64Bytes: first64Bytes,
            isReadable: isReadable,
            isWritable: isWritable,
            resolvedFileURL: resolvedURL
        )
    }
}
