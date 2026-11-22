import DiagnosticsCore
@preconcurrency import Foundation
import ImageCore
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
    /// Live frozen maintenance listeners granted through the broker.

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

        let connectionRegistry = RuntimeXPCConnectionRegistry(eventHub: host.eventHub)
        connectionRegistry.onConnectionRemoved = { [streamCenter = host.streamCenter] connectionID in
            streamCenter.connectionClosed(connectionID)
        }
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

enum RuntimeXPCConnectionKind: Equatable {
    case broker
    case control
    case maintenance
}

private struct RuntimeXPCConnectionRecord {
    let connection: NSXPCConnection
    let kind: RuntimeXPCConnectionKind
    let controlListener: RuntimeXPCControlListener?
    let outputQueue: DispatchQueue
    var activeRequests = 0
    var activityAssertion: RuntimeActivityAssertion?
    var activityHoldTokens = Set<UUID>()
}

private struct RuntimeXPCControlReservation {
    let brokerConnectionID: ObjectIdentifier
    let controlListener: RuntimeXPCControlListener
    let expiresAt: ContinuousClock.Instant
}

private final class RuntimeXPCMaintenanceListener: @unchecked Sendable {
    let listener: NSXPCListener
    let delegate: MaintenanceListenerDelegate

    init(host: RuntimeHost, requirement: String) {
        delegate = MaintenanceListenerDelegate(host: host)
        listener = NSXPCListener.anonymous()
        listener.setConnectionCodeSigningRequirement(requirement)
        listener.delegate = delegate
        listener.resume()
    }
}

private final class RuntimeXPCControlListener: @unchecked Sendable {
    let listener: NSXPCListener
    let delegate: ControlListenerDelegate

    init(
        host: RuntimeHost,
        clientKind: RuntimeClientKind,
        requirement: String,
        reservationID: UUID,
        connectionRegistry: RuntimeXPCConnectionRegistry,
        wrapperPackageID: RuntimePackageID? = nil
    ) {
        delegate = ControlListenerDelegate(
            host: host,
            clientKind: clientKind,
            reservationID: reservationID,
            connectionRegistry: connectionRegistry,
            wrapperPackageID: wrapperPackageID
        )
        listener = NSXPCListener.anonymous()
        listener.setConnectionCodeSigningRequirement(requirement)
        listener.delegate = delegate
        listener.resume()
    }
}

/// Carries a non-Sendable XPC reply closure into an async grant path.
private final class SendableReplyBox: @unchecked Sendable {
    let reply: (Data, NSXPCListenerEndpoint?) -> Void

    init(_ reply: @escaping (Data, NSXPCListenerEndpoint?) -> Void) {
        self.reply = reply
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

final class RuntimeXPCConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private let eventHub: RuntimeEventHub
    /// Extra cleanup run after a connection is invalidated (e.g. stream teardown).
    var onConnectionRemoved: (@Sendable (ObjectIdentifier) -> Void)?
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

    init(eventHub: RuntimeEventHub) {
        self.eventHub = eventHub
    }

    func register(
        _ connection: NSXPCConnection,
        kind: RuntimeXPCConnectionKind,
        clientKind: RuntimeClientKind? = nil,
        reservationID: UUID? = nil
    ) -> Bool {
        let identifier = ObjectIdentifier(connection)
        let outputQueue = DispatchQueue(
            label: "io.apkrun.RuntimeHost.xpc-output.\(UUID().uuidString)"
        )
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
            controlListener: controlListener,
            outputQueue: outputQueue
        )
        lastActivity = ContinuousClock.now
        lock.unlock()

        connection.invalidationHandler = { [weak self] in
            self?.remove(identifier)
        }
        return true
    }

    func outputQueue(for connectionID: ObjectIdentifier) -> DispatchQueue? {
        lock.lock()
        defer { lock.unlock() }
        return connections[connectionID]?.outputQueue
    }

    func holdActivity(
        _ assertion: RuntimeActivityAssertion,
        for connectionID: ObjectIdentifier
    ) -> UUID? {
        let token = UUID()
        lock.lock()
        guard var record = connections[connectionID] else {
            lock.unlock()
            assertion.release()
            return nil
        }
        let shouldRetainAssertion = record.activityAssertion == nil
        if shouldRetainAssertion {
            record.activityAssertion = assertion
        }
        record.activityHoldTokens.insert(token)
        connections[connectionID] = record
        lock.unlock()
        if !shouldRetainAssertion {
            assertion.release()
        }
        return token
    }

    func releaseActivityHold(_ token: UUID, for connectionID: ObjectIdentifier) {
        lock.lock()
        guard var record = connections[connectionID] else {
            lock.unlock()
            return
        }
        guard record.activityHoldTokens.remove(token) != nil else {
            lock.unlock()
            return
        }
        let assertion: RuntimeActivityAssertion?
        if record.activityHoldTokens.isEmpty {
            assertion = record.activityAssertion
            record.activityAssertion = nil
        } else {
            assertion = nil
        }
        connections[connectionID] = record
        lock.unlock()
        assertion?.release()
    }

    func isRegistered(_ connectionID: ObjectIdentifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed && connections[connectionID] != nil
    }

