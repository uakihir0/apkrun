import AppKit
import Testing

@testable import WindowingCore

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
