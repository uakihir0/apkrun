import AppKit
import Foundation
import IOSurface
import InputCore
import RuntimeAPI
import RuntimeCore
import RuntimeHost
import WindowingCore
import XCTest

/// A point in display pixels of display 0: the origin at the top-left, y down.
typealias InputPixel = (x: Double, y: Double)

enum AndroidInputRunFailure: Error, Equatable {
    case timedOut(String)
    case viewNotFound(String)
}

/// One development boot with the window and input, as `apkrun dev launch` runs it (#024, decision D13).
///
/// The boot is `DevBoot` with a developer display and a development input route. The window's adapters (the CLI's
/// `DisplayPump`, `SurfacePoolFrameSource`, and `EmbeddedInputSink`) live in the CLI target, which the test host cannot
/// import, so they are repeated here. `EmbeddedInputSinkTests` checks the CLI's conversion table.
@MainActor
final class AndroidInputRun {
    private static let windowTitle = "APKRun display 0"
    private static let width = 1024
    private static let height = 768

    let adb: AdbClient
    private let home: URL
    private let display = DeveloperDisplay(pixelWidth: AndroidInputRun.width, pixelHeight: AndroidInputRun.height)
    private let route = DevInputRoute()
    private let stop = AsyncStream.makeStream(of: Void.self)
    private let bootLog = BootLog()
    private var frames: DisplayFrames?
    private var framesSeen = 0
    private var window: DisplayWindow?
    private var boot: Task<Void, Never>?

    private init(home: URL, adb: AdbClient) {
        self.home = home
        self.adb = adb
    }

    /// Runs `body` on a boot with the window and input, after `apk` is installed and `package` is started on display 0.
    static func with(apk: URL, package: String, _ body: (AndroidInputRun) async throws -> Void) async throws {
        guard let guest = ProcessInfo.processInfo.environment["APKRUN_GUEST_DIR"], !guest.isEmpty else {
            throw XCTSkip(
                "APKRUN_GUEST_DIR is not set. Build the Guest Agent bundle with scripts/build-guest.sh --out.")
        }
        let bundle = try AndroidBootSession.bundleDirectory()
        let adbExecutable = try AndroidTestEnvironment.adbExecutable()
        if ProcessInfo.processInfo.environment["ANDROID_HOME"] == nil,
            let sdk = AndroidTestEnvironment.current()["ANDROID_HOME"]
        {
            // DevBoot passes its environment only to the paths, and the supervisor finds adb in the process environment.
            setenv("ANDROID_HOME", sdk, 1)
        }
        let home = try AndroidBootFixture.makeHome()
        _ = try await AndroidBootFixture(home: home, bundle: bundle)
        let run = AndroidInputRun(home: home, adb: AdbClient(executable: adbExecutable))
        run.startBoot(guestAgentDirectory: URL(fileURLWithPath: guest, isDirectory: true))
        do {
            try await run.prepare(apk: apk, package: package)
            try await body(run)
        } catch {
            await run.finish()
            throw error
        }
        await run.finish()
    }

    /// The pointer of the window. Its content rectangle is the view's bounds: the window keeps the display's aspect.
    func pointer() throws -> InputPointer {
        let window = try XCTUnwrap(NSApplication.shared.windows.first { $0.title == Self.windowTitle })
        let view = try XCTUnwrap(window.contentView as? IOSurfaceLayerView)
        let size = view.bounds.size
        let mapper = DisplayGeometry.coordinateMapper(
            contentSize: size, in: size, pixelWidth: Self.width, pixelHeight: Self.height, generation: 1)
        return InputPointer(window: window, view: view, mapper: mapper)
    }