    fileprivate func reserveControlConnection(
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

    fileprivate func beginRequest(
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
        let connectionIDs = Array(connections.keys)
        let reservedListeners = reservedControlConnections.values.flatMap { reservations in
            reservations.values.map(\.controlListener)
        }
        let connections = records.map(\.connection)
        self.connections.removeAll()
        reservedControlConnections.removeAll()
        lastActivity = ContinuousClock.now
        lock.unlock()
        eventHub.removeAll(connectionIDs: connectionIDs)
        for record in records {
            record.activityAssertion?.release()
        }
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

    func remove(_ identifier: ObjectIdentifier) {
        lock.lock()
        let record = connections.removeValue(forKey: identifier)
        if record != nil {
            lastActivity = ContinuousClock.now
        }
        lock.unlock()
        record?.activityAssertion?.release()
        record?.controlListener?.listener.invalidate()
        eventHub.remove(connectionID: identifier)
        onConnectionRemoved?(identifier)
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

    /// Live frozen maintenance listeners granted through this connection.
    private var maintenanceListeners: [ObjectIdentifier: RuntimeXPCMaintenanceListener] = [:]

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
            await host.checkBundleForReplacement()
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
            endpointRequest.apiVersion.minor >= 0
        else {
            reply(Self.encode(RuntimeEndpointReply.rejected(.malformedRequest)), nil)
            return
        }

        // The frozen `.maintenance` endpoint answers in every host state and
        // ignores the client's header version (runtime-api.md §12.1): only
        // the code-signing requirement gates it.
        if endpointRequest.kind == .maintenance {
            requestMaintenanceEndpoint(endpointRequest, reply: reply)
            return
        }
        guard
            endpointRequest.kind == .control,
            endpointRequest.apiVersion.major == runtimeAPIVersion.major,
            endpointRequest.apiVersion.minor <= runtimeAPIVersion.minor
        else {
            reply(Self.encode(RuntimeEndpointReply.rejected(.malformedRequest)), nil)
            return
        }

        // `.wrapper` has no static requirement (runtime-api.md §10.1): each
        // registered wrapper gets `identifier "<bundleID>" and cdhash H"…"`
        // built from `Wrappers/registry.json`.
        if endpointRequest.clientKind == .wrapper {
            requestWrapperEndpoint(endpointRequest, reply: reply)
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
        grantControlEndpoint(
            clientKind: endpointRequest.clientKind,
            requirement: requirement,
            requestedVersion: endpointRequest.apiVersion,
            reply: reply
        )
    }

    /// Grants the frozen maintenance endpoint (runtime-api.md §12.1): the
    /// same code-signing requirement as control, but no version negotiation
    /// and available in every host state. Only `.app` and `.cli` clients may
    /// drive an update; launchers, wrappers, and the menu bar are refused.
    private func requestMaintenanceEndpoint(
        _ endpointRequest: RuntimeEndpointRequest,
        reply: @escaping (Data, NSXPCListenerEndpoint?) -> Void
    ) {
        guard endpointRequest.clientKind == .app || endpointRequest.clientKind == .cli else {
            reply(Self.encode(RuntimeEndpointReply.rejected(.unknownClient)), nil)
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
        let maintenanceListener = RuntimeXPCMaintenanceListener(
            host: host,
            requirement: requirement
        )
        maintenanceListeners[ObjectIdentifier(maintenanceListener)] = maintenanceListener
        maintenanceListener.delegate.onAccepted = { [weak self, maintenanceListener] in
            self?.maintenanceListeners.removeValue(forKey: ObjectIdentifier(maintenanceListener))
        }
        reply(Self.encode(RuntimeEndpointReply.granted), maintenanceListener.listener.endpoint)
    }

    /// Grants a control endpoint to a wrapper whose bundle ID and cdhash
    /// match an active registry entry (runtime-api.md §10.1).
    private func requestWrapperEndpoint(
        _ endpointRequest: RuntimeEndpointRequest,
        reply: @escaping (Data, NSXPCListenerEndpoint?) -> Void
    ) {
        let replyBox = SendableReplyBox(reply)
        Task {
            guard
                let credentials = await host.wrapperEndpointCredentials(
                    bundleID: endpointRequest.claimedIdentity)
            else {
                replyBox.reply(Self.encode(RuntimeEndpointReply.rejected(.unknownClient)), nil)
                return
            }
            grantControlEndpoint(
                clientKind: .wrapper,
                requirement: credentials.requirement,
                requestedVersion: endpointRequest.apiVersion,
                wrapperPackageID: credentials.packageID,
                reply: replyBox.reply
            )
        }
    }

    /// Creates an anonymous control listener, reserves the connection, and
    /// replies with its endpoint (runtime-api.md §3.3).
    private func grantControlEndpoint(
        clientKind: RuntimeClientKind,
        requirement: String,
        requestedVersion: APIVersion,
        wrapperPackageID: RuntimePackageID? = nil,
        reply: @escaping (Data, NSXPCListenerEndpoint?) -> Void
    ) {
        let reservationID = UUID()
        let controlListener = RuntimeXPCControlListener(
            host: host,
            clientKind: clientKind,
            requirement: requirement,
            reservationID: reservationID,
            connectionRegistry: connectionRegistry,
            wrapperPackageID: wrapperPackageID
        )
        guard
            connectionRegistry.reserveControlConnection(
                for: clientKind,
                on: connectionID,
                reservationID: reservationID,
                controlListener: controlListener
            )
        else {
            controlListener.listener.invalidate()
            reply(
                Self.encode(
                    RuntimeEndpointReply.rejected(
                        Self.endpointRejection(.busy, requestedVersion: requestedVersion)
                    )
                ),
                nil
            )
            return
        }
        reply(Self.encode(RuntimeEndpointReply.granted), controlListener.listener.endpoint)
    }

    func requestApproval(_ request: Data, reply: @escaping (Data) -> Void) {
        // Not allowed during shutdown: a new prompt could not be answered and
        // would hold the request drain for the full ten-minute timeout.
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            let rejection = Self.rejection(for: admission)
            reply(
                Self.encode(
                    RuntimeApprovalBrokerReply(
                        error: RuntimeWireError(domain: "runtime", code: rejection.errorCode, message: ""))))
            return
        }
        guard
            request.count <= Self.maximumRequestSize,
            let approvalRequest = try? JSONDecoder().decode(ApprovalRequest.self, from: request)
        else {
            reply(
                Self.encode(
                    RuntimeApprovalBrokerReply(
                        error: RuntimeWireError(
                            domain: "runtime", code: "malformedRequest", message: ""))))
            pending.finish()
            return
        }
        let response = XPCDataReply(reply)
        Task {
            defer { pending.finish() }
            do {
                let result = try await host.requestApproval(approvalRequest)
                response.send(Self.encode(RuntimeApprovalBrokerReply(result: result)))
            } catch {
                let wireError =
                    (error as? RuntimeWireError)
                    ?? RuntimeWireError(domain: "runtime", code: "internal", message: "")
                response.send(Self.encode(RuntimeApprovalBrokerReply(error: wireError)))
            }
        }
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
    private let wrapperPackageID: RuntimePackageID?

    init(
        host: RuntimeHost,
        clientKind: RuntimeClientKind,
        reservationID: UUID,
        connectionRegistry: RuntimeXPCConnectionRegistry,
        wrapperPackageID: RuntimePackageID? = nil
    ) {
        self.host = host
        self.clientKind = clientKind
        self.reservationID = reservationID
        self.connectionRegistry = connectionRegistry
        self.wrapperPackageID = wrapperPackageID
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
        let controlInterface = NSXPCInterface(with: RuntimeControlXPC.self)
        guard let fileHandleClasses = NSSet(array: [NSArray.self, FileHandle.self]) as? Set<AnyHashable> else {
            listener.invalidate()
            return false
        }
        controlInterface.setClasses(
            fileHandleClasses,
            for: #selector(RuntimeControlXPC.importPackage(_:files:reply:)),
            argumentIndex: 1,
            ofReply: false
        )
        // `updatePackage` carries the same FileHandle array as `importPackage`
        // for a manual `--file` update; without the whitelist NSXPC refuses
        // the call before it reaches the handler.
        controlInterface.setClasses(
            fileHandleClasses,
            for: #selector(RuntimeControlXPC.updatePackage(_:files:reply:)),
            argumentIndex: 1,
            ofReply: false
        )
        // `importBootstrap` carries one FileHandle per bootstrap.json file
        // (wrapper-json.md §3.4); same whitelist as `importPackage`.
        controlInterface.setClasses(
            fileHandleClasses,
            for: #selector(RuntimeControlXPC.importBootstrap(_:files:reply:)),
            argumentIndex: 1,
            ofReply: false
        )
        // `importFiles` carries the dropped FileHandles; `acceptExport`
        // carries the write target (runtime-api.md §11.2).
        controlInterface.setClasses(
            fileHandleClasses,
            for: #selector(RuntimeControlXPC.importFiles(_:files:reply:)),
            argumentIndex: 1,
            ofReply: false
        )
        controlInterface.setClasses(
            fileHandleClasses,
            for: #selector(RuntimeControlXPC.acceptExport(_:files:reply:)),
            argumentIndex: 1,
            ofReply: false
        )
        // `installImage` carries the `.aar` FileHandle (runtime-maintenance.md
        // §4.7); same whitelist as `importPackage`.
        controlInterface.setClasses(
            fileHandleClasses,
            for: #selector(RuntimeControlXPC.installImage(_:files:reply:)),
            argumentIndex: 1,
            ofReply: false
        )
        // `createDiagnostics` carries the report's output handle
        // (diagnostics.md §8.1).
        controlInterface.setClasses(
            fileHandleClasses,
            for: #selector(RuntimeControlXPC.createDiagnostics(_:files:reply:)),
            argumentIndex: 1,
            ofReply: false
        )
        connection.remoteObjectInterface = NSXPCInterface(with: RuntimeEventSink.self)
        let eventHub = host.eventHub
        let remoteSink =
            connection.remoteObjectProxyWithErrorHandler { _ in
                eventHub.remove(connectionID: connectionID)
            } as? any RuntimeEventSink
        connection.exportedInterface = controlInterface
        connection.exportedObject = ControlService(
            host: host,
            clientKind: clientKind,
            connectionRegistry: connectionRegistry,
            connectionID: connectionID,
            eventSink: remoteSink.map(RuntimeEventSinkReference.init(value:)),
            wrapperPackageID: wrapperPackageID
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
extension HealthRequest: VersionedControlRequest {}
extension HealthFixRequest: VersionedControlRequest {}
extension RuntimeCreateDiagnosticsControlRequest: VersionedControlRequest {}
extension StartRuntimeRequest: VersionedControlRequest {}
extension StopRuntimeRequest: VersionedControlRequest {}
extension RestartRuntimeRequest: VersionedControlRequest {}
extension RuntimeResetControlRequest: VersionedControlRequest {}
extension RuntimeConfigurationControlRequest: VersionedControlRequest {}
extension RuntimeUpdateConfigurationControlRequest: VersionedControlRequest {}
extension RuntimeSetupControlRequest: VersionedControlRequest {}
extension RuntimeResetAndroidControlRequest: VersionedControlRequest {}
extension RuntimeListPackagesControlRequest: VersionedControlRequest {}
extension RuntimePackageInfoControlRequest: VersionedControlRequest {}
extension RuntimeListSessionsControlRequest: VersionedControlRequest {}
extension SelfUpdateStatusRequest: VersionedControlRequest {}
extension RuntimePackageIconControlRequest: VersionedControlRequest {}
extension RuntimeLaunchControlRequest: VersionedControlRequest {}
extension RuntimeTerminateControlRequest: VersionedControlRequest {}
extension RuntimeCloseSessionControlRequest: VersionedControlRequest {}
extension RuntimeImportPackageControlRequest: VersionedControlRequest {}
extension RuntimeInstallImportedControlRequest: VersionedControlRequest {}
extension RuntimeDiscardImportControlRequest: VersionedControlRequest {}
extension RuntimeAdoptPackageControlRequest: VersionedControlRequest {}
extension RuntimeBeginInstallImportedControlRequest: VersionedControlRequest {}
extension RuntimeBeginUninstallPackageControlRequest: VersionedControlRequest {}
extension RuntimeBeginRepairPackageControlRequest: VersionedControlRequest {}
extension RuntimeCancelOperationControlRequest: VersionedControlRequest {}
extension RuntimeListOperationsControlRequest: VersionedControlRequest {}
extension RuntimeOperationStatusControlRequest: VersionedControlRequest {}
extension RuntimeSubscribeControlRequest: VersionedControlRequest {}
extension RuntimeUnsubscribeControlRequest: VersionedControlRequest {}
extension RuntimeVerifyWrapperControlRequest: VersionedControlRequest {}
extension RuntimeCreateWrapperControlRequest: VersionedControlRequest {}
extension RuntimeBuildDistributionWrapperControlRequest: VersionedControlRequest {}
extension RuntimePlaceStagedWrapperControlRequest: VersionedControlRequest {}
extension RuntimeWrapperInfoControlRequest: VersionedControlRequest {}
extension RuntimeWrapperListControlRequest: VersionedControlRequest {}
extension RuntimeRemoveWrapperControlRequest: VersionedControlRequest {}
extension RuntimeRescanWrappersControlRequest: VersionedControlRequest {}
extension RuntimeRefreshWrapperControlRequest: VersionedControlRequest {}
extension RuntimeRefreshAllWrappersControlRequest: VersionedControlRequest {}
extension RuntimePendingApprovalsControlRequest: VersionedControlRequest {}
extension RuntimeDecideApprovalControlRequest: VersionedControlRequest {}
extension RuntimeDeniedWrappersControlRequest: VersionedControlRequest {}
extension RuntimeClearWrapperDenialControlRequest: VersionedControlRequest {}
extension RuntimeImportBootstrapControlRequest: VersionedControlRequest {}
extension RuntimePerfStatisticsControlRequest: VersionedControlRequest {}
extension RuntimeFrameStatisticsControlRequest: VersionedControlRequest {}
extension RuntimePushClipboardControlRequest: VersionedControlRequest {}
extension RuntimeClipboardWrittenControlRequest: VersionedControlRequest {}
extension RuntimeFocusChangedControlRequest: VersionedControlRequest {}
extension RuntimeResolveLinkPromptControlRequest: VersionedControlRequest {}
extension RuntimeIntegrationStatusControlRequest: VersionedControlRequest {}
extension RuntimeImportFilesSessionRequest: VersionedControlRequest {}
extension RuntimeAcceptExportSessionRequest: VersionedControlRequest {}
extension RuntimeSharedFoldersControlRequest: VersionedControlRequest {}
extension RuntimeAddSharedFolderControlRequest: VersionedControlRequest {}
extension RuntimeRemoveSharedFolderControlRequest: VersionedControlRequest {}
extension RuntimeSetSharedFolderAccessControlRequest: VersionedControlRequest {}
extension RuntimeCheckForUpdatesControlRequest: VersionedControlRequest {}
extension RuntimeListUpdatesControlRequest: VersionedControlRequest {}
extension RuntimeUpdateHistoryControlRequest: VersionedControlRequest {}
extension RuntimePackageSettingsControlRequest: VersionedControlRequest {}
extension RuntimeUpdatePackageSettingsControlRequest: VersionedControlRequest {}
extension RuntimeSetUpdatePolicyControlRequest: VersionedControlRequest {}
extension RuntimeSetUpdateAuthorityControlRequest: VersionedControlRequest {}
extension RuntimeRollbackPackageControlRequest: VersionedControlRequest {}
extension RuntimeUpdateSkipControlRequest: VersionedControlRequest {}
extension RuntimeUpdatePackageControlRequest: VersionedControlRequest {}
extension RuntimeConfigGetControlRequest: VersionedControlRequest {}
extension RuntimeConfigSetControlRequest: VersionedControlRequest {}
extension NotificationRelayRequest: VersionedControlRequest {}
extension RelayResponseRequest: VersionedControlRequest {}
extension HostNotificationsRequest: VersionedControlRequest {}
extension HostNotificationResponseRequest: VersionedControlRequest {}
extension CloseStreamRequest: VersionedControlRequest {}

enum RuntimeControlOperation {
    case runtimeStatus
    case startRuntime
    case stopRuntime
    case restartRuntime
    case resetRuntime
    case configuration
    case updateConfiguration
    case setup
    case resetAndroid
    case listPackages
    case packageInfo
    case listSessions
    case packageIcon
    case launch
    case terminate
    case closeSession
    case importPackage
    case installImported
    case discardImport
    case adoptPackage
    case beginInstallImported
    case beginUninstallPackage
    case cancelOperation
    case listOperations
    case operationStatus
    case subscribe
    case unsubscribe
    case verifyWrapper
    case createWrapper
    case buildDistributionWrapper
    case placeStagedWrapper
    case wrapperInfo
    case listWrappers
    case removeWrapper
    case rescanWrappers
    case refreshWrapper
    case refreshAllWrappers
    case pendingApprovals
    case decideApproval
    case deniedWrappers
    case clearWrapperDenial
    case perfStatistics
    case frameStatistics
    case pushClipboard
    case clipboardWritten
    case focusChanged
    case resolveLinkPrompt
    case integrationStatus
    case importFiles
    case acceptExport
    case sharedFolders
    case addSharedFolder
    case removeSharedFolder
    case setSharedFolderAccess
    case checkForUpdates
    case listUpdates
    case updateHistory
    case setUpdatePolicy
    case setUpdateAuthority
    case rollbackPackage
    case beginRepairPackage
    case updateSkipped
    case updatePackage
    case createDiagnostics
    case getConfig
    case setConfig
    case selfUpdateStatus
    case noteSelfUpdateStatus
    case checkSelfUpdate
    case packageSettings
    case updatePackageSettings
    case importBootstrap
    case notificationRelay
    case notificationRelayResponse
    case hostNotifications
    case hostNotificationResponse
    case closeStream
    case installImage
    case imageStatus
    case applyImage
    case rollbackImage
    case deleteImageRecoveryPoint
    case imageFeedAction
    case healthReport
    case applyHealthFixes

    func allows(_ clientKind: RuntimeClientKind) -> Bool {
        switch self {
        case .runtimeStatus:
            switch clientKind {
            case .app, .menuBar, .cli, .launcher:
                true
            case .wrapper:
                false
            }
        case .configuration, .updateConfiguration:
            switch clientKind {
            case .app, .menuBar, .cli:
                true
            case .launcher, .wrapper:
                false
            }
        case .startRuntime, .stopRuntime, .restartRuntime, .resetRuntime,
            .setup, .resetAndroid,
            .importPackage, .installImported, .beginInstallImported, .discardImport, .adoptPackage,
            .beginUninstallPackage,
            .cancelOperation, .listOperations, .operationStatus:
            switch clientKind {
            case .app, .menuBar, .cli:
                true
            case .launcher, .wrapper:
                false
            }
        case .subscribe, .unsubscribe:
            switch clientKind {
            case .app, .menuBar, .cli, .launcher:
                true
            case .wrapper:
                false
            }
        case .createWrapper, .buildDistributionWrapper:
            switch clientKind {
            case .app, .menuBar, .cli:
                true
            case .launcher, .wrapper:
                false
            }
        case .pendingApprovals, .decideApproval:
            switch clientKind {
            case .app:
                true
            case .menuBar, .cli, .launcher, .wrapper:
                false
            }
        case .deniedWrappers, .clearWrapperDenial:
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
        case .listSessions, .packageIcon:
            switch clientKind {
            case .app, .menuBar, .cli:
                true
            case .launcher, .wrapper:
                false
            }
        case .launch, .terminate, .verifyWrapper, .placeStagedWrapper, .wrapperInfo,
            .listWrappers, .removeWrapper, .rescanWrappers, .refreshWrapper, .refreshAllWrappers:
            switch clientKind {
            case .app, .menuBar, .cli:
                true
            case .launcher, .wrapper:
                false
            }
        case .perfStatistics, .frameStatistics:
            // Developer-mode reads; the developer.enabled gate is enforced in
            // RuntimeHost (diagnostics.md §9.3, runtime-api.md §13.1).
            true
        case .closeSession:
            // display-and-windowing.md §7.6: the window process closes its
            // own session with the package's saved close policy.
            switch clientKind {
            case .wrapper, .launcher:
                true
            case .app, .menuBar, .cli:
                false
            }
        case .pushClipboard, .clipboardWritten, .focusChanged, .resolveLinkPrompt,
            .importFiles, .acceptExport:
            // Session-channel messages of desktop-integration.md §3.3, §6
            // and §7.2: the window process reports for its own session.
            switch clientKind {
            case .wrapper, .launcher:
                true
            case .app, .menuBar, .cli:
                false
            }
        case .sharedFolders, .addSharedFolder, .removeSharedFolder,
            .setSharedFolderAccess:
            // Shared-folder management is a control-plane operation
            // (runtime-api.md §11.1); a window process never writes it.
            switch clientKind {
            case .app, .menuBar, .cli:
                true
            case .launcher, .wrapper:
                false
            }
        case .integrationStatus:
            switch clientKind {
            case .app, .menuBar, .cli:
                true
            case .launcher, .wrapper:
                false
            }
        case .checkForUpdates, .listUpdates, .updateHistory, .setUpdatePolicy,
            .setUpdateAuthority, .rollbackPackage, .beginRepairPackage,
            .updateSkipped, .updatePackage, .getConfig, .setConfig,
            .packageSettings, .updatePackageSettings, .installImage,
            .imageStatus, .applyImage, .rollbackImage,
            .deleteImageRecoveryPoint, .imageFeedAction, .healthReport,
            .applyHealthFixes, .createDiagnostics:
            switch clientKind {
            case .app, .menuBar, .cli:
                true
            case .launcher, .wrapper:
                false
            }
        case .importBootstrap:
            // The wrapper endpoint op (wrapper-json.md §3.4): only the
            // launcher inside a generated wrapper may import its bootstrap.
            switch clientKind {
            case .launcher, .wrapper:
                true
            case .app, .menuBar, .cli:
                false
            }
        case .notificationRelay, .notificationRelayResponse:
            // A wrapper relays Android notifications for its own package only
            // (runtime-api.md §11.3).
            switch clientKind {
            case .wrapper:
                true
            case .app, .menuBar, .cli, .launcher:
                false
            }
        case .selfUpdateStatus:
            // The probe snapshot is read by every control client (§12.2).
            switch clientKind {
            case .app, .menuBar, .cli:
                true
            case .launcher, .wrapper:
                false
            }
        case .noteSelfUpdateStatus:
            // Only APKRun.app speaks for Sparkle (§12.2).
            switch clientKind {
            case .app:
                true
            case .menuBar, .cli, .launcher, .wrapper:
                false
            }
        case .checkSelfUpdate:
            // User-initiated probe checks come from the app, the menu bar,
            // and the CLI (§12.2).
            switch clientKind {
            case .app, .menuBar, .cli:
                true
            case .launcher, .wrapper:
                false
            }
        case .hostNotifications, .hostNotificationResponse:
            // The host-notification stream belongs to APKRun.app (§11.3).
            switch clientKind {
            case .app:
                true
            case .menuBar, .cli, .launcher, .wrapper:
                false
            }
        case .closeStream:
            // Any client may close its own streams (§16.4).
            switch clientKind {
            case .wrapper, .app, .menuBar, .cli:
                true
            case .launcher:
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
    private let eventSink: RuntimeEventSinkReference?
    /// The package a `.wrapper` connection may operate on (runtime-api.md §10.1).
    private let wrapperPackageID: RuntimePackageID?
    private let outputQueue: DispatchQueue

    init(
        host: RuntimeHost,
        clientKind: RuntimeClientKind,
        connectionRegistry: RuntimeXPCConnectionRegistry,
        connectionID: ObjectIdentifier,
        eventSink: RuntimeEventSinkReference?,
        wrapperPackageID: RuntimePackageID? = nil
    ) {
        self.host = host
        self.clientKind = clientKind
        self.connectionRegistry = connectionRegistry
        self.connectionID = connectionID
        self.eventSink = eventSink
        self.wrapperPackageID = wrapperPackageID
        outputQueue =
            connectionRegistry.outputQueue(for: connectionID)
            ?? DispatchQueue(label: "io.apkrun.RuntimeHost.xpc-output-fallback.\(UUID().uuidString)")
    }

    func runtimeStatus(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply, snapshotBarrier: true)
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
            response.beginSnapshotBarrier()
            let status = await host.status()
            if status.startupFailureCode == RuntimeHost.newerSettingsSchemaFailureCode {
                response.send(
                    Self.errorReply(
                        for: RuntimeControlError(
                            code: "runtime.hostStartupFailed",
                            message: safeMessage(for: "runtime.hostStartupFailed")
                        )
                    )
                )
            } else {
                response.send(Self.encode(RuntimeControlReply(status: status)))
            }
        }
    }

    func configuration(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply, snapshotBarrier: true)
        let admission = connectionRegistry.beginRequest(on: connectionID, allowDuringShutdown: true)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeConfigurationControlReply(
                        error: Self.wireError(for: Self.rejection(for: admission).controlError)
                    )
                )
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .configuration,
                as: RuntimeConfigurationControlRequest.self
            ) {
                response.send(Self.encode(RuntimeConfigurationControlReply(error: Self.wireError(for: failure))))
                return
            }
            response.beginSnapshotBarrier()
            do {
                response.send(
                    Self.encode(
                        RuntimeConfigurationControlReply(result: try await host.configuration())
                    )
                )
            } catch {
                response.send(
                    Self.encode(
                        RuntimeConfigurationControlReply(error: Self.configurationWireError(for: error))
                    )
                )
            }
        }
    }

    func updateConfiguration(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeUpdateConfigurationControlReply(
                        error: Self.wireError(for: Self.rejection(for: admission).controlError)
                    )
                )
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .updateConfiguration,
                as: RuntimeUpdateConfigurationControlRequest.self
            ) {
                response.send(Self.encode(RuntimeUpdateConfigurationControlReply(error: Self.wireError(for: failure))))
                return
            }
            guard let decoded = try? JSONDecoder().decode(RuntimeUpdateConfigurationControlRequest.self, from: request)
            else {
                response.send(Self.encode(RuntimeUpdateConfigurationControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                let result = try await host.updateConfiguration(decoded.patch)
                response.send(Self.encode(RuntimeUpdateConfigurationControlReply(result: result)))
            } catch {
                response.send(
                    Self.encode(
                        RuntimeUpdateConfigurationControlReply(error: Self.configurationWireError(for: error))
                    )
                )
            }
        }
    }

    func startRuntime(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
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
            guard let decoded = try? JSONDecoder().decode(StartRuntimeRequest.self, from: request) else {
                response.send(Self.errorReply(for: Self.malformedControlError))
                return
            }
            let shouldHold = decoded.hold ?? false
            if shouldHold, clientKind != .cli {
                response.send(
                    Self.errorReply(
                        for: RuntimeControlError(
                            code: "runtime.notAuthorized",
                            message: safeMessage(for: "runtime.notAuthorized")
                        )
                    )
                )
                return
            }
            let holdToken: UUID?
            if shouldHold {
                guard let acquired = await host.assertRuntimeActivity(.cli) else {
                    response.send(Self.errorReply(for: Self.internalControlError))
                    return
                }
                guard let token = connectionRegistry.holdActivity(acquired, for: connectionID) else {
                    response.send(Self.errorReply(for: Self.internalControlError))
                    return
                }
                holdToken = token
            } else {
                holdToken = nil
            }
            do {
                try await host.startRuntime(reason: clientKind == .cli ? .cli : .user)
                response.send(Self.encode(RuntimeControlReply(status: await host.status())))
            } catch {
                if let holdToken {
                    connectionRegistry.releaseActivityHold(holdToken, for: connectionID)
                }
                response.send(Self.errorReply(for: Self.controlError(for: error)))
            }
        }
    }

    func stopRuntime(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
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

    func restartRuntime(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
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
                operation: .restartRuntime,
                as: RestartRuntimeRequest.self
            ) {
                response.send(Self.errorReply(for: failure))
                return
            }
            do {
                try await host.restartRuntime(reason: clientKind == .cli ? .cli : .user)
                response.send(Self.encode(RuntimeControlReply(status: await host.status())))
            } catch {
                response.send(Self.errorReply(for: Self.controlError(for: error)))
            }
        }
    }

    func resetRuntime(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
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

    func setup(_ request: Data, files: [FileHandle], reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(RuntimeSetupControlReply(error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .setup,
                as: RuntimeSetupControlRequest.self
            ) {
                response.send(Self.encode(RuntimeSetupControlReply(error: Self.wireError(for: failure))))
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(RuntimeSetupControlRequest.self, from: request),
                let operationID = RuntimeAPI.OperationID(rawValue: decoded.header.operationID)
            else {
                response.send(Self.encode(RuntimeSetupControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                let handle = try await host.beginSetup(
                    decoded.request,
                    files: files,
                    operationID: operationID,
                    clientKind: clientKind
                )
                response.send(Self.encode(RuntimeSetupControlReply(result: handle)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeSetupControlReply(error: wireError)))
            }
        }
    }

    func resetAndroid(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(RuntimeResetAndroidControlReply(error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .resetAndroid,
                as: RuntimeResetAndroidControlRequest.self
            ) {
                response.send(Self.encode(RuntimeResetAndroidControlReply(error: Self.wireError(for: failure))))
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeResetAndroidControlRequest.self,
                    from: request
                ),
                let operationID = RuntimeAPI.OperationID(rawValue: decoded.header.operationID)
            else {
                response.send(Self.encode(RuntimeResetAndroidControlReply(error: Self.malformedWireError)))
                return
            }
            guard decoded.request.confirmed else {
                response.send(Self.encode(RuntimeResetAndroidControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                let handle = try await host.beginResetAndroid(
                    decoded.request,
                    operationID: operationID,
                    clientKind: clientKind
                )
                response.send(Self.encode(RuntimeResetAndroidControlReply(result: handle)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeResetAndroidControlReply(error: wireError)))
            }
        }
    }

    func listPackages(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply, snapshotBarrier: true)
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
                response.beginSnapshotBarrier()
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
        let response = makeReplyHandler(reply, snapshotBarrier: true)
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
                response.beginSnapshotBarrier()
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

    func listSessions(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply, snapshotBarrier: true)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(RuntimeListSessionsControlReply(error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .listSessions,
                as: RuntimeListSessionsControlRequest.self
            ) {
                response.send(
                    Self.encode(RuntimeListSessionsControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            do {
                response.beginSnapshotBarrier()
                let sessions = await host.listSessions()
                response.send(Self.encode(RuntimeListSessionsControlReply(sessions: sessions)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeListSessionsControlReply(error: wireError)))
            }
        }
    }

    func packageIcon(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply, snapshotBarrier: true)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(RuntimePackageIconControlReply(error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .packageIcon,
                as: RuntimePackageIconControlRequest.self
            ) {
                response.send(
                    Self.encode(RuntimePackageIconControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            guard let decoded = try? JSONDecoder().decode(RuntimePackageIconControlRequest.self, from: request) else {
                response.send(
                    Self.encode(RuntimePackageIconControlReply(error: Self.malformedWireError))
                )
                return
            }
            do {
                response.beginSnapshotBarrier()
                let png = await host.packageIcon(packageID: decoded.packageID)
                response.send(Self.encode(RuntimePackageIconControlReply(png: png)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimePackageIconControlReply(error: wireError)))
            }
        }
    }

    func importPackage(_ request: Data, files: [FileHandle], reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(RuntimeImportPackageControlReply(error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .importPackage,
                as: RuntimeImportPackageControlRequest.self
            ) {
                response.send(Self.encode(RuntimeImportPackageControlReply(error: Self.wireError(for: failure))))
                return
            }
            guard let decoded = try? JSONDecoder().decode(RuntimeImportPackageControlRequest.self, from: request) else {
                response.send(Self.encode(RuntimeImportPackageControlReply(error: Self.malformedWireError)))
                return
            }
            guard
                !files.isEmpty,
                files.count <= 20,
                !decoded.request.files.isEmpty,
                decoded.request.files.count <= 20
            else {
                response.send(
                    Self.encode(
                        RuntimeImportPackageControlReply(
                            error: .store("invalidImport", message: "Choose between 1 and 20 APK files.")
                        )
                    )
                )
                return
            }
            do {
                let preview = try await host.importPackage(decoded.request, files: files)
                response.send(Self.encode(RuntimeImportPackageControlReply(result: preview)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeImportPackageControlReply(error: wireError)))
            }
        }
    }

    func importBootstrap(_ request: Data, files: [FileHandle], reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeImportBootstrapControlReply(error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .importBootstrap,
                as: RuntimeImportBootstrapControlRequest.self
            ) {
                response.send(
                    Self.encode(RuntimeImportBootstrapControlReply(error: Self.wireError(for: failure))))
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeImportBootstrapControlRequest.self, from: request),
                !decoded.bundleID.isEmpty, decoded.bundleID.utf8.count <= 255,
                !decoded.bootstrapJSON.isEmpty
            else {
                response.send(
                    Self.encode(RuntimeImportBootstrapControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                let handle = try await host.beginImportBootstrap(
                    decoded, clientKind: clientKind, files: files)
                response.send(Self.encode(RuntimeImportBootstrapControlReply(result: handle)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeImportBootstrapControlReply(error: wireError)))
            }
        }
    }

    func updatePackage(_ request: Data, files: [FileHandle], reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeUpdatePackageControlReply(error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .updatePackage,
                as: RuntimeUpdatePackageControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeUpdatePackageControlReply(error: Self.wireError(for: failure))))
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeUpdatePackageControlRequest.self,
                    from: request
                )
            else {
                response.send(
                    Self.encode(
                        RuntimeUpdatePackageControlReply(error: Self.malformedWireError)))
                return
            }
            if let sources = decoded.options.files,
                sources.isEmpty || sources.count > 20 || sources.count != files.count
            {
                response.send(
                    Self.encode(
                        RuntimeUpdatePackageControlReply(
                            error: .store("invalidImport", message: "Choose between 1 and 20 APK files.")
                        )
                    )
                )
                return
            }
            if decoded.options.files == nil, !files.isEmpty {
                response.send(
                    Self.encode(
                        RuntimeUpdatePackageControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                let (operation, outcome) = try await host.updatePackage(
                    packageID: decoded.packageID,
                    options: decoded.options,
                    files: files,
                    operationID: OperationID(rawValue: decoded.header.operationID)
                        ?? OperationID(),
                    requestPayload: request,
                    clientKind: clientKind
                )
                response.send(
                    Self.encode(
                        RuntimeUpdatePackageControlReply(
                            operation: operation, outcome: outcome)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeUpdatePackageControlReply(error: wireError)))
            }
        }
    }

    func installImported(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(RuntimeInstallImportedControlReply(error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .installImported,
                as: RuntimeInstallImportedControlRequest.self
            ) {
                response.send(Self.encode(RuntimeInstallImportedControlReply(error: Self.wireError(for: failure))))
                return
            }
            guard let decoded = try? JSONDecoder().decode(RuntimeInstallImportedControlRequest.self, from: request)
            else {
                response.send(Self.encode(RuntimeInstallImportedControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                let result = try await host.installImported(decoded.request)
                response.send(Self.encode(RuntimeInstallImportedControlReply(result: result)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeInstallImportedControlReply(error: wireError)))
            }
        }
    }

    func discardImport(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(RuntimeDiscardImportControlReply(error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .discardImport,
                as: RuntimeDiscardImportControlRequest.self
            ) {
                response.send(Self.encode(RuntimeDiscardImportControlReply(error: Self.wireError(for: failure))))
                return
            }
            guard let decoded = try? JSONDecoder().decode(RuntimeDiscardImportControlRequest.self, from: request)
            else {
                response.send(Self.encode(RuntimeDiscardImportControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                try await host.discardImport(decoded.request)
                response.send(Self.encode(RuntimeDiscardImportControlReply()))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeDiscardImportControlReply(error: wireError)))
            }
        }
    }

    func adoptPackage(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(RuntimeAdoptPackageControlReply(error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .adoptPackage,
                as: RuntimeAdoptPackageControlRequest.self
            ) {
                response.send(Self.encode(RuntimeAdoptPackageControlReply(error: Self.wireError(for: failure))))
                return
            }
            guard let decoded = try? JSONDecoder().decode(RuntimeAdoptPackageControlRequest.self, from: request)
            else {
                response.send(Self.encode(RuntimeAdoptPackageControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                let summary = try await host.adoptPackage(decoded.request)
                response.send(Self.encode(RuntimeAdoptPackageControlReply(summary: summary)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeAdoptPackageControlReply(error: wireError)))
            }
        }
    }

    func beginInstallImported(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeBeginInstallImportedControlReply(error: Self.rejection(for: admission).wireError)
                )
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .beginInstallImported,
                as: RuntimeBeginInstallImportedControlRequest.self
            ) {
                response.send(
                    Self.encode(RuntimeBeginInstallImportedControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeBeginInstallImportedControlRequest.self,
                    from: request
                ),
                let operationID = RuntimeAPI.OperationID(rawValue: decoded.header.operationID)
            else {
                response.send(
                    Self.encode(
                        RuntimeBeginInstallImportedControlReply(error: Self.malformedWireError)
                    )
                )
                return
            }
            do {
                let handle = try await host.beginInstallImported(
                    decoded.request,
                    operationID: operationID,
                    clientKind: clientKind
                )
                response.send(Self.encode(RuntimeBeginInstallImportedControlReply(result: handle)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeBeginInstallImportedControlReply(error: wireError)))
            }
        }
    }

    func beginUninstallPackage(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeBeginUninstallPackageControlReply(error: Self.rejection(for: admission).wireError)
                )
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .beginUninstallPackage,
                as: RuntimeBeginUninstallPackageControlRequest.self
            ) {
                response.send(
                    Self.encode(RuntimeBeginUninstallPackageControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeBeginUninstallPackageControlRequest.self,
                    from: request
                ),
                let operationID = RuntimeAPI.OperationID(rawValue: decoded.header.operationID)
            else {
                response.send(
                    Self.encode(
                        RuntimeBeginUninstallPackageControlReply(error: Self.malformedWireError)
                    )
                )
                return
            }
            do {
                let handle = try await host.beginUninstallPackage(
                    decoded.request,
                    operationID: operationID,
                    clientKind: clientKind
                )
                response.send(Self.encode(RuntimeBeginUninstallPackageControlReply(result: handle)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeBeginUninstallPackageControlReply(error: wireError)))
            }
        }
    }

    func cancelOperation(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeCancelOperationControlReply(error: Self.rejection(for: admission).wireError)
                )
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .cancelOperation,
                as: RuntimeCancelOperationControlRequest.self
            ) {
                response.send(
                    Self.encode(RuntimeCancelOperationControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeCancelOperationControlRequest.self,
                    from: request
                )
            else {
                response.send(Self.encode(RuntimeCancelOperationControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                let result = try await host.cancelOperation(decoded.operationID)
                response.send(Self.encode(RuntimeCancelOperationControlReply(result: result)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeCancelOperationControlReply(error: wireError)))
            }
        }
    }

    func listOperations(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply, snapshotBarrier: true)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeListOperationsControlReply(error: Self.rejection(for: admission).wireError)
                )
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .listOperations,
                as: RuntimeListOperationsControlRequest.self
            ) {
                response.send(
                    Self.encode(RuntimeListOperationsControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            guard (try? JSONDecoder().decode(RuntimeListOperationsControlRequest.self, from: request)) != nil
            else {
                response.send(Self.encode(RuntimeListOperationsControlReply(error: Self.malformedWireError)))
                return
            }
            response.send(
                Self.encode(
                    RuntimeListOperationsControlReply(
                        result: await host.listOperations(beginSnapshotBarrier: {
                            response.beginSnapshotBarrier()
                        })
                    )
                )
            )
        }
    }

    func operationStatus(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply, snapshotBarrier: true)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeOperationStatusControlReply(error: Self.rejection(for: admission).wireError)
                )
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .operationStatus,
                as: RuntimeOperationStatusControlRequest.self
            ) {
                response.send(
                    Self.encode(RuntimeOperationStatusControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeOperationStatusControlRequest.self,
                    from: request
                )
            else {
                response.send(Self.encode(RuntimeOperationStatusControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                let result = try await host.operationStatus(
                    decoded.operationID,
                    beginSnapshotBarrier: {
                        response.beginSnapshotBarrier()
                    }
                )
                response.send(Self.encode(RuntimeOperationStatusControlReply(result: result)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeOperationStatusControlReply(error: wireError)))
            }
        }
    }

    func subscribe(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID, allowDuringShutdown: true)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeSubscribeControlReply(
                        error: Self.rejection(for: admission).wireError
                    )))
            return
        }
        Task { [connectionRegistry = self.connectionRegistry, connectionID = self.connectionID] in
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .subscribe,
                as: RuntimeSubscribeControlRequest.self
            ) {
                response.send(Self.encode(RuntimeSubscribeControlReply(error: Self.wireError(for: failure))))
                return
            }
            guard let decoded = try? JSONDecoder().decode(RuntimeSubscribeControlRequest.self, from: request) else {
                response.send(Self.encode(RuntimeSubscribeControlReply(error: Self.malformedWireError)))
                return
            }
            guard await verifyEventSink(eventSink) else {
                response.send(
                    Self.encode(
                        RuntimeSubscribeControlReply(
                            error: .runtime(
                                "malformedRequest",
                                message: "The client event receiver is unavailable."
                            )
                        )
                    )
                )
                return
            }
            do {
                let topics = try host.eventHub.subscribe(
                    connectionID: connectionID,
                    clientKind: clientKind,
                    topics: decoded.topics,
                    sink: eventSink,
                    outputQueue: outputQueue,
                    isConnectionOpen: { [weak connectionRegistry, connectionID] in
                        connectionRegistry?.isRegistered(connectionID) == true
                    }
                )
                response.send(Self.encode(RuntimeSubscribeControlReply(result: topics)))
            } catch let error as RuntimeWireError {
                response.send(Self.encode(RuntimeSubscribeControlReply(error: error)))
            } catch {
                response.send(Self.encode(RuntimeSubscribeControlReply(error: Self.internalWireError)))
            }
        }
    }

    /// `notificationRelay` (§11.3): opens (or reuses) the wrapper's relay
    /// stream for its own package and returns the handle.
    func notificationRelay(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeStreamHandleControlReply(
                        error: Self.rejection(for: admission).wireError)))
            return
        }
        Task { [connectionRegistry = self.connectionRegistry, connectionID = self.connectionID] in
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .notificationRelay,
                as: NotificationRelayRequest.self
            ) {
                response.send(
                    Self.encode(RuntimeStreamHandleControlReply(error: Self.wireError(for: failure))))
                return
            }
            guard clientKind == .wrapper, let packageID = wrapperPackageID else {
                response.send(
                    Self.encode(
                        RuntimeStreamHandleControlReply(
                            error: Self.wireError(
                                for: RuntimeControlError(
                                    code: "runtime.notAuthorized",
                                    message: "This part of APKRun isn't allowed to do that.")))))
                return
            }
            guard await verifyEventSink(eventSink) else {
                response.send(
                    Self.encode(
                        RuntimeStreamHandleControlReply(
                            error: .runtime(
                                "malformedRequest",
                                message: "The client event receiver is unavailable."))))
                return
            }
            do {
                let handle = try host.streamCenter.openNotificationRelay(
                    connectionID: connectionID,
                    packageID: packageID,
                    sink: eventSink,
                    outputQueue: outputQueue,
                    isOpen: { [weak connectionRegistry, connectionID] in
                        connectionRegistry?.isRegistered(connectionID) == true
                    }
                )
                response.send(Self.encode(RuntimeStreamHandleControlReply(result: handle)))
            } catch let error as RuntimeWireError {
                response.send(Self.encode(RuntimeStreamHandleControlReply(error: error)))
            } catch {
                response.send(Self.encode(RuntimeStreamHandleControlReply(error: Self.internalWireError)))
            }
        }
    }

    /// `notificationRelayResponse` (§11.3): routes the wrapper's answer to
    /// the coordinator.
    func notificationRelayResponse(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeStreamControlReply(error: Self.rejection(for: admission).wireError)))
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .notificationRelayResponse,
                as: RelayResponseRequest.self
            ) {
                response.send(Self.encode(RuntimeStreamControlReply(error: Self.wireError(for: failure))))
                return
            }
            guard let decoded = try? JSONDecoder().decode(RelayResponseRequest.self, from: request),
                host.streamCenter.recordRelayResponse(
                    decoded.streamID, decoded.response, from: connectionID)
            else {
                response.send(
                    Self.encode(
                        RuntimeStreamControlReply(
                            error: .runtime(
                                "malformedRequest",
                                message: "The response names no live stream of this connection."))))
                return
            }
            response.send(Self.encode(RuntimeStreamControlReply()))
        }
    }

