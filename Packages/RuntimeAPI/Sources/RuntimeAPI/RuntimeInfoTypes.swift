import Foundation

/// Requests optional diagnostic details from `runtimeInfo`.
public struct RuntimeInfoRequest: Codable, Equatable, Sendable {
    /// Whether to include resource usage details.
    public let resources: Bool
    /// Whether to include the current display-slot inventory.
    public let displays: Bool

    /// Creates a runtime information request.
    public init(resources: Bool = false, displays: Bool = false) {
        self.resources = resources
        self.displays = displays
    }

    private enum CodingKeys: String, CodingKey {
        case resources
        case displays
    }

    /// Decodes requests from older clients with optional-detail flags disabled.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resources = try container.decodeIfPresent(Bool.self, forKey: .resources) ?? false
        displays = try container.decodeIfPresent(Bool.self, forKey: .displays) ?? false
    }

    /// Encodes the requested detail flags.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(resources, forKey: .resources)
        try container.encode(displays, forKey: .displays)
    }
}

/// The configured virtual-machine processor, memory, and Android storage sizes.
public struct RuntimeSizing: Codable, Equatable, Sendable {
    /// Configured virtual CPUs.
    public let cpuCount: Int
    /// Configured guest memory in GiB.
    public let memoryGiB: Int
    /// Configured Android userdata capacity in GiB, or nil when the host lacks minimum free space.
    public let userdataGiB: Int?

    /// Creates a sizing snapshot.
    public init(cpuCount: Int, memoryGiB: Int, userdataGiB: Int?) {
        self.cpuCount = cpuCount
        self.memoryGiB = memoryGiB
        self.userdataGiB = userdataGiB
    }
}

/// Resource measurements available from the host and Android guest.
public struct ResourceUsage: Codable, Equatable, Sendable {
    /// The daemon's physical memory footprint, in bytes.
    public let daemonPhysicalFootprintBytes: Int64?
    /// Memory used by Android, in bytes, when guest health is available.
    public let guestMemoryUsedBytes: Int64?
    /// Memory allocated to graphics resources, in bytes, when available.
    public let graphicsMemoryBytes: Int64?
    /// The daemon's recent CPU use as a percentage, when sampled.
    public let daemonCPUPercent: Double?

    /// Creates a resource-usage snapshot.
    public init(
        daemonPhysicalFootprintBytes: Int64? = nil,
        guestMemoryUsedBytes: Int64? = nil,
        graphicsMemoryBytes: Int64? = nil,
        daemonCPUPercent: Double? = nil
    ) {
        self.daemonPhysicalFootprintBytes = daemonPhysicalFootprintBytes
        self.guestMemoryUsedBytes = guestMemoryUsedBytes
        self.graphicsMemoryBytes = graphicsMemoryBytes
        self.daemonCPUPercent = daemonCPUPercent
    }
}

/// Runtime state, configured sizing, and optionally requested diagnostics.
public struct RuntimeInfo: Codable, Equatable, Sendable {
    /// The current daemon and Android runtime states.
    public let status: RuntimeHostStatus
    /// The current configured virtual-machine sizing.
    public let sizing: RuntimeSizing
    /// The number of display slots configured in the runtime.
    public let displayPoolSize: Int
    /// Resource measurements, absent unless requested and available.
    public let resources: ResourceUsage?
    /// Display-slot details, absent unless requested.
    public let displays: [RuntimeDisplaySlotSnapshot]?

    /// Creates a runtime information snapshot.
    public init(
        status: RuntimeHostStatus,
        sizing: RuntimeSizing,
        displayPoolSize: Int,
        resources: ResourceUsage? = nil,
        displays: [RuntimeDisplaySlotSnapshot]? = nil
    ) {
        self.status = status
        self.sizing = sizing
        self.displayPoolSize = displayPoolSize
        self.resources = resources
        self.displays = displays
    }
}

/// A pixel width and height reported by the display pool.
public struct PixelSize: Codable, Equatable, Sendable {
    /// Width in pixels.
    public let width: Int
    /// Height in pixels.
    public let height: Int

    /// Creates a pixel size.
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// The lifecycle state of a display slot on the RuntimeAPI wire.
public enum WireDisplayState: Codable, Equatable, Sendable {
    /// The slot is free.
    case free
    /// The slot is reserved by Android or an internal runtime operation without an app session.
    case reserved
    /// A session is attaching its Android display.
    case attaching(UUID)
    /// The display is allocated to a session.
    case allocated(UUID)
    /// A session is releasing its display.
    case releasing(UUID)
    /// The slot is faulted with a public-safe error.
    case faulted(WireError)
    /// The peer sent a state this client does not recognize.
    case unknown

