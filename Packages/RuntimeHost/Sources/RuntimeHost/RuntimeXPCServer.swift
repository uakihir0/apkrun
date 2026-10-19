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
/// brokerage. Each control grant gets a one-use anonymous listener bound to
/// that official client executable's code requirement.
public final class RuntimeXPCServer: @unchecked Sendable {
    /// The LaunchAgent Mach service exposed by this server.
    public let machServiceName: String

    private let brokerListener: NSXPCListener
    private let brokerDelegate: BrokerListenerDelegate
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

        var clientRequirements: [String: String] = [:]
        for item in requirements {
            clientRequirements[item.kind.rawValue] = item.requirement
        }

        let connectionRegistry = RuntimeXPCConnectionRegistry()
        let brokerDelegate = BrokerListenerDelegate(
            host: host,
            buildInfo: buildInfo,
            clientRequirements: clientRequirements,
            connectionRegistry: connectionRegistry
        )
        let brokerListener = NSXPCListener(machServiceName: identity.machServiceName)
        brokerListener.delegate = brokerDelegate

        machServiceName = identity.machServiceName
        self.brokerListener = brokerListener
        self.brokerDelegate = brokerDelegate
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
    }

    /// Whether the stopped runtime has had no connected clients for the requested grace period.
    public func isIdle(for gracePeriod: Duration) -> Bool {
        connectionRegistry.isIdle(for: gracePeriod)
    }
}

private enum RuntimeXPCConnectionKind: Equatable {
    case broker
    case control
}

private struct RuntimeXPCConnectionRecord {
    let connection: NSXPCConnection
    let kind: RuntimeXPCConnectionKind
    let controlListener: RuntimeXPCControlListener?
    var activeRequests = 0
}

private struct RuntimeXPCControlReservation {
    let brokerConnectionID: ObjectIdentifier
    let controlListener: RuntimeXPCControlListener
    let expiresAt: ContinuousClock.Instant
}

private final class RuntimeXPCControlListener: @unchecked Sendable {
    let listener: NSXPCListener
    let delegate: ControlListenerDelegate

    init(
        host: RuntimeHost,
        clientKind: RuntimeClientKind,
        requirement: String,
        reservationID: UUID,
        connectionRegistry: RuntimeXPCConnectionRegistry
    ) {
        delegate = ControlListenerDelegate(
            host: host,
            clientKind: clientKind,
            reservationID: reservationID,
            connectionRegistry: connectionRegistry
        )
        listener = NSXPCListener.anonymous()
        listener.setConnectionCodeSigningRequirement(requirement)
        listener.delegate = delegate
        listener.resume()
    }
}

private enum RuntimeXPCRequestRejection {
    case busy
    case hostShuttingDown

    var errorCode: String {
        switch self {
        case .busy: "runtime.busy"
        case .hostShuttingDown: "runtime.hostShuttingDown"
        }
    }

    var endpointRejection: RuntimeEndpointRejection {
        switch self {
        case .busy: .busy
        case .hostShuttingDown: .hostShuttingDown
        }
    }

    var wireError: RuntimeWireError {
        switch self {
        case .busy:
            .runtime(
                "busy",
                message: safeMessage(for: "runtime.busy"),
                remediation: "Try again when the other requests have finished."
            )
        case .hostShuttingDown:
            .runtime("hostShuttingDown", message: safeMessage(for: "runtime.hostShuttingDown"))
        }
    }

    var controlError: RuntimeControlError {
        RuntimeControlError(code: errorCode, message: safeMessage(for: errorCode))
    }
}

private enum RuntimeXPCRequestAdmission {
    case accepted(RuntimeXPCRequest)
    case rejected(RuntimeXPCRequestRejection)
}

