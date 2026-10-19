import DiagnosticsCore
@preconcurrency import Foundation
import RuntimeAPI
import RuntimeCore

#if canImport(Security)
    import Security
#endif

private let runtimeAPIVersion = APIVersion.current

/// Errors that prevent the daemon from establishing a protected XPC endpoint.
public enum RuntimeXPCServerError: Error, Equatable, Sendable {
    /// The embedded app bundle or a required client executable is unavailable.
    case incompleteAppBundle
    /// The daemon's embedded build identity is unsupported or inconsistent.
    case unsupportedBuildIdentity
    /// The running daemon has no usable signing identity.
    case daemonSignatureUnavailable
    /// A required client executable does not match its expected code identity.
    case clientSignatureUnavailable(RuntimeClientKind)
    /// Security.framework could not parse a generated code-signing requirement.
    case invalidCodeRequirement
    /// The server was asked to start more than once.
    case alreadyStarted
    /// The server was already invalidated.
    case invalidated
}

/// The authenticated broker and transitional runtime-control XPC listeners.
///
/// The public Mach service exposes only identity/version discovery and endpoint
/// brokerage. Each control listener is anonymous and bound to one official
/// client executable's code requirement before its endpoint is returned.
public final class RuntimeXPCServer: @unchecked Sendable {
    private struct ControlListener {
        let listener: NSXPCListener
        let delegate: ControlListenerDelegate
    }

    /// The LaunchAgent Mach service exposed by this server.
    public let machServiceName: String

    private let brokerListener: NSXPCListener
    private let brokerDelegate: BrokerListenerDelegate
    private let controlListeners: [String: ControlListener]
    private let connectionRegistry: RuntimeXPCConnectionRegistry
    private let startLock = NSLock()
    private var hasStarted = false
    private var hasInvalidated = false

    /// Prepares protected endpoint listeners for every APKRun control client.
    ///
    /// `appBundleURL` must be the outer APKRun.app containing apkrund, APKRun,
    /// the menu bar app, the CLI, and APKRunLauncher.
    public init(
        host: RuntimeHost,
        appBundleURL: URL,
        buildInfo: BuildInfo = .current
    ) throws {
        let identity = try RuntimeXPCServerIdentity(buildInfo: buildInfo)
        guard Self.isExpectedAppBundle(appBundleURL, identifier: identity.appIdentifier) else {
            throw RuntimeXPCServerError.incompleteAppBundle
        }
        let daemonTeamIdentifier = try CodeRequirementFactory.daemonTeamIdentifier(
            expectedIdentifier: identity.daemonIdentifier,
            requireTeamIdentifier: buildInfo.configuration == .release
        )

        var requirements: [(kind: RuntimeClientKind, requirement: String)] = []
        for kind in RuntimeClientKind.controlClients {
            let identifier = identity.clientIdentifier(for: kind)
            let executableURL = identity.executableURL(for: kind, in: appBundleURL)
            let requirement = try CodeRequirementFactory.requirement(
                for: executableURL,
                kind: kind,
                expectedIdentifier: identifier,
                configuration: buildInfo.configuration,
                daemonTeamIdentifier: daemonTeamIdentifier
            )
            requirements.append((kind, requirement))
        }

        var listeners: [String: ControlListener] = [:]
        var endpoints: [String: NSXPCListenerEndpoint] = [:]
        let connectionRegistry = RuntimeXPCConnectionRegistry()
        for item in requirements {
            let delegate = ControlListenerDelegate(
                host: host,
                clientKind: item.kind,
                connectionRegistry: connectionRegistry
            )
            let listener = NSXPCListener.anonymous()
            listener.setConnectionCodeSigningRequirement(item.requirement)
            listener.delegate = delegate
            listener.resume()
            listeners[item.kind.rawValue] = ControlListener(listener: listener, delegate: delegate)
            endpoints[item.kind.rawValue] = listener.endpoint
        }

        let brokerDelegate = BrokerListenerDelegate(
            host: host,
            buildInfo: buildInfo,
            endpoints: endpoints,
            connectionRegistry: connectionRegistry
        )
        let brokerListener = NSXPCListener(machServiceName: identity.machServiceName)
        brokerListener.delegate = brokerDelegate

        machServiceName = identity.machServiceName
        self.brokerListener = brokerListener
        self.brokerDelegate = brokerDelegate
        controlListeners = listeners
        self.connectionRegistry = connectionRegistry
    }

