import AppKit
import Dispatch

/// Owns the native window for one app session (display-and-windowing.md §7, #27).
///
/// The window is created at the scanout's size, so the surface shows at its native density, and it is never resized
/// by the guest. Before the first frame, it shows a lightweight app placeholder. The window consumes the frames of its
/// source on the main actor, applies the layer's frame gate, and reports each displayed frame back to the source. Its
/// pointer events go to the input sink (#25). The mapper follows the generation of the frames it shows.
@MainActor
public final class SessionWindowController: NSObject, NSWindowDelegate {
    /// Runs when the user closes the window. The owner stops the runtime, which is the close action of the window.
    public var onClose: (@MainActor () -> Void)?

    private let window: NSWindow
    private let layerView: IOSurfaceLayerView
    private let inputSink: PointerInputSink?
    private let onFocusChanged: (@MainActor (Bool) -> Void)?
    private let allowsResize: Bool
    private var placeholderView: SessionWindowPlaceholderView?
    private var errorView: SessionWindowErrorView?
    private let source: any FrameSource
    private var gate: LayerFrameGate
    private var consumer: Task<Void, Never>?
    private var presentationState: SessionWindowPresentationState
    private let onGeometryChanged:
        ((CGSize, CGFloat, Double, @escaping @MainActor (DisplayResizeOutcome) -> Void) -> Void)?
    private var geometryDebounce: Task<Void, Never>?
    private var geometryUpdatePending = false
    private var pendingSurfaceGeneration: UInt64?
    private var generationHasCommittedFrame = false
    private var isShown = false

    /// Creates the window for `source`, titled `title`, at the points of the source's pixel size divided by `backingScale`.
    /// The pointer events of the window go to `inputSink` (#25). Without a sink the window shows the frames only.
    public init(
        source: any FrameSource,
        title: String,
        backingScale: CGFloat,
        inputSink: PointerInputSink? = nil,
        allowsResize: Bool = true,
        appIcon: NSImage? = nil,
        holdsPlaceholderUntilAppRunning: Bool = false,
        onFocusChanged: (@MainActor (Bool) -> Void)? = nil,
        onGeometryChanged:
            ((CGSize, CGFloat, Double, @escaping @MainActor (DisplayResizeOutcome) -> Void) -> Void)? = nil
    ) {
        self.source = source
        let surfaceSet = source.currentSurfaceSet
        gate = LayerFrameGate(generation: surfaceSet.generation)
        let size = surfaceSet.contentSize
        layerView = IOSurfaceLayerView(
            frame: NSRect(origin: .zero, size: size),
            contentSize: size,
            contentScale: surfaceSet.contentsScale,
            zoom: surfaceSet.zoom
        )
        self.onGeometryChanged = onGeometryChanged
        self.allowsResize = allowsResize
        self.onFocusChanged = onFocusChanged
        presentationState = SessionWindowPresentationState(
            holdsPlaceholderUntilAppRunning: holdsPlaceholderUntilAppRunning
        )
        layerView.setInputEnabled(false)
        self.inputSink = inputSink
        let placeholderView = SessionWindowPlaceholderView(
            appName: title, appIcon: appIcon, frame: NSRect(origin: .zero, size: size))
        var styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if allowsResize {
            styleMask.insert(.resizable)
        }
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        super.init()
        layerView.update(
            pixelWidth: surfaceSet.pixelWidth,
            pixelHeight: surfaceSet.pixelHeight,
            generation: surfaceSet.generation,
            contentSize: surfaceSet.contentSize,
            contentsScale: surfaceSet.contentsScale
        )
        window.title = title
        window.contentMinSize = NSSize(width: 320 * surfaceSet.zoom, height: 400 * surfaceSet.zoom)
        window.isReleasedWhenClosed = false
        let contentView = NSView(frame: NSRect(origin: .zero, size: size))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.cgColor
        layerView.frame = contentView.bounds
        layerView.autoresizingMask = [.width, .height]
        placeholderView.autoresizingMask = [.width, .height]
        contentView.addSubview(layerView)
        contentView.addSubview(placeholderView)
        window.contentView = contentView
        // Key events go to the first responder, so the view that forwards them must be it (input.md §5.1).
        window.initialFirstResponder = layerView
        window.delegate = self
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed
        // Pointer moves without a button are hover events, so the window needs them (input.md §4.1).
        window.acceptsMouseMovedEvents = true
        window.setContentSize(size)
        window.center()
        if allowsResize {
            layerView.onZoomChanged = { [weak self] zoom in
                self?.window.contentMinSize = NSSize(width: 320 * zoom, height: 400 * zoom)
                self?.requestGeometryUpdate(zoom: zoom)
            }
        }
        self.placeholderView = placeholderView
    }

