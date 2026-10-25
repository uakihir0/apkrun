import Foundation
import GuestProtocol
import IntegrationCore
import Testing

@testable import RuntimeHost

@Test func sharedFolderRequestAdapterRoutesAllFileOperations() async throws {
    let fixture = try SharedFolderFixture()
    defer { Task { await fixture.stop() } }
    let handler = SharedFolderRequestAdapter(service: fixture.service).makeHandler()

    try Data("hello".utf8).write(to: fixture.root.appendingPathComponent("source.txt"))

    let rootsResponse = await handler(
        request {
            var operation = GPHostListRoots()
            operation.package = "com.android.documentsui"
            return .hostListRoots(operation)
        })
    guard case .hostListRoots(let roots)? = rootsResponse.result else {
        Issue.record("HostListRoots did not return a root list.")
        return
    }
    #expect(roots.roots.count == 1)
    #expect(roots.roots[0].rootID == "shared")
    #expect(roots.roots[0].title == "Shared")
    #expect(roots.roots[0].access == .readWrite)
    #expect(roots.roots[0].available)
    #expect(roots.roots[0].bytesFree == 0)

    let pageResponse = await handler(
        request {
            var operation = GPHostQueryChildren()
            operation.package = "com.android.documentsui"
            operation.rootID = "shared"
            return .hostQueryChildren(operation)
        })
    guard case .hostQueryChildren(let page)? = pageResponse.result else {
        Issue.record("HostQueryChildren did not return a document page.")
        return
    }
    #expect(page.entries.count == 1)
    #expect(page.entries[0].name == "source.txt")
    #expect(page.entries[0].path == "source.txt")

    let statResponse = await handler(
        request {
            var operation = GPHostStat()
            operation.package = "org.example.app"
            operation.rootID = "shared"
            operation.path = "source.txt"
            return .hostStat(operation)
        })
    guard case .hostStat(let stat)? = statResponse.result else {
        Issue.record("HostStat did not return document metadata.")
        return
    }
    #expect(stat.name == "source.txt")
    #expect(stat.size == 5)
    #expect(stat.mimeType == "text/plain")

    let openResponse = await handler(
        request {
            var operation = GPHostOpenFile()
            operation.package = "org.example.app"
            operation.rootID = "shared"
            operation.path = "source.txt"
            operation.mode = .readWrite
            return .hostOpenFile(operation)
        })
    guard case .hostOpenFile(let opened)? = openResponse.result else {
        Issue.record("HostOpenFile did not return a host handle.")
        return
    }
    #expect(opened.size == 5)

    let readResponse = await handler(
        request {
            var operation = GPHostReadRange()
            operation.handle = opened.handle
            operation.offset = 1
            operation.length = 2
            return .hostReadRange(operation)
        })
    guard case .hostReadRange(let read)? = readResponse.result else {
        Issue.record("HostReadRange did not return bytes.")
        return
    }
    #expect(read.data == Data("el".utf8))

    let writeResponse = await handler(
        request {
            var operation = GPHostWriteRange()
            operation.handle = opened.handle
            operation.offset = 1
            operation.data = Data("IP".utf8)
            return .hostWriteRange(operation)
        })
    #expect(isEmptyResult(writeResponse, expected: .hostWriteRange))

    let closeResponse = await handler(
        request {
            var operation = GPHostCloseFile()
            operation.handle = opened.handle
            operation.fsync = true
            return .hostCloseFile(operation)
        })
    #expect(isEmptyResult(closeResponse, expected: .hostCloseFile))
    let updatedContents = try Data(contentsOf: fixture.root.appendingPathComponent("source.txt"))
    #expect(updatedContents == Data("hIPlo".utf8))

    let writeModeResponse = await handler(openRequest(package: "org.example.app", mode: .write))
    guard case .hostOpenFile(let writeModeHandle)? = writeModeResponse.result else {
        Issue.record("HostOpenFile did not accept WRITE mode.")
        return
    }
    let writeModeCloseResponse = await handler(closeRequest(handle: writeModeHandle.handle))
    #expect(isEmptyResult(writeModeCloseResponse, expected: .hostCloseFile))

    let truncateModeResponse = await handler(openRequest(package: "org.example.app", mode: .truncate))
    guard case .hostOpenFile(let truncateModeHandle)? = truncateModeResponse.result else {
        Issue.record("HostOpenFile did not accept TRUNCATE mode.")
        return
    }
    #expect(truncateModeHandle.size == 0)
    let truncateModeCloseResponse = await handler(closeRequest(handle: truncateModeHandle.handle))
    #expect(isEmptyResult(truncateModeCloseResponse, expected: .hostCloseFile))

    let createResponse = await handler(
        request {
            var operation = GPHostCreateDocument()
            operation.package = "org.example.app"
            operation.rootID = "shared"
            operation.name = "created.txt"
            return .hostCreateDocument(operation)
        })
    guard case .hostCreateDocument(let created)? = createResponse.result else {
        Issue.record("HostCreateDocument did not return document metadata.")
        return
    }
    #expect(created.name == "created.txt")
    #expect(created.path == "created.txt")
    #expect(!created.isDir)

    let createDirectoryResponse = await handler(
        request {
            var operation = GPHostCreateDocument()
            operation.package = "org.example.app"
            operation.rootID = "shared"
            operation.name = "folder"
            operation.isDir = true
            return .hostCreateDocument(operation)
        })
    guard case .hostCreateDocument(let directory)? = createDirectoryResponse.result else {
        Issue.record("HostCreateDocument did not return directory metadata.")
        return
    }
    #expect(directory.isDir)

    let renameResponse = await handler(
        request {
            var operation = GPHostRenameDocument()
            operation.package = "org.example.app"
            operation.rootID = "shared"
            operation.path = "created.txt"
            operation.newName = "renamed.txt"
            return .hostRenameDocument(operation)
        })
    guard case .hostRenameDocument(let renamed)? = renameResponse.result else {
        Issue.record("HostRenameDocument did not return renamed metadata.")
        return
    }
    #expect(renamed.name == "renamed.txt")
    #expect(renamed.path == "renamed.txt")

    let deleteResponse = await handler(
        request {
            var operation = GPHostDeleteDocument()
            operation.package = "org.example.app"
            operation.rootID = "shared"
            operation.path = "renamed.txt"
            return .hostDeleteDocument(operation)
        })
    #expect(isEmptyResult(deleteResponse, expected: .hostDeleteDocument))

    let deleteDirectoryResponse = await handler(
        request {
            var operation = GPHostDeleteDocument()
            operation.package = "org.example.app"
            operation.rootID = "shared"
            operation.path = "folder"
            return .hostDeleteDocument(operation)
        })
    #expect(isEmptyResult(deleteDirectoryResponse, expected: .hostDeleteDocument))
}