    private static func isExpectedAppBundle(_ url: URL, identifier: String) -> Bool {
        guard url.isFileURL, url.pathExtension == "app" else { return false }
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
            let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let info = propertyList as? [String: Any]
        else {
            return false
        }
        return info["CFBundleIdentifier"] as? String == identifier
    }

    /// Publishes the broker under its LaunchAgent Mach service name.
    public func start() throws {
        startLock.lock()
        defer { startLock.unlock() }
        guard !hasInvalidated else {
            throw RuntimeXPCServerError.invalidated
        }
        guard !hasStarted else {
            throw RuntimeXPCServerError.alreadyStarted
        }
        brokerListener.resume()
        hasStarted = true
    }

    /// Stops accepting new broker and control connections.
    public func invalidate() {
        startLock.lock()
        guard !hasInvalidated else {
            startLock.unlock()
            return
        }
        hasInvalidated = true
        hasStarted = false
        startLock.unlock()

        connectionRegistry.close()
        invalidateListeners()
    }

    /// Rejects new connections while allowing accepted requests to finish during shutdown.
    public func stopAcceptingNewConnections() {
        startLock.lock()
        guard !hasInvalidated else {
            startLock.unlock()
            return
        }
        connectionRegistry.stopAcceptingNewConnections()
        startLock.unlock()
    }

    /// Waits for XPC calls admitted before shutdown to send their replies.
    public func waitForPendingRequestsToDrain() async {
        await connectionRegistry.waitForRequestsToDrain()
    }

    /// Stops the daemon listeners only when both the runtime and XPC clients have stayed idle.
    public func invalidateIfIdle(for gracePeriod: Duration) -> Bool {
        startLock.lock()
        guard !hasInvalidated,
            connectionRegistry.closeIfIdle(for: gracePeriod)
        else {
            startLock.unlock()
            return false
        }
        hasInvalidated = true
        hasStarted = false
        startLock.unlock()

        invalidateListeners()
        return true
    }

    private func invalidateListeners() {
        brokerListener.invalidate()
        for listener in controlListeners.values {
            listener.listener.invalidate()
        }
    }

    /// Whether the stopped runtime has had no connected clients for the requested grace period.
    public func isIdle(for gracePeriod: Duration) -> Bool {
        connectionRegistry.isIdle(for: gracePeriod)
    }
}

private final class RuntimeXPCConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NSXPCConnection] = [:]
    private var acceptingNewConnections = true
    private var acceptingLifecycleRequests = true
    private var acceptingReadOnlyRequests = true
    private var isDrainingRequests = false
    private var closed = false
    private var lastActivity = ContinuousClock.now
    private var activeRequests = 0
    private var requestDrainWaiters: [CheckedContinuation<Void, Never>] = []

    func register(_ connection: NSXPCConnection) -> Bool {
        let identifier = ObjectIdentifier(connection)
        lock.lock()
        guard acceptingNewConnections, !closed else {
            lock.unlock()
            return false
        }
        connections[identifier] = connection
        lastActivity = ContinuousClock.now
        lock.unlock()

        connection.invalidationHandler = { [weak self] in
            self?.remove(identifier)
        }
        return true
    }

    func stopAcceptingNewConnections() {
        lock.lock()
        acceptingNewConnections = false
        acceptingLifecycleRequests = false
        lock.unlock()
    }

    func beginRequest(allowDuringShutdown: Bool = false) -> RuntimeXPCRequest? {
        lock.lock()
        let isAdmitted =
            !closed
            && !isDrainingRequests
            && (acceptingLifecycleRequests || (allowDuringShutdown && acceptingReadOnlyRequests))
        guard isAdmitted else {
            lock.unlock()
            return nil
        }
        activeRequests += 1
        lock.unlock()
        return RuntimeXPCRequest(registry: self)
    }

    func waitForRequestsToDrain() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            isDrainingRequests = true
            acceptingReadOnlyRequests = false
            guard activeRequests > 0 else {
                lock.unlock()
                continuation.resume()
                return
            }
            requestDrainWaiters.append(continuation)
            lock.unlock()
        }
    }

    fileprivate func endRequest() {
        lock.lock()
        activeRequests -= 1
        let waiters: [CheckedContinuation<Void, Never>]
        if activeRequests == 0, isDrainingRequests {
            waiters = requestDrainWaiters
            requestDrainWaiters.removeAll()
        } else {
            waiters = []
        }
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func close() {
        lock.lock()
        closed = true
        let connections = Array(self.connections.values)
        self.connections.removeAll()
        lastActivity = ContinuousClock.now
        lock.unlock()
        for connection in connections {
            connection.invalidate()
        }
    }

    func closeIfIdle(for gracePeriod: Duration) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed,
            connections.isEmpty,
            activeRequests == 0,
            lastActivity.duration(to: ContinuousClock.now) >= gracePeriod
        else {
            return false
        }
        closed = true
        lastActivity = ContinuousClock.now
        return true
    }

    func isIdle(for gracePeriod: Duration) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, connections.isEmpty, activeRequests == 0 else { return false }
        return lastActivity.duration(to: ContinuousClock.now) >= gracePeriod
    }

    private func remove(_ identifier: ObjectIdentifier) {
        lock.lock()
        if connections.removeValue(forKey: identifier) != nil {
            lastActivity = ContinuousClock.now
        }
        lock.unlock()
    }
}

