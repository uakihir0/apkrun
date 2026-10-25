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

    /// Connects to a session endpoint using the current signed APKRun process identity.
    public init(
        endpoint: NSXPCListenerEndpoint,
        clientKind: RuntimeClientKind = .wrapper,
        claimedIdentity: String? = nil
    ) throws(RuntimeControlClientError) {
        guard clientKind == .wrapper else {
            throw .invalidClientIdentity
        }
        let configuration = try RuntimeControlClientConfiguration.current(
            clientKind: clientKind,
            claimedIdentity: claimedIdentity
        )
        let channel = try XPCSessionChannel(
            endpoint: endpoint,
            daemonSigningRequirement: configuration.daemonCodeSigningRequirement
        )
        self.clientKind = configuration.clientKind
        self.channel = channel
    }

    init(clientKind: RuntimeClientKind, channel: any RuntimeSessionChannel) {
        self.clientKind = clientKind
        self.channel = channel
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

    /// Invalidates the session connection.
    public func invalidate() {
        channel.invalidate()
    }
}

protocol RuntimeSessionChannel: Sendable {
    func importFiles(_ request: Data, files: [FileHandle]) async throws(RuntimeControlClientError) -> Data
    func invalidate()
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
        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = interface
        connection.setCodeSigningRequirement(daemonSigningRequirement)
        connection.resume()
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

    func invalidate() {
        connection.invalidate()
    }
}
