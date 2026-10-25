@preconcurrency import Foundation
import RuntimeAPI

/// Sends file drops over the authenticated XPC connection bound to one app session.
///
/// The endpoint is created for one session by the daemon and must be obtained from the session
/// launch flow. This client does not accept a session identifier; the endpoint supplies that
/// binding on the daemon side.
public final class RuntimeSessionClient: @unchecked Sendable {
    private let clientKind: RuntimeClientKind
    private let channel: any RuntimeSessionChannel
    private let exportOfferReceiver: RuntimeSessionExportReceiver

    /// Connects to a session endpoint using the current signed APKRun process identity.
    public init(
        endpoint: NSXPCListenerEndpoint,
        clientKind: RuntimeClientKind = .wrapper,
        claimedIdentity: String? = nil,
        onExportOffer: (@Sendable (ExportOffer) -> Void)? = nil
    ) throws(RuntimeControlClientError) {
        guard clientKind == .wrapper else {
            throw .invalidClientIdentity
        }
        let configuration = try RuntimeControlClientConfiguration.current(
            clientKind: clientKind,
            claimedIdentity: claimedIdentity
        )
        let exportOfferReceiver = RuntimeSessionExportReceiver(onOffer: onExportOffer)
        let channel = try XPCSessionChannel(
            endpoint: endpoint,
            daemonSigningRequirement: configuration.daemonCodeSigningRequirement
        )
        self.clientKind = configuration.clientKind
        self.channel = channel
        self.exportOfferReceiver = exportOfferReceiver
        channel.installExportOfferReceiver(exportOfferReceiver)
    }

    init(
        clientKind: RuntimeClientKind,
        channel: any RuntimeSessionChannel,
        onExportOffer: (@Sendable (ExportOffer) -> Void)? = nil
    ) {
        let exportOfferReceiver = RuntimeSessionExportReceiver(onOffer: onExportOffer)
        self.clientKind = clientKind
        self.channel = channel
        self.exportOfferReceiver = exportOfferReceiver
        channel.installExportOfferReceiver(exportOfferReceiver)
    }

    /// Transfers files to the session represented by this endpoint.
    ///
    /// A transport failure is returned without replay because Android may already have received
    /// the files.
    public func importFiles(
        _ request: ImportFilesRequest,
        files: [FileHandle]
    ) async throws(RuntimeControlClientError) -> ImportResult {
        do {
            let sessionRequest = RuntimeImportFilesSessionRequest(
                header: APIRequestHeader(clientKind: clientKind),
                request: request
            )
            let data: Data
            do {
                data = try JSONEncoder().encode(sessionRequest)
            } catch {
                throw RuntimeControlClientError.encodingFailure
            }
            let response = try await channel.importFiles(data, files: files)
            let reply: RuntimeImportFilesSessionReply
            do {
                reply = try JSONDecoder().decode(RuntimeImportFilesSessionReply.self, from: response)
            } catch {
                throw RuntimeControlClientError.malformedReply
            }
            guard (reply.result != nil) != (reply.error != nil) else {
                throw RuntimeControlClientError.malformedReply
            }
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(code: failure.code, message: failure.message)
            }
            guard let result = reply.result else {
                throw RuntimeControlClientError.malformedReply
            }
            return result
        } catch let error as RuntimeControlClientError {
            throw error
        } catch {
            let error = error as NSError
            throw .transportFailure(domain: error.domain, code: error.code)
        }
    }

    /// Accepts an Android file offer, or cancels it when `destination` is nil.
    ///
    /// The endpoint binds the operation to its app session. A transport failure is returned
    /// without replay because the daemon may already be writing to the destination.
    public func acceptExport(
        offerID: UUID,
        destination: FileHandle?
    ) async throws(RuntimeControlClientError) {
        do {
            let request = AcceptExportRequest(offerID: offerID, fileIndex: destination == nil ? nil : 0)
            let sessionRequest = RuntimeAcceptExportSessionRequest(
                header: APIRequestHeader(clientKind: clientKind),
                request: request
            )
            let data: Data
            do {
                data = try JSONEncoder().encode(sessionRequest)
            } catch {
                throw RuntimeControlClientError.encodingFailure
            }
            let response = try await channel.acceptExport(data, file: destination)
            let reply: RuntimeAcceptExportSessionReply
            do {
                reply = try JSONDecoder().decode(RuntimeAcceptExportSessionReply.self, from: response)
            } catch {
                throw RuntimeControlClientError.malformedReply
            }
            guard (reply.result != nil) != (reply.error != nil) else {
                throw RuntimeControlClientError.malformedReply
            }
            if let failure = reply.error {
                throw RuntimeControlClientError.remoteFailure(code: failure.code, message: failure.message)
            }
        } catch let error as RuntimeControlClientError {
            throw error
        } catch {
            let error = error as NSError
            throw .transportFailure(domain: error.domain, code: error.code)
        }
    }

    /// Invalidates the session connection.
    public func invalidate() {
        channel.invalidate()
    }
}

