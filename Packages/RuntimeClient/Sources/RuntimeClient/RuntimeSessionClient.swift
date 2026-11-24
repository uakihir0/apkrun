@preconcurrency import Foundation
import IOSurface
import RuntimeAPI

/// Events delivered by the private endpoint for one app session.
public enum RuntimeSessionEvent: @unchecked Sendable {
    /// One IOSurface in the current pool is ready to present.
    case frameReady(FrameReadyMessage)
    /// A complete new IOSurface pool replaced the prior generation.
    case surfacesReplaced(SurfacesReplacedMessage, surfaces: [IOSurface])
    /// The daemon invalidated the session endpoint.
    case invalidated
}

/// Sends file drops over the authenticated XPC connection bound to one app session.
///
/// The endpoint is created for one session by the daemon and must be obtained from the session
/// launch flow. This client does not accept a session identifier; the endpoint supplies that
/// binding on the daemon side.
public final class RuntimeSessionClient: @unchecked Sendable {
    private let clientKind: RuntimeClientKind
    private let channel: any RuntimeSessionChannel
    private let exportOfferReceiver: RuntimeSessionExportReceiver
    private let eventHub: RuntimeSessionEventHub

    /// The single-consumer event stream for frame presentation and remote invalidation.
    public let events: AsyncStream<RuntimeSessionEvent>

    /// Connects to a session endpoint using the current signed APKRun process identity.
    public init(
        endpoint: NSXPCListenerEndpoint,
        clientKind: RuntimeClientKind = .wrapper,
        claimedIdentity: String? = nil,
        onExportOffer: (@Sendable (ExportOffer) -> Void)? = nil
    ) throws(RuntimeControlClientError) {
        guard clientKind == .wrapper || clientKind == .launcher else {
            throw .invalidClientIdentity
        }
        let configuration = try RuntimeControlClientConfiguration.current(
            clientKind: clientKind,
            claimedIdentity: claimedIdentity
        )
        let eventHub = RuntimeSessionEventHub()
        let exportOfferReceiver = RuntimeSessionExportReceiver(onOffer: onExportOffer, eventHub: eventHub)
        let channel = try XPCSessionChannel(
            endpoint: endpoint,
            daemonSigningRequirement: configuration.daemonCodeSigningRequirement
        )
        self.clientKind = configuration.clientKind
        self.channel = channel
        self.exportOfferReceiver = exportOfferReceiver
        self.eventHub = eventHub
        events = eventHub.stream
        channel.setInvalidationHandler { [weak exportOfferReceiver] in
            exportOfferReceiver?.finish(notifyInvalidation: true)
        }
        channel.installExportOfferReceiver(exportOfferReceiver)
    }

