import Foundation

/// The window's logical dimensions in points.
public struct DisplayPointSize: Codable, Equatable, Sendable {
    /// Horizontal size.
    public var width: Double
    /// Vertical size.
    public var height: Double

    /// Creates a point size.
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// The requested Android display geometry for one app session.
public struct DisplayGeometry: Codable, Equatable, Sendable {
    /// Window dimensions in points.
    public var pointSize: DisplayPointSize
    /// Backing scale, normally 1 or 2.
    public var backingScale: Double
    /// User interface zoom.
    public var zoom: Double

    /// Creates display geometry.
    public init(pointSize: DisplayPointSize, backingScale: Double, zoom: Double) {
        self.pointSize = pointSize
        self.backingScale = backingScale
        self.zoom = zoom
    }
}

/// Host timing markers captured while launching an app window.
public struct LaunchTiming: Codable, Equatable, Sendable {
    /// Host `mach_continuous_time` nanoseconds when the launcher process started.
    public var processStart: UInt64
    /// Host `mach_continuous_time` nanoseconds immediately before the open-session request.
    public var requestSent: UInt64

    /// Creates launch timing markers.
    public init(processStart: UInt64, requestSent: UInt64) {
        self.processStart = processStart
        self.requestSent = requestSent
    }
}

/// Opens one package session on the authenticated launcher connection.
public struct OpenSessionRequest: Codable, Equatable, Sendable {
    /// Request identity and protocol version.
    public var header: APIRequestHeader
    /// Android package to display in the app window.
    public var packageID: RuntimePackageID
    /// Requested window size, scale, and zoom.
    public var geometry: DisplayGeometry
    /// Available screen size in points.
    public var screenSize: DisplayPointSize
    /// Optional host launch timing markers.
    public var launchTiming: LaunchTiming?

    /// Creates an open-session request.
    public init(
        header: APIRequestHeader,
        packageID: RuntimePackageID,
        geometry: DisplayGeometry,
        screenSize: DisplayPointSize,
        launchTiming: LaunchTiming? = nil
    ) {
        self.header = header
        self.packageID = packageID
        self.geometry = geometry
        self.screenSize = screenSize
        self.launchTiming = launchTiming
    }
}

/// Result of opening a session; its IOSurfaces are carried in the adjacent XPC reply argument.
public struct OpenSessionControlReply: Codable, Equatable, Sendable {
    /// Session metadata when the request succeeds.
    public var result: SessionDescriptor?
    /// Catalog-backed failure when the request fails.
    public var error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: SessionDescriptor) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// Outcome of changing the geometry of an open app session.
public enum SessionResizeOutcome: String, Codable, Equatable, Sendable {
    /// Android and GraphicsCore applied the requested geometry.
    case applied
    /// The requested geometry already matches the current display mode.
    case unchanged
    /// The request was rejected and the current display mode remains in effect.
    case rejected
    /// The host could not confirm whether the previous display mode was restored.
    case stateUncertain
}

/// Changes display geometry for the session bound to the authenticated launcher connection.
public struct ResizeSessionRequest: Codable, Equatable, Sendable {
    /// Request identity and protocol version.
    public var header: APIRequestHeader
    /// Requested window size, backing scale, and zoom.
    public var geometry: DisplayGeometry

    /// Creates a session resize request.
    public init(header: APIRequestHeader, geometry: DisplayGeometry) {
        self.header = header
        self.geometry = geometry
    }
}

/// Result of changing a session's display geometry; replacement IOSurfaces travel separately over XPC.
public struct ResizeSessionControlReply: Codable, Equatable, Sendable {
    /// Applied, unchanged, rejected, or uncertain result.
    public var outcome: SessionResizeOutcome?
    /// Updated session metadata when `outcome` is `.applied`.
    public var result: SessionDescriptor?
    /// Catalog-backed request failure.
    public var error: RuntimeWireError?

    /// Creates a resize outcome reply.
    public init(
        outcome: SessionResizeOutcome,
        result: SessionDescriptor? = nil,
        error: RuntimeWireError? = nil
    ) {
        self.outcome = outcome
        self.result = result
        self.error = error
    }

