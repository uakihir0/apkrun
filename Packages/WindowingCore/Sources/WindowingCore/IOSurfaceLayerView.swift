import AppKit
import IOSurface
import InputCore
import QuartzCore

/// Shows one IOSurface as the contents of a plain layer (display-and-windowing.md §5.3, #023), and captures the pointer and key
/// events of the window (input.md §3, §4, §5, #024, #025).
///
/// The view never draws with the CPU. Setting the contents is zero-copy: Core Animation reads the surface, and the
/// consumer's `displayed` callback runs once Core Animation has committed the new contents.
///
/// The pointer events go through an ``EventTranslator``, and the key events through a ``KeyTranslator``. Both send to ``inputSink``. The mapper follows the content
/// rectangle, which is the aspect-fit rectangle of the view, so the letterbox maps to nothing.
@MainActor
public final class IOSurfaceLayerView: NSView {
    /// The interval of the timer that sends the held hover moves and scrolls: 1/120 s (input.md §4.1, decision D4).
    private static let flushInterval: TimeInterval = 1.0 / 120.0

    private let contentLayer = CALayer()
    private let contentSize: CGSize
    private var translator: EventTranslator
    /// The key events of key mode (input.md §5.1). The keys that are down end with `focusLost` and `cancelAll`.
    private var keyTranslator = KeyTranslator()
    /// The pixel size and generation that the owner set with ``update(pixelWidth:pixelHeight:generation:)``. Nil until
    /// then, so the translator maps nothing before the first surface.
    private var geometry: (pixelWidth: Int, pixelHeight: Int, generation: UInt64)?
    private var trackingArea: NSTrackingArea?
    /// The rectangle of the tracking area, so that a layout that does not move the content keeps the area.
    private var trackingRect: CGRect = .zero
    private var flushTimer: Timer?
    /// Startup input must not mutate translator state until the first frame is committed.
    private var inputEnabled = true

    /// Receives the pointer and key events, in order.
    public var inputSink: PointerInputSink?

    /// Observes raw pointer receipt for explicitly enabled diagnostics. The default input path does not call an observer.
    public var inputEventReceiptObserver: ((Int, UInt64) -> Void)?

    /// Creates a view whose content is `contentSize` points, shown at `contentScale` pixels per point.
    public init(frame: NSRect, contentSize: CGSize, contentScale: CGFloat) {
        self.contentSize = contentSize
        // An empty mapper maps nothing, so no event leaves before `update` has set the surface.
        let unset = CoordinateMapper(
            contentRect: DisplayRect(x: 0, y: 0, width: 0, height: 0), pixelWidth: 0, pixelHeight: 0, generation: 0)
        translator = EventTranslator(mapper: unset)
        super.init(frame: frame)
        wantsLayer = true
        contentLayer.bounds = CGRect(origin: .zero, size: contentSize)
        contentLayer.contentsScale = contentScale
        contentLayer.contentsGravity = .resize
        contentLayer.isOpaque = true
        layer?.addSublayer(contentLayer)
    }

