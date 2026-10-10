import Foundation

/// One operation of a control channel, typed for the host (guest-protocol.md §13.1, §4.1). It pairs the request
/// with its result and names the capability that it needs. Each operation is a struct, so a call site is typed.
///
/// The field number is the same in `Request.op` and in `Response.result` (guest-protocol.md §4.1). `GuestOperationTests`
/// checks the pairing of every operation below against the schema.
public protocol GuestOperation: Sendable {
    /// The result message of the operation.
    associatedtype Result: Sendable

    /// The operation's name, for errors and logs.
    var operationName: String { get }

    /// The capability that the operation needs (guest-protocol.md §5.3).
    var capability: GuestCapability { get }

    /// How long the agent may take, which is the default request timeout (guest-protocol.md §6).
    var timeout: Duration { get }

    /// The `Request.op` of the operation.
    func request() -> GPRequest.OneOf_Op

    /// The result, or nil when the response carries another kind of result.
    static func decode(_ result: GPResponse.OneOf_Result) -> Result?

    /// The field number of the operation in `Request.op` and `Response.result` (guest-protocol.md §7.1).
    static var number: Int { get }
}

/// `Ping`: liveness of the agent (guest-protocol.md §6, §7.1 #10).
public struct GuestPing: GuestOperation {
    /// The decoded result of the operation.
    public typealias Result = GPPong
    /// The operation number of guest-protocol.md §7.1.
    public static let number = 10
    /// The nonce that the answer echoes.
    public let nonce: UInt64

    /// Creates the operation.
    public init(nonce: UInt64) {
        self.nonce = nonce
    }

    /// The name that errors report for the operation.
    public var operationName: String { "Ping" }
    /// The capability that the operation needs (guest-protocol.md §5.3).
    public var capability: GuestCapability { .core }
    /// The time the agent has to answer.
    public var timeout: Duration { .seconds(5) }

    /// The request that carries the operation.
    public func request() -> GPRequest.OneOf_Op {
        var ping = GPPing()
        ping.nonce = nonce
        return .ping(ping)
    }

    /// Decodes the agent's answer into the result of the operation.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPPong? {
        if case .ping(let pong) = result { return pong }
        return nil
    }
}

/// `GetSnapshot`: the state that the host reads after every handshake (guest-protocol.md §7.2 #11).
public struct GuestGetSnapshot: GuestOperation {
    /// The decoded result of the operation.
    public typealias Result = GPSnapshot
    /// The operation number of guest-protocol.md §7.1.
    public static let number = 11

    /// Creates the operation.
    public init() {}

    /// The name that errors report for the operation.
    public var operationName: String { "GetSnapshot" }
    /// The capability that the operation needs (guest-protocol.md §5.3).
    public var capability: GuestCapability { .core }
    /// The time the agent has to answer.
    public var timeout: Duration { .seconds(5) }

    /// The request that carries the operation.
    public func request() -> GPRequest.OneOf_Op { .getSnapshot(GPGetSnapshot()) }

    /// Decodes the agent's answer into the result of the operation.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPSnapshot? {
        if case .getSnapshot(let snapshot) = result { return snapshot }
        return nil
    }
}

/// `SetDisplayPolicy`: the density and the IME policy of a display (guest-protocol.md §7.1 #12).
public struct GuestSetDisplayPolicy: GuestOperation {
    /// The decoded result of the operation.
    public typealias Result = GPEmpty
    /// The operation number of guest-protocol.md §7.1.
    public static let number = 12
    /// The display of the operation.
    public let displayID: Int32
    /// The density of the display, in dots per inch.
    public let densityDPI: Int32
    /// The input method policy of the display.
    public let imePolicy: GPImePolicy

    /// Creates the operation.
    public init(displayID: Int32, densityDPI: Int32, imePolicy: GPImePolicy) {
        self.displayID = displayID
        self.densityDPI = densityDPI
        self.imePolicy = imePolicy
    }

    /// The name that errors report for the operation.
    public var operationName: String { "SetDisplayPolicy" }
    /// The capability that the operation needs (guest-protocol.md §5.3).
    public var capability: GuestCapability { .display }
    /// The time the agent has to answer.
    public var timeout: Duration { .seconds(5) }

    /// The request that carries the operation.
    public func request() -> GPRequest.OneOf_Op {
        var policy = GPSetDisplayPolicy()
        policy.displayID = displayID
        policy.densityDpi = densityDPI
        policy.imePolicy = imePolicy
        return .setDisplayPolicy(policy)
    }

    /// Decodes the agent's answer into the result of the operation.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPEmpty? {
        if case .setDisplayPolicy(let empty) = result { return empty }
        return nil
    }
}

/// `LaunchApplication`: starts a package on a display (guest-protocol.md §7.1 #14, guest-components.md §6.4).
public struct GuestLaunchApplication: GuestOperation {
    /// The decoded result of the operation.
    public typealias Result = GPLaunchResult
    /// The operation number of guest-protocol.md §7.1.
    public static let number = 14
    /// The package name of the app to launch.
    public let package: String
    /// The display of the operation.
    public let displayID: Int32
    /// The launch mode.
    public let mode: GPLaunchMode

    /// Creates the operation.
    public init(package: String, displayID: Int32, mode: GPLaunchMode = .bringToFrontOrStart) {
        self.package = package
        self.displayID = displayID
        self.mode = mode
    }

    /// The name that errors report for the operation.
    public var operationName: String { "LaunchApplication" }
    /// The capability that the operation needs (guest-protocol.md §5.3).
    public var capability: GuestCapability { .launch }
    /// The time the agent has to answer.
    public var timeout: Duration { .seconds(15) }

    /// The request that carries the operation.
    public func request() -> GPRequest.OneOf_Op {
        var launch = GPLaunchApplication()
        launch.package = package
        launch.displayID = displayID
        launch.mode = mode
        return .launchApplication(launch)
    }

    /// Decodes the agent's answer into the result of the operation.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPLaunchResult? {
        if case .launchApplication(let launch) = result { return launch }
        return nil
    }
}

/// `FocusDisplay`: moves the focus to the top task of a display (guest-protocol.md §7.1 #18).
public struct GuestFocusDisplay: GuestOperation {
    /// The decoded result of the operation.
    public typealias Result = GPEmpty
    /// The operation number of guest-protocol.md §7.1.
    public static let number = 18
    /// The display of the operation.
    public let displayID: Int32

    /// Creates the operation.
    public init(displayID: Int32) {
        self.displayID = displayID
    }

    /// The name that errors report for the operation.
    public var operationName: String { "FocusDisplay" }
    /// The capability that the operation needs (guest-protocol.md §5.3).
    public var capability: GuestCapability { .input }
    /// The time the agent has to answer.
    public var timeout: Duration { .seconds(5) }

    /// The request that carries the operation.
    public func request() -> GPRequest.OneOf_Op {
        var focus = GPFocusDisplay()
        focus.displayID = displayID
        return .focusDisplay(focus)
    }

    /// Decodes the agent's answer into the result of the operation.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPEmpty? {
        if case .focusDisplay(let empty) = result { return empty }
        return nil
    }
}
