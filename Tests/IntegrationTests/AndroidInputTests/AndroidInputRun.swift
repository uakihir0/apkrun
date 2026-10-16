import AppKit
import CoreGraphics
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
    /// The launch started no process of the package, so the view could not appear (IR-1286).
    case appDidNotStart(String)
    /// The boot ended before the condition held, so waiting longer cannot help (IR-1256).
    case bootEnded(String)
    case inputRouteUnbound
    case inputAckTraceNotNegotiated
    case windowNotActive
    case ambiguousDisplay
    case cannotCreateSystemEvent
    case periodicAcknowledgementRequiresDirectView
}

enum InputPointerDelivery: Sendable, Equatable {
    case directView
    case windowServer
}

struct InputTouchCaptureSnapshot {
    let touches: InputTouchEventHistory
    let sentEvents: InputSentEventHistory
    let acknowledgements: InputAcknowledgementHistory?
    let counters: InputCounters
}

struct InputTouchEventHistory: Sendable, Equatable {
    let records: [TouchEvent]
    let discardedRecords: Int
}

private final class InputTouchEventRecorder: @unchecked Sendable {
    private static let recordLimit = 256

    private let lock = NSLock()
    private var records: [TouchEvent] = []
    private var discardedRecords = 0

    func record(_ events: [InputCore.InputEvent]) {
        lock.lock()
        defer { lock.unlock() }
        for event in events {
            guard case .touch(let touch) = event else {
                continue
            }
            if records.count == Self.recordLimit {
                records.removeFirst()
                discardedRecords += 1
            }
            records.append(touch)
        }
    }

    func snapshot() -> InputTouchEventHistory {
        lock.lock()
        defer { lock.unlock() }
        return InputTouchEventHistory(records: records, discardedRecords: discardedRecords)
    }
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
    private let pointerDelivery: InputPointerDelivery
    private let display = DeveloperDisplay(pixelWidth: AndroidInputRun.width, pixelHeight: AndroidInputRun.height)
    private let route = DevInputRoute()
    private let stop = AsyncStream.makeStream(of: Void.self)
    private let bootLog = BootLog()
    private var frames: DisplayFrames?
    private var framesSeen = 0
    private var window: SessionWindowController?
    private var inputSink: WireSink?
    private var inputTraceRecorder: InputTraceRecorder?
    private var inputTouchEventRecorder: InputTouchEventRecorder?
    private var boot: Task<Void, Never>?

    private init(home: URL, adb: AdbClient, pointerDelivery: InputPointerDelivery) {
        self.home = home
        self.adb = adb
        self.pointerDelivery = pointerDelivery
    }

    /// Runs `body` on a boot with the window and input, after `apk` is installed and `package` is started on display 0.
    static func with(
        apk: URL,
        package: String,
        pointerDelivery: InputPointerDelivery = .directView,
        _ body: (AndroidInputRun) async throws -> Void
    ) async throws {
        if pointerDelivery == .windowServer, !CGPreflightPostEventAccess() {
            throw XCTSkip("WindowServer input needs Accessibility permission on the dedicated lab GUI session.")
        }
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
        do {
            _ = try await AndroidBootFixture(home: home, bundle: bundle)
        } catch {
            VMRunResources.removeHomeOrReport(home)
            throw error
        }
        let run = AndroidInputRun(
            home: home,
            adb: AdbClient(executable: adbExecutable),
            pointerDelivery: pointerDelivery
        )
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
        let (window, view) = try windowAndView()
        let size = view.bounds.size
        let mapper = DisplayGeometry.coordinateMapper(
            contentSize: size, in: size, pixelWidth: Self.width, pixelHeight: Self.height, generation: 1)
        return InputPointer(window: window, view: view, mapper: mapper, delivery: pointerDelivery)
    }