    /// Decodes a tagged display state, preserving future cases as `.unknown`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RuntimeInfoCodingKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "A display state must have one case.")
            )
        }

        switch key.stringValue {
        case "free":
            self = .free
        case "reserved":
            self = .reserved
        case "attaching":
            let payload = try container.nestedContainer(
                keyedBy: RuntimeInfoCodingKey.self,
                forKey: key
            )
            self = .attaching(try payload.decode(UUID.self, forKey: .payload))
        case "allocated":
            let payload = try container.nestedContainer(
                keyedBy: RuntimeInfoCodingKey.self,
                forKey: key
            )
            self = .allocated(try payload.decode(UUID.self, forKey: .payload))
        case "releasing":
            let payload = try container.nestedContainer(
                keyedBy: RuntimeInfoCodingKey.self,
                forKey: key
            )
            self = .releasing(try payload.decode(UUID.self, forKey: .payload))
        case "faulted":
            let payload = try container.nestedContainer(
                keyedBy: RuntimeInfoCodingKey.self,
                forKey: key
            )
            self = .faulted(try payload.decode(WireError.self, forKey: .payload))
        default:
            self = .unknown
        }
    }

    /// Encodes the tagged display state, rejecting `.unknown` from the wire.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: RuntimeInfoCodingKey.self)
        switch self {
        case .free:
            _ = container.nestedContainer(
                keyedBy: RuntimeInfoCodingKey.self,
                forKey: RuntimeInfoCodingKey("free")
            )
        case .reserved:
            _ = container.nestedContainer(
                keyedBy: RuntimeInfoCodingKey.self,
                forKey: RuntimeInfoCodingKey("reserved")
            )
        case .attaching(let sessionID):
            var payload = container.nestedContainer(
                keyedBy: RuntimeInfoCodingKey.self,
                forKey: RuntimeInfoCodingKey("attaching")
            )
            try payload.encode(sessionID, forKey: .payload)
        case .allocated(let sessionID):
            var payload = container.nestedContainer(
                keyedBy: RuntimeInfoCodingKey.self,
                forKey: RuntimeInfoCodingKey("allocated")
            )
            try payload.encode(sessionID, forKey: .payload)
        case .releasing(let sessionID):
            var payload = container.nestedContainer(
                keyedBy: RuntimeInfoCodingKey.self,
                forKey: RuntimeInfoCodingKey("releasing")
            )
            try payload.encode(sessionID, forKey: .payload)
        case .faulted(let error):
            var payload = container.nestedContainer(
                keyedBy: RuntimeInfoCodingKey.self,
                forKey: RuntimeInfoCodingKey("faulted")
            )
            try payload.encode(error, forKey: .payload)
        case .unknown:
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Unknown display states cannot be encoded.")
            )
        }
    }
}

/// A snapshot of one configured display slot.
public struct RuntimeDisplaySlotSnapshot: Codable, Equatable, Sendable {
    /// The zero-based slot index; slot 0 is Android's primary display.
    public let slot: Int
    /// The slot lifecycle state.
    public let state: WireDisplayState
    /// The stable lease ID, when one exists.
    public let displayID: DisplayID?
    /// Android's logical display ID, when attached.
    public let androidDisplayID: Int32?
    /// The active pixel dimensions, when a mode is available.
    public let pixelSize: PixelSize?
    /// The active pixel density, when a mode is available.
    public let densityDpi: Int?

    /// Creates a display-slot snapshot.
    public init(
        slot: Int,
        state: WireDisplayState,
        displayID: DisplayID? = nil,
        androidDisplayID: Int32? = nil,
        pixelSize: PixelSize? = nil,
        densityDpi: Int? = nil
    ) {
        self.slot = slot
        self.state = state
        self.displayID = displayID
        self.androidDisplayID = androidDisplayID
        self.pixelSize = pixelSize
        self.densityDpi = densityDpi
    }
}

/// The host-window strategy associated with a session.
public enum RuntimeAndroidWindowMode: String, Codable, Equatable, Sendable {
    /// The Android app has its own secondary display.
    case secondaryDisplay
    /// The app uses Android's primary display for compatibility.
    case primaryDisplayCompatibility
    /// The peer sent a window mode this client does not recognize.
    case unknown