    /// Shows the window, and starts applying the frames of the source.
    public func show() {
        isShown = true
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(layerView)
        consumer = Task { [source] in
            for await event in source.frames {
                self.apply(event)
            }
        }
    }

    /// Changes the window title, which a developer display may use for its statistics line.
    public func setTitle(_ title: String) {
        window.title = title
    }

    /// Changes the app name shown in the window and in its placeholder or failure panel.
    public func setAppName(_ title: String) {
        window.title = title
        placeholderView?.setAppName(title)
        errorView?.setAppName(title)
    }

    /// Updates the status shown until the first frame arrives.
    public func setPlaceholderStatus(_ status: String) {
        placeholderView?.setStatus(status)
    }

    /// Reveals the app after its first post-launch frame has committed to the window.
    public func appDidPresentFirstFrame() {
        presentationState.markAppRunning()
        guard !presentationState.showsPlaceholder else {
            updateInputAvailability()
            return
        }
        placeholderView?.removeFromSuperview()
        placeholderView = nil
        updateInputAvailability()
    }

    /// Replaces the app frame with a persistent launch failure and its remediation.
    public func showFailure(message: String, remediation: String) {
        presentationState.markFailed()
        geometryDebounce?.cancel()
        geometryDebounce = nil
        geometryUpdatePending = false
        window.styleMask.remove(.resizable)
        layerView.setInputEnabled(false)
        placeholderView?.removeFromSuperview()
        placeholderView = nil
        errorView?.removeFromSuperview()
        guard let contentView = window.contentView else {
            return
        }
        let view = SessionWindowErrorView(
            appName: window.title,
            message: message,
            remediation: remediation
        ) { [weak self] in
            self?.window.performClose(nil)
        }
        view.frame = contentView.bounds
        view.autoresizingMask = [.width, .height]
        contentView.addSubview(view)
        errorView = view
    }

    /// Closes the window without asking. The owner calls it when the boot ends.
    public func close() {
        window.close()
    }

    /// The window lost key status, so the open gesture ends on the guest (input.md §4.2).
    public func windowDidResignKey(_ notification: Notification) {
        // InputRouter owns guest cancellation when this window gives up focus. Reset local event state here without
        // sending a second cancel batch through the input stream.
        layerView.focusLost(sendCancellation: false)
        onFocusChanged?(false)
    }

    /// The window became key, so Android must focus the task on this window's display.
    public func windowDidBecomeKey(_ notification: Notification) {
        onFocusChanged?(true)
    }

    /// Applies the new Android mode once the user's resize settles.
    public func windowDidEndLiveResize(_ notification: Notification) {
        requestGeometryUpdate()
    }

    /// A quiet-period resize also handles fullscreen transitions, which do not always send live-resize callbacks.
    public func windowDidResize(_ notification: Notification) {
        requestGeometryUpdate()
    }

    /// Moving to a display with another backing scale uses the same mode replacement path.
    public func windowDidChangeBackingProperties(_ notification: Notification) {
        requestGeometryUpdate()
    }

    /// Ends the input, then stops the frames, and tells the owner that the user closed the window.
    public func windowWillClose(_ notification: Notification) {
        // The session route sends cancelAll before its display lease is released.
        layerView.focusLost(sendCancellation: false)
        geometryDebounce?.cancel()
        geometryDebounce = nil
        consumer?.cancel()
        consumer = nil
        onClose?()
    }