private final class RuntimeXPCRequest: @unchecked Sendable {
    private let registry: RuntimeXPCConnectionRegistry
    private let lock = NSLock()
    private var isFinished = false

    init(registry: RuntimeXPCConnectionRegistry) {
        self.registry = registry
    }

    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        lock.unlock()
        registry.endRequest()
    }

    deinit {
        finish()
    }
}

extension RuntimeClientKind {
    fileprivate static let controlClients: [RuntimeClientKind] = [.app, .menuBar, .cli, .launcher]
}

private struct RuntimeXPCServerIdentity {
    let machServiceName: String
    let daemonIdentifier: String
    let appIdentifier: String
    let suffix: String

    init(buildInfo: BuildInfo) throws {
        switch (buildInfo.configuration, buildInfo.buildIdentity) {
        case (.debug, "dev"):
            suffix = ".dev"
            machServiceName = "io.apkrun.apkrund.dev.xpc"
        case (.release, "release"):
            suffix = ""
            machServiceName = "io.apkrun.apkrund.xpc"
        case (.release, "updatetest"):
            suffix = ".updatetest"
            machServiceName = "io.apkrun.apkrund.updatetest.xpc"
        default:
            throw RuntimeXPCServerError.unsupportedBuildIdentity
        }
        daemonIdentifier = "io.apkrun.apkrund\(suffix)"
        appIdentifier = "io.apkrun.APKRun\(suffix)"
    }

    func clientIdentifier(for kind: RuntimeClientKind) -> String {
        return switch kind {
        case .app: "io.apkrun.APKRun\(suffix)"
        case .menuBar: "io.apkrun.APKRunMenuBar\(suffix)"
        case .cli: "io.apkrun.cli\(suffix)"
        case .launcher: "io.apkrun.APKRunLauncher\(suffix)"
        case .wrapper: ""
        }
    }

    func executableURL(for kind: RuntimeClientKind, in appBundleURL: URL) -> URL {
        let contents = appBundleURL.appendingPathComponent("Contents", isDirectory: true)
        return switch kind {
        case .app:
            contents.appendingPathComponent("MacOS/APKRun")
        case .menuBar:
            contents.appendingPathComponent(
                "Library/LoginItems/APKRunMenuBar.app/Contents/MacOS/APKRunMenuBar"
            )
        case .cli:
            contents.appendingPathComponent("Resources/bin/apkrun")
        case .launcher:
            contents.appendingPathComponent(
                "Helpers/APKRunLauncher.app/Contents/MacOS/APKRunLauncher"
            )
        case .wrapper:
            appBundleURL
        }
    }
}

