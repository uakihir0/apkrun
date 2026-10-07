import Darwin
import Foundation
import Security
import Testing
import VirtualMachineCoreTestSupport
import Virtualization

@testable import VirtualMachineCore

private let validationProbeEnabled =
    ProcessInfo.processInfo.environment["APKRUN_TEST_LINUX_DIR"]?.isEmpty == false

@Test
func validationProbeArtifactDirectoryRejectsDocumentsPathsAndAliases() throws {
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    let documentsDirectory = homeDirectory.appending(path: "Documents", directoryHint: .isDirectory)
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appending(path: "apkrun-artifact-path-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: temporaryDirectory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let documentsAlias = temporaryDirectory.appending(path: "documents")
    try FileManager.default.createSymbolicLink(
        atPath: documentsAlias.path,
        withDestinationPath: documentsDirectory.path
    )

    #expect(throws: ArtifactDirectoryFailure.self) {
        try safeArtifactDirectory(documentsDirectory, homeDirectory: homeDirectory)
    }
    #expect(throws: ArtifactDirectoryFailure.self) {
        try safeArtifactDirectory(
            documentsAlias.appending(path: "artifacts", directoryHint: .isDirectory),
            homeDirectory: homeDirectory
        )
    }
}

@Test(
    .enabled(
        if: validationProbeEnabled,
        "Set APKRUN_TEST_LINUX_DIR to the pinned Linux test artifacts to run this probe."
    )
)
func vzConfigurationValidationReportsProcessEntitlement() throws {
    #expect(VZVirtualMachine.isSupported)

    let configuredPath = ProcessInfo.processInfo.environment["APKRUN_TEST_LINUX_DIR"]!
    try #require(configuredPath.hasPrefix("/"))
    let artifactDirectory = try safeArtifactDirectory(
        URL(fileURLWithPath: configuredPath, isDirectory: true),
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser
    )
    let kernelURL = artifactDirectory.appending(path: "Image")
    let initrdURL = artifactDirectory.appending(path: "initramfs.cpio.gz")
    try #require(FileManager.default.fileExists(atPath: kernelURL.path))
    try #require(FileManager.default.fileExists(atPath: initrdURL.path))

    let task = SecTaskCreateFromSelf(kCFAllocatorDefault)!
    var entitlementQueryError: Unmanaged<CFError>?
    let entitlement = SecTaskCopyValueForEntitlement(
        task,
        "com.apple.security.virtualization" as CFString,
        &entitlementQueryError
    )
    if let entitlementQueryError {
        throw entitlementQueryError.takeRetainedValue()
    }
    let hasVirtualizationEntitlement = (entitlement as? Bool) == true

    var builder = VMDefinitionBuilder()
    builder.kernelURL = kernelURL
    builder.initialRamdiskURL = initrdURL
    builder.machineIdentifier = MachineIdentity.newMachineIdentifier()
    let definition = builder.build()
    let attachments = try VZConfigurationBuilder.nullDeviceConsoleAttachments(
        count: definition.consolePorts.count
    )
    let buildResult = try VZConfigurationBuilder.build(
        definition,
        consolePortAttachments: attachments
    )

    do {
        try buildResult.configuration.validate()
        #expect(hasVirtualizationEntitlement)
    } catch {
        let error = error as NSError
        let failureReason =
            error.userInfo[NSLocalizedFailureReasonErrorKey] as? String ?? "<missing>"
        #expect(!hasVirtualizationEntitlement)
        #expect(error.domain == "VZErrorDomain")
        #expect(error.code == 2)
        #expect(failureReason.contains("com.apple.security.virtualization"))
    }
}

private enum ArtifactDirectoryFailure: Error {
    case invalidPath
}