    private func apply(_ event: FrameSourceEvent) {
        switch event {
        case .surfacesReplaced(let generation):
            guard generation > gate.generation else { return }
            gate.announce(generation: generation)
            pendingSurfaceGeneration = max(pendingSurfaceGeneration ?? generation, generation)
            generationHasCommittedFrame = false
            layerView.setInputEnabled(false)
        case .frameReady(let generation, let bufferIndex, let sequence):
            guard let surfaceSet = source.surfaceSet(generation: generation) else {
                return
            }
            guard generation >= gate.generation else { return }
            let replacesGeometry = generation > gate.generation
            if replacesGeometry {
                gate.switchTo(generation: generation)
                guard gate.generation == generation else {
                    return
                }
                if let pendingSurfaceGeneration, pendingSurfaceGeneration <= generation {
                    self.pendingSurfaceGeneration = nil
                }
                generationHasCommittedFrame = false
                layerView.setInputEnabled(false)
            }
            guard gate.accept(generation: generation, sequence: sequence),
                surfaceSet.surfaces.indices.contains(bufferIndex)
            else {
                return
            }
            let source = source
            layerView.show(
                surfaceSet.surfaces[bufferIndex],
                replacingWith: replacesGeometry ? surfaceSet : nil
            ) { [weak self] in
                source.frameDisplayed(generation: generation, sequence: sequence)
                guard let self else {
                    return
                }
                guard generation == gate.generation else {
                    return
                }
                if replacesGeometry {
                    layerView.commitGeometry(generation: generation)
                }
                presentationState.markGeometrySynchronized(generation: generation)
                if pendingSurfaceGeneration.map({ $0 <= generation }) ?? true {
                    generationHasCommittedFrame = true
                }
                presentationState.markFramePresented()
                guard !presentationState.showsPlaceholder else {
                    updateInputAvailability()
                    return
                }
                placeholderView?.removeFromSuperview()
                placeholderView = nil
                updateInputAvailability()
            }
        }
    }

    private func requestGeometryUpdate(zoom: Double? = nil) {
        guard allowsResize, isShown, !presentationState.hasFailed else {
            return
        }
        geometryUpdatePending = true
        layerView.setInputEnabled(false)
        geometryDebounce?.cancel()
        let requestedZoom = zoom ?? layerView.currentZoom
        geometryDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else {
                return
            }
            geometryDebounce = nil
            guard let contentSize = window.contentView?.bounds.size else {
                return
            }
            guard let onGeometryChanged else {
                geometryUpdateDidFinish(outcome: .rejected)
                return
            }
            onGeometryChanged(contentSize, window.backingScaleFactor, requestedZoom) { [weak self] outcome in
                self?.geometryUpdateDidFinish(outcome: outcome)
            }
        }
    }

    private func geometryUpdateDidFinish(outcome: DisplayResizeOutcome) {
        geometryUpdatePending = false
        switch outcome {
        case .applied:
            let newestGeneration = source.currentSurfaceSet.generation
            if newestGeneration > gate.generation {
                gate.announce(generation: newestGeneration)
                pendingSurfaceGeneration = max(pendingSurfaceGeneration ?? newestGeneration, newestGeneration)
                generationHasCommittedFrame = false
            }
        case .rejected:
            if pendingSurfaceGeneration == nil {
                generationHasCommittedFrame = generationHasCommittedFrame || presentationState.hasPresentedFrame
            }
        case .unchanged:
            break
        case .stateUncertain:
            presentationState.markGeometryUncertain(after: source.currentSurfaceSet.generation)
        }
        updateInputAvailability()
    }

    private func updateInputAvailability() {
        layerView.inputSink = inputSink
        layerView.setInputEnabled(
            presentationState.acceptsInput
                && generationHasCommittedFrame
                && pendingSurfaceGeneration == nil
                && !geometryUpdatePending
        )
    }
}

/// Tracks frame commitment, optional app-launch readiness, and geometry safety for a session window.
struct SessionWindowPresentationState: Equatable {
    private let holdsPlaceholderUntilAppRunning: Bool
    private(set) var hasAppReachedRunningState = false
    private(set) var hasPresentedFrame = false
    private(set) var hasFailed = false
    private(set) var uncertainAfterGeneration: UInt64?

    init(holdsPlaceholderUntilAppRunning: Bool = false) {
        self.holdsPlaceholderUntilAppRunning = holdsPlaceholderUntilAppRunning
    }

    var showsPlaceholder: Bool {
        !hasPresentedFrame || (holdsPlaceholderUntilAppRunning && !hasAppReachedRunningState)
    }

    var acceptsInput: Bool {
        hasPresentedFrame && (!holdsPlaceholderUntilAppRunning || hasAppReachedRunningState)
            && !hasFailed && geometryIsCertain
    }