    /// `hostNotifications` (§11.3): opens the app's single stream; an existing
    /// one ends with `replaced`.
    func hostNotifications(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeStreamHandleControlReply(
                        error: Self.rejection(for: admission).wireError)))
            return
        }
        Task { [connectionRegistry = self.connectionRegistry, connectionID = self.connectionID] in
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .hostNotifications,
                as: HostNotificationsRequest.self
            ) {
                response.send(
                    Self.encode(RuntimeStreamHandleControlReply(error: Self.wireError(for: failure))))
                return
            }
            guard await verifyEventSink(eventSink) else {
                response.send(
                    Self.encode(
                        RuntimeStreamHandleControlReply(
                            error: .runtime(
                                "malformedRequest",
                                message: "The client event receiver is unavailable."))))
                return
            }
            do {
                let handle = try host.streamCenter.openHostNotifications(
                    connectionID: connectionID,
                    sink: eventSink,
                    outputQueue: outputQueue,
                    isOpen: { [weak connectionRegistry, connectionID] in
                        connectionRegistry?.isRegistered(connectionID) == true
                    }
                )
                response.send(Self.encode(RuntimeStreamHandleControlReply(result: handle)))
            } catch let error as RuntimeWireError {
                response.send(Self.encode(RuntimeStreamHandleControlReply(error: error)))
            } catch {
                response.send(Self.encode(RuntimeStreamHandleControlReply(error: Self.internalWireError)))
            }
        }
    }

    /// `hostNotificationResponse` (§11.3): routes the app's answer.
    func hostNotificationResponse(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeStreamControlReply(error: Self.rejection(for: admission).wireError)))
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .hostNotificationResponse,
                as: HostNotificationResponseRequest.self
            ) {
                response.send(Self.encode(RuntimeStreamControlReply(error: Self.wireError(for: failure))))
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    HostNotificationResponseRequest.self, from: request),
                host.streamCenter.recordHostNotificationResponse(
                    decoded.streamID, decoded.response, from: connectionID)
            else {
                response.send(
                    Self.encode(
                        RuntimeStreamControlReply(
                            error: .runtime(
                                "malformedRequest",
                                message: "The response names no live stream of this connection."))))
                return
            }
            response.send(Self.encode(RuntimeStreamControlReply()))
        }
    }

    /// `closeStream` (§16.4): idempotent for unknown, ended, or foreign
    /// streams.
    func closeStream(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID, allowDuringShutdown: true)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeStreamControlReply(error: Self.rejection(for: admission).wireError)))
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .closeStream,
                as: CloseStreamRequest.self
            ) {
                response.send(Self.encode(RuntimeStreamControlReply(error: Self.wireError(for: failure))))
                return
            }
            if let decoded = try? JSONDecoder().decode(CloseStreamRequest.self, from: request) {
                host.streamCenter.closeStream(decoded.streamID, from: connectionID)
            }
            response.send(Self.encode(RuntimeStreamControlReply()))
        }
    }

    func installImage(_ request: Data, files: [FileHandle], reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(WireImageInstallReply(error: Self.rejection(for: admission).wireError)))
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .installImage,
                as: WireImageInstallRequest.self
            ) {
                response.send(
                    Self.encode(WireImageInstallReply(error: Self.wireError(for: failure))))
                return
            }
            guard files.count == 1 else {
                response.send(
                    Self.encode(WireImageInstallReply(error: Self.malformedWireError)))
                return
            }
            do {
                let version = try await host.installImage(from: files[0])
                response.send(Self.encode(WireImageInstallReply(version: version.description)))
            } catch {
                response.send(Self.encode(WireImageInstallReply(error: Self.imageWireError(error))))
            }
        }
    }

    func imageStatus(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(WireImageStatusReply(error: Self.rejection(for: admission).wireError)))
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .imageStatus,
                as: WireImageStatusRequest.self
            ) {
                response.send(
                    Self.encode(WireImageStatusReply(error: Self.wireError(for: failure))))
                return
            }
            response.send(Self.encode(WireImageStatusReply(status: await host.imageStatus())))
        }
    }

    func applyImage(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(WireImageApplyReply(error: Self.rejection(for: admission).wireError)))
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .applyImage,
                as: WireImageApplyRequest.self
            ) {
                response.send(
                    Self.encode(WireImageApplyReply(error: Self.wireError(for: failure))))
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    WireImageApplyRequest.self, from: request)
            else {
                response.send(Self.encode(WireImageApplyReply(error: Self.malformedWireError)))
                return
            }
            do {
                try await host.applyImage(decoded.version)
                response.send(Self.encode(WireImageApplyReply(result: "Applied.")))
            } catch {
                response.send(Self.encode(WireImageApplyReply(error: Self.imageWireError(error))))
            }
        }
    }

    func rollbackImage(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(WireImageApplyReply(error: Self.rejection(for: admission).wireError)))
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .rollbackImage,
                as: WireImageRollbackRequest.self
            ) {
                response.send(
                    Self.encode(WireImageApplyReply(error: Self.wireError(for: failure))))
                return
            }
            do {
                let result = try await host.rollbackImage()
                response.send(Self.encode(WireImageApplyReply(result: result)))
            } catch {
                response.send(Self.encode(WireImageApplyReply(error: Self.imageWireError(error))))
            }
        }
    }

    /// Runs the health checks (`apkrun doctor`). Reply: `WireHealthReport`.
    func healthReport(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(WireHealthReport(error: Self.rejection(for: admission).wireError)))
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .healthReport,
                as: HealthRequest.self
            ) {
                response.send(
                    Self.encode(WireHealthReport(error: Self.wireError(for: failure))))
                return
            }
            guard let decoded = try? JSONDecoder().decode(HealthRequest.self, from: request)
            else {
                response.send(Self.encode(WireHealthReport(error: Self.malformedWireError)))
                return
            }
            do {
                let report = try await host.healthReport(
                    deep: decoded.deep, checks: decoded.checks)
                response.send(Self.encode(report))
            } catch {
                response.send(
                    Self.encode(
                        WireHealthReport(
                            error: error as? RuntimeWireError ?? Self.malformedWireError)))
            }
        }
    }

    /// Applies safe health repairs (`apkrun doctor --fix`). Reply:
    /// `WireHealthReport`.
    func applyHealthFixes(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(WireHealthReport(error: Self.rejection(for: admission).wireError)))
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .applyHealthFixes,
                as: HealthFixRequest.self
            ) {
                response.send(
                    Self.encode(WireHealthReport(error: Self.wireError(for: failure))))
                return
            }
            guard let decoded = try? JSONDecoder().decode(HealthFixRequest.self, from: request)
            else {
                response.send(Self.encode(WireHealthReport(error: Self.malformedWireError)))
                return
            }
            do {
                let report = try await host.applyHealthFixes(checks: decoded.checks)
                response.send(Self.encode(report))
            } catch {
                response.send(
                    Self.encode(
                        WireHealthReport(
                            error: error as? RuntimeWireError ?? Self.malformedWireError)))
            }
        }
    }

    func createDiagnostics(_ request: Data, files: [FileHandle], reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeCreateDiagnosticsControlReply(
                        error: Self.rejection(for: admission).wireError)))
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .createDiagnostics,
                as: RuntimeCreateDiagnosticsControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeCreateDiagnosticsControlReply(
                            error: Self.wireError(for: failure))))
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeCreateDiagnosticsControlRequest.self,
                    from: request
                ),
                let operationID = RuntimeAPI.OperationID(rawValue: decoded.header.operationID),
                let output = files.first
            else {
                response.send(
                    Self.encode(
                        RuntimeCreateDiagnosticsControlReply(
                            error: Self.malformedWireError)))
                return
            }
            do {
                let result = try await host.createDiagnostics(
                    decoded.request,
                    output: output,
                    operationID: operationID,
                    clientKind: decoded.header.clientKind
                )
                response.send(
                    Self.encode(RuntimeCreateDiagnosticsControlReply(result: result)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(
                    Self.encode(RuntimeCreateDiagnosticsControlReply(error: wireError)))
            }
        }
    }

    func imageFeedAction(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(WireImageApplyReply(error: Self.rejection(for: admission).wireError)))
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .imageFeedAction,
                as: WireImageFeedActionRequest.self
            ) {
                response.send(
                    Self.encode(WireImageApplyReply(error: Self.wireError(for: failure))))
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    WireImageFeedActionRequest.self, from: request)
            else {
                response.send(Self.encode(WireImageApplyReply(error: Self.malformedWireError)))
                return
            }
            do {
                let result: String
                if decoded.action == "install-latest" {
                    result = try await host.imageInstallLatest()
                } else {
                    result = await host.imageCheckNow()
                }
                response.send(Self.encode(WireImageApplyReply(result: result)))
            } catch {
                response.send(Self.encode(WireImageApplyReply(error: Self.imageWireError(error))))
            }
        }
    }

    func deleteImageRecoveryPoint(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(WireImageApplyReply(error: Self.rejection(for: admission).wireError)))
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .deleteImageRecoveryPoint,
                as: WireImageRecoveryPointDeleteRequest.self
            ) {
                response.send(
                    Self.encode(WireImageApplyReply(error: Self.wireError(for: failure))))
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    WireImageRecoveryPointDeleteRequest.self, from: request)
            else {
                response.send(Self.encode(WireImageApplyReply(error: Self.malformedWireError)))
                return
            }
            do {
                try await host.deleteImageRecoveryPoint(named: decoded.name)
                response.send(Self.encode(WireImageApplyReply(result: "Deleted.")))
            } catch {
                response.send(Self.encode(WireImageApplyReply(error: Self.imageWireError(error))))
            }
        }
    }

    private func verifyEventSink(_ sink: RuntimeEventSinkReference?) async -> Bool {
        guard let sink else { return false }
        return await withCheckedContinuation { continuation in
            let gate = XPCEventSinkHandshakeGate(continuation)
            let timeout = DispatchWorkItem {
                gate.complete(false)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(1), execute: timeout)
            outputQueue.async {
                sink.value.handshake { available in
                    timeout.cancel()
                    gate.complete(available)
                }
            }
        }
    }

    func unsubscribe(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID, allowDuringShutdown: true)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeUnsubscribeControlReply(
                        error: Self.rejection(for: admission).wireError
                    )))
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .unsubscribe,
                as: RuntimeUnsubscribeControlRequest.self
            ) {
                response.send(Self.encode(RuntimeUnsubscribeControlReply(error: Self.wireError(for: failure))))
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeUnsubscribeControlRequest.self,
                    from: request
                )
            else {
                response.send(Self.encode(RuntimeUnsubscribeControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                try host.eventHub.unsubscribe(
                    connectionID: connectionID,
                    clientKind: clientKind,
                    topics: decoded.topics
                )
                response.send(Self.encode(RuntimeUnsubscribeControlReply()))
            } catch let error as RuntimeWireError {
                response.send(Self.encode(RuntimeUnsubscribeControlReply(error: error)))
            } catch {
                response.send(Self.encode(RuntimeUnsubscribeControlReply(error: Self.internalWireError)))
            }
        }
    }

    func launch(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
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
                let result = try await host.launch(
                    RuntimeLaunchRequest(
                        packageID: decoded.packageID, launchTiming: decoded.launchTiming))
                response.send(Self.encode(RuntimeLaunchControlReply(result: result)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeLaunchControlReply(error: wireError)))
            }
        }
    }

    func terminate(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
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

    func closeSession(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(Self.encode(RuntimeCloseSessionControlReply(error: Self.rejection(for: admission).wireError)))
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .closeSession,
                as: RuntimeCloseSessionControlRequest.self
            ) {
                response.send(
                    Self.encode(RuntimeCloseSessionControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            guard let decoded = try? JSONDecoder().decode(RuntimeCloseSessionControlRequest.self, from: request) else {
                response.send(Self.encode(RuntimeCloseSessionControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                let result = try await host.closeSession(
                    RuntimeCloseSessionRequest(packageID: decoded.packageID, policy: decoded.policy))
                response.send(Self.encode(RuntimeCloseSessionControlReply(hadSession: result.hadSession)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeCloseSessionControlReply(error: wireError)))
            }
        }
    }

    func verifyWrapper(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(RuntimeVerifyWrapperControlReply(error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .verifyWrapper,
                as: RuntimeVerifyWrapperControlRequest.self
            ) {
                response.send(
                    Self.encode(RuntimeVerifyWrapperControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            guard let decoded = try? JSONDecoder().decode(RuntimeVerifyWrapperControlRequest.self, from: request) else {
                response.send(
                    Self.encode(RuntimeVerifyWrapperControlReply(error: Self.malformedWireError))
                )
                return
            }
            do {
                let result = try await host.verifyWrapper(
                    VerifyWrapperRequest(bundleURL: decoded.bundleURL, deep: decoded.deep)
                )
                response.send(Self.encode(RuntimeVerifyWrapperControlReply(result: result)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeVerifyWrapperControlReply(error: wireError)))
            }
        }
    }

    func createWrapper(_ request: Data, icon: FileHandle?, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(RuntimeCreateWrapperControlReply(error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .createWrapper,
                as: RuntimeCreateWrapperControlRequest.self
            ) {
                response.send(
                    Self.encode(RuntimeCreateWrapperControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeCreateWrapperControlRequest.self,
                    from: request
                ),
                let operationID = RuntimeAPI.OperationID(rawValue: decoded.header.operationID)
            else {
                response.send(
                    Self.encode(RuntimeCreateWrapperControlReply(error: Self.malformedWireError))
                )
                return
            }
            do {
                let result = try await host.createWrapper(
                    decoded.request,
                    icon: icon,
                    operationID: operationID,
                    clientKind: decoded.header.clientKind
                )
                response.send(Self.encode(RuntimeCreateWrapperControlReply(result: result)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeCreateWrapperControlReply(error: wireError)))
            }
        }
    }

    func buildDistributionWrapper(_ request: Data, icon: FileHandle?, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeBuildDistributionWrapperControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .buildDistributionWrapper,
                as: RuntimeBuildDistributionWrapperControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeBuildDistributionWrapperControlReply(
                            error: Self.wireError(for: failure)))
                )
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeBuildDistributionWrapperControlRequest.self,
                    from: request
                ),
                let operationID = RuntimeAPI.OperationID(rawValue: decoded.header.operationID)
            else {
                response.send(
                    Self.encode(
                        RuntimeBuildDistributionWrapperControlReply(
                            error: Self.malformedWireError))
                )
                return
            }
            do {
                let result = try await host.buildDistributionWrapper(
                    decoded.request,
                    icon: icon,
                    operationID: operationID,
                    clientKind: decoded.header.clientKind
                )
                response.send(
                    Self.encode(
                        RuntimeBuildDistributionWrapperControlReply(result: result)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(
                    Self.encode(
                        RuntimeBuildDistributionWrapperControlReply(error: wireError)))
            }
        }
    }

    func placeStagedWrapper(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimePlaceStagedWrapperControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .placeStagedWrapper,
                as: RuntimePlaceStagedWrapperControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimePlaceStagedWrapperControlReply(
                            error: Self.wireError(for: failure)))
                )
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimePlaceStagedWrapperControlRequest.self,
                    from: request
                )
            else {
                response.send(
                    Self.encode(
                        RuntimePlaceStagedWrapperControlReply(error: Self.malformedWireError))
                )
                return
            }
            do {
                let result = try await host.placeStagedWrapper(
                    stagingToken: decoded.stagingToken,
                    finalURL: decoded.finalURL,
                    bookmark: decoded.bookmark
                )
                response.send(Self.encode(RuntimePlaceStagedWrapperControlReply(result: result)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(
                    Self.encode(RuntimePlaceStagedWrapperControlReply(error: wireError)))
            }
        }
    }

    func wrapperInfo(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeWrapperInfoControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .wrapperInfo,
                as: RuntimeWrapperInfoControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeWrapperInfoControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeWrapperInfoControlRequest.self,
                    from: request
                )
            else {
                response.send(
                    Self.encode(RuntimeWrapperInfoControlReply(error: Self.malformedWireError))
                )
                return
            }
            do {
                let result = try await host.wrapperInfo(
                    RuntimePackageRequest(packageID: decoded.packageID)
                )
                response.send(Self.encode(RuntimeWrapperInfoControlReply(result: result)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeWrapperInfoControlReply(error: wireError)))
            }
        }
    }

    func packageSettings(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimePackageSettingsControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .packageSettings,
                as: RuntimePackageSettingsControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimePackageSettingsControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimePackageSettingsControlRequest.self,
                    from: request
                )
            else {
                response.send(
                    Self.encode(
                        RuntimePackageSettingsControlReply(error: Self.malformedWireError))
                )
                return
            }
            do {
                let result = try await host.packageSettings(decoded.request.packageID)
                response.send(Self.encode(RuntimePackageSettingsControlReply(result: result)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimePackageSettingsControlReply(error: wireError)))
            }
        }
    }

    func updatePackageSettings(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeUpdatePackageSettingsControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .updatePackageSettings,
                as: RuntimeUpdatePackageSettingsControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeUpdatePackageSettingsControlReply(
                            error: Self.wireError(for: failure)))
                )
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeUpdatePackageSettingsControlRequest.self,
                    from: request
                )
            else {
                response.send(
                    Self.encode(
                        RuntimeUpdatePackageSettingsControlReply(
                            error: Self.malformedWireError))
                )
                return
            }
            do {
                let result = try await host.updatePackageSettings(decoded.request)
                response.send(
                    Self.encode(RuntimeUpdatePackageSettingsControlReply(result: result)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(
                    Self.encode(RuntimeUpdatePackageSettingsControlReply(error: wireError)))
            }
        }
    }

    func listWrappers(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeWrapperListControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .listWrappers,
                as: RuntimeWrapperListControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeWrapperListControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            do {
                let result = try await host.listWrappers()
                response.send(Self.encode(RuntimeWrapperListControlReply(result: result)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeWrapperListControlReply(error: wireError)))
            }
        }
    }

    func removeWrapper(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeRemoveWrapperControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .removeWrapper,
                as: RuntimeRemoveWrapperControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeRemoveWrapperControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeRemoveWrapperControlRequest.self,
                    from: request
                )
            else {
                response.send(
                    Self.encode(
                        RuntimeRemoveWrapperControlReply(error: Self.malformedWireError))
                )
                return
            }
            do {
                let result = try await host.removeWrapper(
                    packageID: decoded.packageID, trash: decoded.trash)
                response.send(Self.encode(RuntimeRemoveWrapperControlReply(result: result)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(
                    Self.encode(RuntimeRemoveWrapperControlReply(error: wireError)))
            }
        }
    }

    func rescanWrappers(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeRescanWrappersControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .rescanWrappers,
                as: RuntimeRescanWrappersControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeRescanWrappersControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeRescanWrappersControlRequest.self,
                    from: request
                )
            else {
                response.send(
                    Self.encode(
                        RuntimeRescanWrappersControlReply(error: Self.malformedWireError))
                )
                return
            }
            do {
                let result = try await host.rescanWrappers(register: decoded.register)
                response.send(Self.encode(RuntimeRescanWrappersControlReply(result: result)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(
                    Self.encode(RuntimeRescanWrappersControlReply(error: wireError)))
            }
        }
    }

    func refreshWrapper(_ request: Data, icon: FileHandle?, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeRefreshWrapperControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .refreshWrapper,
                as: RuntimeRefreshWrapperControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeRefreshWrapperControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeRefreshWrapperControlRequest.self,
                    from: request
                ),
                let operationID = RuntimeAPI.OperationID(rawValue: decoded.header.operationID)
            else {
                response.send(
                    Self.encode(RuntimeRefreshWrapperControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                let result = try await host.refreshWrapper(
                    packageID: decoded.packageID,
                    change: decoded.change,
                    icon: icon,
                    operationID: operationID,
                    clientKind: decoded.header.clientKind
                )
                response.send(Self.encode(RuntimeRefreshWrapperControlReply(result: result)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeRefreshWrapperControlReply(error: wireError)))
            }
        }
    }

    func refreshAllWrappers(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeRefreshAllWrappersControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .refreshAllWrappers,
                as: RuntimeRefreshAllWrappersControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeRefreshAllWrappersControlReply(
                            error: Self.wireError(for: failure)))
                )
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeRefreshAllWrappersControlRequest.self,
                    from: request
                ),
                let operationID = RuntimeAPI.OperationID(rawValue: decoded.header.operationID)
            else {
                response.send(
                    Self.encode(
                        RuntimeRefreshAllWrappersControlReply(
                            error: Self.malformedWireError)))
                return
            }
            do {
                let result = try await host.refreshAllWrappers(
                    scope: decoded.scope,
                    launcherOnly: decoded.launcherOnly,
                    operationID: operationID,
                    clientKind: decoded.header.clientKind
                )
                response.send(Self.encode(RuntimeRefreshAllWrappersControlReply(result: result)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(
                    Self.encode(RuntimeRefreshAllWrappersControlReply(error: wireError)))
            }
        }
    }

    func pendingApprovals(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimePendingApprovalsControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .pendingApprovals,
                as: RuntimePendingApprovalsControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimePendingApprovalsControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            let prompts = await host.pendingApprovals()
            response.send(Self.encode(RuntimePendingApprovalsControlReply(result: prompts)))
        }
    }

    func decideApproval(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeDecideApprovalControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .decideApproval,
                as: RuntimeDecideApprovalControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeDecideApprovalControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeDecideApprovalControlRequest.self,
                    from: request
                )
            else {
                response.send(
                    Self.encode(RuntimeDecideApprovalControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                try await host.decideApproval(
                    DecideApprovalRequest(approvalID: decoded.approvalID, allow: decoded.allow))
                response.send(Self.encode(RuntimeDecideApprovalControlReply()))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeDecideApprovalControlReply(error: wireError)))
            }
        }
    }

    func deniedWrappers(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeDeniedWrappersControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .deniedWrappers,
                as: RuntimeDeniedWrappersControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeDeniedWrappersControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            let denied = await host.deniedWrappers()
            response.send(Self.encode(RuntimeDeniedWrappersControlReply(result: denied)))
        }
    }

    func clearWrapperDenial(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeClearWrapperDenialControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .clearWrapperDenial,
                as: RuntimeClearWrapperDenialControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeClearWrapperDenialControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeClearWrapperDenialControlRequest.self,
                    from: request
                )
            else {
                response.send(
                    Self.encode(
                        RuntimeClearWrapperDenialControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                try await host.clearWrapperDenial(
                    ClearWrapperDenialRequest(bundleID: decoded.bundleID, cdhash: decoded.cdhash))
                response.send(Self.encode(RuntimeClearWrapperDenialControlReply()))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeClearWrapperDenialControlReply(error: wireError)))
            }
        }
    }

    func perfStatistics(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimePerfStatisticsControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .perfStatistics,
                as: RuntimePerfStatisticsControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimePerfStatisticsControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimePerfStatisticsControlRequest.self,
                    from: request
                )
            else {
                response.send(
                    Self.encode(
                        RuntimePerfStatisticsControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                let result = try await host.perfStatistics(
                    PerfStatisticsRequest(reset: decoded.reset))
                response.send(Self.encode(RuntimePerfStatisticsControlReply(result: result)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimePerfStatisticsControlReply(error: wireError)))
            }
        }
    }

    func frameStatistics(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeFrameStatisticsControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .frameStatistics,
                as: RuntimeFrameStatisticsControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeFrameStatisticsControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeFrameStatisticsControlRequest.self,
                    from: request
                )
            else {
                response.send(
                    Self.encode(
                        RuntimeFrameStatisticsControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                let sessions = try await host.frameStatistics(sessionID: decoded.sessionID)
                response.send(Self.encode(RuntimeFrameStatisticsControlReply(sessions: sessions)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeFrameStatisticsControlReply(error: wireError)))
            }
        }
    }

    func pushClipboard(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimePushClipboardControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .pushClipboard,
                as: RuntimePushClipboardControlRequest.self,
                byteLimit: Self.maximumClipboardRequestSize
            ) {
                response.send(
                    Self.encode(
                        RuntimePushClipboardControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimePushClipboardControlRequest.self,
                    from: request
                )
            else {
                response.send(
                    Self.encode(
                        RuntimePushClipboardControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                let ack = try await host.pushClipboard(
                    sessionID: decoded.sessionID, item: decoded.item)
                response.send(Self.encode(RuntimePushClipboardControlReply(ack: ack)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimePushClipboardControlReply(error: wireError)))
            }
        }
    }

    func clipboardWritten(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeClipboardWrittenControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .clipboardWritten,
                as: RuntimeClipboardWrittenControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeClipboardWrittenControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeClipboardWrittenControlRequest.self,
                    from: request
                )
            else {
                response.send(
                    Self.encode(
                        RuntimeClipboardWrittenControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                try await host.clipboardWritten(
                    sessionID: decoded.sessionID, written: decoded.written)
                response.send(Self.encode(RuntimeClipboardWrittenControlReply()))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeClipboardWrittenControlReply(error: wireError)))
            }
        }
    }

    func focusChanged(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeFocusChangedControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .focusChanged,
                as: RuntimeFocusChangedControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeFocusChangedControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeFocusChangedControlRequest.self,
                    from: request
                )
            else {
                response.send(
                    Self.encode(
                        RuntimeFocusChangedControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                try await host.focusChanged(sessionID: decoded.sessionID, isKey: decoded.isKey)
                response.send(Self.encode(RuntimeFocusChangedControlReply()))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeFocusChangedControlReply(error: wireError)))
            }
        }
    }

    func resolveLinkPrompt(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeResolveLinkPromptControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .resolveLinkPrompt,
                as: RuntimeResolveLinkPromptControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeResolveLinkPromptControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeResolveLinkPromptControlRequest.self,
                    from: request
                )
            else {
                response.send(
                    Self.encode(
                        RuntimeResolveLinkPromptControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                // NFR-SEC-07: a wrapper connection may only answer prompts of
                // its own package; the forwarder reports a mismatch as an
                // expired prompt (runtime-api.md §10.1, §11.2).
                try await host.resolveLinkPrompt(
                    sessionID: decoded.sessionID,
                    promptID: decoded.promptID,
                    choice: decoded.choice,
                    remember: decoded.remember,
                    callerPackageID: wrapperPackageID)
                response.send(Self.encode(RuntimeResolveLinkPromptControlReply(result: RuntimeEmpty())))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeResolveLinkPromptControlReply(error: wireError)))
            }
        }
    }

    func integrationStatus(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeIntegrationStatusControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .integrationStatus,
                as: RuntimeIntegrationStatusControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeIntegrationStatusControlReply(error: Self.wireError(for: failure)))
                )
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeIntegrationStatusControlRequest.self,
                    from: request
                )
            else {
                response.send(
                    Self.encode(
                        RuntimeIntegrationStatusControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                let status = try await host.integrationStatus(packageID: decoded.packageID)
                response.send(Self.encode(RuntimeIntegrationStatusControlReply(status: status)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeIntegrationStatusControlReply(error: wireError)))
            }
        }
    }

    func importFiles(_ request: Data, files: [FileHandle], reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeImportFilesSessionReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .importFiles,
                as: RuntimeImportFilesSessionRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeImportFilesSessionReply(error: Self.wireError(for: failure))))
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeImportFilesSessionRequest.self,
                    from: request
                )
            else {
                response.send(
                    Self.encode(
                        RuntimeImportFilesSessionReply(error: Self.malformedWireError)))
                return
            }
            do {
                // NFR-SEC-07: a wrapper imports files for its own session
                // only; the session's package is resolved by the host.
                let result = try await host.importFiles(
                    sessionID: decoded.sessionID,
                    files: files,
                    infos: decoded.files,
                    target: decoded.target,
                    callerPackageID: wrapperPackageID)
                response.send(Self.encode(RuntimeImportFilesSessionReply(result: result)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeImportFilesSessionReply(error: wireError)))
            }
        }
    }

    func acceptExport(_ request: Data, files: [FileHandle], reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeAcceptExportSessionReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .acceptExport,
                as: RuntimeAcceptExportSessionRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeAcceptExportSessionReply(error: Self.wireError(for: failure))))
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeAcceptExportSessionRequest.self,
                    from: request
                )
            else {
                response.send(
                    Self.encode(
                        RuntimeAcceptExportSessionReply(error: Self.malformedWireError)))
                return
            }
            do {
                try await host.acceptExport(
                    sessionID: decoded.sessionID,
                    offerID: decoded.offerID,
                    fileIndex: decoded.fileIndex,
                    target: files.first,
                    callerPackageID: wrapperPackageID)
                response.send(Self.encode(RuntimeAcceptExportSessionReply(result: RuntimeEmpty())))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeAcceptExportSessionReply(error: wireError)))
            }
        }
    }

    func sharedFolders(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeSharedFoldersControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .sharedFolders,
                as: RuntimeSharedFoldersControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeSharedFoldersControlReply(error: Self.wireError(for: failure))))
                return
            }
            do {
                let roots = try await host.sharedFolders()
                response.send(Self.encode(RuntimeSharedFoldersControlReply(result: roots)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeSharedFoldersControlReply(error: wireError)))
            }
        }
    }

    func addSharedFolder(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeSharedFolderControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .addSharedFolder,
                as: RuntimeAddSharedFolderControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeSharedFolderControlReply(error: Self.wireError(for: failure))))
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeAddSharedFolderControlRequest.self,
                    from: request
                )
            else {
                response.send(
                    Self.encode(
                        RuntimeSharedFolderControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                let root = try await host.addSharedFolder(
                    bookmark: decoded.bookmark, access: decoded.access)
                response.send(Self.encode(RuntimeSharedFolderControlReply(result: root)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeSharedFolderControlReply(error: wireError)))
            }
        }
    }

    func removeSharedFolder(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeRemoveSharedFolderControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .removeSharedFolder,
                as: RuntimeRemoveSharedFolderControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeRemoveSharedFolderControlReply(
                            error: Self.wireError(for: failure))))
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeRemoveSharedFolderControlRequest.self,
                    from: request
                )
            else {
                response.send(
                    Self.encode(
                        RuntimeRemoveSharedFolderControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                try await host.removeSharedFolder(id: decoded.id)
                response.send(
                    Self.encode(RuntimeRemoveSharedFolderControlReply(result: RuntimeEmpty())))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeRemoveSharedFolderControlReply(error: wireError)))
            }
        }
    }

    func setSharedFolderAccess(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeSharedFolderControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .setSharedFolderAccess,
                as: RuntimeSetSharedFolderAccessControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeSharedFolderControlReply(error: Self.wireError(for: failure))))
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeSetSharedFolderAccessControlRequest.self,
                    from: request
                )
            else {
                response.send(
                    Self.encode(
                        RuntimeSharedFolderControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                let root = try await host.setSharedFolderAccess(
                    id: decoded.id, access: decoded.access)
                response.send(Self.encode(RuntimeSharedFolderControlReply(result: root)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeSharedFolderControlReply(error: wireError)))
            }
        }
    }

    func checkForUpdates(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeCheckForUpdatesControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .checkForUpdates,
                as: RuntimeCheckForUpdatesControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeCheckForUpdatesControlReply(error: Self.wireError(for: failure))))
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeCheckForUpdatesControlRequest.self,
                    from: request
                )
            else {
                response.send(
                    Self.encode(
                        RuntimeCheckForUpdatesControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                let (operation, results) = try await host.checkForUpdates(
                    packages: decoded.packages,
                    checkOnly: decoded.checkOnly,
                    operationID: OperationID(rawValue: decoded.header.operationID)
                        ?? OperationID(),
                    requestPayload: request,
                    clientKind: clientKind
                )
                response.send(
                    Self.encode(
                        RuntimeCheckForUpdatesControlReply(
                            operation: operation, results: results)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeCheckForUpdatesControlReply(error: wireError)))
            }
        }
    }

    func listUpdates(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeListUpdatesControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .listUpdates,
                as: RuntimeListUpdatesControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeListUpdatesControlReply(error: Self.wireError(for: failure))))
                return
            }
            guard
                (try? JSONDecoder().decode(
                    RuntimeListUpdatesControlRequest.self,
                    from: request
                )) != nil
            else {
                response.send(
                    Self.encode(
                        RuntimeListUpdatesControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                let updates = try await host.listUpdates()
                response.send(Self.encode(RuntimeListUpdatesControlReply(updates: updates)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeListUpdatesControlReply(error: wireError)))
            }
        }
    }

    func updateHistory(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeUpdateHistoryControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .updateHistory,
                as: RuntimeUpdateHistoryControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeUpdateHistoryControlReply(error: Self.wireError(for: failure))))
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeUpdateHistoryControlRequest.self,
                    from: request
                )
            else {
                response.send(
                    Self.encode(
                        RuntimeUpdateHistoryControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                let entries = try await host.updateHistory(
                    packageID: decoded.packageID,
                    limit: min(decoded.limit ?? 50, 1000)
                )
                response.send(Self.encode(RuntimeUpdateHistoryControlReply(entries: entries)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeUpdateHistoryControlReply(error: wireError)))
            }
        }
    }

    func setUpdatePolicy(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeSetUpdatePolicyControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .setUpdatePolicy,
                as: RuntimeSetUpdatePolicyControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeSetUpdatePolicyControlReply(error: Self.wireError(for: failure))))
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeSetUpdatePolicyControlRequest.self,
                    from: request
                )
            else {
                response.send(
                    Self.encode(
                        RuntimeSetUpdatePolicyControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                let status = try await host.setUpdatePolicy(
                    packageID: decoded.packageID, policy: decoded.policy)
                response.send(Self.encode(RuntimeSetUpdatePolicyControlReply(status: status)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeSetUpdatePolicyControlReply(error: wireError)))
            }
        }
    }

    func setUpdateAuthority(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeSetUpdateAuthorityControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .setUpdateAuthority,
                as: RuntimeSetUpdateAuthorityControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeSetUpdateAuthorityControlReply(error: Self.wireError(for: failure))))
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeSetUpdateAuthorityControlRequest.self,
                    from: request
                )
            else {
                response.send(
                    Self.encode(
                        RuntimeSetUpdateAuthorityControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                let status = try await host.setUpdateAuthority(
                    packageID: decoded.packageID, authority: decoded.authority)
                response.send(Self.encode(RuntimeSetUpdateAuthorityControlReply(status: status)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeSetUpdateAuthorityControlReply(error: wireError)))
            }
        }
    }

    /// `rollbackPackage` (update-system.md §8.5, cli.md §4.3).
    func rollbackPackage(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeRollbackPackageControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .rollbackPackage,
                as: RuntimeRollbackPackageControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeRollbackPackageControlReply(
                            error: Self.wireError(for: failure))))
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeRollbackPackageControlRequest.self,
                    from: request
                )
            else {
                response.send(
                    Self.encode(
                        RuntimeRollbackPackageControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                let outcome = try await host.rollbackPackage(
                    packageID: decoded.packageID, allowDataLoss: decoded.allowDataLoss)
                response.send(Self.encode(outcome))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeRollbackPackageControlReply(error: wireError)))
            }
        }
    }

    /// `repairPackage` (package-store.md §11.1, cli.md §4.3): a long
    /// operation that reinstalls a `broken` package from `current/`.
    func beginRepairPackage(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeBeginRepairPackageControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .beginRepairPackage,
                as: RuntimeBeginRepairPackageControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeBeginRepairPackageControlReply(
                            error: Self.wireError(for: failure))))
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeBeginRepairPackageControlRequest.self,
                    from: request
                ),
                let operationID = RuntimeAPI.OperationID(rawValue: decoded.header.operationID)
            else {
                response.send(
                    Self.encode(
                        RuntimeBeginRepairPackageControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                let handle = try await host.beginRepairPackage(
                    decoded.request,
                    operationID: operationID,
                    clientKind: clientKind
                )
                response.send(
                    Self.encode(RuntimeBeginRepairPackageControlReply(result: handle)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(
                    Self.encode(RuntimeBeginRepairPackageControlReply(error: wireError)))
            }
        }
    }

    /// `updateSkipped` (update-system.md §8.4, cli.md §4.3).
    func updateSkipped(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeUpdateSkipControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .updateSkipped,
                as: RuntimeUpdateSkipControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeUpdateSkipControlReply(error: Self.wireError(for: failure))))
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeUpdateSkipControlRequest.self,
                    from: request
                )
            else {
                response.send(
                    Self.encode(
                        RuntimeUpdateSkipControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                try await host.setSkippedVersion(
                    packageID: decoded.packageID,
                    versionCode: decoded.versionCode,
                    skipped: decoded.skipped)
                response.send(Self.encode(RuntimeUpdateSkipControlReply()))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeUpdateSkipControlReply(error: wireError)))
            }
        }
    }

    private func makeReplyHandler(
        _ reply: @escaping (Data) -> Void,
        snapshotBarrier: Bool = false
    ) -> XPCDataReply {
        let eventHub = host.eventHub
        let connectionID = self.connectionID
        let beginSnapshotBarrier: (@Sendable () -> Void)?
        if snapshotBarrier {
            beginSnapshotBarrier = { [eventHub, connectionID] in
                eventHub.beginSnapshotBarrier(connectionID: connectionID)
            }
        } else {
            beginSnapshotBarrier = nil
        }
        let beforeSend: (@Sendable () -> Void)?
        let sendAfterBarrier: (@Sendable (@escaping @Sendable () -> Void) -> Void)?
        if snapshotBarrier {
            beforeSend = { [eventHub] in
                eventHub.flush(connectionID: connectionID)
            }
            sendAfterBarrier = { [eventHub, outputQueue] sendReply in
                eventHub.endSnapshotBarrier(
                    connectionID: connectionID,
                    outputQueue: outputQueue,
                    reply: sendReply
                )
            }
        } else {
            beforeSend = { [eventHub] in
                eventHub.flush(connectionID: connectionID)
            }
            sendAfterBarrier = nil
        }
        return XPCDataReply(
            reply,
            outputQueue: outputQueue,
            beforeSend: beforeSend,
            beginSnapshotBarrier: beginSnapshotBarrier,
            sendAfterBarrier: sendAfterBarrier
        )
    }

    private static let maximumRequestSize = 1024 * 1024

    /// The bound of a clipboard request: 1 MiB text + 1 MiB HTML + a 16 MiB
    /// PNG (which JSON-encodes to base64, ~1.34x), plus envelope overhead
    /// (runtime-api.md §11.4).
    private static let maximumClipboardRequestSize = 24 * 1024 * 1024

    private static let malformedWireError = RuntimeWireError.runtime(
        "malformedRequest",
        message: safeMessage(for: "runtime.malformedRequest")
    )
    private static let malformedControlError = RuntimeControlError(
        code: "runtime.malformedRequest",
        message: safeMessage(for: "runtime.malformedRequest")
    )
    private static let internalWireError = RuntimeWireError.runtime(
        "internal",
        message: safeMessage(for: "runtime.internal")
    )
    private static let internalControlError = RuntimeControlError(
        code: "runtime.internal",
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
        as requestType: Request.Type,
        byteLimit: Int = maximumRequestSize
    ) -> RuntimeControlError? {
        guard data.count <= byteLimit,
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
            case .hostUpdating:
                code = "runtime.hostUpdating"
            case .alreadyStarted:
                code = "runtime.internal"
            case .startupFailed(_, let startupCode):
                code =
                    startupCode == RuntimeHost.newerSettingsSchemaFailureCode
                    ? "runtime.hostStartupFailed"
                    : startupCode.contains(".") ? startupCode : "runtime.hostStartupFailed"
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

    private static func imageWireError(_ error: any Error) -> RuntimeWireError {
        if let wire = error as? RuntimeWireError {
            return wire
        }
        if let failure = error as? ImageFailure {
            let code = "image.\(failure.code)"
            let entry = ErrorCatalog.entry(for: code)
            return RuntimeWireError(
                domain: "image",
                code: code,
                message: entry?.message?["en"] ?? failure.code,
                remediation: entry?.remediation?["en"],
                parameters: failure.parameters.mapValues { "\($0)" }
            )
        }
        return .runtime("internal", message: safeMessage(for: "runtime.internal"))
    }

    private static func configurationWireError(for error: any Error) -> RuntimeWireError {
        if let hostError = error as? RuntimeHostError {
            switch hostError {
            case .startupFailed(_, _):
                return .runtime("hostStartupFailed", message: safeMessage(for: "runtime.hostStartupFailed"))
            case .runtimeFailure(.instanceLocked(owner: _)):
                return .runtime("serviceUnavailable", message: safeMessage(for: "runtime.serviceUnavailable"))
            default:
                return .runtime("internal", message: safeMessage(for: "runtime.internal"))
            }
        }
        if let storeError = error as? RuntimeConfigurationStoreError {
            switch storeError {
            case .unknownSetting:
                return .runtime("unknownSetting", message: safeMessage(for: "runtime.unknownSetting"))
            case .invalidSettingValue:
                return .runtime("invalidSettingValue", message: safeMessage(for: "runtime.invalidSettingValue"))
            case .unsupportedSchema:
                return .runtime("hostStartupFailed", message: safeMessage(for: "runtime.hostStartupFailed"))
            case .unreadable, .writeFailed:
                return .runtime("internal", message: safeMessage(for: "runtime.internal"))
            }
        }
        return .runtime("internal", message: safeMessage(for: "runtime.internal"))
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
    func getConfig(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeConfigGetControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .getConfig,
                as: RuntimeConfigGetControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeConfigGetControlReply(error: Self.wireError(for: failure))))
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeConfigGetControlRequest.self,
                    from: request
                )
            else {
                response.send(
                    Self.encode(
                        RuntimeConfigGetControlReply(error: Self.malformedWireError)))
                return
            }
            let values = await host.updateConfigValues(keys: decoded.keys)
            response.send(Self.encode(RuntimeConfigGetControlReply(values: values)))
        }
    }

    func setConfig(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    RuntimeConfigSetControlReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .setConfig,
                as: RuntimeConfigSetControlRequest.self
            ) {
                response.send(
                    Self.encode(
                        RuntimeConfigSetControlReply(error: Self.wireError(for: failure))))
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(
                    RuntimeConfigSetControlRequest.self,
                    from: request
                )
            else {
                response.send(
                    Self.encode(
                        RuntimeConfigSetControlReply(error: Self.malformedWireError)))
                return
            }
            do {
                let values = try await host.updateConfigSet(
                    key: decoded.key, value: decoded.value)
                response.send(Self.encode(RuntimeConfigSetControlReply(values: values)))
            } catch {
                let wireError = error as? RuntimeWireError ?? Self.internalWireError
                response.send(Self.encode(RuntimeConfigSetControlReply(error: wireError)))
            }
        }
    }

    func selfUpdateStatus(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply, snapshotBarrier: true)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    SelfUpdateStatusReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .selfUpdateStatus,
                as: SelfUpdateStatusRequest.self
            ) {
                response.send(
                    Self.encode(
                        SelfUpdateStatusReply(error: Self.wireError(for: failure))))
                return
            }
            response.beginSnapshotBarrier()
            let status = await host.selfUpdateStatus()
            response.send(Self.encode(SelfUpdateStatusReply(result: status)))
        }
    }

    func noteSelfUpdateStatus(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    SelfUpdateNoteReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .noteSelfUpdateStatus,
                as: SelfUpdateNote.self
            ) {
                response.send(
                    Self.encode(
                        SelfUpdateNoteReply(error: Self.wireError(for: failure))))
                return
            }
            guard
                let note = try? JSONDecoder().decode(SelfUpdateNote.self, from: request)
            else {
                response.send(
                    Self.encode(
                        SelfUpdateNoteReply(error: Self.malformedWireError)))
                return
            }
            await host.noteSelfUpdate(note)
            response.send(Self.encode(SelfUpdateNoteReply(result: RuntimeEmpty())))
        }
    }

    func checkSelfUpdate(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = makeReplyHandler(reply)
        let admission = connectionRegistry.beginRequest(on: connectionID)
        guard case .accepted(let pending) = admission else {
            response.send(
                Self.encode(
                    SelfUpdateStatusReply(
                        error: Self.rejection(for: admission).wireError))
            )
            return
        }
        Task {
            defer { pending.finish() }
            if let failure = Self.validate(
                request,
                clientKind: clientKind,
                operation: .checkSelfUpdate,
                as: CheckSelfUpdateRequest.self
            ) {
                response.send(
                    Self.encode(
                        SelfUpdateStatusReply(error: Self.wireError(for: failure))))
                return
            }
            guard
                let check = try? JSONDecoder().decode(CheckSelfUpdateRequest.self, from: request)
            else {
                response.send(
                    Self.encode(
                        SelfUpdateStatusReply(error: Self.malformedWireError)))
                return
            }
            let status = await host.checkSelfUpdate(userInitiated: check.userInitiated)
            response.send(Self.encode(SelfUpdateStatusReply(result: status)))
        }
    }

}