private final class RuntimeXPCConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: RuntimeXPCConnectionRecord] = [:]
    private var acceptingNewConnections = true
    private var acceptingLifecycleRequests = true
    private var acceptingReadOnlyRequests = true
    private var isDrainingRequests = false
    private var closed = false
    private var reservedControlConnections: [String: [UUID: RuntimeXPCControlReservation]] = [:]
    private var lastActivity = ContinuousClock.now
    private var activeRequests = 0
    private var requestDrainWaiters: [CheckedContinuation<Void, Never>] = []

    func register(
        _ connection: NSXPCConnection,
        kind: RuntimeXPCConnectionKind,
        clientKind: RuntimeClientKind? = nil,
        reservationID: UUID? = nil
    ) -> Bool {
        let identifier = ObjectIdentifier(connection)
        lock.lock()
        expireControlReservations()
        let controlListener: RuntimeXPCControlListener?
        if kind == .control {
            guard let clientKind, let reservationID,
                let reservation = reservedControlConnections[clientKind.rawValue]?.removeValue(forKey: reservationID)
            else {
                lock.unlock()
                return false
            }
            controlListener = reservation.controlListener
        } else {
            controlListener = nil
        }
        let currentKindCount = connections.values.reduce(into: 0) { count, record in
            if record.kind == kind {
                count += 1
            }
        }
        let kindLimit = kind == .control ? 8 : 32
        guard acceptingNewConnections, !closed, currentKindCount < kindLimit else {
            controlListener?.listener.invalidate()
            lock.unlock()
            return false
        }
        connections[identifier] = RuntimeXPCConnectionRecord(
            connection: connection,
            kind: kind,
            controlListener: controlListener
        )
        lastActivity = ContinuousClock.now
        lock.unlock()

        connection.invalidationHandler = { [weak self] in
            self?.remove(identifier)
        }
        return true
    }

    func reserveControlConnection(
        for clientKind: RuntimeClientKind,
        on brokerConnectionID: ObjectIdentifier,
        reservationID: UUID,
        controlListener: RuntimeXPCControlListener
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        expireControlReservations()
        guard acceptingNewConnections, !closed else {
            return false
        }
        guard
            !reservedControlConnections.values.contains(where: { reservations in
                reservations.values.contains { $0.brokerConnectionID == brokerConnectionID }
            })
        else {
            return false
        }
        let reserved = reservedControlConnections.values.reduce(0) { $0 + $1.count }
        // Endpoint grants do not consume the eight live-control-connection slots. Bound their
        // temporary listener state by the independent broker-connection limit instead.
        guard reserved < 32 else {
            return false
        }
        reservedControlConnections[clientKind.rawValue, default: [:]][reservationID] = RuntimeXPCControlReservation(
            brokerConnectionID: brokerConnectionID,
            controlListener: controlListener,
            expiresAt: ContinuousClock.now.advanced(by: .seconds(5))
        )
        lastActivity = ContinuousClock.now
        return true
    }

    private func expireControlReservations() {
        let now = ContinuousClock.now
        for clientKind in Array(reservedControlConnections.keys) {
            guard let reservations = reservedControlConnections[clientKind] else {
                continue
            }
            for (reservationID, reservation) in reservations where reservation.expiresAt <= now {
                reservedControlConnections[clientKind]?.removeValue(forKey: reservationID)
                reservation.controlListener.listener.invalidate()
            }
            if reservedControlConnections[clientKind]?.isEmpty == true {
                reservedControlConnections[clientKind] = nil
            }
        }
    }

    func stopAcceptingNewConnections() {
        lock.lock()
        acceptingNewConnections = false
        acceptingLifecycleRequests = false
        lock.unlock()
    }

    func beginRequest(
        on connectionID: ObjectIdentifier,
        allowDuringShutdown: Bool = false
    ) -> RuntimeXPCRequestAdmission {
        lock.lock()
        let isAdmitted =
            !closed
            && !isDrainingRequests
            && (acceptingLifecycleRequests || (allowDuringShutdown && acceptingReadOnlyRequests))
        guard isAdmitted, var record = connections[connectionID] else {
            lock.unlock()
            return .rejected(.hostShuttingDown)
        }
        guard record.activeRequests < 64 else {
            lock.unlock()
            return .rejected(.busy)
        }
        record.activeRequests += 1
        connections[connectionID] = record
        activeRequests += 1
        lock.unlock()
        return .accepted(RuntimeXPCRequest(registry: self, connectionID: connectionID))
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

    fileprivate func endRequest(on connectionID: ObjectIdentifier) {
        lock.lock()
        activeRequests -= 1
        if var record = connections[connectionID] {
            record.activeRequests -= 1
            connections[connectionID] = record
        }
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
        let records = Array(self.connections.values)
        let reservedListeners = reservedControlConnections.values.flatMap { reservations in
            reservations.values.map(\.controlListener)
        }
        let connections = records.map(\.connection)
        self.connections.removeAll()
        reservedControlConnections.removeAll()
        lastActivity = ContinuousClock.now
        lock.unlock()
        for controlListener in records.compactMap(\.controlListener) + reservedListeners {
            controlListener.listener.invalidate()
        }
        for connection in connections {
            connection.invalidate()
        }
    }

    func closeIfIdle(for gracePeriod: Duration) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        expireControlReservations()
        guard !closed,
            connections.isEmpty,
            activeRequests == 0,
            reservedControlConnections.isEmpty,
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
        expireControlReservations()
        guard !closed, connections.isEmpty, activeRequests == 0, reservedControlConnections.isEmpty else {
            return false
        }
        return lastActivity.duration(to: ContinuousClock.now) >= gracePeriod
    }

    private func remove(_ identifier: ObjectIdentifier) {
        lock.lock()
        let record = connections.removeValue(forKey: identifier)
        if record != nil {
            lastActivity = ContinuousClock.now
        }
        lock.unlock()
        record?.controlListener?.listener.invalidate()
    }
}

