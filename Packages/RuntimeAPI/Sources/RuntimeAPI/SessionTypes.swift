import Foundation

/// A size expressed in macOS points.
public struct SessionSize: Codable, Equatable, Sendable {
    /// The horizontal dimension.
    public var width: Double
    /// The vertical dimension.
    public var height: Double

    /// Creates a session size.
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// The window geometry requested when opening an app session.
public struct SessionDisplayGeometry: Codable, Equatable, Sendable {
    /// The desired window content size in macOS points.
    public var pointSize: SessionSize
    /// The window's backing scale factor.
    public var backingScale: Double
    /// The per-package zoom preference.
    public var zoom: Double

    /// Creates requested display geometry.
    public init(pointSize: SessionSize, backingScale: Double, zoom: Double) {
        self.pointSize = pointSize
        self.backingScale = backingScale
        self.zoom = zoom
    }
}

/// The host-side timing markers supplied when opening an app session.
public struct SessionLaunchTiming: Codable, Equatable, Sendable {
    /// The host monotonic timestamp when the launcher process started, in nanoseconds.
    public var processStart: UInt64
    /// The host monotonic timestamp when the launcher sent `openSession`, in nanoseconds.
    public var requestSent: UInt64

    /// Creates launch timing markers.
    public init(processStart: UInt64, requestSent: UInt64) {
        self.processStart = processStart
        self.requestSent = requestSent
    }
}

/// Opens a window session for an installed Android package.
public struct OpenSessionRequest: Codable, Equatable, Sendable {
    /// The package to launch.
    public var packageID: RuntimePackageID
    /// The requested window size, scale, and zoom.
    public var geometry: SessionDisplayGeometry
    /// The current screen size in macOS points.
    public var screenSize: SessionSize
    /// Optional launcher timing markers for diagnostics.
    public var launchTiming: SessionLaunchTiming?

    /// Creates a session request.
    public init(
        packageID: RuntimePackageID,
        geometry: SessionDisplayGeometry,
        screenSize: SessionSize,
        launchTiming: SessionLaunchTiming? = nil
    ) {
        self.packageID = packageID
        self.geometry = geometry
        self.screenSize = screenSize
        self.launchTiming = launchTiming
    }
}

/// The resolved display size in pixels.
public struct SessionPixelSize: Codable, Equatable, Sendable {
    /// The horizontal pixel count.
    public var width: Int
    /// The vertical pixel count.
    public var height: Int

    /// Creates a pixel size.
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Metadata for three IOSurfaces transferred separately over XPC.
public struct SurfaceSet: Codable, Equatable, Sendable {
    /// The pool generation.
    public var generation: UInt32
    /// The resolved display size in pixels.
    public var pixelSize: SessionPixelSize
    /// The Android display density.
    public var densityDpi: Int

    /// The fixed number of IOSurfaces in every pool.
    public static let surfaceCount = 3

    /// Creates surface-pool metadata.
    public init(generation: UInt32, pixelSize: SessionPixelSize, densityDpi: Int) {
        self.generation = generation
        self.pixelSize = pixelSize
        self.densityDpi = densityDpi
    }
}

/// The display mode used for one Android application session.
public enum AndroidWindowMode: String, Codable, Equatable, Sendable {
    /// A dedicated Android external display.
    case secondaryDisplay
    /// Exclusive compatibility access to Android's primary display.
    case primaryDisplayCompatibility
    /// A mode introduced by a newer runtime.
    case unknown

    /// Decodes a known mode, preserving unrecognized values.
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }

    /// Encodes the stable mode value.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Window preferences applied to the session's Mac window.
public struct WindowPrefs: Codable, Equatable, Sendable {
    /// Whether the window may be resized.
    public var resizable: Bool
    /// Whether the window stays above other windows.
    public var alwaysOnTop: Bool
    /// The configured display zoom.
    public var zoom: Double

    /// Creates window preferences.
    public init(resizable: Bool, alwaysOnTop: Bool, zoom: Double) {
        self.resizable = resizable
        self.alwaysOnTop = alwaysOnTop
        self.zoom = zoom
    }
}

/// The Android Back-key behavior for Escape.
public enum EscapeKeyMapping: String, Codable, Equatable, Sendable {
    /// Send Android Back.
    case back
    /// Send Android Escape.
    case escape
    /// A mapping introduced by a newer runtime.
    case unknown

    /// Decodes a known mapping, preserving unrecognized values.
    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }

    /// Encodes the stable mapping value.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The guest action generated by a secondary click.
public enum SecondaryClickMapping: String, Codable, Equatable, Sendable {
    /// Send a secondary mouse button.
    case mouseSecondary
    /// Send a long press.
    case longPress
    /// A mapping introduced by a newer runtime.
    case unknown

    /// Decodes a known mapping, preserving unrecognized values.
    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }

    /// Encodes the stable mapping value.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The guest action generated by a scroll gesture.
public enum SessionScrollMode: String, Codable, Equatable, Sendable {
    /// Send Android scroll events.
    case scroll
    /// Convert scrolling into touch-drag gestures.
    case touchDrag
    /// A mode introduced by a newer runtime.
    case unknown