    var geometryIsCertain: Bool {
        uncertainAfterGeneration == nil
    }

    mutating func markFramePresented() {
        hasPresentedFrame = true
    }

    mutating func markAppRunning() {
        hasAppReachedRunningState = true
    }

    mutating func markGeometryUncertain(after generation: UInt64) {
        uncertainAfterGeneration = max(uncertainAfterGeneration ?? generation, generation)
    }

    mutating func markGeometrySynchronized(generation: UInt64) {
        guard let uncertainAfterGeneration, generation > uncertainAfterGeneration else {
            return
        }
        self.uncertainAfterGeneration = nil
    }

    mutating func markFailed() {
        hasFailed = true
    }
}

@MainActor
private final class SessionWindowPlaceholderView: NSView {
    private var appName: String
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "Starting Android…")

    init(appName: String, appIcon: NSImage?, frame: NSRect) {
        self.appName = appName
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        let fallbackIcon =
            NSImage(
                systemSymbolName: "app.fill",
                accessibilityDescription: "\(appName) app icon"
            ) ?? NSImage()
        let icon = NSImageView(image: appIcon ?? fallbackIcon)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
        icon.contentTintColor = .white
        icon.setContentHuggingPriority(.required, for: .vertical)

        nameLabel.stringValue = appName
        nameLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        nameLabel.textColor = .white
        statusLabel.textColor = NSColor(calibratedWhite: 0.78, alpha: 1)

        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.isIndeterminate = true
        progress.startAnimation(nil)

        let stack = NSStackView(views: [icon, nameLabel, statusLabel, progress])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(appName), Starting Android")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SessionWindowPlaceholderView is created in code.")
    }

    func setStatus(_ status: String) {
        statusLabel.stringValue = status
        setAccessibilityLabel("\(appName), \(status)")
    }

    func setAppName(_ appName: String) {
        self.appName = appName
        nameLabel.stringValue = appName
        setAccessibilityLabel("\(appName), \(statusLabel.stringValue)")
    }
}

/// The AppKit event loop of the development windows.
///
/// `run()` must be called on the main thread, from a context that is neither an actor job nor a main-queue block. A
/// job that blocks in the loop stops the main actor's tasks, and a main-queue block that blocks in it stops the queue
/// that the virtual machine uses (IR-1103). The caller runs the work that the loop serves on other tasks.
public enum DisplayApplication {
    /// A stop that arrives before or during the loop. It is kept, so a loop that starts later still returns.
    private static let stopRequest = StopRequest()

    /// Runs the event loop on the calling thread until `stop()`.
    @MainActor
    public static func run() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.mainMenu = makeMainMenu()
        application.activate(ignoringOtherApps: true)
        guard !stopRequest.isRequested else {
            return
        }
        application.run()
    }

    /// Stops the event loop. Any thread may call it. The loop returns after the current event.
    public static func stop() {
        stopRequest.request()
        DispatchQueue.main.async {
            NSApplication.shared.stop(nil)
            // A posted event wakes the loop, so it sees the stop at once.
            if let event = NSEvent.otherEvent(
                with: .applicationDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 0,
                data1: 0,
                data2: 0
            ) {
                NSApplication.shared.postEvent(event, atStart: true)
            }
        }
    }

    @MainActor
    private static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let zoomIn = NSMenuItem(title: "Zoom In", action: #selector(IOSurfaceLayerView.zoomIn(_:)), keyEquivalent: "=")
        zoomIn.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(zoomIn)
        let zoomOut = NSMenuItem(
            title: "Zoom Out", action: #selector(IOSurfaceLayerView.zoomOut(_:)), keyEquivalent: "-")
        zoomOut.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(zoomOut)
        let actualSize = NSMenuItem(
            title: "Actual Size",
            action: #selector(IOSurfaceLayerView.actualSize(_:)),
            keyEquivalent: "0"
        )
        actualSize.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(actualSize)
        return mainMenu
    }
}

/// The flag that `DisplayApplication.stop` sets, read by the loop's start.
// UNCHECKED-SENDABLE: the flag is written and read under its lock, from any thread.
private final class StopRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    var isRequested: Bool {
        lock.withLock { requested }
    }

    func request() {
        lock.withLock { requested = true }
    }
}