@Test func sharedFolderRequestAdapterMapsEveryIntegrationFailureWithoutPathData() {
    let cases: [(IntegrationFailure, GPGuestErrorCode)] = [
        (.emptyFileSet, .invalidArgument),
        (.filesDisabled, .unsupported),
        (.invalidFileHandle, .permissionDenied),
        (.invalidMetadata, .internal),
        (.tooManyFiles(count: 3, limit: 2), .invalidArgument),
        (.fileTooLarge(name: "/private/customer.txt", bytes: 99), .invalidArgument),
        (.transferFailed, .internal),
        (.folderUnavailable(.missing, name: "/private/customer-folder"), .unavailable),
        (.folderUnavailable(.privacyDenied, name: "/private/customer-folder"), .unavailable),
        (.folderUnavailable(.offline, name: "/private/customer-folder"), .unavailable),
        (.pathRejected(.outsideRoot), .permissionDenied),
        (.pathRejected(.hidden), .permissionDenied),
        (.pathRejected(.notRegularFile), .permissionDenied),
        (.packageAccessDenied, .permissionDenied),
        (.readOnly, .permissionDenied),
        (.resourceExhausted, .resourceExhausted),
        (.itemNotFound, .notFound),
        (.invalidRequest, .invalidArgument),
        (.invalidRootConfiguration, .internal),
    ]

    for (failure, expectedCode) in cases {
        let error = SharedFolderRequestAdapter.guestError(for: failure)
        #expect(error.code == expectedCode)
        #expect(error.detail["integration_code"] == failure.code)
        #expect(!error.message.contains("customer"))
        #expect(!error.message.contains("private"))
    }
}