private final class RuntimeXPCRequest: @unchecked Sendable {
    private let registry: RuntimeXPCConnectionRegistry
    private let connectionID: ObjectIdentifier
    private let lock = NSLock()
    private var isFinished = false

    init(registry: RuntimeXPCConnectionRegistry, connectionID: ObjectIdentifier) {
        self.registry = registry
        self.connectionID = connectionID
    }

    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        lock.unlock()
        registry.endRequest(on: connectionID)
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
    private let clientRequirements: [String: String]
    private let connectionRegistry: RuntimeXPCConnectionRegistry

    init(
        host: RuntimeHost,
        buildInfo: BuildInfo,
        clientRequirements: [String: String],
        connectionRegistry: RuntimeXPCConnectionRegistry
    ) {
        self.host = host
        self.buildInfo = buildInfo
        self.clientRequirements = clientRequirements
        self.connectionRegistry = connectionRegistry
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connectionRegistry.register(connection, kind: .broker) else { return false }
        let connectionID = ObjectIdentifier(connection)
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
            clientRequirements: clientRequirements,
            connectionRegistry: connectionRegistry,
            connectionID: connectionID
        )
        connection.resume()
        return true
    }
}

private final class BrokerService: NSObject, RuntimeBrokerXPC, @unchecked Sendable {
    private let host: RuntimeHost
    private let buildInfo: BuildInfo
    private let clientRequirements: [String: String]
    private let connectionRegistry: RuntimeXPCConnectionRegistry
    private let connectionID: ObjectIdentifier

    init(
        host: RuntimeHost,
        buildInfo: BuildInfo,
        clientRequirements: [String: String],
        connectionRegistry: RuntimeXPCConnectionRegistry,
        connectionID: ObjectIdentifier
    ) {
        self.host = host
        self.buildInfo = buildInfo
        self.clientRequirements = clientRequirements
        self.connectionRegistry = connectionRegistry
        self.connectionID = connectionID
    }