private enum CodeRequirementFactory {
    static func daemonTeamIdentifier(
        expectedIdentifier: String,
        requireTeamIdentifier: Bool
    ) throws -> String? {
        #if canImport(Security)
            var selfCode: SecCode?
            guard SecCodeCopySelf(SecCSFlags(), &selfCode) == errSecSuccess,
                let selfCode,
                let staticCode = staticCode(for: selfCode),
                signatureIsValid(staticCode),
                let information = try? signingInformation(for: staticCode),
                information.identifier == expectedIdentifier
            else {
                throw RuntimeXPCServerError.daemonSignatureUnavailable
            }
            guard requireTeamIdentifier else { return information.teamIdentifier }
            guard let teamIdentifier = information.teamIdentifier,
                teamIdentifier.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil
            else {
                throw RuntimeXPCServerError.daemonSignatureUnavailable
            }
            let requirement = try makeRequirement(
                "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\" "
                    + "and identifier \"\(expectedIdentifier)\""
            )
            guard signatureIsValid(staticCode, requirement: requirement) else {
                throw RuntimeXPCServerError.daemonSignatureUnavailable
            }
            return teamIdentifier
        #else
            throw RuntimeXPCServerError.daemonSignatureUnavailable
        #endif
    }

    static func requirement(
        for executableURL: URL,
        kind: RuntimeClientKind,
        expectedIdentifier: String,
        configuration: BuildConfiguration,
        daemonTeamIdentifier: String?
    ) throws -> String {
        #if canImport(Security)
            guard !expectedIdentifier.isEmpty else {
                throw RuntimeXPCServerError.clientSignatureUnavailable(kind)
            }
            let isSymlink = (try? executableURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? true
            guard !isSymlink, FileManager.default.isExecutableFile(atPath: executableURL.path) else {
                throw RuntimeXPCServerError.incompleteAppBundle
            }
            guard
                let code = staticCode(at: executableURL),
                signatureIsValid(code),
                let information = try? signingInformation(for: code),
                information.identifier == expectedIdentifier
            else {
                throw RuntimeXPCServerError.clientSignatureUnavailable(kind)
            }

            let requirement: String
            switch configuration {
            case .release:
                guard let daemonTeamIdentifier else {
                    throw RuntimeXPCServerError.daemonSignatureUnavailable
                }
                guard information.teamIdentifier == daemonTeamIdentifier else {
                    throw RuntimeXPCServerError.clientSignatureUnavailable(kind)
                }
                requirement =
                    "anchor apple generic and certificate leaf[subject.OU] = \"\(daemonTeamIdentifier)\" "
                    + "and identifier \"\(expectedIdentifier)\""
            case .debug:
                guard let cdhash = information.cdhash else {
                    throw RuntimeXPCServerError.clientSignatureUnavailable(kind)
                }
                requirement = "cdhash H\"\(cdhash)\""
            }

            let parsedRequirement = try makeRequirement(requirement)
            guard signatureIsValid(code, requirement: parsedRequirement) else {
                throw RuntimeXPCServerError.clientSignatureUnavailable(kind)
            }
            return requirement
        #else
            throw RuntimeXPCServerError.clientSignatureUnavailable(kind)
        #endif
    }

    #if canImport(Security)
        private struct SigningInformation {
            let identifier: String?
            let teamIdentifier: String?
            let cdhash: String?
        }

        private static func staticCode(at url: URL) -> SecStaticCode? {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess else {
                return nil
            }
            return code
        }

        private static func staticCode(for code: SecCode) -> SecStaticCode? {
            var staticCode: SecStaticCode?
            guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess else {
                return nil
            }
            return staticCode
        }

        private static func signingInformation(for code: SecStaticCode) throws -> SigningInformation {
            var rawInformation: CFDictionary?
            guard
                SecCodeCopySigningInformation(
                    code,
                    SecCSFlags(rawValue: kSecCSSigningInformation),
                    &rawInformation
                ) == errSecSuccess,
                let rawInformation,
                let information = rawInformation as? [String: Any]
            else {
                throw RuntimeXPCServerError.daemonSignatureUnavailable
            }
            let unique = information[kSecCodeInfoUnique as String] as? Data
            return SigningInformation(
                identifier: information[kSecCodeInfoIdentifier as String] as? String,
                teamIdentifier: information[kSecCodeInfoTeamIdentifier as String] as? String,
                cdhash: unique?.map { String(format: "%02x", $0) }.joined()
            )
        }

        private static func makeRequirement(_ value: String) throws -> SecRequirement {
            var requirement: SecRequirement?
            guard
                SecRequirementCreateWithString(
                    value as CFString,
                    SecCSFlags(),
                    &requirement
                ) == errSecSuccess,
                let requirement
            else {
                throw RuntimeXPCServerError.invalidCodeRequirement
            }
            return requirement
        }

        private static func signatureIsValid(
            _ code: SecStaticCode,
            requirement: SecRequirement? = nil
        ) -> Bool {
            SecStaticCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
        }
    #endif
}

private final class BrokerListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let host: RuntimeHost
    private let buildInfo: BuildInfo
    private let endpoints: [String: NSXPCListenerEndpoint]
    private let connectionRegistry: RuntimeXPCConnectionRegistry