    /// Creates a typed failure reply.
    public init(error: RuntimeWireError) {
        outcome = nil
        result = nil
        self.error = error
    }
}

/// Restarts the package bound to the authenticated app session without replacing its display.
public struct RestartAppRequest: Codable, Equatable, Sendable {
    /// Request identity and protocol version.
    public var header: APIRequestHeader
    /// Session whose current window and display must remain open.
    public var sessionID: UUID
    /// Package to restart; the daemon verifies it against the authenticated session.
    public var packageID: RuntimePackageID

    /// Creates a session-scoped restart request.
    public init(header: APIRequestHeader, sessionID: UUID, packageID: RuntimePackageID) {
        self.header = header
        self.sessionID = sessionID
        self.packageID = packageID
    }
}

/// Result of restarting an app session's Android package.
public struct RestartAppControlReply: Codable, Equatable, Sendable {
    /// Present when Android accepted the relaunch.
    public var result: RuntimeEmpty?
    /// Catalog-backed request failure.
    public var error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: RuntimeEmpty = RuntimeEmpty()) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// Policy for closing an app session.
public enum SessionClosePolicy: String, Codable, Equatable, Sendable {
    /// Ask the Guest Agent to finish the package's tasks before releasing the display.
    case stop
}

/// Gracefully closes the package bound to the authenticated app session.
public struct CloseSessionRequest: Codable, Equatable, Sendable {
    /// Request identity and protocol version.
    public var header: APIRequestHeader
    /// Session to close.
    public var sessionID: UUID
    /// Package bound to the session; the daemon verifies both values.
    public var packageID: RuntimePackageID
    /// Explicit close preference. `nil` and `.stop` use graceful stop; keep-running is not yet available.
    public var policy: SessionClosePolicy?

    /// Creates a session-scoped close request. Closing always uses Guest Agent `StopApplication`.
    public init(
        header: APIRequestHeader,
        sessionID: UUID,
        packageID: RuntimePackageID,
        policy: SessionClosePolicy? = nil
    ) {
        self.header = header
        self.sessionID = sessionID
        self.packageID = packageID
        self.policy = policy
    }
}

/// Result of closing an app session and releasing its display.
public struct CloseSessionControlReply: Codable, Equatable, Sendable {
    /// Present when Android accepted the graceful stop and the session was closed.
    public var result: RuntimeEmpty?
    /// Catalog-backed request failure.
    public var error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: RuntimeEmpty = RuntimeEmpty()) {
        self.result = result
        error = nil
    }

    /// Creates a typed failure reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// Integer pixel dimensions for one Android display surface.
public struct PixelSize: Codable, Equatable, Sendable {
    /// Horizontal pixel count.
    public var width: Int
    /// Vertical pixel count.
    public var height: Int

    /// Creates a pixel size.
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Metadata for the three IOSurfaces that back one display generation.
///
/// The IOSurfaces themselves are transferred as a separate XPC argument. The
/// wire metadata carries their required count and the display mode they share.
public struct SurfaceSet: Codable, Equatable, Sendable {
    /// The generation used to reject frames from a replaced pool.
    public var generation: UInt32
    /// The fixed number of IOSurfaces in every v1 surface pool.
    public let surfaceCount: Int
    /// Pixel dimensions shared by all surfaces in this generation.
    public var pixelSize: PixelSize
    /// Android density for this display.
    public var densityDpi: Int

    /// The required number of IOSurfaces in a surface pool.
    public static let requiredSurfaceCount = 3

    /// Creates metadata for one three-surface generation.
    public init(generation: UInt32, pixelSize: PixelSize, densityDpi: Int) {
        self.generation = generation
        surfaceCount = Self.requiredSurfaceCount
        self.pixelSize = pixelSize
        self.densityDpi = densityDpi
    }

    private enum CodingKeys: String, CodingKey {
        case generation
        case surfaceCount
        case pixelSize
        case densityDpi
    }

