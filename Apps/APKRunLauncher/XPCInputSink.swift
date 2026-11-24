import InputCore
import RuntimeAPI
import RuntimeClient
import WindowingCore

/// Converts WindowingCore input samples to RuntimeAPI wire batches for one XPC session.
final class XPCInputSink: PointerInputSink, @unchecked Sendable {
    private static let maximumEventsPerBatch = 512
    private let session: RuntimeSessionClient
    private let inputPrefs: RuntimeAPI.InputPrefs

    init(session: RuntimeSessionClient, inputPrefs: RuntimeAPI.InputPrefs) {
        self.session = session
        self.inputPrefs = inputPrefs
    }

    func deliver(_ events: [InputCore.InputEvent]) {
        for batch in Self.batches(events, inputPrefs: inputPrefs) {
            session.sendInput(batch)
        }
    }

    func focusChanged(_ focused: Bool) {
        session.focusChanged(focused)
    }

    private static func batches(
        _ events: [InputCore.InputEvent],
        inputPrefs: RuntimeAPI.InputPrefs
    ) -> [RuntimeAPI.InputBatch] {
        let wireEvents = events.compactMap { wire($0, inputPrefs: inputPrefs) }
        return stride(from: 0, to: wireEvents.count, by: maximumEventsPerBatch).map { start in
            let end = min(start + maximumEventsPerBatch, wireEvents.count)
            return RuntimeAPI.InputBatch(events: Array(wireEvents[start..<end]))
        }
    }

    private static func wire(
        _ event: InputCore.InputEvent,
        inputPrefs: RuntimeAPI.InputPrefs
    ) -> RuntimeAPI.WireInputEvent? {
        switch event {
        case .touch(let touch):
            return .touch(
                RuntimeAPI.WireTouchEvent(
                    phase: touchPhase(touch.phase),
                    pointerID: touch.pointerID,
                    position: wirePoint(touch.position),
                    time: wireTime(touch.time)
                )
            )
        case .mouse(let mouse):
            switch mouse.action {
            case .hoverEnter, .hoverMove, .hoverExit:
                guard inputPrefs.hover else { return nil }
            case .press(.secondary) where inputPrefs.secondaryClick == .longPress:
                return .longPress(wirePoint(mouse.position), wireTime(mouse.time))
            case .release(.secondary) where inputPrefs.secondaryClick == .longPress:
                return nil
            default:
                break
            }
            return .mouse(
                RuntimeAPI.WireMouseEvent(
                    action: mouseAction(mouse.action),
                    position: wirePoint(mouse.position),
                    buttons: mouse.buttons.rawValue,
                    time: wireTime(mouse.time)
                )
            )
        case .scroll(let scroll):
            return .scroll(
                RuntimeAPI.WireScrollEvent(
                    position: wirePoint(scroll.position),
                    vertical: scroll.vertical,
                    horizontal: scroll.horizontal,
                    time: wireTime(scroll.time)
                )
            )
        case .key(let key):
            return .key(
                RuntimeAPI.WireKeyEvent(
                    action: keyAction(key.action),
                    androidKeyCode: key.androidKeyCode,
                    metaState: key.metaState.rawValue,
                    repeatCount: key.repeatCount,
                    time: wireTime(key.time)
                )
            )
        case .longPress(let position, let time):
            return .longPress(wirePoint(position), wireTime(time))
        case .cancelAll(let time):
            return .cancelAll(wireTime(time))
        }
    }

    private static func touchPhase(_ phase: InputCore.TouchEvent.Phase) -> RuntimeAPI.TouchPhase {
        switch phase {
        case .down: .down
        case .move: .move
        case .up: .up
        case .cancel: .cancel
        }
    }

    private static func mouseAction(_ action: InputCore.MouseEvent.Action) -> RuntimeAPI.MouseAction {
        switch action {
        case .hoverEnter: .hoverEnter
        case .hoverMove: .hoverMove
        case .hoverExit: .hoverExit
        case .press(let button): .press(mouseButton(button))
        case .release(let button): .release(mouseButton(button))
        }
    }

    private static func mouseButton(_ button: InputCore.MouseButton) -> RuntimeAPI.MouseButton {
        switch button {
        case .primary: .primary
        case .secondary: .secondary
        case .tertiary: .tertiary
        case .back: .back
        case .forward: .forward
        }
    }

    private static func keyAction(_ action: InputCore.KeyEvent.Action) -> RuntimeAPI.KeyAction {
        switch action {
        case .down: .down
        case .up: .up
        }
    }

    private static func wireTime(_ time: InputCore.InputTimestamp) -> RuntimeAPI.InputTimestamp {
        RuntimeAPI.InputTimestamp(hostNanos: time.hostNanos)
    }

    private static func wirePoint(_ point: InputCore.DisplayPoint) -> RuntimeAPI.DisplayPoint {
        RuntimeAPI.DisplayPoint(x: point.x, y: point.y)
    }
}