    /// The centre of the view `resourceID` in display pixels, from a `uiautomator dump` (retried while the screen is
    /// busy, as scripts/dev/validate-input-coordinates.sh does).
    func centre(of resourceID: String) async throws -> InputPixel {
        let path = "/data/local/tmp/apkrun-024-input.xml"
        for _ in 0..<15 {
            let xml =
                (try? await adb.shell("uiautomator dump \(path) > /dev/null; cat \(path); rm -f \(path)").output) ?? ""
            if let bounds = Self.bounds(of: resourceID, in: xml) {
                return ((bounds[0] + bounds[2]) / 2, (bounds[1] + bounds[3]) / 2)
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw AndroidInputRunFailure.viewNotFound(resourceID)
    }

    /// The fixture's log lines, polled every 500 ms until `enough` holds or 30 s have passed.
    func fixtureLog(until enough: ([String]) -> Bool) async throws -> [String] {
        var lines: [String] = []
        for _ in 0..<60 {
            let output = try await adb.shell("logcat -d -s APKRUN-FIXTURE").output
            lines = output.split(separator: "\n").map(String.init)
            if enough(lines) {
                break
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        return lines
    }

    /// The integers that follow `prefix` on the lines that carry it, in order: `click 7` gives 7.
    static func numbers(in lines: [String], after prefix: String) -> [Int] {
        lines.compactMap { line in
            line.range(of: prefix).flatMap { Int(line[$0.upperBound...].trimmingCharacters(in: .whitespaces)) }
        }
    }

    /// The bounds of the node `resourceID` in a uiautomator dump: left, top, right, and bottom in display pixels.
    static func bounds(of resourceID: String, in xml: String) -> [Double]? {
        let node = xml.components(separatedBy: "resource-id=\"\(resourceID)\"").dropFirst().first ?? ""
        let rest = node.prefix { $0 != ">" }.components(separatedBy: "bounds=\"").dropFirst().first ?? ""
        let numbers = rest.split { !$0.isNumber }.compactMap { Double($0) }
        return numbers.count >= 4 ? Array(numbers.prefix(4)) : nil
    }

    /// Ends the input and the window, stops Android, and removes the home, in that order.
    func finish() async {
        window?.close()
        stop.continuation.yield(())
        await boot?.value
        VMRunResources.removeHomeOrReport(home)
    }

    private func startBoot(guestAgentDirectory: URL) {
        var options = DevBootOptions(gpu: .virgl, stopWhenReady: false, guestAgentDirectory: guestAgentDirectory)
        options.developerDisplay = display
        options.inputRoute = route
        let bootLog = bootLog
        let stops = stop.stream
        let home = home
        let report: @Sendable (DevBootEvent) -> Void = { event in
            if case .message(let text) = event { bootLog.append(text) }
            if case .warning(let text) = event { bootLog.append(text) }
        }
        boot = Task.detached {
            do {
                try await DevBoot().run(
                    options: options, environment: ["APKRUN_HOME": home.path], stopRequests: stops, onEvent: report)
            } catch {
                bootLog.append("failed: \(error)")
            }
        }
        Task { @MainActor in
            for await event in display.events {
                handle(event)
            }
        }
    }

    /// Makes the window when the display is attached, and passes each frame to it.
    private func handle(_ event: DeveloperDisplayEvent) {
        switch event {
        case .attached(let surfaces):
            let source = DisplayFrames(surfaces: surfaces, display: display)
            let scale = NSScreen.main?.backingScaleFactor ?? 1
            let window = DisplayWindow(
                source: source, title: Self.windowTitle, backingScale: scale, inputSink: WireSink(route: route))
            window.show()
            frames = source
            self.window = window
        case .frameReady(let generation, let bufferIndex, let sequence):
            framesSeen += 1
            frames?.ingest(generation: generation, bufferIndex: bufferIndex, sequence: sequence)
        }
    }

    /// Waits until the input is bound and frames have arrived, then installs `apk` and starts `package`. The launch is
    /// `monkey` with one event, which starts the launcher activity: the boot would start a named package before the
    /// install could happen, so the suite starts it over adb.
    private func prepare(apk: URL, package: String) async throws {
        try await waitUntil(seconds: 900, "input is bound to display 0") {
            self.bootLog.contains("input is bound to display 0")
        }
        try await waitUntil(seconds: 120, "the first frames") { self.framesSeen >= 2 }
        try await adb.connect(timeout: .seconds(30))
        try await adb.install(apk: apk)
        _ = try await adb.shell("monkey -p \(package) -c android.intent.category.LAUNCHER 1")
    }

    /// Polls `condition` every 200 ms until it holds. It throws when `seconds` have passed.
    private func waitUntil(seconds: Double, _ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw AndroidInputRunFailure.timedOut("\(what) (boot: \(bootLog.recent))")
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }
}

/// Posts AppKit pointer events into the window's content view, which receives them as the window delivers them.
///
/// The view's mouse methods are called directly. A window that is not key does not deliver a click, because the view
/// refuses the first mouse (`acceptsFirstMouse`), and the test host is never key.
@MainActor
struct InputPointer {
    let window: NSWindow
    let view: IOSurfaceLayerView
    let mapper: CoordinateMapper

    func click(at pixel: InputPixel) async throws {
        deliver(.leftMouseDown, at: pixel)
        try await Task.sleep(for: .milliseconds(50))
        deliver(.leftMouseUp, at: pixel)
    }

    func rightClick(at pixel: InputPixel) async throws {
        deliver(.rightMouseDown, at: pixel)
        try await Task.sleep(for: .milliseconds(50))
        deliver(.rightMouseUp, at: pixel)
    }

    /// A left-button drag: down at `start`, `steps` moves along the straight path, and up at `end`.
    func drag(from start: InputPixel, to end: InputPixel, steps: Int) async throws {
        deliver(.leftMouseDown, at: start)
        try await Task.sleep(for: .milliseconds(50))
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            deliver(.leftMouseDragged, at: (start.x + (end.x - start.x) * t, start.y + (end.y - start.y) * t))
            try await Task.sleep(for: .milliseconds(20))
        }
        deliver(.leftMouseUp, at: end)
    }

    /// A scroll of `deltaY` at `pixel`: points for a trackpad (`precise`), lines for a wheel. The CGEvent is made as the
    /// event tap delivers it, and AppKit makes the NSEvent that the view reads.
    func scroll(at pixel: InputPixel, deltaY: Int32, precise: Bool) {
        let location = view.convert(windowPoint(pixel), to: nil)
        let screen = window.convertToScreen(NSRect(origin: location, size: .zero)).origin
        let units: CGScrollEventUnit = precise ? .pixel : .line
        guard
            let cg = CGEvent(
                scrollWheelEvent2Source: nil, units: units, wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0)
        else {
            return
        }
        if precise {
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        }
        // CoreGraphics counts the global y from the top of the primary display, and AppKit from its bottom.
        cg.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
        if let event = NSEvent(cgEvent: cg) {
            view.scrollWheel(with: event)
        }
    }

    private func deliver(_ type: NSEvent.EventType, at pixel: InputPixel) {
        let location = view.convert(windowPoint(pixel), to: nil)
        guard
            let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else {
            return
        }
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        case .rightMouseDown: view.rightMouseDown(with: event)
        case .rightMouseUp: view.rightMouseUp(with: event)
        default: break
        }
    }

    /// The window point of a display pixel: the inverse of the window's mapping.
    private func windowPoint(_ pixel: InputPixel) -> NSPoint {
        let point = mapper.windowPoint(forPixel: InputCore.DisplayPoint(x: pixel.x, y: pixel.y))
        return NSPoint(x: point.x, y: point.y)
    }
}

/// The window's frames, from the developer display (the CLI's `SurfacePoolFrameSource`, #023).
private final class DisplayFrames: FrameSource, @unchecked Sendable {
    // UNCHECKED-SENDABLE: the surfaces are written once, and the continuation is used on the main actor only.
    let surfaces: [IOSurface]
    let generation: UInt64 = 1
    let pixelWidth: Int
    let pixelHeight: Int
    let frames: AsyncStream<FrameSourceEvent>
    private let continuation: AsyncStream<FrameSourceEvent>.Continuation
    private let display: DeveloperDisplay

    init(surfaces: [IOSurface], display: DeveloperDisplay) {
        self.surfaces = surfaces
        self.display = display
        pixelWidth = display.pixelWidth
        pixelHeight = display.pixelHeight
        let made = AsyncStream.makeStream(of: FrameSourceEvent.self, bufferingPolicy: .bufferingNewest(8))
        frames = made.stream
        continuation = made.continuation
    }

    func ingest(generation: UInt64, bufferIndex: Int, sequence: UInt64) {
        continuation.yield(.frameReady(generation: generation, bufferIndex: bufferIndex, sequence: sequence))
    }

    func frameDisplayed(sequence: UInt64) {
        display.frameDisplayed(sequence: sequence)
    }
}

/// The window's events, routed in order (the CLI's `EmbeddedInputSink`, decision D10). One task converts each queued
/// list to the wire types of runtime-api.md §7.2 and routes it, so no batch overtakes another.
private final class WireSink: PointerInputSink, @unchecked Sendable {
    private let queue: AsyncStream<[InputCore.InputEvent]>.Continuation

    init(route: DevInputRoute) {
        // Unbounded: a dropped press or release would leave a gesture open on the guest.
        let made = AsyncStream.makeStream(of: [InputCore.InputEvent].self, bufferingPolicy: .unbounded)
        queue = made.continuation
        Task {
            for await events in made.stream {
                await route.send(RuntimeAPI.InputBatch(events: events.compactMap(WireSink.wire)))
            }
        }
    }

    func deliver(_ events: [InputCore.InputEvent]) {
        queue.yield(events)
    }

    /// The wire form of `event`. The translator makes no key or long-press event in #024 (decision D6).
    static func wire(_ event: InputCore.InputEvent) -> RuntimeAPI.WireInputEvent? {
        switch event {
        case .touch(let touch):
            let phase: RuntimeAPI.TouchPhase =
                switch touch.phase {
                case .down: .down
                case .move: .move
                case .up: .up
                case .cancel: .cancel
                }
            return .touch(
                .init(phase: phase, pointerID: touch.pointerID, position: point(touch.position), time: time(touch.time))
            )
        case .mouse(let mouse):
            return .mouse(
                .init(
                    action: action(mouse.action), position: point(mouse.position), buttons: mouse.buttons.rawValue,
                    time: time(mouse.time)))
        case .scroll(let scroll):
            return .scroll(
                .init(
                    position: point(scroll.position), vertical: scroll.vertical, horizontal: scroll.horizontal,
                    time: time(scroll.time)))
        case .cancelAll(let at):
            return .cancelAll(time(at))
        default:
            return nil
        }
    }

    private static func action(_ action: InputCore.MouseEvent.Action) -> RuntimeAPI.MouseAction {
        switch action {
        case .hoverEnter: .hoverEnter
        case .hoverMove: .hoverMove
        case .hoverExit: .hoverExit
        case .press(let button): .press(wireButton(button))
        case .release(let button): .release(wireButton(button))
        }
    }

    private static func wireButton(_ button: InputCore.MouseButton) -> RuntimeAPI.MouseButton {
        switch button {
        case .primary: .primary
        case .secondary: .secondary
        case .tertiary: .tertiary
        case .back: .back
        case .forward: .forward
        }
    }

    private static func time(_ time: InputCore.InputTimestamp) -> RuntimeAPI.InputTimestamp {
        RuntimeAPI.InputTimestamp(hostNanos: time.hostNanos)
    }

    private static func point(_ point: InputCore.DisplayPoint) -> RuntimeAPI.DisplayPoint {
        RuntimeAPI.DisplayPoint(x: point.x, y: point.y)
    }
}

/// The messages and warnings of the boot, which `DevBoot` reports on its own task.
private final class BootLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.withLock { lines.append(line) }
    }

    func contains(_ line: String) -> Bool {
        lock.withLock { lines.contains(line) }
    }

    var recent: String {
        lock.withLock { lines.suffix(3).joined(separator: "; ") }
    }
}