    init(
        host: RuntimeHost,
        buildInfo: BuildInfo,
        endpoints: [String: NSXPCListenerEndpoint],
        connectionRegistry: RuntimeXPCConnectionRegistry
    ) {
        self.host = host
        self.buildInfo = buildInfo
        self.endpoints = endpoints
        self.connectionRegistry = connectionRegistry
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connectionRegistry.register(connection) else { return false }
        let interface = NSXPCInterface(with: RuntimeBrokerXPC.self)
        guard let endpointClasses = NSSet(object: NSXPCListenerEndpoint.self) as? Set<AnyHashable> else {
            return false
        }
        interface.setClasses(
            endpointClasses,
            for: #selector(RuntimeBrokerXPC.requestEndpoint(_:reply:)),
            argumentIndex: 1,
            ofReply: true
        )
        connection.exportedInterface = interface
        connection.exportedObject = BrokerService(
            host: host,
            buildInfo: buildInfo,
            endpoints: endpoints,
            connectionRegistry: connectionRegistry
        )
        connection.resume()
        return true
    }
}

private final class BrokerService: NSObject, RuntimeBrokerXPC, @unchecked Sendable {
    private let host: RuntimeHost
    private let buildInfo: BuildInfo
    private let endpoints: [String: NSXPCListenerEndpoint]
    private let connectionRegistry: RuntimeXPCConnectionRegistry

    init(
        host: RuntimeHost,
        buildInfo: BuildInfo,
        endpoints: [String: NSXPCListenerEndpoint],
        connectionRegistry: RuntimeXPCConnectionRegistry
    ) {
        self.host = host
        self.buildInfo = buildInfo
        self.endpoints = endpoints
        self.connectionRegistry = connectionRegistry
    }

    func hello(_ request: Data, reply: @escaping (Data) -> Void) {
        let replyHandler = XPCDataReply(reply)
        guard let pending = connectionRegistry.beginRequest(allowDuringShutdown: true) else {
            replyHandler.send(Self.encodeBrokerError(code: "runtime.hostShuttingDown"))
            return
        }
        guard
            request.count <= Self.maximumRequestSize,
            let hello = try? JSONDecoder().decode(RuntimeHelloRequest.self, from: request),
            hello.apiVersion.major > 0,
            hello.apiVersion.minor >= 0,
            !hello.claimedIdentity.isEmpty,
            hello.claimedIdentity.utf8.count <= 255,
            (hello.clientVersion?.utf8.count ?? 0) <= 128,
            hello.clientBuild.map({ $0 >= 0 }) ?? true
        else {
            replyHandler.send(Self.encodeBrokerError(code: "runtime.malformedRequest"))
            pending.finish()
            return
        }

        Task {
            defer { pending.finish() }
            let status = await host.status()
            let version = Int(buildInfo.buildNumber) ?? 0
            let helloReply = RuntimeHelloReply(
                runtimeVersion: buildInfo.marketingVersion,
                runtimeBuild: version,
                apiVersion: runtimeAPIVersion,
                hostState: status.hostState
            )
            replyHandler.send(Self.encode(helloReply))
        }
    }