@Test func sharedFolderRequestAdapterEnforcesPackagePolicyAndProtocolErrors() async throws {
    let fixture = try SharedFolderFixture()
    defer { Task { await fixture.stop() } }
    try Data("read-only".utf8).write(to: fixture.root.appendingPathComponent("source.txt"))
    let handler = SharedFolderRequestAdapter(service: fixture.service).makeHandler()

    let unspecifiedModeResponse = await handler(
        request {
            var operation = GPHostOpenFile()
            operation.package = "org.example.app"
            operation.rootID = "shared"
            operation.path = "source.txt"
            operation.mode = .unspecified
            return .hostOpenFile(operation)
        })
    #expect(guestErrorCode(unspecifiedModeResponse) == .invalidArgument)

    let outsideRootResponse = await handler(
        request {
            var operation = GPHostStat()
            operation.package = "org.example.app"
            operation.rootID = "shared"
            operation.path = "../source.txt"
            return .hostStat(operation)
        })
    #expect(guestErrorCode(outsideRootResponse) == .permissionDenied)

    let deniedPackageResponse = await handler(
        request {
            var operation = GPHostStat()
            operation.package = "org.example.unapproved"
            operation.rootID = "shared"
            operation.path = "source.txt"
            return .hostStat(operation)
        })
    #expect(guestErrorCode(deniedPackageResponse) == .permissionDenied)

    let readOnlyWriteResponse = await handler(
        request {
            var operation = GPHostOpenFile()
            operation.package = "org.example.readonly"
            operation.rootID = "shared"
            operation.path = "source.txt"
            operation.mode = .write
            return .hostOpenFile(operation)
        })
    #expect(guestErrorCode(readOnlyWriteResponse) == .permissionDenied)

    let readOnlyCreateResponse = await handler(
        request {
            var operation = GPHostCreateDocument()
            operation.package = "org.example.readonly"
            operation.rootID = "shared"
            operation.name = "read-only-created.txt"
            return .hostCreateDocument(operation)
        })
    #expect(guestErrorCode(readOnlyCreateResponse) == .permissionDenied)

    let deniedPickerWriteResponse = await handler(
        request {
            var operation = GPHostCreateDocument()
            operation.package = "com.android.documentsui"
            operation.rootID = "shared"
            operation.name = "picker-created.txt"
            return .hostCreateDocument(operation)
        })
    #expect(guestErrorCode(deniedPickerWriteResponse) == .permissionDenied)

    let missingItemResponse = await handler(
        request {
            var operation = GPHostStat()
            operation.package = "org.example.app"
            operation.rootID = "shared"
            operation.path = "missing.txt"
            return .hostStat(operation)
        })
    #expect(guestErrorCode(missingItemResponse) == .notFound)

    let unknownHandleResponse = await handler(
        request {
            var operation = GPHostReadRange()
            operation.handle = 9_999
            operation.length = 1
            return .hostReadRange(operation)
        })
    #expect(guestErrorCode(unknownHandleResponse) == .permissionDenied)

    var unrelated = GPRequest()
    unrelated.ping = GPPing()
    let unsupportedResponse = await handler(unrelated)
    let missingOperationResponse = await handler(GPRequest())
    #expect(guestErrorCode(unsupportedResponse) == .unsupported)
    #expect(guestErrorCode(missingOperationResponse) == .invalidArgument)
}