    func hello(_ request: Data, reply: @escaping (Data) -> Void) {
        let replyHandler = XPCDataReply(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID, allowDuringShutdown: true)
        guard case .accepted(let pending) = admission else {
            let rejection = Self.rejection(for: admission)
            replyHandler.send(Self.encodeBrokerError(code: rejection.errorCode))
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
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            let rejection = Self.rejection(for: admission)
            reply(
                Self.encode(
                    RuntimeEndpointReply.rejected(
                        Self.endpointRejection(rejection.endpointRejection, compatibleWithRequest: request)
                    )
                ),
                nil
            )
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
            ), endpointRequest.claimedIdentity == identifier,
            let requirement = clientRequirements[endpointRequest.clientKind.rawValue]
        else {
            reply(Self.encode(RuntimeEndpointReply.rejected(.unknownClient)), nil)
            return
        }
        let reservationID = UUID()
        let controlListener = RuntimeXPCControlListener(
            host: host,
            clientKind: endpointRequest.clientKind,
            requirement: requirement,
            reservationID: reservationID,
            connectionRegistry: connectionRegistry
        )
        guard
            connectionRegistry.reserveControlConnection(
                for: endpointRequest.clientKind,
                on: connectionID,
                reservationID: reservationID,
                controlListener: controlListener
            )
        else {
            controlListener.listener.invalidate()
            reply(
                Self.encode(
                    RuntimeEndpointReply.rejected(
                        Self.endpointRejection(.busy, requestedVersion: endpointRequest.apiVersion)
                    )
                ),
                nil
            )
            return
        }
        reply(Self.encode(RuntimeEndpointReply.granted), controlListener.listener.endpoint)
    }

    private static let maximumRequestSize = 16 * 1024

    private static func endpointRejection(
        _ rejection: RuntimeEndpointRejection,
        requestedVersion: APIVersion
    ) -> RuntimeEndpointRejection {
        guard rejection == .busy, requestedVersion.minor < 3 else {
            return rejection
        }
        // API 1.0–1.2 clients do not know the additive 1.3 `.busy` rejection.
        return .hostShuttingDown
    }

    private static func endpointRejection(
        _ rejection: RuntimeEndpointRejection,
        compatibleWithRequest request: Data
    ) -> RuntimeEndpointRejection {
        guard rejection == .busy,
            request.count <= maximumRequestSize,
            let endpointRequest = try? JSONDecoder().decode(RuntimeEndpointRequest.self, from: request)
        else {
            return rejection
        }
        return endpointRejection(rejection, requestedVersion: endpointRequest.apiVersion)
    }

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

    private static func rejection(for admission: RuntimeXPCRequestAdmission) -> RuntimeXPCRequestRejection {
        guard case .rejected(let rejection) = admission else {
            return .hostShuttingDown
        }
        return rejection
    }
}

private struct BrokerErrorReply: Codable {
    let error: RuntimeControlError
}

private final class ControlListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let host: RuntimeHost
    private let clientKind: RuntimeClientKind
    private let reservationID: UUID
    private let connectionRegistry: RuntimeXPCConnectionRegistry

    init(
        host: RuntimeHost,
        clientKind: RuntimeClientKind,
        reservationID: UUID,
        connectionRegistry: RuntimeXPCConnectionRegistry
    ) {
        self.host = host
        self.clientKind = clientKind
        self.reservationID = reservationID
        self.connectionRegistry = connectionRegistry
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard
            connectionRegistry.register(
                connection,
                kind: .control,
                clientKind: clientKind,
                reservationID: reservationID
            )
        else {
            listener.invalidate()
            return false
        }
        let connectionID = ObjectIdentifier(connection)
        connection.exportedInterface = NSXPCInterface(with: RuntimeControlXPC.self)
        connection.exportedObject = ControlService(
            host: host,
            clientKind: clientKind,
            connectionRegistry: connectionRegistry,
            connectionID: connectionID
        )
        connection.resume()
        listener.invalidate()
        return true
    }
}