    func requestEndpoint(_ request: Data, reply: @escaping (Data, NSXPCListenerEndpoint?) -> Void) {
        guard let pending = connectionRegistry.beginRequest() else {
            reply(Self.encode(RuntimeEndpointReply.rejected(.hostShuttingDown)), nil)
            return
        }
        defer { pending.finish() }
        guard
            request.count <= Self.maximumRequestSize,
            let endpointRequest = try? JSONDecoder().decode(RuntimeEndpointRequest.self, from: request),
            endpointRequest.apiVersion.major > 0,
            endpointRequest.apiVersion.minor >= 0,
            endpointRequest.kind == .control,
            endpointRequest.apiVersion.major == runtimeAPIVersion.major,
            endpointRequest.apiVersion.minor <= runtimeAPIVersion.minor
        else {
            reply(Self.encode(RuntimeEndpointReply.rejected(.malformedRequest)), nil)
            return
        }

        guard
            let identifier = Self.expectedIdentifier(
                for: endpointRequest.clientKind,
                buildIdentity: buildInfo.buildIdentity
            ),
            endpointRequest.claimedIdentity == identifier,
            let endpoint = endpoints[endpointRequest.clientKind.rawValue]
        else {
            reply(Self.encode(RuntimeEndpointReply.rejected(.unknownClient)), nil)
            return
        }
        reply(Self.encode(RuntimeEndpointReply.granted), endpoint)
    }

    private static let maximumRequestSize = 16 * 1024

    private static func expectedIdentifier(
        for kind: RuntimeClientKind,
        buildIdentity: String
    ) -> String? {
        let suffix: String
        switch buildIdentity {
        case "dev": suffix = ".dev"
        case "release": suffix = ""
        case "updatetest": suffix = ".updatetest"
        default: return nil
        }
        return switch kind {
        case .app: "io.apkrun.APKRun\(suffix)"
        case .menuBar: "io.apkrun.APKRunMenuBar\(suffix)"
        case .cli: "io.apkrun.cli\(suffix)"
        case .launcher: "io.apkrun.APKRunLauncher\(suffix)"
        case .wrapper: nil
        }
    }

    private static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    private static func encodeBrokerError(code: String) -> Data {
        encode(BrokerErrorReply(error: RuntimeControlError(code: code, message: safeMessage(for: code))))
    }
}

private struct BrokerErrorReply: Codable {
    let error: RuntimeControlError
}

private final class ControlListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let host: RuntimeHost
    private let clientKind: RuntimeClientKind
    private let connectionRegistry: RuntimeXPCConnectionRegistry

    init(
        host: RuntimeHost,
        clientKind: RuntimeClientKind,
        connectionRegistry: RuntimeXPCConnectionRegistry
    ) {
        self.host = host
        self.clientKind = clientKind
        self.connectionRegistry = connectionRegistry
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connectionRegistry.register(connection) else { return false }
        connection.exportedInterface = NSXPCInterface(with: RuntimeControlXPC.self)
        connection.exportedObject = ControlService(
            host: host,
            clientKind: clientKind,
            connectionRegistry: connectionRegistry
        )
        connection.resume()
        return true
    }
}

private protocol VersionedControlRequest: Decodable {
    var header: APIRequestHeader { get }
}

extension RuntimeStatusRequest: VersionedControlRequest {}
extension StartRuntimeRequest: VersionedControlRequest {}
extension StopRuntimeRequest: VersionedControlRequest {}

private final class ControlService: NSObject, RuntimeControlXPC, @unchecked Sendable {
    private let host: RuntimeHost
    private let clientKind: RuntimeClientKind
    private let connectionRegistry: RuntimeXPCConnectionRegistry

    init(
        host: RuntimeHost,
        clientKind: RuntimeClientKind,
        connectionRegistry: RuntimeXPCConnectionRegistry
    ) {
        self.host = host
        self.clientKind = clientKind
        self.connectionRegistry = connectionRegistry
    }

    func runtimeStatus(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = XPCDataReply(reply)
        guard let pending = connectionRegistry.beginRequest(allowDuringShutdown: true) else {
            response.send(Self.errorReply(for: Self.hostShuttingDownError))
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(request, clientKind: clientKind, as: RuntimeStatusRequest.self) {
                response.send(Self.errorReply(for: failure))
                return
            }
            response.send(Self.encode(RuntimeControlReply(status: await host.status())))
        }
    }

    func startRuntime(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = XPCDataReply(reply)
        guard let pending = connectionRegistry.beginRequest() else {
            response.send(Self.errorReply(for: Self.hostShuttingDownError))
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(request, clientKind: clientKind, as: StartRuntimeRequest.self) {
                response.send(Self.errorReply(for: failure))
                return
            }
            do {
                try await host.startRuntime(reason: clientKind == .cli ? .cli : .user)
                response.send(Self.encode(RuntimeControlReply(status: await host.status())))
            } catch {
                response.send(Self.errorReply(for: Self.controlError(for: error)))
            }
        }
    }

