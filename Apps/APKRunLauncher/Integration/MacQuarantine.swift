import Darwin
import Foundation

/// Writes the standard macOS quarantine extended attribute to an exported file.
enum MacQuarantine {
    enum Failure: Error, Equatable {
        case destinationUnavailable
        case attributeWriteFailed(code: Int32)
    }

    static func set(at url: URL, agentName: String) throws {
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            throw Failure.destinationUnavailable
        }
        defer { close(descriptor) }

        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
            (fileStatus.st_mode & S_IFMT) == S_IFREG
        else {
            throw Failure.destinationUnavailable
        }

        let timestamp = String(Int(Date().timeIntervalSince1970), radix: 16)
        let safeAgentName = agentName
            .precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: ";", with: "-")
            .components(separatedBy: CharacterSet.controlCharacters)
            .joined()
        let value = "0081;\(timestamp);\(safeAgentName);\(UUID().uuidString)"
        let data = Data(value.utf8)
        let result = data.withUnsafeBytes { buffer in
            fsetxattr(descriptor, "com.apple.quarantine", buffer.baseAddress, buffer.count, 0, 0)
        }
        guard result == 0 else {
            throw Failure.attributeWriteFailed(code: errno)
        }
    }
}
