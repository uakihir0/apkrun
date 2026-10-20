#if APKRUN_EMBEDDED_RUNTIME
    import Foundation
    import InputCore
    import RuntimeAPI
    import RuntimeHost
    import WindowingCore

    /// Sends the pointer events of the development window to the embedded runtime (#25, decision D10).
    ///
    /// The window delivers its events on the main thread. The sink queues each list, and one task sends the lists to the
    /// route in the order they were delivered, so a batch never overtakes an earlier one. The events are converted to the
    /// wire types of runtime-api.md §7.2 here, and RuntimeHost converts them back before `InputRouter`. The conversion
    /// tables of the two sides are the same, and `EmbeddedInputSinkTests` and `DevInputRouteTests` check both.
    final class EmbeddedInputSink: PointerInputSink {
        private enum Event: Sendable {
            case input([InputCore.InputEvent])
            case focusChanged(Bool, generation: UInt64)
        }

        private let queue: AsyncStream<Event>.Continuation
        private let focusGeneration = InputFocusGeneration.shared

        /// Creates a sink that sends to `route`. The task that sends runs for the life of the process.
        init(route: DevInputRoute) {
            // Unbounded: a dropped press or release would leave a gesture open on the guest.
            let (stream, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
            queue = continuation
            Task {
                for await event in stream {
                    switch event {
                    case .input(let events):
                        for batch in EmbeddedInputSink.batches(events) {
                            await route.send(batch)
                        }
                    case .focusChanged(let focused, let generation):
                        await route.focusChanged(focused, generation: generation)
                    }
                }
            }
        }

        func deliver(_ events: [InputCore.InputEvent]) {
            queue.yield(.input(events))
        }

        func focusChanged(_ focused: Bool) {
            queue.yield(.focusChanged(focused, generation: focusGeneration.next()))
        }

        /// The wire batches of `events`, in order. A list longer than the route accepts in one batch is cut into
        /// batches of the route's size, so that no event is dropped on the way.
        static func batches(_ events: [InputCore.InputEvent]) -> [RuntimeAPI.InputBatch] {
            stride(from: 0, to: events.count, by: DevInputRoute.maximumEventsPerBatch).map { start in
                let end = min(start + DevInputRoute.maximumEventsPerBatch, events.count)
                return RuntimeAPI.InputBatch(events: events[start..<end].map(wire))
            }
        }

        /// One event in the wire types (runtime-api.md §7.2). The inverse of `WireInputConversion` in RuntimeHost.
        static func wire(_ event: InputCore.InputEvent) -> RuntimeAPI.WireInputEvent {
            switch event {
            case .touch(let touch):
                return .touch(
                    RuntimeAPI.WireTouchEvent(
                        phase: touchPhase(touch.phase),
                        pointerID: touch.pointerID,
                        position: wirePoint(touch.position),
                        time: wireTime(touch.time)))
            case .mouse(let mouse):
                return .mouse(
                    RuntimeAPI.WireMouseEvent(
                        action: mouseAction(mouse.action),
                        position: wirePoint(mouse.position),
                        buttons: mouse.buttons.rawValue,
                        time: wireTime(mouse.time)))
            case .scroll(let scroll):
                return .scroll(
                    RuntimeAPI.WireScrollEvent(
                        position: wirePoint(scroll.position),
                        vertical: scroll.vertical,
                        horizontal: scroll.horizontal,
                        time: wireTime(scroll.time)))
            case .key(let key):
                return .key(
                    RuntimeAPI.WireKeyEvent(
                        action: keyAction(key.action),
                        androidKeyCode: key.androidKeyCode,
                        metaState: key.metaState.rawValue,
                        repeatCount: key.repeatCount,
                        time: wireTime(key.time)))
            case .longPress(let position, let time):
                return .longPress(wirePoint(position), wireTime(time))
            case .cancelAll(let time):
                return .cancelAll(wireTime(time))
            }
        }

        static func touchPhase(_ phase: InputCore.TouchEvent.Phase) -> RuntimeAPI.TouchPhase {
            switch phase {
            case .down: .down
            case .move: .move
            case .up: .up
            case .cancel: .cancel
            }
        }

        static func mouseAction(_ action: InputCore.MouseEvent.Action) -> RuntimeAPI.MouseAction {
            switch action {
            case .hoverEnter: .hoverEnter
            case .hoverMove: .hoverMove
            case .hoverExit: .hoverExit
            case .press(let button): .press(mouseButton(button))
            case .release(let button): .release(mouseButton(button))
            }
        }

        static func mouseButton(_ button: InputCore.MouseButton) -> RuntimeAPI.MouseButton {
            switch button {
            case .primary: .primary
            case .secondary: .secondary
            case .tertiary: .tertiary
            case .back: .back
            case .forward: .forward
            }
        }

        static func keyAction(_ action: InputCore.KeyEvent.Action) -> RuntimeAPI.KeyAction {
            switch action {
            case .down: .down
            case .up: .up
            }
        }

        static func wireTime(_ time: InputCore.InputTimestamp) -> RuntimeAPI.InputTimestamp {
            RuntimeAPI.InputTimestamp(hostNanos: time.hostNanos)
        }

        static func wirePoint(_ point: InputCore.DisplayPoint) -> RuntimeAPI.DisplayPoint {
            RuntimeAPI.DisplayPoint(x: point.x, y: point.y)
        }
    }

    /// Assigns one process-wide order to native focus notifications from all app windows.
    private final class InputFocusGeneration: @unchecked Sendable {
        static let shared = InputFocusGeneration()

        private let lock = NSLock()
        private var value: UInt64 = 0

        func next() -> UInt64 {
            lock.withLock {
                value &+= 1
                return value
            }
        }
    }
#endif