    /// Decodes a known mode, preserving unrecognized values.
    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }

    /// Encodes the stable mode value.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Input preferences applied to an app session.
public struct InputPrefs: Codable, Equatable, Sendable {
    /// The action generated by Escape.
    public var escapeKey: EscapeKeyMapping
    /// The guest action generated by a secondary click.
    public var secondaryClick: SecondaryClickMapping
    /// The guest action generated by scrolling.
    public var scrollMode: SessionScrollMode
    /// Whether pointer movement is sent while no button is pressed.
    public var hover: Bool
    /// Whether the Command key is forwarded to Android.
    public var sendCommandKey: Bool

    /// Creates session input preferences.
    public init(
        escapeKey: EscapeKeyMapping,
        secondaryClick: SecondaryClickMapping,
        scrollMode: SessionScrollMode,
        hover: Bool,
        sendCommandKey: Bool
    ) {
        self.escapeKey = escapeKey
        self.secondaryClick = secondaryClick
        self.scrollMode = scrollMode
        self.hover = hover
        self.sendCommandKey = sendCommandKey
    }
}

/// A lifecycle or failure state reported for an app session.
public enum SessionPhase: Equatable, Sendable, Codable {
    case starting
    case booting(BootProgress)
    case waitingForPackage
    case launching
    case running
    case ended(SessionEndReason)
    case unknown

    private enum CodingKeys: String, CodingKey {
        case kind
        case progress
        case reason
    }

    private enum Kind: String {
        case starting
        case booting
        case waitingForPackage
        case launching
        case running
        case ended
        case unknown
    }

    /// Decodes a session phase, mapping unrecognized kinds to `.unknown`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch Kind(rawValue: try container.decode(String.self, forKey: .kind)) ?? .unknown {
        case .starting:
            self = .starting
        case .booting:
            self = .booting(try container.decode(BootProgress.self, forKey: .progress))
        case .waitingForPackage:
            self = .waitingForPackage
        case .launching:
            self = .launching
        case .running:
            self = .running
        case .ended:
            self = .ended(try container.decode(SessionEndReason.self, forKey: .reason))
        case .unknown:
            self = .unknown
        }
    }

    /// Encodes the stable phase kind and any associated payload.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .starting:
            try container.encode(Kind.starting.rawValue, forKey: .kind)
        case .booting(let progress):
            try container.encode(Kind.booting.rawValue, forKey: .kind)
            try container.encode(progress, forKey: .progress)
        case .waitingForPackage:
            try container.encode(Kind.waitingForPackage.rawValue, forKey: .kind)
        case .launching:
            try container.encode(Kind.launching.rawValue, forKey: .kind)
        case .running:
            try container.encode(Kind.running.rawValue, forKey: .kind)
        case .ended(let reason):
            try container.encode(Kind.ended.rawValue, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .unknown:
            try container.encode(Kind.unknown.rawValue, forKey: .kind)
        }
    }
}

/// The reason an app session ended.
public enum SessionEndReason: Equatable, Sendable, Codable {
    case userClosed
    case appExited
    case appCrashed
    case runtimeStopped
    case updating
    case runtimeUpdating
    case packageUninstalled
    case error(RuntimeWireError)
    case unknown

    private enum CodingKeys: String, CodingKey {
        case kind
        case error
    }

    private enum Kind: String {
        case userClosed
        case appExited
        case appCrashed
        case runtimeStopped
        case updating
        case runtimeUpdating
        case packageUninstalled
        case error
        case unknown
    }

    /// Decodes a session end reason, mapping unrecognized kinds to `.unknown`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch Kind(rawValue: try container.decode(String.self, forKey: .kind)) ?? .unknown {
        case .userClosed:
            self = .userClosed
        case .appExited:
            self = .appExited
        case .appCrashed:
            self = .appCrashed
        case .runtimeStopped:
            self = .runtimeStopped
        case .updating:
            self = .updating
        case .runtimeUpdating:
            self = .runtimeUpdating
        case .packageUninstalled:
            self = .packageUninstalled
        case .error:
            self = .error(try container.decode(RuntimeWireError.self, forKey: .error))
        case .unknown:
            self = .unknown
        }
    }

    /// Encodes the stable session end reason and any associated error.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .userClosed:
            try container.encode(Kind.userClosed.rawValue, forKey: .kind)
        case .appExited:
            try container.encode(Kind.appExited.rawValue, forKey: .kind)
        case .appCrashed:
            try container.encode(Kind.appCrashed.rawValue, forKey: .kind)
        case .runtimeStopped:
            try container.encode(Kind.runtimeStopped.rawValue, forKey: .kind)
        case .updating:
            try container.encode(Kind.updating.rawValue, forKey: .kind)
        case .runtimeUpdating:
            try container.encode(Kind.runtimeUpdating.rawValue, forKey: .kind)
        case .packageUninstalled:
            try container.encode(Kind.packageUninstalled.rawValue, forKey: .kind)
        case .error(let error):
            try container.encode(Kind.error.rawValue, forKey: .kind)
            try container.encode(error, forKey: .error)
        case .unknown:
            try container.encode(Kind.unknown.rawValue, forKey: .kind)
        }
    }
}