    /// Not supported: the view is created in code.
    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("IOSurfaceLayerView is created in code.")
    }

    /// Keeps the content aspect-fit when the window is resized (display-and-windowing.md §7.1). The mapper follows the
    /// new content rectangle, and the tracking area follows it too.
    public override func layout() {
        super.layout()
        contentLayer.frame = contentRect
        if contentRect != trackingRect {
            installTrackingArea()
        }
        replaceMapper()
    }

    /// Shows `surface`. `displayed` runs on the main actor after Core Animation commits the contents.
    public func show(_ surface: IOSurface, displayed: @escaping @MainActor @Sendable () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                displayed()
            }
        }
        contentLayer.contents = surface
        CATransaction.commit()
    }

    /// Sets the pixel size and the generation of the display that the content shows (input.md §3). The mapper is replaced
    /// at once. A new generation cancels the gesture that is open, so the guest ends it.
    public func update(pixelWidth: Int, pixelHeight: Int, generation: UInt64) {
        geometry = (pixelWidth: pixelWidth, pixelHeight: pixelHeight, generation: generation)
        replaceMapper()
    }

    /// Enables event translation after the owner is ready to route input to the guest.
    func setInputEnabled(_ enabled: Bool) {
        inputEnabled = enabled
    }

    /// The window lost key status. The open gesture, the buttons, the hover, and the keys end on the guest (input.md §4.2,
    /// §7.3). The `cancelAll` that the pointer translator sends releases the keys on the guest.
    public func focusLost() {
        cancelPending()
        keyTranslator.reset()
        deliver(translator.focusLost(at: Self.now()))
    }

    /// The window is closing. Everything that is open ends on the guest, as with `focusLost` (input.md §4.2).
    public func cancelAll() {
        cancelPending()
        keyTranslator.reset()
        deliver(translator.cancelAll(at: Self.now()))
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installTrackingArea()
    }

    /// A window that is not key only activates on a click, so the click is not delivered (input.md §4.1).
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        false
    }

    public override var acceptsFirstResponder: Bool {
        true
    }

    public override func mouseDown(with event: NSEvent) {
        forward(event)
    }

    public override func mouseDragged(with event: NSEvent) {
        forward(event)
    }

    public override func mouseUp(with event: NSEvent) {
        forward(event)
    }

    public override func rightMouseDown(with event: NSEvent) {
        forward(event)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        forward(event)
    }

    public override func rightMouseUp(with event: NSEvent) {
        forward(event)
    }

    public override func mouseMoved(with event: NSEvent) {
        forward(event)
    }

    public override func mouseEntered(with event: NSEvent) {
        forward(event)
    }

    public override func mouseExited(with event: NSEvent) {
        forward(event)
    }

    public override func scrollWheel(with event: NSEvent) {
        forward(event)
    }

    /// Key mode: a key goes down. The view does not call `super`, so an unhandled key does not beep (input.md §5.1).
    public override func keyDown(with event: NSEvent) {
        forwardKey(event)
    }

    public override func keyUp(with event: NSEvent) {
        forwardKey(event)
    }

    /// A modifier key goes down or up, and Caps Lock toggles.
    public override func flagsChanged(with event: NSEvent) {
        forwardKey(event)
    }

    /// The ⌘ shortcuts of input.md §6 (⌘C, ⌘X, ⌘V, ⌘A, ⌘Z, and ⌘[) reach the guest before the menus can take them. The
    /// other key equivalents are left to the menus, so ⌘Q, ⌘W, and the rest keep their meaning.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard inputEnabled,
            let sample = KeyEventAdapter.sample(for: event),
            KeyTranslator.forwardsCommandShortcut(sample)
        else {
            return false
        }
        deliver(keyTranslator.translate(sample))
        return true
    }

    /// The content rectangle in the view's coordinates: the aspect fit of the content in the bounds.
    private var contentRect: CGRect {
        DisplayGeometry.aspectFit(contentSize: contentSize, in: bounds.size)
    }

    /// Replaces the tracking area with one over the content rectangle, so that the enter and exit events follow the
    /// letterbox. The option `.inVisibleRect` would replace the rectangle with the visible rectangle, so it is not used.
    private func installTrackingArea() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        trackingRect = contentRect
        let area = NSTrackingArea(
            rect: trackingRect,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    /// Converts one event to a sample, translates it, and sends the events that come out. A held hover or scroll starts
    /// the flush timer.
    private func forward(_ event: NSEvent) {
        guard inputEnabled else {
            return
        }
        if let inputEventReceiptObserver {
            let timestampNanos = PointerEventAdapter.timestamp(seconds: event.timestamp).hostNanos
            inputEventReceiptObserver(Int(event.type.rawValue), timestampNanos)
        }
        let location = convert(event.locationInWindow, from: nil)
        guard let sample = PointerEventAdapter.sample(for: event, locationInContent: location) else {
            return
        }
        deliver(translator.translate(sample))
        if translator.hasPending {
            scheduleFlush()
        }
    }

    /// Converts one key event to a sample, translates it, and sends the events that come out.
    private func forwardKey(_ event: NSEvent) {
        guard inputEnabled else {
            return
        }
        guard let sample = KeyEventAdapter.sample(for: event) else {
            return
        }
        deliver(keyTranslator.translate(sample))
    }

    /// Stores the mapper for the current geometry. Nothing is stored before the first `update`.
    private func replaceMapper() {
        guard let geometry else {
            return
        }
        let mapper = DisplayGeometry.coordinateMapper(
            contentSize: contentSize,
            in: bounds.size,
            pixelWidth: geometry.pixelWidth,
            pixelHeight: geometry.pixelHeight,
            generation: geometry.generation
        )
        deliver(translator.replaceMapper(mapper, at: Self.now()))
        if translator.hasPending {
            scheduleFlush()
        }
    }

    /// Schedules one flush at the flush interval, unless one is already scheduled.
    private func scheduleFlush() {
        guard flushTimer == nil else {
            return
        }
        flushTimer = Timer.scheduledTimer(withTimeInterval: Self.flushInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushPending()
            }
        }
    }

    /// Sends the held hover move or scroll that is due. It schedules the next flush while something is still held.
    private func flushPending() {
        flushTimer = nil
        deliver(translator.flush(now: Self.now()))
        if translator.hasPending {
            scheduleFlush()
        }
    }

    /// Stops the flush timer. The caller ends the held events in the translator with `focusLost` or `cancelAll`.
    private func cancelPending() {
        flushTimer?.invalidate()
        flushTimer = nil
    }

    private func deliver(_ events: [InputEvent]) {
        guard !events.isEmpty else {
            return
        }
        inputSink?.deliver(events)
    }

    /// The current time on the clock of the event timestamps (`NSEvent.timestamp` is seconds since the system started).
    private static func now() -> InputTimestamp {
        InputTimestamp(hostNanos: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000))
    }
}