    /// Decodes and validates the fixed surface count.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let surfaceCount = try container.decode(Int.self, forKey: .surfaceCount)
        guard surfaceCount == Self.requiredSurfaceCount else {
            throw DecodingError.dataCorruptedError(
                forKey: .surfaceCount,
                in: container,
                debugDescription: "A v1 surface set must contain exactly three IOSurfaces."
            )
        }
        generation = try container.decode(UInt32.self, forKey: .generation)
        self.surfaceCount = surfaceCount
        pixelSize = try container.decode(PixelSize.self, forKey: .pixelSize)
        densityDpi = try container.decode(Int.self, forKey: .densityDpi)
    }

    /// Encodes the display metadata and fixed surface count.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(generation, forKey: .generation)
        try container.encode(surfaceCount, forKey: .surfaceCount)
        try container.encode(pixelSize, forKey: .pixelSize)
        try container.encode(densityDpi, forKey: .densityDpi)
    }
}

/// A future-compatible window mode for an app session.
public enum SessionWindowMode: String, Codable, Equatable, Sendable {
    /// The session owns a secondary Android display.
    case secondaryDisplay
    /// The session temporarily presents Android's primary display.
    case primaryDisplayCompatibility
    /// The server sent a window mode unknown to this client.
    case unknown

    /// Decodes a wire string, mapping future modes to `.unknown`.
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }

    /// Encodes the stable window-mode wire string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The Escape-key behavior selected for this session.
public enum EscapeKeyMapping: String, Codable, Equatable, Sendable {
    /// Send Android Back.
    case back
    /// Send the Escape key.
    case escape
    /// The server sent a mapping unknown to this client.
    case unknown

    /// Decodes a wire string, mapping future mappings to `.unknown`.
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }

    /// Encodes the stable Escape-key mapping string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The secondary-click behavior selected for this session.
public enum SecondaryClickMapping: String, Codable, Equatable, Sendable {
    /// Send a secondary mouse button.
    case mouseSecondary
    /// Send a long press.
    case longPress
    /// The server sent a mapping unknown to this client.
    case unknown

    /// Decodes a wire string, mapping future mappings to `.unknown`.
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }

    /// Encodes the stable secondary-click mapping string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The scroll behavior selected for this session.
public enum ScrollModeMapping: String, Codable, Equatable, Sendable {
    /// Send Android scroll input.
    case scroll
    /// Translate scrolling into touch drags.
    case touchDrag
    /// The server sent a mapping unknown to this client.
    case unknown

    /// Decodes a wire string, mapping future mappings to `.unknown`.
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }

    /// Encodes the stable scroll-mode mapping string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Input mappings and forwarding preferences for one session.
public struct InputPrefs: Codable, Equatable, Sendable {
    /// Escape-key mapping.
    public var escapeKey: EscapeKeyMapping
    /// Secondary-click mapping.
    public var secondaryClick: SecondaryClickMapping
    /// Scroll mapping.
    public var scrollMode: ScrollModeMapping
    /// Whether pointer hover events are forwarded.
    public var hover: Bool
    /// Whether the Command key is forwarded to Android.
    public var sendCommandKey: Bool

    /// Creates input preferences, using the documented defaults.
    public init(
        escapeKey: EscapeKeyMapping = .back,
        secondaryClick: SecondaryClickMapping = .mouseSecondary,
        scrollMode: ScrollModeMapping = .scroll,
        hover: Bool = true,
        sendCommandKey: Bool = false
    ) {
        self.escapeKey = escapeKey
        self.secondaryClick = secondaryClick
        self.scrollMode = scrollMode
        self.hover = hover
        self.sendCommandKey = sendCommandKey
    }
}

/// Window preferences applied to an app session.
public struct WindowPrefs: Codable, Equatable, Sendable {
    /// Whether the window can be resized by the user.
    public var resizable: Bool
    /// Whether the window stays above other windows.
    public var alwaysOnTop: Bool
    /// Requested UI zoom, normally in the range 0.75...2.0.
    public var zoom: Double

    /// Creates window preferences, using the documented defaults.
    public init(resizable: Bool = true, alwaysOnTop: Bool = false, zoom: Double = 1.0) {
        self.resizable = resizable
        self.alwaysOnTop = alwaysOnTop
        self.zoom = zoom
    }
}