private protocol VersionedControlRequest: Decodable {
    var header: APIRequestHeader { get }
}

extension RuntimeStatusRequest: VersionedControlRequest {}
extension StartRuntimeRequest: VersionedControlRequest {}
extension StopRuntimeRequest: VersionedControlRequest {}
extension RuntimeResetControlRequest: VersionedControlRequest {}
extension RuntimeListPackagesControlRequest: VersionedControlRequest {}
extension RuntimePackageInfoControlRequest: VersionedControlRequest {}
extension RuntimeLaunchControlRequest: VersionedControlRequest {}
extension RuntimeTerminateControlRequest: VersionedControlRequest {}

enum RuntimeControlOperation {
    case runtimeStatus
    case startRuntime
    case stopRuntime
    case resetRuntime
    case listPackages
    case packageInfo
    case launch
    case terminate

    func allows(_ clientKind: RuntimeClientKind) -> Bool {
        switch self {
        case .runtimeStatus:
            switch clientKind {
            case .app, .menuBar, .cli, .launcher:
                true
            case .wrapper:
                false
            }
        case .startRuntime, .stopRuntime, .resetRuntime:
            switch clientKind {
            case .app, .menuBar, .cli:
                true
            case .launcher, .wrapper:
                false
            }
        case .listPackages:
            switch clientKind {
            case .app, .menuBar, .cli:
                true
            case .launcher, .wrapper:
                false
            }
        case .packageInfo:
            switch clientKind {
            case .app, .menuBar, .cli, .launcher:
                true
            case .wrapper:
                false
            }
        case .launch, .terminate:
            switch clientKind {
            case .app, .menuBar, .cli:
                true
            case .launcher, .wrapper:
                false
            }
        }
    }
}

private final class ControlService: NSObject, RuntimeControlXPC, @unchecked Sendable {
    private let host: RuntimeHost
    private let clientKind: RuntimeClientKind
    private let connectionRegistry: RuntimeXPCConnectionRegistry
    private let connectionID: ObjectIdentifier

    init(
        host: RuntimeHost,
        clientKind: RuntimeClientKind,
        connectionRegistry: RuntimeXPCConnectionRegistry,
        connectionID: ObjectIdentifier
    ) {
        self.host = host
        self.clientKind = clientKind
        self.connectionRegistry = connectionRegistry
        self.connectionID = connectionID
    }

