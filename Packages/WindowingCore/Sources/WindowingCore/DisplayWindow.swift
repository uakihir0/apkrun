import AppKit
import Dispatch

/// A development window for one display (display-and-windowing.md §7, #023).
///
/// The window is created at the scanout's size, so the surface shows at its native density, and it is never resized
/// by the guest. The window consumes the frames of its source on the main actor, applies the layer's frame gate, and
/// reports each displayed frame back to the source. Its pointer events go to the input sink (#024). The mapper follows
/// the generation of the frames it shows.
@MainActor
public final class DisplayWindow: NSObject, NSWindowDelegate {
    /// Runs when the user closes the window. The owner stops the runtime, which is the close action of the window.
    public var onClose: (@MainActor () -> Void)?

    private let window: NSWindow
    private let layerView: IOSurfaceLayerView
    private let source: any FrameSource
    private var gate: LayerFrameGate
    private var consumer: Task<Void, Never>?
    /// The generation that the input mapper maps to. Nil until the first frame is shown.
    private var inputGeneration: UInt64?

    /// Creates the window for `source`, titled `title`, at the points of the source's pixel size divided by `backingScale`.
    /// The pointer events of the window go to `inputSink` (#024). Without a sink the window shows the frames only.
    public init(
        source: any FrameSource,
        title: String,
        backingScale: CGFloat,
        inputSink: PointerInputSink? = nil
    ) {
        self.source = source
        gate = LayerFrameGate(generation: source.generation)
        let size = DisplayGeometry.contentSize(
            pixelWidth: source.pixelWidth,
            pixelHeight: source.pixelHeight,
            backingScale: backingScale
        )
        layerView = IOSurfaceLayerView(
            frame: NSRect(origin: .zero, size: size),
            contentSize: size,
            contentScale: backingScale
        )
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = title
        window.isReleasedWhenClosed = false
        layerView.inputSink = inputSink
        window.contentView = layerView
        window.delegate = self
        // Pointer moves without a button are hover events, so the window needs them (input.md §4.1).
        window.acceptsMouseMovedEvents = true
        window.setContentSize(size)
        window.center()
    }

    /// Shows the window, and starts applying the frames of the source.
    public func show() {
        window.makeKeyAndOrderFront(nil)
        consumer = Task { [source] in
            for await event in source.frames {
                self.apply(event)
            }
        }
    }

    /// Changes the window title, which the development display uses for its statistics line.
    public func setTitle(_ title: String) {
        window.title = title
    }

    /// Closes the window without asking. The owner calls it when the boot ends.
    public func close() {
        window.close()
    }

    /// The window lost key status, so the open gesture ends on the guest (input.md §4.2).
    public func windowDidResignKey(_ notification: Notification) {
        layerView.focusLost()
    }

    /// Ends the input, then stops the frames, and tells the owner that the user closed the window.
    public func windowWillClose(_ notification: Notification) {
        layerView.cancelAll()
        consumer?.cancel()
        consumer = nil
        onClose?()
    }

    private func apply(_ event: FrameSourceEvent) {
        switch event {
        case .frameReady(let generation, let bufferIndex, let sequence):
            guard gate.accept(generation: generation, sequence: sequence),
                source.surfaces.indices.contains(bufferIndex)
            else {
                return
            }
            // A new generation changes the mapper, and an open gesture of the old one is cancelled (input.md §3).
            if generation != inputGeneration {
                inputGeneration = generation
                layerView.update(
                    pixelWidth: source.pixelWidth,
                    pixelHeight: source.pixelHeight,
                    generation: generation
                )
            }
            let source = source
            layerView.show(source.surfaces[bufferIndex]) {
                source.frameDisplayed(sequence: sequence)
            }
        }
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
    public static func run() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
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