/// The reason an app session ended.
public enum SessionEndReason: Codable, Equatable, Sendable {
    /// The user closed the window.
    case userClosed
    /// The app exited normally.
    case appExited
    /// The app crashed.
    case appCrashed
    /// The runtime stopped.
    case runtimeStopped
    /// The package is being updated.
    case updating
    /// APKRun itself is being updated.
    case runtimeUpdating
    /// The package was uninstalled.
    case packageUninstalled
    /// The session ended because of a structured error.
    case error(WireError)
    /// The server sent an end reason unknown to this client.
    case unknown

    private enum AssociatedKey: String, CodingKey {
        case value = "_0"
    }

    /// Decodes a known or future session end reason.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: SessionContractCodingKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected one session end reason.")
            )
        }
        switch key.stringValue {
        case "userClosed":
            self = .userClosed
        case "appExited":
            self = .appExited
        case "appCrashed":
            self = .appCrashed
        case "runtimeStopped":
            self = .runtimeStopped
        case "updating":
            self = .updating
        case "runtimeUpdating":
            self = .runtimeUpdating
        case "packageUninstalled":
            self = .packageUninstalled
        case "error":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .error(try payload.decode(WireError.self, forKey: .value))
        default:
            self = .unknown
        }
    }

    /// Encodes the one-case session end-reason enum object.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: SessionContractCodingKey.self)
        switch self {
        case .userClosed:
            Self.encodeEmptyCase("userClosed", into: &container)
        case .appExited:
            Self.encodeEmptyCase("appExited", into: &container)
        case .appCrashed:
            Self.encodeEmptyCase("appCrashed", into: &container)
        case .runtimeStopped:
            Self.encodeEmptyCase("runtimeStopped", into: &container)
        case .updating:
            Self.encodeEmptyCase("updating", into: &container)
        case .runtimeUpdating:
            Self.encodeEmptyCase("runtimeUpdating", into: &container)
        case .packageUninstalled:
            Self.encodeEmptyCase("packageUninstalled", into: &container)
        case .error(let error):
            var payload = container.nestedContainer(
                keyedBy: AssociatedKey.self,
                forKey: SessionContractCodingKey("error")
            )
            try payload.encode(error, forKey: .value)
        case .unknown:
            Self.encodeEmptyCase("unknown", into: &container)
        }
    }

    private static func encodeEmptyCase(
        _ name: String,
        into container: inout KeyedEncodingContainer<SessionContractCodingKey>
    ) {
        _ = container.nestedContainer(
            keyedBy: SessionContractCodingKey.self,
            forKey: SessionContractCodingKey(name)
        )
    }
}

/// The lifecycle phase of an app session.
public enum SessionPhase: Codable, Equatable, Sendable {
    /// Session admission has begun.
    case starting
    /// Android is booting for the session.
    case booting(BootProgress)
    /// The package is waiting for a store transaction to finish.
    case waitingForPackage
    /// The app is launching on its Android display.
    case launching
    /// The app has produced its first frame.
    case running
    /// The session has ended.
    case ended(SessionEndReason)
    /// The server sent a session phase unknown to this client.
    case unknown

    private enum AssociatedKey: String, CodingKey {
        case value = "_0"
    }

    /// Decodes a known or future session phase.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: SessionContractCodingKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected one session phase.")
            )
        }
        switch key.stringValue {
        case "starting":
            self = .starting
        case "booting":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .booting(try payload.decode(BootProgress.self, forKey: .value))
        case "waitingForPackage":
            self = .waitingForPackage
        case "launching":
            self = .launching
        case "running":
            self = .running
        case "ended":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .ended(try payload.decode(SessionEndReason.self, forKey: .value))
        default:
            self = .unknown
        }
    }

    /// Encodes the one-case session phase enum object.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: SessionContractCodingKey.self)
        switch self {
        case .starting:
            Self.encodeEmptyCase("starting", into: &container)
        case .booting(let progress):
            try Self.encode(progress, as: "booting", into: &container)
        case .waitingForPackage:
            Self.encodeEmptyCase("waitingForPackage", into: &container)
        case .launching:
            Self.encodeEmptyCase("launching", into: &container)
        case .running:
            Self.encodeEmptyCase("running", into: &container)
        case .ended(let reason):
            try Self.encode(reason, as: "ended", into: &container)
        case .unknown:
            Self.encodeEmptyCase("unknown", into: &container)
        }
    }

    private static func encode<Value: Encodable>(
        _ value: Value,
        as name: String,
        into container: inout KeyedEncodingContainer<SessionContractCodingKey>
    ) throws {
        var payload = container.nestedContainer(
            keyedBy: AssociatedKey.self,
            forKey: SessionContractCodingKey(name)
        )
        try payload.encode(value, forKey: .value)
    }

    private static func encodeEmptyCase(
        _ name: String,
        into container: inout KeyedEncodingContainer<SessionContractCodingKey>
    ) {
        _ = container.nestedContainer(
            keyedBy: SessionContractCodingKey.self,
            forKey: SessionContractCodingKey(name)
        )
    }
}