private final class XPCDataReply: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ReplyHandler?
    private let outputQueue: DispatchQueue?
    private let beforeSend: (@Sendable () -> Void)?
    private let startSnapshotBarrier: (@Sendable () -> Void)?
    private let sendAfterBarrier: (@Sendable (@escaping @Sendable () -> Void) -> Void)?
    private var snapshotBarrierStarted = false

    init(
        _ handler: @escaping (Data) -> Void,
        outputQueue: DispatchQueue? = nil,
        beforeSend: (@Sendable () -> Void)? = nil,
        beginSnapshotBarrier: (@Sendable () -> Void)? = nil,
        sendAfterBarrier: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil
    ) {
        self.handler = ReplyHandler(handler)
        self.outputQueue = outputQueue
        self.beforeSend = beforeSend
        startSnapshotBarrier = beginSnapshotBarrier
        self.sendAfterBarrier = sendAfterBarrier
    }

    func beginSnapshotBarrier() {
        lock.lock()
        defer { lock.unlock() }
        guard handler != nil, !snapshotBarrierStarted else { return }
        startSnapshotBarrier?()
        snapshotBarrierStarted = startSnapshotBarrier != nil
    }

    func send(_ data: Data) {
        lock.lock()
        let handler = self.handler
        self.handler = nil
        let snapshotBarrierStarted = self.snapshotBarrierStarted
        self.snapshotBarrierStarted = false
        lock.unlock()
        guard let handler else {
            return
        }
        if snapshotBarrierStarted, let sendAfterBarrier {
            let sendReply: @Sendable () -> Void = {
                handler.send(data)
            }
            sendAfterBarrier(sendReply)
            return
        }
        beforeSend?()
        if let outputQueue {
            outputQueue.async {
                handler.send(data)
            }
        } else {
            handler.send(data)
        }
    }

    private final class ReplyHandler: @unchecked Sendable {
        private let handler: (Data) -> Void

        init(_ handler: @escaping (Data) -> Void) {
            self.handler = handler
        }

        func send(_ data: Data) {
            handler(data)
        }
    }
}

private final class XPCEventSinkHandshakeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func complete(_ available: Bool) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: available)
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
    case "runtime.unknownSetting":
        "APKRun doesn't recognize this setting."
    case "runtime.invalidSettingValue":
        "The setting value isn't valid."
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
extension CheckSelfUpdateRequest: VersionedControlRequest {}
extension WireImageInstallRequest: VersionedControlRequest {}
extension WireImageStatusRequest: VersionedControlRequest {}
extension WireImageApplyRequest: VersionedControlRequest {}
extension WireImageRollbackRequest: VersionedControlRequest {}
extension WireImageFeedActionRequest: VersionedControlRequest {}
extension WireImageRecoveryPointDeleteRequest: VersionedControlRequest {}
extension SelfUpdateNote: VersionedControlRequest {}
extension MaintenanceControlRequest: VersionedControlRequest {}

// MARK: - Frozen maintenance endpoint (runtime-api.md §12.1)

/// Accepts one maintenance connection and exports a `MaintenanceControlService`
/// whose `perform` envelope dispatches `MaintenanceControlOperation`s. New
/// operations extend the request DTO, never this listener — the endpoint is
/// additive-only and answers in every host state.
private final class MaintenanceListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let host: RuntimeHost

    init(host: RuntimeHost) {
        self.host = host
    }

    var onAccepted: @Sendable () -> Void = {}

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: RuntimeMaintenanceXPC.self)
        connection.exportedObject = MaintenanceControlService(host: host)
        connection.resume()
        onAccepted()
        listener.invalidate()
        return true
    }
}

/// Host-side implementation of the frozen maintenance XPC surface.
private final class MaintenanceControlService: NSObject, RuntimeMaintenanceXPC, @unchecked Sendable {
    private let host: RuntimeHost

    init(host: RuntimeHost) {
        self.host = host
    }

    func perform(_ request: Data, reply: @escaping (Data) -> Void) {
        let response = XPCDataReply(reply)
        Task {
            let controlRequest: MaintenanceControlRequest
            do {
                controlRequest = try JSONDecoder().decode(MaintenanceControlRequest.self, from: request)
            } catch {
                response.send(
                    Self.encode(
                        MaintenanceControlReply(
                            error: RuntimeWireError(domain: "maintenance", code: "malformedRequest", message: "")
                        )))
                return
            }
            let replyValue = await host.maintenanceOperation(controlRequest)
            response.send(Self.encode(replyValue))
        }
    }

    private static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }
}
