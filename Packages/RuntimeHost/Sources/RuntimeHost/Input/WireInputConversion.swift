import InputCore
import RuntimeAPI

/// The conversion of the input wire types (runtime-api.md §7.2) to InputCore values, before `InputRouter` (decision
/// D10). The wire types share the names `InputTimestamp`, `DisplayPoint`, and `MouseButton` with InputCore, so every
/// name in this file is qualified with its module.
enum WireInputConversion {
    /// The events of a batch, converted in order.
    static func events(_ wire: [RuntimeAPI.WireInputEvent]) -> [InputCore.InputEvent] {
        wire.map(event)
    }

    /// One event, converted.
    static func event(_ wire: RuntimeAPI.WireInputEvent) -> InputCore.InputEvent {
        switch wire {
        case .touch(let touch):
            return .touch(touchEvent(touch))
        case .mouse(let mouse):
            return .mouse(mouseEvent(mouse))
        case .scroll(let scroll):
            return .scroll(
                InputCore.ScrollEvent(
                    position: point(scroll.position),
                    vertical: scroll.vertical,
                    horizontal: scroll.horizontal,
                    time: timestamp(scroll.time)))
        case .key(let key):
            return .key(keyEvent(key))
        case .longPress(let position, let time):
            return .longPress(point(position), timestamp(time))
        case .cancelAll(let time):
            return .cancelAll(timestamp(time))
        }
    }

    static func touchEvent(_ wire: RuntimeAPI.WireTouchEvent) -> InputCore.TouchEvent {
        InputCore.TouchEvent(
            phase: phase(wire.phase),
            pointerID: wire.pointerID,
            position: point(wire.position),
            time: timestamp(wire.time))
    }

    static func mouseEvent(_ wire: RuntimeAPI.WireMouseEvent) -> InputCore.MouseEvent {
        InputCore.MouseEvent(
            action: mouseAction(wire.action),
            position: point(wire.position),
            buttons: InputCore.MouseButtons(rawValue: wire.buttons),
            time: timestamp(wire.time))
    }

    static func keyEvent(_ wire: RuntimeAPI.WireKeyEvent) -> InputCore.KeyEvent {
        InputCore.KeyEvent(
            action: keyAction(wire.action),
            androidKeyCode: wire.androidKeyCode,
            metaState: InputCore.AndroidMetaState(rawValue: wire.metaState),
            repeatCount: wire.repeatCount,
            time: timestamp(wire.time))
    }

    static func phase(_ wire: RuntimeAPI.TouchPhase) -> InputCore.TouchEvent.Phase {
        switch wire {
        case .down: .down
        case .move: .move
        case .up: .up
        case .cancel: .cancel
        }
    }

    static func mouseAction(_ wire: RuntimeAPI.MouseAction) -> InputCore.MouseEvent.Action {
        switch wire {
        case .hoverEnter: .hoverEnter
        case .hoverMove: .hoverMove
        case .hoverExit: .hoverExit
        case .press(let button): .press(mouseButton(button))
        case .release(let button): .release(mouseButton(button))
        }
    }

    static func mouseButton(_ wire: RuntimeAPI.MouseButton) -> InputCore.MouseButton {
        switch wire {
        case .primary: .primary
        case .secondary: .secondary
        case .tertiary: .tertiary
        case .back: .back
        case .forward: .forward
        }
    }

    static func keyAction(_ wire: RuntimeAPI.KeyAction) -> InputCore.KeyEvent.Action {
        switch wire {
        case .down: .down
        case .up: .up
        }
    }

    static func timestamp(_ wire: RuntimeAPI.InputTimestamp) -> InputCore.InputTimestamp {
        InputCore.InputTimestamp(hostNanos: wire.hostNanos)
    }

    static func point(_ wire: RuntimeAPI.DisplayPoint) -> InputCore.DisplayPoint {
        InputCore.DisplayPoint(x: wire.x, y: wire.y)
    }
}