    func stopRuntime(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = XPCDataReply(reply)
        guard let pending = connectionRegistry.beginRequest() else {
            response.send(Self.errorReply(for: Self.hostShuttingDownError))
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(request, clientKind: clientKind, as: StopRuntimeRequest.self) {
                response.send(Self.errorReply(for: failure))
                return
            }
            do {
                try await host.stopRuntime()
                response.send(Self.encode(RuntimeControlReply(status: await host.status())))
            } catch {
                response.send(Self.errorReply(for: Self.controlError(for: error)))
            }
        }
    }

    private static let maximumRequestSize = 1024 * 1024

    private static let hostShuttingDownError = RuntimeControlError(
        code: "runtime.hostShuttingDown",
        message: safeMessage(for: "runtime.hostShuttingDown")
    )

    private static func validate<Request: VersionedControlRequest>(
        _ data: Data,
        clientKind: RuntimeClientKind,
        as requestType: Request.Type
    ) -> RuntimeControlError? {
        guard data.count <= maximumRequestSize,
            let request = try? JSONDecoder().decode(requestType, from: data)
        else {
            return RuntimeControlError(
                code: "runtime.malformedRequest",
                message: "APKRun's background service couldn't read the request."
            )
        }
        guard request.header.apiVersion.major > 0, request.header.apiVersion.minor >= 0 else {
            return RuntimeControlError(
                code: "runtime.malformedRequest",
                message: "APKRun's background service couldn't read the request."
            )
        }
        guard request.header.apiVersion.major == runtimeAPIVersion.major,
            request.header.apiVersion.minor <= runtimeAPIVersion.minor
        else {
            return RuntimeControlError(
                code: "runtime.apiVersionMismatch",
                message: "APKRun needs to be restarted."
            )
        }
        guard request.header.clientKind == clientKind else {
            return RuntimeControlError(
                code: "runtime.notAuthorized",
                message: "This part of APKRun isn't allowed to do that."
            )
        }
        return nil
    }

    private static func controlError(for error: any Error) -> RuntimeControlError {
        let code: String
        if let hostError = error as? RuntimeHostError {
            switch hostError {
            case .notStarted:
                code = "runtime.serviceUnavailable"
            case .shuttingDown:
                code = "runtime.hostShuttingDown"
            case .alreadyStarted:
                code = "runtime.internal"
            case .startupFailed(_, let startupCode):
                code = startupCode.contains(".") ? startupCode : "runtime.hostStartupFailed"
            case .crashLoopActive, .stateStore:
                code = "runtime.hostStartupFailed"
            case .runtimeFailure(let failure):
                code = failure.qualifiedCode
            case .image(let failure):
                code = failure.qualifiedCode
            case .guestAgentBundle:
                code = "runtime.guestAgentBundleMissing"
            case .runtimeBoot(let failure):
                code = failure.qualifiedCode
            }
        } else {
            code = "runtime.internal"
        }
        return RuntimeControlError(code: code, message: safeMessage(for: code))
    }

    private static func errorReply(for error: RuntimeControlError) -> Data {
        return encode(RuntimeControlReply(error: error))
    }

    private static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }
}

private final class XPCDataReply: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Data) -> Void)?

    init(_ handler: @escaping (Data) -> Void) {
        self.handler = handler
    }

    func send(_ data: Data) {
        lock.lock()
        let handler = self.handler
        self.handler = nil
        lock.unlock()
        handler?(data)
    }
}

private func safeMessage(for code: String) -> String {
    switch code {
    case "runtime.apiVersionMismatch":
        "APKRun needs to be restarted."
    case "runtime.malformedRequest":
        "APKRun's background service couldn't read the request."
    case "runtime.notAuthorized":
        "This part of APKRun isn't allowed to do that."
    case "runtime.hostShuttingDown":
        "APKRun's background service is stopping. Try again in a moment."
    case "runtime.serviceUnavailable", "runtime.hostStartupFailed":
        "APKRun's background service isn't available."
    case "runtime.guestAgentBundleMissing":
        "APKRun's bundled Guest Agent is missing or invalid."
    default:
        "Something went wrong in APKRun's background service."
    }
}