    /// Decodes unknown future modes as `.unknown`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self(rawValue: try container.decode(String.self)) ?? .unknown
    }

    /// Encodes a stable mode, rejecting `.unknown` from the wire.
    public func encode(to encoder: any Encoder) throws {
        guard self != .unknown else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Unknown window modes cannot be encoded.")
            )
        }
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A summary of one open Android app session.
public struct SessionSummary: Codable, Equatable, Sendable {
    /// The session's stable identifier.
    public let sessionID: UUID
    /// The Android package opened by the session.
    public let packageID: RuntimePackageID
    /// The package's display name.
    public let displayName: String
    /// The latest observed session phase.
    public let state: RuntimeSessionPhase
    /// The display lease assigned to the session, when available.
    public let displayID: DisplayID?
    /// The process class that owns the session.
    public let clientKind: RuntimeClientKind
    /// When the session opened.
    public let openedAt: Date
    /// The window strategy used for the session.
    public let windowMode: RuntimeAndroidWindowMode
    /// Whether a screen recording is active for the session.
    public let recording: Bool
    /// The last known window size in points, for the **Use Current Size** action.
    public let pointSize: CGSize?

    /// Creates a session summary.
    public init(
        sessionID: UUID,
        packageID: RuntimePackageID,
        displayName: String,
        state: RuntimeSessionPhase,
        displayID: DisplayID? = nil,
        clientKind: RuntimeClientKind,
        openedAt: Date,
        windowMode: RuntimeAndroidWindowMode,
        recording: Bool,
        pointSize: CGSize? = nil
    ) {
        self.sessionID = sessionID
        self.packageID = packageID
        self.displayName = displayName
        self.state = state
        self.displayID = displayID
        self.clientKind = clientKind
        self.openedAt = openedAt
        self.windowMode = windowMode
        self.recording = recording
        self.pointSize = pointSize
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case packageID
        case displayName
        case state
        case displayID
        case clientKind
        case openedAt
        case windowMode
        case recording
        case pointSize
    }

    /// Decodes `CGSize` through its documented `{width, height}` wire shape.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        packageID = try container.decode(RuntimePackageID.self, forKey: .packageID)
        displayName = try container.decode(String.self, forKey: .displayName)
        state = try container.decode(RuntimeSessionPhase.self, forKey: .state)
        displayID = try container.decodeIfPresent(DisplayID.self, forKey: .displayID)
        clientKind = try container.decode(RuntimeClientKind.self, forKey: .clientKind)
        openedAt = try container.decode(Date.self, forKey: .openedAt)
        windowMode = try container.decode(RuntimeAndroidWindowMode.self, forKey: .windowMode)
        recording = try container.decode(Bool.self, forKey: .recording)
        pointSize = try container.decodeIfPresent(RuntimeInfoPointSize.self, forKey: .pointSize)?.size
    }

    /// Encodes `CGSize` using the documented `{width, height}` wire shape.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(packageID, forKey: .packageID)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(displayID, forKey: .displayID)
        try container.encode(clientKind, forKey: .clientKind)
        try container.encode(openedAt, forKey: .openedAt)
        try container.encode(windowMode, forKey: .windowMode)
        try container.encode(recording, forKey: .recording)
        if let pointSize {
            try container.encode(RuntimeInfoPointSize(pointSize), forKey: .pointSize)
        }
    }

    /// Compares point sizes by their dimensions because `CGSize` is not Equatable here.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sessionID == rhs.sessionID
            && lhs.packageID == rhs.packageID
            && lhs.displayName == rhs.displayName
            && lhs.state == rhs.state
            && lhs.displayID == rhs.displayID
            && lhs.clientKind == rhs.clientKind
            && lhs.openedAt == rhs.openedAt
            && lhs.windowMode == rhs.windowMode
            && lhs.recording == rhs.recording
            && lhs.pointSize.map(RuntimeInfoPointSize.init) == rhs.pointSize.map(RuntimeInfoPointSize.init)
    }
}

private struct RuntimeInfoPointSize: Codable, Equatable, Sendable {
    let width: Double
    let height: Double

    init(_ size: CGSize) {
        width = Double(size.width)
        height = Double(size.height)
    }

    var size: CGSize {
        CGSize(width: width, height: height)
    }
}

private struct RuntimeInfoCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    static let payload = Self("_0")
}