/// The metadata returned when a client opens an app session.
public struct SessionDescriptor: Codable, Equatable, Sendable {
    /// Stable identifier for this app session.
    public var sessionID: UUID
    /// Android's logical display ID assigned to the session.
    public var displayID: Int32
    /// Window behavior to apply in the launcher.
    public var windowPrefs: WindowPrefs
    /// Input behavior to apply in the launcher.
    public var inputPrefs: InputPrefs
    /// Whether the session uses a secondary or compatibility display.
    public var windowMode: SessionWindowMode
    /// Current session lifecycle state.
    public var state: SessionPhase
    /// Current generation and display metadata. IOSurfaces travel separately over XPC.
    public var surfaces: SurfaceSet

    /// Creates a session descriptor.
    public init(
        sessionID: UUID,
        displayID: Int32,
        windowPrefs: WindowPrefs,
        inputPrefs: InputPrefs,
        windowMode: SessionWindowMode,
        state: SessionPhase,
        surfaces: SurfaceSet
    ) {
        self.sessionID = sessionID
        self.displayID = displayID
        self.windowPrefs = windowPrefs
        self.inputPrefs = inputPrefs
        self.windowMode = windowMode
        self.state = state
        self.surfaces = surfaces
    }
}

/// A frame ready for presentation by the session's window.
public struct FrameReady: Codable, Equatable, Sendable {
    /// IOSurface generation that contains the frame.
    public var generation: UInt32
    /// Zero-based index of the surface carrying the frame.
    public var surfaceIndex: Int
    /// Monotonic per-session frame sequence across generations.
    public var frameSeq: UInt64
    /// Host `mach_absolute_time` captured at GPU completion.
    public var presentationTime: UInt64

    /// Creates a frame-ready message.
    public init(generation: UInt32, surfaceIndex: Int, frameSeq: UInt64, presentationTime: UInt64) {
        self.generation = generation
        self.surfaceIndex = surfaceIndex
        self.frameSeq = frameSeq
        self.presentationTime = presentationTime
    }
}

/// Metadata sent when a session receives a new IOSurface generation.
///
/// The new `[IOSurface]` array is carried alongside this Codable value in XPC.
public struct SurfacesReplaced: Codable, Equatable, Sendable {
    /// Replacement surface generation metadata.
    public var surfaceSet: SurfaceSet

    /// Creates a surface replacement message.
    public init(surfaceSet: SurfaceSet) {
        self.surfaceSet = surfaceSet
    }
}

/// Acknowledgement sent after a frame is committed to the window layer.
public struct FrameDisplayed: Codable, Equatable, Sendable {
    /// The generation that was displayed.
    public var generation: UInt32
    /// The displayed frame sequence.
    public var frameSeq: UInt64

    /// Creates a frame acknowledgement.
    public init(generation: UInt32, frameSeq: UInt64) {
        self.generation = generation
        self.frameSeq = frameSeq
    }
}

/// Visibility update for the session's window.
public struct VisibilityChanged: Codable, Equatable, Sendable {
    /// Whether the window is visible.
    public var visible: Bool

    /// Creates a visibility update.
    public init(visible: Bool) {
        self.visible = visible
    }
}

private struct SessionContractCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