@Test func sharedFolderRequestAdapterLimitsHandlesAndClosesThemWithConnection() async throws {
    let fixture = try SharedFolderFixture()
    defer { Task { await fixture.stop() } }
    try Data("handle".utf8).write(to: fixture.root.appendingPathComponent("source.txt"))
    let adapter = SharedFolderRequestAdapter(service: fixture.service)
    let handler = adapter.makeHandler()

    var handles: [UInt64] = []
    for _ in 0..<SharedFolderService.maximumOpenHandlesPerPackage {
        let response = await handler(openRequest(package: "org.example.app"))
        guard case .hostOpenFile(let opened)? = response.result else {
            Issue.record("A permitted open did not return a handle.")
            return
        }
        handles.append(opened.handle)
    }
    #expect(handles.count == SharedFolderService.maximumOpenHandlesPerPackage)

    let overflowResponse = await handler(openRequest(package: "org.example.app"))
    #expect(guestErrorCode(overflowResponse) == .resourceExhausted)

    let otherConnection = SharedFolderRequestAdapter(service: fixture.service)
    let foreignHandleResponse = await otherConnection.handle(readRequest(handle: handles[0]))
    #expect(guestErrorCode(foreignHandleResponse) == .permissionDenied)

    await adapter.closeConnection()
    let closedHandleResponse = await handler(readRequest(handle: handles[0]))
    #expect(guestErrorCode(closedHandleResponse) == .failedPrecondition)
    let foreignCloseResponse = await otherConnection.handle(closeRequest(handle: handles[0]))
    #expect(guestErrorCode(foreignCloseResponse) == .permissionDenied)
    await otherConnection.closeConnection()
}

private struct SharedFolderFixture {
    let root: URL
    let service: SharedFolderService

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("apkrun-shared-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = try SharedFolderService(
            roots: [
                SharedFolderRoot(
                    id: "shared",
                    title: "Shared",
                    directoryURL: root,
                    maximumAccess: .readWrite
                )
            ],
            packageAccess: [
                "org.example.app": ["shared": .readWrite],
                "org.example.readonly": ["shared": .readOnly],
            ]
        )
    }

    func stop() async {
        await service.runtimeDidStop()
        try? FileManager.default.removeItem(at: root)
    }
}

private func request(_ operation: () -> GPRequest.OneOf_Op) -> GPRequest {
    var result = GPRequest()
    result.op = operation()
    return result
}

private func openRequest(package: String, mode: GPOpenMode = .read) -> GPRequest {
    request {
        var operation = GPHostOpenFile()
        operation.package = package
        operation.rootID = "shared"
        operation.path = "source.txt"
        operation.mode = mode
        return .hostOpenFile(operation)
    }
}

private func readRequest(handle: UInt64) -> GPRequest {
    request {
        var operation = GPHostReadRange()
        operation.handle = handle
        operation.length = 1
        return .hostReadRange(operation)
    }
}

private func closeRequest(handle: UInt64) -> GPRequest {
    request {
        var operation = GPHostCloseFile()
        operation.handle = handle
        return .hostCloseFile(operation)
    }
}

private func guestErrorCode(_ response: GPResponse) -> GPGuestErrorCode? {
    guard case .error(let error)? = response.result else { return nil }
    return error.code
}

private func isEmptyResult(
    _ response: GPResponse,
    expected: EmptyOperation
) -> Bool {
    switch (expected, response.result) {
    case (.hostWriteRange, .hostWriteRange), (.hostCloseFile, .hostCloseFile),
        (.hostDeleteDocument, .hostDeleteDocument):
        true
    default:
        false
    }
}

private enum EmptyOperation {
    case hostWriteRange
    case hostCloseFile
    case hostDeleteDocument
}
