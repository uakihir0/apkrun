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

    var allowsTestOnlyDiskSync: Bool {
        false
    }

    func probeFile(at url: URL) -> VMFileProbe {
        guard url.isFileURL else {
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

        guard let resolvedPath = url.path.withCString({ Darwin.realpath($0, nil) }) else {
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
        defer { free(resolvedPath) }

        let resolvedPathString = String(cString: resolvedPath)
        let resolvedURL = URL(fileURLWithPath: resolvedPathString).standardizedFileURL
        var fileInfo = stat()
        guard resolvedPathString.withCString({ stat($0, &fileInfo) }) == 0 else {
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

        let isRegularFile = (fileInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
        let fileSize = fileInfo.st_size >= 0 ? UInt64(fileInfo.st_size) : nil
        var first64Bytes = Data()
        var isReadable = false
        var isWritable = false

        if isRegularFile {
            let readDescriptor = Darwin.open(
                resolvedPathString,
                O_RDONLY | O_CLOEXEC | O_NONBLOCK
            )
            if readDescriptor >= 0 {
                defer {
                    Darwin.close(readDescriptor)
                }
                var header = [UInt8](repeating: 0, count: 64)
                let bytesRead = header.withUnsafeMutableBytes { buffer -> Int in
                    var result: Int
                    repeat {
                        result = pread(
                            readDescriptor,
                            buffer.baseAddress,
                            buffer.count,
                            0
                        )
                    } while result < 0 && errno == EINTR
                    return result
                }
                if bytesRead >= 0 {
                    first64Bytes = Data(header.prefix(bytesRead))
                    isReadable = true
                }
            }

            let writeDescriptor = Darwin.open(
                resolvedPathString,
                O_WRONLY | O_CLOEXEC | O_NONBLOCK
            )
            if writeDescriptor >= 0 {
                isWritable = true
                Darwin.close(writeDescriptor)
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