    func runtimeStatus(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = XPCDataReply(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID, allowDuringShutdown: true)
        guard case .accepted(let pending) = admission else {
            response.send(Self.errorReply(for: Self.rejection(for: admission).controlError))
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .runtimeStatus,
                as: RuntimeStatusRequest.self
            ) {
                response.send(Self.errorReply(for: failure))
                return
            }
            response.send(Self.encode(RuntimeControlReply(status: await host.status())))
        }
    }

    func startRuntime(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = XPCDataReply(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(Self.errorReply(for: Self.rejection(for: admission).controlError))
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .startRuntime,
                as: StartRuntimeRequest.self
            ) {
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
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(Self.errorReply(for: Self.rejection(for: admission).controlError))
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .stopRuntime,
                as: StopRuntimeRequest.self
            ) {
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

    func resetRuntime(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = XPCDataReply(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(Self.errorReply(for: Self.rejection(for: admission).controlError))
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .resetRuntime,
                as: RuntimeResetControlRequest.self
            ) {
                response.send(Self.errorReply(for: failure))
                return
            }
            do {
                let status = try await host.resetRuntime()
                response.send(Self.encode(RuntimeControlReply(status: status)))
            } catch {
                response.send(Self.errorReply(for: Self.controlError(for: error)))
            }
        }
    }

    func listPackages(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = XPCDataReply(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(RuntimeListPackagesControlReply(error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .listPackages,
                as: RuntimeListPackagesControlRequest.self
            ) {
                response.send(
                    Self.encode(RuntimeListPackagesControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            guard let decoded = try? JSONDecoder().decode(RuntimeListPackagesControlRequest.self, from: request) else {
                response.send(
                    Self.encode(RuntimeListPackagesControlReply(error: Self.malformedWireError))
                )
                return
            }
            do {
                let result = try await host.listPackages(
                    RuntimeListPackagesRequest(filter: decoded.filter)
                )
                response.send(Self.encode(RuntimeListPackagesControlReply(result: result)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeListPackagesControlReply(error: wireError)))
            }
        }
    }

    func packageInfo(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = XPCDataReply(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(RuntimePackageInfoControlReply(error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .packageInfo,
                as: RuntimePackageInfoControlRequest.self
            ) {
                response.send(
                    Self.encode(RuntimePackageInfoControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            guard let decoded = try? JSONDecoder().decode(RuntimePackageInfoControlRequest.self, from: request) else {
                response.send(
                    Self.encode(RuntimePackageInfoControlReply(error: Self.malformedWireError))
                )
                return
            }
            do {
                let details = try await host.packageInfo(
                    RuntimePackageRequest(packageID: decoded.packageID)
                )
                response.send(Self.encode(RuntimePackageInfoControlReply(result: details)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimePackageInfoControlReply(error: wireError)))
            }
        }
    }

    func launch(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = XPCDataReply(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            let error = Self.rejection(for: admission).wireError
            response.send(Self.encode(RuntimeLaunchControlReply(error: error)))
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .launch,
                as: RuntimeLaunchControlRequest.self
            ) {
                response.send(
                    Self.encode(RuntimeLaunchControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            guard let decoded = try? JSONDecoder().decode(RuntimeLaunchControlRequest.self, from: request) else {
                response.send(Self.encode(RuntimeLaunchControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                let result = try await host.launch(RuntimeLaunchRequest(packageID: decoded.packageID))
                response.send(Self.encode(RuntimeLaunchControlReply(result: result)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeLaunchControlReply(error: wireError)))
            }
        }
    }

    func terminate(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = XPCDataReply(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(Self.encode(RuntimeTerminateControlReply(error: Self.rejection(for: admission).wireError)))
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .terminate,
                as: RuntimeTerminateControlRequest.self
            ) {
                response.send(
                    Self.encode(RuntimeTerminateControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            guard let decoded = try? JSONDecoder().decode(RuntimeTerminateControlRequest.self, from: request) else {
                response.send(Self.encode(RuntimeTerminateControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                let result = try await host.terminate(RuntimeTerminateRequest(packageID: decoded.packageID))
                response.send(Self.encode(RuntimeTerminateControlReply(result: result)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeTerminateControlReply(error: wireError)))
            }
        }
    }

    private static let maximumRequestSize = 1024 * 1024

    private static let malformedWireError = RuntimeWireError.runtime(
        "malformedRequest",
        message: safeMessage(for: "runtime.malformedRequest")
    )
    private static let internalWireError = RuntimeWireError.runtime(
        "internal",
        message: safeMessage(for: "runtime.internal")
    )

    private static func rejection(for admission: RuntimeXPCRequestAdmission) -> RuntimeXPCRequestRejection {
        guard case .rejected(let rejection) = admission else {
            return .hostShuttingDown
        }
        return rejection
    }

    private static func validate<Request: VersionedControlRequest>(
        _ data: Data,
        clientKind: RuntimeClientKind,
        operation: RuntimeControlOperation,
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
        guard operation.allows(clientKind) else {
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
            case .invalidTransition:
                code = "runtime.invalidTransition"
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

    private static func wireError(for error: RuntimeControlError) -> RuntimeWireError {
        RuntimeWireError(
            domain: String(error.code.split(separator: ".", maxSplits: 1).first ?? "runtime"),
            code: error.code,
            message: error.message
        )
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
