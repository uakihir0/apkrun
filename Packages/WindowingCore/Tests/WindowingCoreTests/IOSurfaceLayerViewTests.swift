import AppKit
import InputCore
import Testing

@testable import WindowingCore

private final class RecordingInputSink: PointerInputSink, @unchecked Sendable {
    private(set) var events: [InputEvent] = []

    func deliver(_ events: [InputEvent]) {
        self.events.append(contentsOf: events)
    }
}

private func keyEvent(_ type: NSEvent.EventType, code: UInt16) -> NSEvent {
    NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: [], timestamp: 1.5,
        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
        keyCode: code)!
}

private func pointerEvent(_ type: NSEvent.EventType) -> NSEvent {
    NSEvent.mouseEvent(
        with: type, location: CGPoint(x: 50, y: 50), modifierFlags: [], timestamp: 1.5,
        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
}

@MainActor
@Test func rawPointerReceiptObserverReportsTheAppKitEventBeforeTranslation() throws {
    let view = IOSurfaceLayerView(
        frame: NSRect(x: 0, y: 0, width: 100, height: 100),
        contentSize: CGSize(width: 100, height: 100),
        contentScale: 1
    )
    var receipts: [(Int, UInt64)] = []
    view.inputEventReceiptObserver = { type, timestampNanos in
        receipts.append((type, timestampNanos))
    }
    let event = try #require(
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: CGPoint(x: 20, y: 30),
            modifierFlags: [],
            timestamp: 12.5,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    )

    view.mouseDown(with: event)

    #expect(receipts.count == 1)
    #expect(receipts.first?.0 == Int(NSEvent.EventType.leftMouseDown.rawValue))
    #expect(receipts.first?.1 == 12_500_000_000)
}

@MainActor
@Test func startupKeyEventsDoNotMutateTranslatorState() {
    let view = IOSurfaceLayerView(
        frame: NSRect(x: 0, y: 0, width: 100, height: 100),
        contentSize: CGSize(width: 100, height: 100),
        contentScale: 1
    )
    view.update(
        pixelWidth: 100,
        pixelHeight: 100,
        generation: 1,
        contentSize: CGSize(width: 100, height: 100),
        contentsScale: 1
    )
    let sink = RecordingInputSink()
    view.setInputEnabled(false)

    view.keyDown(with: keyEvent(.keyDown, code: 0x00))
    view.mouseDown(with: pointerEvent(.leftMouseDown))
    view.setInputEnabled(true)
    view.inputSink = sink
    view.keyUp(with: keyEvent(.keyUp, code: 0x00))
    view.mouseUp(with: pointerEvent(.leftMouseUp))

    #expect(sink.events.isEmpty)
}

@MainActor
@Test func disablingInputCancelsAnOpenPointerGestureAndHeldKey() {
    let view = IOSurfaceLayerView(
        frame: NSRect(x: 0, y: 0, width: 100, height: 100),
        contentSize: CGSize(width: 100, height: 100),
        contentScale: 1
    )
    view.update(
        pixelWidth: 100,
        pixelHeight: 100,
        generation: 1,
        contentSize: CGSize(width: 100, height: 100),
        contentsScale: 1
    )
    let sink = RecordingInputSink()
    view.inputSink = sink

    view.mouseDown(with: pointerEvent(.leftMouseDown))
    view.keyDown(with: keyEvent(.keyDown, code: 0x00))
    view.setInputEnabled(false)

    #expect(sink.events.count == 3)
    guard case .touch(let touch) = sink.events[0] else {
        Issue.record("Expected the pointer press before input was disabled.")
        return
    }
    #expect(touch.phase == .down)
    guard case .key(let key) = sink.events[1] else {
        Issue.record("Expected the key press before input was disabled.")
        return
    }
    #expect(key.action == .down)
    guard case .cancelAll = sink.events[2] else {
        Issue.record("Disabling input must cancel the guest's open pointer and key states.")
        return
    }

    view.setInputEnabled(true)
    view.keyUp(with: keyEvent(.keyUp, code: 0x00))
    view.mouseUp(with: pointerEvent(.leftMouseUp))
    #expect(sink.events.count == 3)
}