/// The descriptor returned with the direct IOSurface array and session endpoint.
public struct SessionDescriptor: Codable, Equatable, Sendable {
    /// The session's stable identity.
    public var sessionID: UUID
    /// The runtime's display-slot identity.
    public var displayID: DisplayID
    /// Window preferences resolved for the package.
    public var windowPrefs: WindowPrefs
    /// Input preferences resolved for the package.
    public var inputPrefs: InputPrefs
    /// The Android display mode used by this session.
    public var windowMode: AndroidWindowMode
    /// The current session lifecycle state.
    public var state: SessionPhase
    /// Metadata for the initial IOSurface pool.
    public var surfaces: SurfaceSet

    /// Creates a session descriptor.
    public init(
        sessionID: UUID,
        displayID: DisplayID,
        windowPrefs: WindowPrefs,
        inputPrefs: InputPrefs,
        windowMode: AndroidWindowMode,
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

/// GPU completion metadata for one buffer that is ready to display.
public struct FrameReadyMessage: Codable, Equatable, Sendable {
    /// The surface-pool generation.
    public var generation: UInt32
    /// The zero-based IOSurface index.
    public var surfaceIndex: Int
    /// A sequence that increases across generations for the session.
    public var frameSeq: UInt64
    /// The host `mach_absolute_time` value at GPU completion.
    public var presentationTime: UInt64

    /// Creates a ready-frame event.
    public init(generation: UInt32, surfaceIndex: Int, frameSeq: UInt64, presentationTime: UInt64) {
        self.generation = generation
        self.surfaceIndex = surfaceIndex
        self.frameSeq = frameSeq
        self.presentationTime = presentationTime
    }
}

/// Metadata for a replacement IOSurface pool.
public struct SurfacesReplacedMessage: Codable, Equatable, Sendable {
    /// The replacement pool metadata.
    public var surfaceSet: SurfaceSet

    /// Creates a replacement-pool event.
    public init(surfaceSet: SurfaceSet) {
        self.surfaceSet = surfaceSet
    }
}

/// The wrapper reports that Core Animation displayed a frame.
public struct FrameDisplayedMessage: Codable, Equatable, Sendable {
    /// The surface-pool generation.
    public var generation: UInt32
    /// The frame sequence displayed by the wrapper.
    public var frameSeq: UInt64

    /// Creates a displayed-frame message.
    public init(generation: UInt32, frameSeq: UInt64) {
        self.generation = generation
        self.frameSeq = frameSeq
    }
}

/// The wrapper reports whether its window is visible.
public struct VisibilityChangedMessage: Codable, Equatable, Sendable {
    /// Whether the app window is visible.
    public var visible: Bool

    /// Creates a visibility message.
    public init(visible: Bool) {
        self.visible = visible
    }
}

/// A versioned control request to open a window session.
public struct RuntimeOpenSessionControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public var header: APIRequestHeader
    /// The session parameters.
    public var request: OpenSessionRequest

    /// Creates an open-session control request.
    public init(header: APIRequestHeader, request: OpenSessionRequest) {
        self.header = header
        self.request = request
    }
}

/// The JSON portion of an open-session reply; IOSurfaces and the endpoint are separate XPC arguments.
public struct RuntimeOpenSessionControlReply: Codable, Equatable, Sendable {
    /// The session descriptor on success.
    public var result: SessionDescriptor?
    /// The typed failure on error.
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

/// The Android task policy applied when an app window closes.
public enum SessionClosePolicy: String, Codable, Equatable, Sendable {
    /// Stop the app's tasks on its Android display.
    case stop
    /// Keep the app running after its window closes.
    case keepRunning
}

/// Closes one session window.
public struct CloseSessionRequest: Codable, Equatable, Sendable {
    /// An explicit close policy, or `nil` to use the app preference.
    public var policy: SessionClosePolicy?

    /// Creates a close request.
    public init(policy: SessionClosePolicy? = nil) {
        self.policy = policy
    }
}

/// A versioned close request on a session-bound endpoint.
public struct RuntimeCloseSessionRequest: Codable, Equatable, Sendable {
    /// Request metadata.
    public var header: APIRequestHeader
    /// Close parameters.
    public var request: CloseSessionRequest

    /// Creates a versioned close request.
    public init(header: APIRequestHeader, request: CloseSessionRequest) {
        self.header = header
        self.request = request
    }
}

/// The result of closing a session window.
public struct RuntimeCloseSessionReply: Codable, Equatable, Sendable {
    /// A typed failure, if the session could not be closed.
    public var error: RuntimeWireError?

    /// Creates a successful close reply.
    public init() {
        error = nil
    }

    /// Creates a failed close reply.
    public init(error: RuntimeWireError) {
        self.error = error
    }
}