protocol RuntimeSessionChannel: Sendable {
    func importFiles(_ request: Data, files: [FileHandle]) async throws(RuntimeControlClientError) -> Data
    func acceptExport(_ request: Data, file: FileHandle?) async throws(RuntimeControlClientError) -> Data
    func installExportOfferReceiver(_ receiver: RuntimeSessionExportReceiver)
    func invalidate()
}

/// Decodes and validates export offers before handing them to wrapper code.
final class RuntimeSessionExportReceiver: NSObject, RuntimeSessionExportSink, @unchecked Sendable {
    private let onOffer: (@Sendable (ExportOffer) -> Void)?

    init(onOffer: (@Sendable (ExportOffer) -> Void)?) {
        self.onOffer = onOffer
    }

    func exportOffered(_ data: Data, reply: @escaping (Bool) -> Void) {
        guard let onOffer,
            let offer = try? JSONDecoder().decode(ExportOffer.self, from: data),
            Self.isValid(offer)
        else {
            reply(false)
            return
        }
        onOffer(offer)
        reply(true)
    }

    private static func isValid(_ offer: ExportOffer) -> Bool {
        let name = offer.name
        guard !name.isEmpty,
            name.utf8.count <= 255,
            name == name.trimmingCharacters(in: .whitespacesAndNewlines),
            name != ".",
            name != "..",
            !name.contains("/"),
            !name.contains("\\"),
            !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            offer.size.map({ $0 >= 0 }) ?? true
        else {
            return false
        }

        let mimeType = offer.type
        let components = mimeType.split(separator: "/", omittingEmptySubsequences: false)
        return mimeType.utf8.count <= 255
            && components.count == 2
            && components.allSatisfy { !$0.isEmpty }
            && !mimeType.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0)
                    || CharacterSet.controlCharacters.contains($0)
            })
    }
}

private final class XPCSessionChannel: RuntimeSessionChannel, @unchecked Sendable {
    private let connection: NSXPCConnection

    init(endpoint: NSXPCListenerEndpoint, daemonSigningRequirement: String) throws(RuntimeControlClientError) {
        let interface = NSXPCInterface(with: RuntimeSessionXPC.self)
        guard let fileHandleClasses = NSSet(array: [NSArray.self, FileHandle.self]) as? Set<AnyHashable> else {
            throw .invalidXPCInterface
        }
        interface.setClasses(
            fileHandleClasses,
            for: #selector(RuntimeSessionXPC.importFiles(_:files:reply:)),
            argumentIndex: 1,
            ofReply: false
        )
        interface.setClasses(
            fileHandleClasses,
            for: #selector(RuntimeSessionXPC.acceptExport(_:file:reply:)),
            argumentIndex: 1,
            ofReply: false
        )
        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = interface
        connection.setCodeSigningRequirement(daemonSigningRequirement)
        self.connection = connection
    }

    func importFiles(_ request: Data, files: [FileHandle]) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    let error = error as NSError
                    finish(.failure(.transportFailure(domain: error.domain, code: error.code)))
                } as? any RuntimeSessionXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.importFiles(request, files: files) { response in
                finish(.success(response))
            }
        }
    }

    func acceptExport(_ request: Data, file: FileHandle?) async throws(RuntimeControlClientError) -> Data {
        try await withXPCReply { finish in
            let proxy =
                connection.remoteObjectProxyWithErrorHandler { error in
                    let error = error as NSError
                    finish(.failure(.transportFailure(domain: error.domain, code: error.code)))
                } as? any RuntimeSessionXPC
            guard let proxy else {
                finish(.failure(.invalidRemoteProxy))
                return
            }
            proxy.acceptExport(request, file: file) { response in
                finish(.success(response))
            }
        }
    }

    func installExportOfferReceiver(_ receiver: RuntimeSessionExportReceiver) {
        connection.exportedInterface = NSXPCInterface(with: RuntimeSessionExportSink.self)
        connection.exportedObject = receiver
        connection.resume()
    }

    func invalidate() {
        connection.invalidate()
    }
}