    init(
        clientKind: RuntimeClientKind,
        channel: any RuntimeSessionChannel,
        onExportOffer: (@Sendable (ExportOffer) -> Void)? = nil
    ) {
        let eventHub = RuntimeSessionEventHub()
        let exportOfferReceiver = RuntimeSessionExportReceiver(onOffer: onExportOffer, eventHub: eventHub)
        self.clientKind = clientKind
        self.channel = channel
        self.exportOfferReceiver = exportOfferReceiver
        self.eventHub = eventHub
        events = eventHub.stream
        channel.setInvalidationHandler { [weak exportOfferReceiver] in
            exportOfferReceiver?.finish(notifyInvalidation: true)
        }
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

    /// Sends one ordered batch of translated window input to the guest.
    public func sendInput(_ batch: InputBatch) {
        guard let data = try? JSONEncoder().encode(batch) else {
            return
        }
        channel.sendInput(data)
    }

    /// Reports whether this session's native window is key.
    public func focusChanged(_ focused: Bool) {
        channel.focusChanged(focused)
    }

    /// Reports that Core Animation committed a frame to the window.
    ///
    /// The session endpoint is session-scoped, so no caller-supplied session ID is needed.
    public func frameDisplayed(_ message: FrameDisplayedMessage) {
        guard let data = try? JSONEncoder().encode(message) else {
            return
        }
        channel.frameDisplayed(data)
    }

    /// Reports whether the session window is visible.
    public func visibilityChanged(_ message: VisibilityChangedMessage) {
        guard let data = try? JSONEncoder().encode(message) else {
            return
        }
        channel.visibilityChanged(data)
    }

    /// Closes this session using its configured Android task policy unless `policy` is supplied.
    ///
    /// A transport failure is returned without replay because the daemon may already have finished
    /// the task and released the display.
    public func closeSession(policy: SessionClosePolicy? = nil) async throws(RuntimeControlClientError) {
        do {
            let request = RuntimeCloseSessionRequest(
                header: APIRequestHeader(clientKind: clientKind),
                request: CloseSessionRequest(policy: policy)
            )
            let data: Data
            do {
                data = try JSONEncoder().encode(request)
            } catch {
                throw RuntimeControlClientError.encodingFailure
            }
            let response = try await channel.closeSession(data)
            let reply: RuntimeCloseSessionReply
            do {
                reply = try JSONDecoder().decode(RuntimeCloseSessionReply.self, from: response)
            } catch {
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
        eventHub.finish(notifyInvalidation: false)
        channel.invalidate()
    }
}

protocol RuntimeSessionChannel: Sendable {
    func importFiles(_ request: Data, files: [FileHandle]) async throws(RuntimeControlClientError) -> Data
    func acceptExport(_ request: Data, file: FileHandle?) async throws(RuntimeControlClientError) -> Data
    func sendInput(_ batch: Data)
    func focusChanged(_ focused: Bool)
    func closeSession(_ request: Data) async throws(RuntimeControlClientError) -> Data
    func frameDisplayed(_ request: Data)
    func visibilityChanged(_ request: Data)
    func installExportOfferReceiver(_ receiver: RuntimeSessionExportReceiver)
    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void)
    func invalidate()
}

extension RuntimeSessionChannel {
    func sendInput(_ batch: Data) {}
    func focusChanged(_ focused: Bool) {}
    func closeSession(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        throw .invalidRemoteProxy
    }
    func frameDisplayed(_ request: Data) {}
    func visibilityChanged(_ request: Data) {}
    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {}
}

/// Bounded event delivery shared by the XPC receiver and its session client.
final class RuntimeSessionEventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<RuntimeSessionEvent>.Continuation?
    private var isFinished = false
    let stream: AsyncStream<RuntimeSessionEvent>

    init() {
        let pair = AsyncStream.makeStream(
            of: RuntimeSessionEvent.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    func yield(_ event: RuntimeSessionEvent) {
        lock.withLock {
            guard !isFinished else { return }
            continuation?.yield(event)
        }
    }

    func finish(notifyInvalidation: Bool) {
        lock.withLock {
            guard !isFinished else { return }
            if notifyInvalidation {
                continuation?.yield(.invalidated)
            }
            isFinished = true
            continuation?.finish()
            continuation = nil
        }
    }
}

/// Decodes and validates export offers before handing them to wrapper code.
final class RuntimeSessionExportReceiver: NSObject, RuntimeSessionClientSink, @unchecked Sendable {
    private let onOffer: (@Sendable (ExportOffer) -> Void)?
    private let eventHub: RuntimeSessionEventHub

    init(onOffer: (@Sendable (ExportOffer) -> Void)?, eventHub: RuntimeSessionEventHub) {
        self.onOffer = onOffer
        self.eventHub = eventHub
    }

    func frameReady(_ data: Data) {
        guard let message = try? JSONDecoder().decode(FrameReadyMessage.self, from: data),
            message.surfaceIndex >= 0
        else {
            return
        }
        eventHub.yield(.frameReady(message))
    }

    func surfacesReplaced(_ data: Data, surfaces: [IOSurface]) {
        guard let message = try? JSONDecoder().decode(SurfacesReplacedMessage.self, from: data),
            surfaces.count == SurfaceSet.surfaceCount,
            message.surfaceSet.pixelSize.width > 0,
            message.surfaceSet.pixelSize.height > 0,
            surfaces.allSatisfy({
                IOSurfaceGetWidth($0) == message.surfaceSet.pixelSize.width
                    && IOSurfaceGetHeight($0) == message.surfaceSet.pixelSize.height
            })
        else {
            return
        }
        eventHub.yield(.surfacesReplaced(message, surfaces: surfaces))
    }

    func finish(notifyInvalidation: Bool) {
        eventHub.finish(notifyInvalidation: notifyInvalidation)
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
    private var invalidationRelay: RuntimeSessionConnectionEventRelay?

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

    func sendInput(_ batch: Data) {
        let proxy =
            connection.remoteObjectProxyWithErrorHandler { _ in
                // Connection invalidation is observed separately; this one-way message has no reply.
            } as? any RuntimeSessionXPC
        proxy?.sendInput(batch)
    }

    func focusChanged(_ focused: Bool) {
        let proxy =
            connection.remoteObjectProxyWithErrorHandler { _ in
                // Connection invalidation is observed separately; this one-way message has no reply.
            } as? any RuntimeSessionXPC
        proxy?.focusChanged(focused)
    }

    func closeSession(_ request: Data) async throws(RuntimeControlClientError) -> Data {
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
            proxy.closeSession(request) { response in
                finish(.success(response))
            }
        }
    }

    func frameDisplayed(_ request: Data) {
        let proxy =
            connection.remoteObjectProxyWithErrorHandler { _ in
                // Connection invalidation is observed separately; this one-way message has no reply.
            } as? any RuntimeSessionXPC
        proxy?.frameDisplayed(request)
    }

    func visibilityChanged(_ request: Data) {
        let proxy =
            connection.remoteObjectProxyWithErrorHandler { _ in
                // Connection invalidation is observed separately; this one-way message has no reply.
            } as? any RuntimeSessionXPC
        proxy?.visibilityChanged(request)
    }

    func installExportOfferReceiver(_ receiver: RuntimeSessionExportReceiver) {
        let interface = NSXPCInterface(with: RuntimeSessionClientSink.self)
        guard let surfaceClasses = NSSet(array: [NSArray.self, IOSurface.self]) as? Set<AnyHashable> else {
            receiver.finish(notifyInvalidation: true)
            return
        }
        interface.setClasses(
            surfaceClasses,
            for: #selector(RuntimeSessionEventSink.surfacesReplaced(_:surfaces:)),
            argumentIndex: 1,
            ofReply: false
        )
        connection.exportedInterface = interface
        connection.exportedObject = receiver
        connection.resume()
    }

    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        let relay = RuntimeSessionConnectionEventRelay(handler)
        invalidationRelay = relay
        let callback: @Sendable () -> Void = { [relay] in relay.fire() }
        connection.interruptionHandler = callback
        connection.invalidationHandler = callback
    }

    func invalidate() {
        connection.invalidate()
    }
}

private final class RuntimeSessionConnectionEventRelay: @unchecked Sendable {
    private let handler: @Sendable () -> Void

    init(_ handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    func fire() {
        handler()
    }
}
