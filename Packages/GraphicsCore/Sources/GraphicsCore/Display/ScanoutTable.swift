/// One of the 16 scanouts the virtio-gpu device exposes, indexed `0...15`.
public struct ScanoutID: Hashable, Sendable, CustomStringConvertible {
    /// The zero-based scanout index.
    public let rawValue: Int

    /// Returns `nil` when `rawValue` is outside `0..<16`.
    public init?(rawValue: Int) {
        guard (0..<VirtioGPUProtocol.scanoutCount).contains(rawValue) else {
            return nil
        }
        self.rawValue = rawValue
    }

    /// The scanout index as text.
    public var description: String {
        String(rawValue)
    }
}

/// A display mode the host offers on a scanout (graphics.md §6.1).
public struct DisplayMode: Equatable, Sendable, CustomStringConvertible {
    /// The active width in pixels. EDID detailed timings limit it to 4095.
    public var widthPixels: Int
    /// The active height in pixels. EDID detailed timings limit it to 4095.
    public var heightPixels: Int
    /// The refresh rate in hertz.
    public var refreshHz: Int
    /// The density used to derive the physical size in the EDID.
    public var dotsPerInch: Int

    /// The fixed mode of scanout 0 until the image's default mode is used (#028).
    public static let testDefault = DisplayMode(
        widthPixels: 1024,
        heightPixels: 768,
        refreshHz: 60,
        dotsPerInch: 160
    )

    /// Creates a mode. Values are checked by `isSupported`, not by the initializer.
    public init(widthPixels: Int, heightPixels: Int, refreshHz: Int, dotsPerInch: Int) {
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.refreshHz = refreshHz
        self.dotsPerInch = dotsPerInch
    }

    /// Whether the mode fits the EDID and size limits this device can express.
    public var isSupported: Bool {
        (1...4095).contains(widthPixels)
            && (1...4095).contains(heightPixels)
            && (24...120).contains(refreshHz)
            && (1...1_200).contains(dotsPerInch)
    }

    /// The mode as `WIDTHxHEIGHT@HZ`.
    public var description: String {
        "\(widthPixels)x\(heightPixels)@\(refreshHz)"
    }
}

/// The host-owned state of one scanout.
public struct ScanoutState: Equatable, Sendable {
    /// Whether the scanout reports a connected display to the guest.
    public var isEnabled: Bool
    /// The mode the scanout offers, kept while the scanout is disabled.
    public var mode: DisplayMode

    /// Creates a scanout state.
    public init(isEnabled: Bool, mode: DisplayMode) {
        self.isEnabled = isEnabled
        self.mode = mode
    }
}

/// The 16 scanouts and the display generation that drives change events (graphics.md §4.3).
///
/// `displayGeneration` increases on every change that the guest must see. A no-op
/// change does not increase it. The table is a value type. The owning device guards
/// it with its lock.
public struct ScanoutTable: Equatable, Sendable {
    /// The number of changes so far. The guest is told about each one.
    public private(set) var displayGeneration: UInt64 = 0

    private var states: [ScanoutState]

    /// Creates the table with scanout 0 enabled at `initialMode` and the other scanouts disabled.
    public init(initialMode: DisplayMode = .testDefault) {
        let disabled = ScanoutState(isEnabled: false, mode: initialMode)
        states = Array(repeating: disabled, count: VirtioGPUProtocol.scanoutCount)
        states[0] = ScanoutState(isEnabled: true, mode: initialMode)
    }

    /// The state of one scanout.
    public func state(of scanout: ScanoutID) -> ScanoutState {
        states[scanout.rawValue]
    }

    /// The states of all 16 scanouts in index order.
    public var allStates: [ScanoutState] {
        states
    }

    /// Enables the scanout with `mode`. Returns `true` when the state changed.
    public mutating func enable(_ scanout: ScanoutID, mode: DisplayMode) throws(GraphicsFailure) -> Bool {
        guard mode.isSupported else {
            throw .modeUnsupported(mode: mode)
        }
        let next = ScanoutState(isEnabled: true, mode: mode)
        return replace(scanout, with: next)
    }

    /// Disables the scanout and keeps its last mode. Returns `true` when the state changed.
    public mutating func disable(_ scanout: ScanoutID) -> Bool {
        let current = states[scanout.rawValue]
        return replace(scanout, with: ScanoutState(isEnabled: false, mode: current.mode))
    }

    /// The enabled scanouts in index order.
    public var enabledScanouts: [ScanoutID] {
        states.indices.compactMap { index in
            states[index].isEnabled ? ScanoutID(rawValue: index) : nil
        }
    }

    private mutating func replace(_ scanout: ScanoutID, with next: ScanoutState) -> Bool {
        guard states[scanout.rawValue] != next else {
            return false
        }
        states[scanout.rawValue] = next
        displayGeneration &+= 1
        return true
    }
}