    /// Activates the display window before the test posts system mouse events.
    func prepareForWindowServerPointerDispatch() async throws {
        guard pointerDelivery == .windowServer else {
            throw AndroidInputRunFailure.windowNotActive
        }
        guard NSScreen.screens.count == 1 else {
            throw AndroidInputRunFailure.ambiguousDisplay
        }
        let (window, view) = try windowAndView()
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if NSApplication.shared.isActive, window.isKeyWindow {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AndroidInputRunFailure.windowNotActive
    }

    /// Waits until the window sink has routed all previously received view events.
    func drainInput() async throws {
        guard let inputSink else {
            throw AndroidInputRunFailure.inputRouteUnbound
        }
        _ = await inputSink.drain()
    }

    /// The route counters after all previously received view events have been routed.
    func inputCounters() async throws -> InputCounters {
        try await drainInput()
        return await route.counters()
    }

    /// Wire-encoded touch phases after all previously received view events have been routed.
    func inputWireTouchPhaseCounts() async throws -> InputWireTouchPhaseCounts {
        guard let inputSink else {
            throw AndroidInputRunFailure.inputRouteUnbound
        }
        return await inputSink.drain()
    }

    /// Enables bounded guest ACK capture for an explicitly opted-in diagnostic run.
    func startAcknowledgementHistoryCapture() async throws -> InputCounters {
        guard inputSink != nil else {
            throw AndroidInputRunFailure.inputRouteUnbound
        }
        try await drainInput()
        guard let counters = await route.startAcknowledgementHistoryCapture() else {
            throw AndroidInputRunFailure.inputRouteUnbound
        }
        return counters
    }

    /// Captures translated touch coordinates and sent events without changing normal batching or ACK cadence.
    func startTouchEventCapture() async throws -> InputCounters {
        guard let inputSink, inputTouchEventRecorder == nil else {
            throw AndroidInputRunFailure.inputRouteUnbound
        }
        try await drainInput()
        guard
            let counters = await route.startAcknowledgementHistoryCapture(
                captureSentEventHistory: true
            )
        else {
            throw AndroidInputRunFailure.inputRouteUnbound
        }
        let recorder = InputTouchEventRecorder()
        inputTouchEventRecorder = recorder
        inputSink.setTouchEventRecorder(recorder)
        return counters
    }

    /// A drained snapshot of touch translations, successfully sent events, and route counters.
    func touchEventCaptureSnapshot() async throws -> InputTouchCaptureSnapshot {
        guard let recorder = inputTouchEventRecorder else {
            throw AndroidInputRunFailure.inputRouteUnbound
        }
        try await drainInput()
        return InputTouchCaptureSnapshot(
            touches: recorder.snapshot(),
            sentEvents: await route.sentEventHistory(),
            acknowledgements: nil,
            counters: await route.counters()
        )
    }

    /// Returns the periodic ACK at the next 32-batch boundary at or after the latest sent batch.
    ///
    /// The ACK is a route-progress marker. Its rejection count applies only to its own batch.
    func acknowledgeLatestInput(
        with pointer: InputPointer,
        at pixel: InputPixel
    ) async throws -> InputAcknowledgementHistory.Record {
        guard inputTouchEventRecorder != nil else {
            throw AndroidInputRunFailure.inputRouteUnbound
        }
        var snapshot = try await touchEventCaptureSnapshot()
        guard let lastSentSequence = snapshot.sentEvents.records.last?.batchSequence else {
            throw AndroidInputRunFailure.timedOut("a routed input batch to acknowledge")
        }
        let acknowledgementSequence = ((lastSentSequence - 1) / 32 + 1) * 32
        let deadline = ContinuousClock.now + .seconds(10)
        var latestSentSequence = lastSentSequence
        while latestSentSequence < acknowledgementSequence {
            guard ContinuousClock.now < deadline else {
                throw AndroidInputRunFailure.timedOut(
                    "normal periodic input ACK \(acknowledgementSequence); latest sent sequence \(latestSentSequence)")
            }
            try await pointer.advancePeriodicAcknowledgement(at: pixel)
            snapshot = try await touchEventCaptureSnapshot()
            guard snapshot.sentEvents.discardedRecords == 0 else {
                throw AndroidInputRunFailure.timedOut("bounded input event history overflowed")
            }
            guard let sentSequence = snapshot.sentEvents.records.last?.batchSequence else {
                throw AndroidInputRunFailure.timedOut("a routed input batch to acknowledge")
            }
            latestSentSequence = sentSequence
        }
        let history = try await waitForAcknowledgement(through: acknowledgementSequence)
        guard let acknowledgement = history.records.first(where: { $0.batchSequence == acknowledgementSequence }) else {
            throw AndroidInputRunFailure.timedOut("input ACK \(acknowledgementSequence)")
        }
        return acknowledgement
    }

    /// Stops touch capture after draining and returns the final guest ACK and route evidence.
    func stopTouchEventCapture() async throws -> InputTouchCaptureSnapshot {
        guard let recorder = inputTouchEventRecorder else {
            throw AndroidInputRunFailure.inputRouteUnbound
        }
        try await drainInput()
        let acknowledgements = await route.stopAcknowledgementHistoryCapture()
        let snapshot = InputTouchCaptureSnapshot(
            touches: recorder.snapshot(),
            sentEvents: await route.sentEventHistory(),
            acknowledgements: acknowledgements,
            counters: await route.counters()
        )
        inputSink?.setTouchEventRecorder(nil)
        inputTouchEventRecorder = nil
        return snapshot
    }

    /// The bounded history of guest ACKs after all previously received view events have been routed.
    func acknowledgementHistory() async throws -> InputAcknowledgementHistory {
        try await drainInput()
        return await route.acknowledgementHistory()
    }

    /// Starts the opt-in per-event trace after checking that this guest can return its event-time bridge.
    func startPerEventInputTraceCapture() async throws -> InputCounters {
        guard let inputSink, inputTraceRecorder == nil else {
            throw AndroidInputRunFailure.inputRouteUnbound
        }
        try await drainInput()
        guard await route.supportsAcknowledgementEventTimeTrace() else {
            throw AndroidInputRunFailure.inputAckTraceNotNegotiated
        }
        guard
            let counters = await route.startAcknowledgementHistoryCapture(
                everyBatch: true, captureSentEventHistory: true
            )
        else {
            throw AndroidInputRunFailure.inputRouteUnbound
        }

        let recorder = InputTraceRecorder()
        inputTraceRecorder = recorder
        inputSink.setTraceRecorder(recorder)
        let (_, view) = try windowAndView()
        view.inputEventReceiptObserver = { [weak recorder] eventType, hostTimeNanos in
            recorder?.recordRawReceipt(eventType: eventType, hostTimeNanos: hostTimeNanos)
        }
        return counters
    }

    /// Stops the per-event capture after the ordered sink drains, and returns every bounded trace layer.
    func stopPerEventInputTraceCapture() async throws -> (
        host: InputTraceHostSnapshot,
        routed: InputSentEventHistory,
        acknowledgements: InputAcknowledgementHistory,
        counters: InputCounters,
        missingAcknowledgementSequences: [UInt64]
    ) {
        guard let recorder = inputTraceRecorder else {
            throw AndroidInputRunFailure.inputRouteUnbound
        }
        try await drainInput()
        let missingAcknowledgementSequences = await waitForPerEventAcknowledgements()
        let acknowledgements = await route.stopAcknowledgementHistoryCapture()
        let routed = await route.sentEventHistory()
        let counters = await route.counters()
        let host = recorder.snapshot()
        clearInputTraceCapture()
        return (host, routed, acknowledgements, counters, missingAcknowledgementSequences)
    }

    /// Waits for the ACK that covers `batchSequence`, and returns the complete bounded ACK history.
    func waitForAcknowledgement(through batchSequence: UInt64) async throws -> InputAcknowledgementHistory {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            let history = try await acknowledgementHistory()
            if history.discardedRecords > 0 {
                throw AndroidInputRunFailure.timedOut(
                    "ACK history overflowed before sequence \(batchSequence)")
            }
            if history.records.contains(where: { $0.batchSequence == batchSequence }) {
                return history
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let history = try await acknowledgementHistory()
        throw AndroidInputRunFailure.timedOut(
            "input ACK \(batchSequence); received \(history.records.map(\.batchSequence))")
    }

    /// Keeps ACK capture open until every sent trace batch is acknowledged, or the diagnostic deadline expires.
    ///
    /// An incomplete result is returned rather than thrown so the caller can attach the partial trace as test evidence.
    private func waitForPerEventAcknowledgements() async -> [UInt64] {
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            let sent = await route.sentEventHistory()
            let acknowledgements = await route.acknowledgementHistory()
            let expected = Set(sent.records.map(\.batchSequence))
            let received = Set(acknowledgements.records.map(\.batchSequence))
            let missing = expected.subtracting(received).sorted()
            if missing.isEmpty || sent.discardedRecords > 0 || acknowledgements.discardedRecords > 0 {
                return missing
            }
            guard ContinuousClock.now < deadline else {
                return missing
            }
            do {
                try await Task.sleep(for: min(.milliseconds(25), deadline - .now))
            } catch {
                return missing
            }
        }
    }

    /// The keyboard of the window: the same view, which takes the key events as AppKit delivers them (#025).
    func keyboard() throws -> InputKeyboard {
        let (window, view) = try windowAndView()
        return InputKeyboard(window: window, view: view)
    }

    private func windowAndView() throws -> (NSWindow, IOSurfaceLayerView) {
        let window = try XCTUnwrap(NSApplication.shared.windows.first { $0.title == Self.windowTitle })
        let view = try XCTUnwrap(surfaceLayerView(in: window.contentView))
        return (window, view)
    }

    private func surfaceLayerView(in view: NSView?) -> IOSurfaceLayerView? {
        guard let view else {
            return nil
        }
        if let layerView = view as? IOSurfaceLayerView {
            return layerView
        }
        for subview in view.subviews {
            if let layerView = surfaceLayerView(in: subview) {
                return layerView
            }
        }
        return nil
    }

    /// The uiautomator dump of the screen, read with no input. A dump that fails gives an empty string.
    func uiDump() async throws -> String {
        let path = "/data/local/tmp/apkrun-025-dump.xml"
        return (try? await adb.shell("uiautomator dump \(path) > /dev/null; cat \(path); rm -f \(path)").output) ?? ""
    }

    /// Whether the node `resourceID` has focus in a uiautomator dump, or nil when the dump has no such node. The element is
    /// cut at its `<node` and its `>`, whatever the order of its attributes.
    static func isFocused(_ resourceID: String, in xml: String) -> Bool? {
        guard let id = xml.range(of: "resource-id=\"\(resourceID)\"") else {
            return nil
        }
        let start = xml[..<id.lowerBound].range(of: "<node", options: .backwards)?.lowerBound ?? xml.startIndex
        let end = xml[id.upperBound...].firstIndex(of: ">") ?? xml.endIndex
        return xml[start..<end].contains("focused=\"true\"")
    }

    /// The centre of the view `resourceID` in display pixels, from a `uiautomator dump` (retried while the screen is
    /// busy, as scripts/dev/validate-input-coordinates.sh does).
    func centre(of resourceID: String) async throws -> InputPixel {
        let path = "/data/local/tmp/apkrun-024-input.xml"
        var lastXML = ""
        for _ in 0..<15 {
            let xml =
                (try? await adb.shell("uiautomator dump \(path) > /dev/null; cat \(path); rm -f \(path)").output) ?? ""
            lastXML = xml
            if let bounds = Self.bounds(of: resourceID, in: xml) {
                return ((bounds[0] + bounds[2]) / 2, (bounds[1] + bounds[3]) / 2)
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw AndroidInputRunFailure.viewNotFound("\(resourceID); the last dump shows \(Self.packages(in: lastXML))")
    }

    /// Polls the uiautomator dump, for 30 s, until a node has the text `text`. It throws `viewNotFound` with the packages of
    /// the last dump otherwise, so a launch that shows another screen is named.
    func waitForText(_ text: String) async throws {
        var xml = ""
        for _ in 0..<30 {
            xml = try await uiDump()
            if xml.contains("text=\"\(text)\"") {
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw AndroidInputRunFailure.viewNotFound("text \(text); the last dump shows \(Self.packages(in: xml))")
    }

    /// The packages of the nodes of a uiautomator dump, so that a failure names the screen that the dump saw.
    static func packages(in xml: String) -> String {
        let names = xml.components(separatedBy: "package=\"").dropFirst().compactMap {
            $0.components(separatedBy: "\"").first
        }
        let unique = Set(names).sorted()
        return unique.isEmpty ? "no nodes in the dump" : unique.joined(separator: ", ")
    }

    /// The fixture's log lines, polled every 500 ms until `enough` holds or `timeout` has passed.
    func fixtureLog(until enough: ([String]) -> Bool, timeout: Duration = .seconds(30)) async throws -> [String] {
        let deadline = ContinuousClock.now + timeout
        var lines: [String] = []
        while ContinuousClock.now < deadline {
            let output = try await adb.shell("logcat -d -s APKRUN-FIXTURE").output
            lines = output.split(separator: "\n").map(String.init)
            if enough(lines) {
                return lines
            }
            try await Task.sleep(for: min(.milliseconds(500), deadline - .now))
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
        clearInputTraceCapture()
        _ = await route.stopAcknowledgementHistoryCapture()
        window?.close()
        stop.continuation.yield(())
        await boot?.value
        VMRunResources.removeHomeOrReport(home)
    }

    private func clearInputTraceCapture() {
        if let view = NSApplication.shared.windows
            .first(where: { $0.title == Self.windowTitle })
            .flatMap({ surfaceLayerView(in: $0.contentView) })
        {
            view.inputEventReceiptObserver = nil
        }
        inputSink?.setTraceRecorder(nil)
        inputSink?.setTouchEventRecorder(nil)
        inputTraceRecorder = nil
        inputTouchEventRecorder = nil
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
            if case .catalogWarning(let error) = event {
                bootLog.append("\(error.qualifiedCode): \(error.cause?.qualifiedCode ?? "no Guest Agent")")
            }
        }
        boot = Task.detached {
            do {
                try await DevBoot().run(
                    options: options, environment: ["APKRUN_HOME": home.path], stopRequests: stops, onEvent: report)
            } catch {
                bootLog.append("failed: \(error)")
            }
            bootLog.end()
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
            let sink = WireSink(route: route)
            let window = SessionWindowController(
                source: source, title: Self.windowTitle, backingScale: scale, inputSink: sink)
            window.show()
            frames = source
            self.window = window
            inputSink = sink
        case .frameReady(let generation, let bufferIndex, let sequence):
            framesSeen += 1
            frames?.ingest(generation: generation, bufferIndex: bufferIndex, sequence: sequence)
        }
    }

    /// Starts the launcher activity of `package` by its component name, as AndroidPackageTests does (#017), and waits until
    /// its process runs. monkey starts nothing on this image (IR-1286). A launch that starts no process throws with the
    /// resumed activity and the fatal lines of the guest log, so the first failure names the cause.
    private func launch(_ package: String) async throws {
        try await adb.startActivity(component: "\(package)/.MainActivity")
        for _ in 0..<30 {
            if try await adb.pidof(package) != nil {
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        let resumed = (try? await adb.shell("dumpsys activity activities | grep -m3 -i resumed").output) ?? ""
        let fatal = (try? await adb.shell("logcat -d '*:F' | tail -3").output) ?? ""
        throw AndroidInputRunFailure.appDidNotStart(
            "\(package) has no process; resumed: \(resumed.trimmingCharacters(in: .whitespacesAndNewlines)); "
                + "fatal: \(fatal.trimmingCharacters(in: .whitespacesAndNewlines))")
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
        // The lock screen covers the app on this image: the dump of the first failing case showed only SystemUI (IR-1285). The
        // G3 gate wakes the screen and dismisses the keyguard the same way (G3GraphicsTests). These run before the sequence.
        _ = try await adb.shell("input keyevent 82")
        _ = try await adb.shell("wm dismiss-keyguard")
        try await launch(package)
    }

    /// Polls `condition` every 200 ms until it holds. It throws when `seconds` have passed.
    private func waitUntil(seconds: Double, _ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            // A boot that has ended (a graphics failure, for example) cannot reach the condition, so stop waiting.
            if bootLog.hasEnded {
                throw AndroidInputRunFailure.bootEnded("\(what) (boot: \(bootLog.recent))")
            }
            guard ContinuousClock.now < deadline else {
                throw AndroidInputRunFailure.timedOut("\(what) (boot: \(bootLog.recent))")
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }
}

/// Delivers pointer events either directly to the view or through the WindowServer.
@MainActor
struct InputPointer {
    let window: NSWindow
    let view: IOSurfaceLayerView
    let mapper: CoordinateMapper
    let delivery: InputPointerDelivery

    func click(at pixel: InputPixel, interClickGap: Duration = .zero) async throws {
        try deliver(.leftMouseDown, at: pixel)
        var released = false
        defer {
            if !released {
                try? deliver(.leftMouseUp, at: pixel)
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        try deliver(.leftMouseUp, at: pixel)
        released = true
        if interClickGap > .zero {
            try await Task.sleep(for: interClickGap)
        }
    }

    func rightClick(at pixel: InputPixel) async throws {
        try deliver(.rightMouseDown, at: pixel)
        var released = false
        defer {
            if !released {
                try? deliver(.rightMouseUp, at: pixel)
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        try deliver(.rightMouseUp, at: pixel)
        released = true
    }

    /// A left-button drag: down at `start`, `steps` moves along the straight path, and up at `end`.
    func drag(from start: InputPixel, to end: InputPixel, steps: Int) async throws {
        try deliver(.leftMouseDown, at: start)
        var released = false
        defer {
            if !released {
                try? deliver(.leftMouseUp, at: end)
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            try deliver(.leftMouseDragged, at: (start.x + (end.x - start.x) * t, start.y + (end.y - start.y) * t))
            try await Task.sleep(for: .milliseconds(20))
        }
        try deliver(.leftMouseUp, at: end)
        released = true
    }

    /// Drags to a point outside the view, using direct view dispatch to check clamping on the Android guest.
    func drag(from start: InputPixel, toViewPoint end: NSPoint, steps: Int) async throws {
        let startPoint = windowPoint(start)
        try deliver(.leftMouseDown, atViewPoint: startPoint)
        var released = false
        defer {
            if !released {
                try? deliver(.leftMouseUp, atViewPoint: end)
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        for step in 1...steps {
            let progress = Double(step) / Double(steps)
            let point = NSPoint(
                x: startPoint.x + (end.x - startPoint.x) * progress,
                y: startPoint.y + (end.y - startPoint.y) * progress
            )
            try deliver(.leftMouseDragged, atViewPoint: point)
            try await Task.sleep(for: .milliseconds(20))
        }
        try deliver(.leftMouseUp, atViewPoint: end)
        released = true
    }

    /// Adds one normal pointer move so tests can reach the protocol's periodic ACK without changing its cadence.
    func advancePeriodicAcknowledgement(at pixel: InputPixel) async throws {
        guard delivery == .directView else {
            throw AndroidInputRunFailure.periodicAcknowledgementRequiresDirectView
        }
        try deliver(.mouseMoved, at: pixel)
        try await Task.sleep(for: .milliseconds(20))
    }

    /// A scroll of `deltaY` at `pixel`: points for a trackpad (`precise`), lines for a wheel. The CGEvent is made as the
    /// event tap delivers it, and AppKit makes the NSEvent that the view reads.
    func scroll(at pixel: InputPixel, deltaY: Int32, precise: Bool) {
        let location = view.convert(windowPoint(pixel), to: nil)
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
        // NSEvent(cgEvent:) reports the location as a global AppKit point, without a window (IR-1288), and the view reads
        // `locationInWindow` as a window point. So the CG point is the window point, flipped to CoreGraphics's top-left
        // origin, and AppKit reads it back as the window point. The event is not posted anywhere.
        cg.location = CGPoint(x: location.x, y: (NSScreen.screens.first?.frame.height ?? 0) - location.y)
        if let event = NSEvent(cgEvent: cg) {
            view.scrollWheel(with: event)
        }
    }

    private func deliver(_ type: NSEvent.EventType, at pixel: InputPixel) throws {
        try deliver(type, atViewPoint: windowPoint(pixel))
    }

    private func deliver(_ type: NSEvent.EventType, atViewPoint point: NSPoint) throws {
        let location = view.convert(point, to: nil)
        if delivery == .windowServer {
            try postThroughWindowServer(type, at: window.convertPoint(toScreen: location))
            return
        }
        guard
            let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else {
            throw AndroidInputRunFailure.cannotCreateSystemEvent
        }
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        case .mouseMoved: view.mouseMoved(with: event)
        case .rightMouseDown: view.rightMouseDown(with: event)
        case .rightMouseUp: view.rightMouseUp(with: event)
        default: break
        }
    }

    /// Posts a real system mouse event so WindowServer and AppKit select the target window and view.
    private func postThroughWindowServer(_ type: NSEvent.EventType, at screenLocation: NSPoint) throws {
        let isRelease = type == .leftMouseUp || type == .rightMouseUp
        if !isRelease, !(NSApplication.shared.isActive && window.isKeyWindow) {
            throw AndroidInputRunFailure.windowNotActive
        }
        guard let screen = window.screen,
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            throw AndroidInputRunFailure.ambiguousDisplay
        }
        let displayBounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        let screenFrame = screen.frame
        let quartzLocation = CGPoint(
            x: displayBounds.minX + screenLocation.x - screenFrame.minX,
            y: displayBounds.minY + screenFrame.maxY - screenLocation.y
        )
        let mouseType: CGEventType
        let button: CGMouseButton
        switch type {
        case .leftMouseDown:
            mouseType = .leftMouseDown
            button = .left
        case .leftMouseDragged:
            mouseType = .leftMouseDragged
            button = .left
        case .leftMouseUp:
            mouseType = .leftMouseUp
            button = .left
        case .rightMouseDown:
            mouseType = .rightMouseDown
            button = .right
        case .rightMouseDragged:
            mouseType = .rightMouseDragged
            button = .right
        case .rightMouseUp:
            mouseType = .rightMouseUp
            button = .right
        default:
            throw AndroidInputRunFailure.cannotCreateSystemEvent
        }
        guard
            let event = CGEvent(
                mouseEventSource: nil,
                mouseType: mouseType,
                mouseCursorPosition: quartzLocation,
                mouseButton: button
            )
        else {
            throw AndroidInputRunFailure.cannotCreateSystemEvent
        }
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.setDoubleValueField(.mouseEventPressure, value: mouseType == .leftMouseUp ? 0 : 1)
        event.post(tap: .cghidEventTap)
    }

    /// The window point of a display pixel: the inverse of the window's mapping.
    private func windowPoint(_ pixel: InputPixel) -> NSPoint {
        let point = mapper.windowPoint(forPixel: InputCore.DisplayPoint(x: pixel.x, y: pixel.y))
        return NSPoint(x: point.x, y: point.y)
    }

    /// The view point of a display pixel, for tests that deliberately leave the content rectangle.
    func viewPoint(for pixel: InputPixel) -> NSPoint {
        windowPoint(pixel)
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

/// Counts of test-window touch phases after wire conversion and before route dispatch.
struct InputWireTouchPhaseCounts: Equatable, Sendable, CustomStringConvertible {
    private(set) var down: Int
    private(set) var move: Int
    private(set) var up: Int
    private(set) var cancel: Int
    private(set) var cancelAll: Int

    init(down: Int = 0, move: Int = 0, up: Int = 0, cancel: Int = 0, cancelAll: Int = 0) {
        self.down = down
        self.move = move
        self.up = up
        self.cancel = cancel
        self.cancelAll = cancelAll
    }

    mutating func record(_ events: [RuntimeAPI.WireInputEvent]) {
        for event in events {
            switch event {
            case .touch(let touch):
                switch touch.phase {
                case .down:
                    down += 1
                case .move:
                    move += 1
                case .up:
                    up += 1
                case .cancel:
                    cancel += 1
                }
            case .cancelAll:
                cancelAll += 1
            default:
                break
            }
        }
    }

    func delta(since earlier: Self) -> Self {
        Self(
            down: down - earlier.down,
            move: move - earlier.move,
            up: up - earlier.up,
            cancel: cancel - earlier.cancel,
            cancelAll: cancelAll - earlier.cancelAll
        )
    }

    var description: String {
        "down=\(down) move=\(move) up=\(up) touchCancel=\(cancel) cancelAll=\(cancelAll)"
    }
}

/// The window's events, routed in order (the CLI's `EmbeddedInputSink`, decision D10). One task converts each queued
/// list to the wire types of runtime-api.md §7.2 and routes it, so no batch overtakes another.
private final class WireSink: PointerInputSink, @unchecked Sendable {
    private enum Command: Sendable {
        case events([InputCore.InputEvent])
        case drained(CheckedContinuation<InputWireTouchPhaseCounts, Never>)
    }

    private let queue: AsyncStream<Command>.Continuation
    // `IOSurfaceLayerView` calls `deliver` on the main thread, and the test changes this only on MainActor before input.
    private var traceRecorder: InputTraceRecorder?
    private var touchEventRecorder: InputTouchEventRecorder?

    init(route: DevInputRoute) {
        // Unbounded: a dropped press or release would leave a gesture open on the guest.
        let made = AsyncStream.makeStream(of: Command.self, bufferingPolicy: .unbounded)
        queue = made.continuation
        Task {
            var touchPhaseCounts = InputWireTouchPhaseCounts()
            for await command in made.stream {
                switch command {
                case .events(let events):
                    // A list longer than the route takes in one batch is cut, as `EmbeddedInputSink` cuts it.
                    for start in stride(from: 0, to: events.count, by: DevInputRoute.maximumEventsPerBatch) {
                        let end = min(start + DevInputRoute.maximumEventsPerBatch, events.count)
                        let wireEvents = events[start..<end].compactMap(WireSink.wire)
                        touchPhaseCounts.record(wireEvents)
                        await route.send(RuntimeAPI.InputBatch(events: wireEvents))
                    }
                case .drained(let continuation):
                    continuation.resume(returning: touchPhaseCounts)
                }
            }
        }
    }

    func deliver(_ events: [InputCore.InputEvent]) {
        traceRecorder?.recordTranslated(events)
        touchEventRecorder?.record(events)
        queue.yield(.events(events))
    }

    func setTraceRecorder(_ recorder: InputTraceRecorder?) {
        traceRecorder = recorder
    }

    func setTouchEventRecorder(_ recorder: InputTouchEventRecorder?) {
        touchEventRecorder = recorder
    }

    /// Completes after every earlier event list has finished routing.
    func drain() async -> InputWireTouchPhaseCounts {
        await withCheckedContinuation { continuation in
            queue.yield(.drained(continuation))
        }
    }

    /// The wire form of `event`. A long press is not sent (decision D6), and the key events are converted as the CLI's
    /// `EmbeddedInputSink` converts them (#025).
    static func wire(_ event: InputCore.InputEvent) -> RuntimeAPI.WireInputEvent? {
        switch event {
        case .key(let key):
            return .key(
                .init(
                    action: keyAction(key.action), androidKeyCode: key.androidKeyCode,
                    metaState: key.metaState.rawValue, repeatCount: key.repeatCount, time: time(key.time)))
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

    private static func keyAction(_ action: InputCore.KeyEvent.Action) -> RuntimeAPI.KeyAction {
        switch action {
        case .down: .down
        case .up: .up
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
    private var ended = false

    func append(_ line: String) {
        lock.withLock { lines.append(line) }
    }

    func contains(_ line: String) -> Bool {
        lock.withLock { lines.contains(line) }
    }

    /// Records that the boot task has returned, whether it stopped or failed.
    func end() {
        lock.withLock { ended = true }
    }

    var hasEnded: Bool {
        lock.withLock { ended }
    }

    var recent: String {
        lock.withLock { lines.suffix(3).joined(separator: "; ") }
    }
}