private func safeArtifactDirectory(_ requestedURL: URL, homeDirectory: URL) throws -> URL {
    let lexicalHome = homeDirectory.standardizedFileURL
    let lexicalDocuments = lexicalHome.appending(path: "Documents", directoryHint: .isDirectory)
    guard !isWithin(requestedURL.path, directory: lexicalDocuments.path) else {
        throw ArtifactDirectoryFailure.invalidPath
    }

    let resolvedHomePath = try resolvePathWithoutEnteringProtected(
        lexicalHome.path,
        protectedDirectories: []
    )
    let protectedDirectories = [
        lexicalDocuments.path,
        URL(fileURLWithPath: resolvedHomePath, isDirectory: true)
            .appending(path: "Documents", directoryHint: .isDirectory)
            .path,
    ]
    let resolvedPath = try resolvePathWithoutEnteringProtected(
        requestedURL.path,
        protectedDirectories: protectedDirectories
    )
    return URL(fileURLWithPath: resolvedPath, isDirectory: true)
}

private func resolvePathWithoutEnteringProtected(
    _ path: String,
    protectedDirectories: [String]
) throws -> String {
    guard path.hasPrefix("/") else {
        throw ArtifactDirectoryFailure.invalidPath
    }

    var resolvedPath = "/"
    var unresolvedComponents: [String] = []
    var pendingComponents = path.split(separator: "/").map(String.init)
    var followedLinks = 0

    while !pendingComponents.isEmpty {
        let component = pendingComponents.removeFirst()
        if component.isEmpty || component == "." {
            continue
        }
        if !unresolvedComponents.isEmpty {
            if component == ".." {
                unresolvedComponents.removeLast()
            } else {
                unresolvedComponents.append(component)
            }
            let unresolvedPath = unresolvedComponents.reduce(resolvedPath) {
                $0 == "/" ? "/\($1)" : "\($0)/\($1)"
            }
            try requireOutsideProtectedDirectories(unresolvedPath, protectedDirectories)
            continue
        }
        if component == ".." {
            resolvedPath = (resolvedPath as NSString).deletingLastPathComponent
            try requireOutsideProtectedDirectories(resolvedPath, protectedDirectories)
            continue
        }

        let candidatePath = resolvedPath == "/" ? "/\(component)" : "\(resolvedPath)/\(component)"
        try requireOutsideProtectedDirectories(candidatePath, protectedDirectories)

        var fileStatus = stat()
        let status = candidatePath.withCString { lstat($0, &fileStatus) }
        if status != 0 {
            guard errno == ENOENT || errno == ENOTDIR else {
                throw ArtifactDirectoryFailure.invalidPath
            }
            unresolvedComponents.append(component)
            continue
        }

        if (fileStatus.st_mode & S_IFMT) == S_IFLNK {
            followedLinks += 1
            guard followedLinks <= 40 else {
                throw ArtifactDirectoryFailure.invalidPath
            }
            var targetBuffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let targetLength = candidatePath.withCString { path in
                targetBuffer.withUnsafeMutableBufferPointer { buffer in
                    readlink(path, buffer.baseAddress, buffer.count)
                }
            }
            guard targetLength >= 0, targetLength < targetBuffer.count else {
                throw ArtifactDirectoryFailure.invalidPath
            }
            let target = String(
                decoding: targetBuffer[..<targetLength].map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            if target.hasPrefix("/") {
                resolvedPath = "/"
            }
            pendingComponents = target.split(separator: "/").map(String.init) + pendingComponents
            continue
        }

        resolvedPath = candidatePath
    }

    return unresolvedComponents.reduce(resolvedPath) {
        $0 == "/" ? "/\($1)" : "\($0)/\($1)"
    }
}

private func requireOutsideProtectedDirectories(
    _ path: String,
    _ protectedDirectories: [String]
) throws {
    guard !protectedDirectories.contains(where: { isWithin(path, directory: $0) }) else {
        throw ArtifactDirectoryFailure.invalidPath
    }
}

private func isWithin(_ path: String, directory: String) -> Bool {
    let candidate = lexicallyStandardizedPath(path).lowercased()
    let root = lexicallyStandardizedPath(directory).lowercased()
    return candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
}

private func lexicallyStandardizedPath(_ path: String) -> String {
    var components: [Substring] = []
    for component in path.split(separator: "/") {
        switch component {
        case ".", "":
            continue
        case "..":
            if !components.isEmpty {
                components.removeLast()
            }
        default:
            components.append(component)
        }
    }
    return "/" + components.joined(separator: "/")
}
