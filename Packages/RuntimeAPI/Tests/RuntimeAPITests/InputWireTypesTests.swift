import Foundation
import Testing

@testable import RuntimeAPI

/// The Codable round trips of the input wire types (runtime-api.md §7.2, §4.2).

private func roundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(Value.self, from: data)
}

private func jsonObject(_ value: some Encodable) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private let time = InputTimestamp(hostNanos: 9_007_199_254_740_993)
private let point = DisplayPoint(x: 1_080.5, y: -0.25)

@Test func everyCaseOfWireInputEventRoundTrips() throws {
    let events: [WireInputEvent] = [
        .touch(WireTouchEvent(phase: .down, pointerID: 0, position: point, time: time)),
        .touch(WireTouchEvent(phase: .move, pointerID: 0, position: point, time: time)),
        .touch(WireTouchEvent(phase: .up, pointerID: 0, position: point, time: time)),
        .touch(WireTouchEvent(phase: .cancel, pointerID: 0, position: point, time: time)),
        .mouse(WireMouseEvent(action: .hoverEnter, position: point, buttons: 0, time: time)),
        .mouse(WireMouseEvent(action: .hoverMove, position: point, buttons: 0, time: time)),
        .mouse(WireMouseEvent(action: .hoverExit, position: point, buttons: 0, time: time)),
        .mouse(WireMouseEvent(action: .press(.primary), position: point, buttons: 1, time: time)),
        .mouse(WireMouseEvent(action: .press(.secondary), position: point, buttons: 2, time: time)),
        .mouse(WireMouseEvent(action: .press(.tertiary), position: point, buttons: 4, time: time)),
        .mouse(WireMouseEvent(action: .press(.back), position: point, buttons: 8, time: time)),
        .mouse(WireMouseEvent(action: .press(.forward), position: point, buttons: 16, time: time)),
        .mouse(WireMouseEvent(action: .release(.secondary), position: point, buttons: 0, time: time)),
        .scroll(WireScrollEvent(position: point, vertical: -1.5, horizontal: 0.25, time: time)),
        .key(WireKeyEvent(action: .down, androidKeyCode: 66, metaState: 0x1, repeatCount: 0, time: time)),
        .key(WireKeyEvent(action: .up, androidKeyCode: 66, metaState: 0, repeatCount: 2, time: time)),
        .longPress(point, time),
        .cancelAll(time),
    ]
    for event in events {
        #expect(try roundTrip(event) == event)
    }
    let batch = InputBatch(events: events)
    #expect(try roundTrip(batch) == batch)
}

@Test func everyCaseOfWireImeTextEventRoundTrips() throws {
    let events: [WireImeTextEvent] = [
        .commit("日本語"),
        .setComposing("にほん", selection: TextRange(start: 0, end: 3)),
        .finishComposing,
        .key(WireKeyEvent(action: .down, androidKeyCode: 67, metaState: 0, repeatCount: 0, time: time)),
        .editorAction(6),
        .contextMenuAction(.copy),
        .contextMenuAction(.cut),
        .contextMenuAction(.paste),
        .contextMenuAction(.selectAll),
    ]
    for event in events {
        #expect(try roundTrip(event) == event)
    }
}

@Test func everyMouseActionAndButtonRoundTrips() throws {
    let buttons: [MouseButton] = [.primary, .secondary, .tertiary, .back, .forward]
    for button in buttons {
        #expect(try roundTrip(button) == button)
        #expect(try roundTrip(MouseAction.press(button)) == .press(button))
        #expect(try roundTrip(MouseAction.release(button)) == .release(button))
    }
    let plain: [MouseAction] = [.hoverEnter, .hoverMove, .hoverExit]
    for action in plain {
        #expect(try roundTrip(action) == action)
    }
}

@Test func rawValueEnumsEncodeTheCaseNames() throws {
    #expect(try JSONEncoder().encode(TouchPhase.move) == Data("\"move\"".utf8))
    #expect(try JSONEncoder().encode(MouseButton.secondary) == Data("\"secondary\"".utf8))
    #expect(try JSONEncoder().encode(KeyAction.up) == Data("\"up\"".utf8))
    #expect(try JSONEncoder().encode(ContextMenuAction.selectAll) == Data("\"selectAll\"".utf8))
    for phase in [TouchPhase.down, .move, .up, .cancel] {
        #expect(try roundTrip(phase) == phase)
    }
    for action in [KeyAction.down, .up] {
        #expect(try roundTrip(action) == action)
    }
    for action in [ContextMenuAction.copy, .cut, .paste, .selectAll] {
        #expect(try roundTrip(action) == action)
    }
}

@Test func payloadCasesUseTheSynthesizedShape() throws {
    // A case with a payload is one key, the case name (runtime-api.md §4.2).
    let touch = try jsonObject(
        WireInputEvent.touch(WireTouchEvent(phase: .down, pointerID: 0, position: point, time: time)))
    #expect(Set(touch.keys) == ["touch"])

    // A case without payload is an empty object, and an unlabeled payload is `_0`.
    let hover = try jsonObject(MouseAction.hoverEnter)
    #expect(Set(hover.keys) == ["hoverEnter"])
    #expect((hover["hoverEnter"] as? [String: Any])?.isEmpty == true)
    let press = try jsonObject(MouseAction.press(.primary))
    let payload = try #require(press["press"] as? [String: Any])
    #expect(payload["_0"] as? String == "primary")
}

@Test func timestampsKeepTheirFullPrecision() throws {
    // mach continuous time is above 2^53 on a long-running host, so it must not pass through a Double.
    #expect(try roundTrip(time).hostNanos == 9_007_199_254_740_993)
}
