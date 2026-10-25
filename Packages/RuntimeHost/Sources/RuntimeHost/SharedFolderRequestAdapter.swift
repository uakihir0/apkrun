import Foundation
import GuestProtocol
import IntegrationCore

/// Routes one bulk-connection's shared-folder requests to the host policy service.
///
/// Each adapter belongs to one guest bulk connection. File handles are remembered only after
/// the service authorizes an open, so later range requests cannot choose a package themselves.
public actor SharedFolderRequestAdapter {
    private let service: SharedFolderService
    private let documentPickerPackageName: String
    private var packagesByHandle: [UInt64: String] = [:]
    private var isClosed = false

    /// Creates a handler for one guest bulk connection.
    public init(
        service: SharedFolderService,
        documentPickerPackageName: String = "com.android.documentsui"
    ) {
        self.service = service
        self.documentPickerPackageName = documentPickerPackageName
    }

    /// Returns the request closure expected by the bulk-channel connection.
    public nonisolated func makeHandler() -> @Sendable (GPRequest) async -> GPResponse {
        { [self] request in
            await handle(request)
        }
    }

    /// Handles one shared-folder request.
    public func handle(_ request: GPRequest) async -> GPResponse {
        guard !isClosed else {
            return Self.errorResponse(code: .failedPrecondition, message: "Shared-folder connection is closed.")
        }

        do {
            switch request.op {
            case .hostListRoots(let operation):
                let roots = try await service.listRoots(context: listingContext(package: operation.package))
                var result = GPRootList()
                result.roots = roots.map(Self.rootInfo)
                return Self.response(.hostListRoots(result))

            case .hostQueryChildren(let operation):
                let page = try await service.queryChildren(
                    context: listingContext(package: operation.package),
                    rootID: operation.rootID,
                    path: operation.path,
                    pageToken: operation.pageToken
                )
                var result = GPDocPage()
                result.entries = page.entries.map(Self.documentInfo)
                result.nextPageToken = page.nextPageToken
                return Self.response(.hostQueryChildren(result))

            case .hostStat(let operation):
                let entry = try await service.stat(
                    packageID: operation.package,
                    rootID: operation.rootID,
                    path: operation.path
                )
                return Self.response(.hostStat(Self.documentInfo(entry)))

            case .hostOpenFile(let operation):
                guard let mode = Self.openMode(operation.mode) else {
                    throw IntegrationFailure.invalidRequest
                }
                let opened = try await service.openFile(
                    packageID: operation.package,
                    rootID: operation.rootID,
                    path: operation.path,
                    mode: mode
                )
                guard !isClosed else {
                    try? await service.closeFile(packageID: operation.package, handle: opened.handle)
                    return Self.errorResponse(
                        code: .failedPrecondition,
                        message: "Shared-folder connection is closed."
                    )
                }
                packagesByHandle[opened.handle] = operation.package
                var result = GPOpenFile()
                result.handle = opened.handle
                result.size = opened.sizeBytes
                return Self.response(.hostOpenFile(result))

            case .hostReadRange(let operation):
                let packageID = try packageForHandle(operation.handle)
                let data = try await service.readRange(
                    packageID: packageID,
                    handle: operation.handle,
                    offset: operation.offset,
                    length: Int(operation.length)
                )
                var result = GPReadRangeResult()
                result.data = data
                return Self.response(.hostReadRange(result))

            case .hostWriteRange(let operation):
                let packageID = try packageForHandle(operation.handle)
                try await service.writeRange(
                    packageID: packageID,
                    handle: operation.handle,
                    offset: operation.offset,
                    data: operation.data
                )
                return Self.response(.hostWriteRange(GPEmpty()))

            case .hostCloseFile(let operation):
                let packageID = try packageForHandle(operation.handle)
                try await service.closeFile(
                    packageID: packageID,
                    handle: operation.handle,
                    synchronize: operation.fsync
                )
                packagesByHandle.removeValue(forKey: operation.handle)
                return Self.response(.hostCloseFile(GPEmpty()))

            case .hostCreateDocument(let operation):
                let entry = try await service.createDocument(
                    packageID: operation.package,
                    rootID: operation.rootID,
                    parentPath: operation.parentPath,
                    name: operation.name,
                    isDirectory: operation.isDir
                )
                return Self.response(.hostCreateDocument(Self.documentInfo(entry)))

            case .hostDeleteDocument(let operation):
                try await service.deleteDocument(
                    packageID: operation.package,
                    rootID: operation.rootID,
                    path: operation.path
                )
                return Self.response(.hostDeleteDocument(GPEmpty()))

            case .hostRenameDocument(let operation):
                let oldEntry = try await service.stat(
                    packageID: operation.package,
                    rootID: operation.rootID,
                    path: operation.path
                )
                try await service.renameDocument(
                    packageID: operation.package,
                    rootID: operation.rootID,
                    path: operation.path,
                    newName: operation.newName
                )
                var renamedEntry = Self.documentInfo(oldEntry)
                renamedEntry.path = Self.path(operation.path, replacingLastComponentWith: operation.newName)
                renamedEntry.name = operation.newName
                return Self.response(.hostRenameDocument(renamedEntry))

            case .none:
                return Self.errorResponse(code: .invalidArgument, message: "Shared-folder operation is missing.")

            default:
                return Self.errorResponse(code: .unsupported, message: "Unsupported shared-folder operation.")
            }
        } catch let failure as IntegrationFailure {
            return Self.errorResponse(for: failure)
        } catch {
            return Self.errorResponse(code: .internal, message: "The shared-folder operation failed.")
        }
    }

    /// Closes all handles owned by this connection.
    ///
    /// Calling this when the connection ends ensures an abandoned guest handle cannot keep a
    /// host descriptor alive. Handles are removed from local state before yielding to the service.
    public func closeConnection() async {
        guard !isClosed else { return }
        isClosed = true
        let openHandles = packagesByHandle
        packagesByHandle.removeAll()
        for (handle, packageID) in openHandles {
            try? await service.closeFile(packageID: packageID, handle: handle)
        }
    }

    /// Converts every IntegrationCore failure to the stable GuestError vocabulary.
    static func guestError(for failure: IntegrationFailure) -> GPGuestError {
        let code: GPGuestErrorCode
        let message: String
        switch failure {
        case .emptyFileSet:
            code = .invalidArgument
            message = "At least one file is required."
        case .filesDisabled:
            code = .unsupported
            message = "File integration is disabled."
        case .invalidFileHandle:
            code = .permissionDenied
            message = "The file handle is not authorized."
        case .invalidMetadata, .transferFailed, .invalidRootConfiguration:
            code = .internal
            message = "The shared-folder operation failed."
        case .tooManyFiles, .fileTooLarge, .invalidRequest:
            code = .invalidArgument
            message = "The shared-folder request is invalid."
        case .folderUnavailable:
            code = .unavailable
            message = "The shared folder is unavailable."
        case .pathRejected, .packageAccessDenied, .readOnly:
            code = .permissionDenied
            message = "The shared-folder request is not authorized."
        case .resourceExhausted:
            code = .resourceExhausted
            message = "The shared-folder service is at capacity."
        case .itemNotFound:
            code = .notFound
            message = "The shared-folder item was not found."
        }

        var result = GPGuestError()
        result.code = code
        result.message = message
        result.detail = ["integration_code": failure.code]
        return result
    }

    private func listingContext(package: String) -> SharedFolderListingContext {
        package == documentPickerPackageName ? .documentPicker : .package(package)
    }

    private func packageForHandle(_ handle: UInt64) throws(IntegrationFailure) -> String {
        guard let packageID = packagesByHandle[handle] else {
            throw .packageAccessDenied
        }
        return packageID
    }

    private static func response(_ result: GPResponse.OneOf_Result) -> GPResponse {
        var response = GPResponse()
        response.result = result
        return response
    }

    private static func errorResponse(for failure: IntegrationFailure) -> GPResponse {
        errorResponse(guestError(for: failure))
    }

    private static func errorResponse(code: GPGuestErrorCode, message: String) -> GPResponse {
        var error = GPGuestError()
        error.code = code
        error.message = message
        return errorResponse(error)
    }

    private static func errorResponse(_ error: GPGuestError) -> GPResponse {
        var response = GPResponse()
        response.error = error
        return response
    }

    private static func rootInfo(_ root: SharedFolderRootInfo) -> GPRootInfo {
        var result = GPRootInfo()
        result.rootID = root.id
        result.title = root.title
        switch root.access {
        case .off:
            result.access = .unspecified
        case .readOnly:
            result.access = .readOnly
        case .readWrite:
            result.access = .readWrite
        }
        result.available = root.isAvailable
        // SharedFolderService does not expose volume free-space data.
        result.bytesFree = 0
        return result
    }

    private static func documentInfo(_ entry: SharedFolderEntry) -> GPDocInfo {
        var result = GPDocInfo()
        result.path = entry.path
        result.name = entry.name
        result.isDir = entry.isDirectory
        result.size = entry.sizeBytes
        result.mtimeMs = entry.modificationTimeMilliseconds
        result.mimeType = entry.mimeType
        return result
    }

    private static func openMode(_ mode: GPOpenMode) -> SharedFolderOpenMode? {
        switch mode {
        case .read:
            .read
        case .write:
            .write
        case .readWrite:
            .readWrite
        case .truncate:
            .truncate
        case .unspecified, .UNRECOGNIZED:
            nil
        }
    }

    private static func path(_ originalPath: String, replacingLastComponentWith newName: String) -> String {
        guard let separator = originalPath.lastIndex(of: "/") else {
            return newName
        }
        return String(originalPath[...separator]) + newName
    }
}
