#if APKRUN_EMBEDDED_RUNTIME
    import Foundation
    import InputCore
    import RuntimeAPI
    import Testing

    @testable import apkrun

    // The conversion of the development window's events to the wire types (runtime-api.md §7.2, #25). RuntimeHost
    // converts the wire types back, and DevInputRouteTests use the same pairs, so the two tables are checked together.

    private let coreTime = InputCore.InputTimestamp(hostNanos: 77)
    private let corePoint = InputCore.DisplayPoint(x: 12.5, y: 3)
    private let wireTime = RuntimeAPI.InputTimestamp(hostNanos: 77)
    private let wirePoint = RuntimeAPI.DisplayPoint(x: 12.5, y: 3)

    @Test func everyInputCoreCaseConvertsToItsWireValue() {
        #expect(
            EmbeddedInputSink.wire(
                .touch(InputCore.TouchEvent(phase: .move, pointerID: 0, position: corePoint, time: coreTime)))
                == .touch(
                    RuntimeAPI.WireTouchEvent(phase: .move, pointerID: 0, position: wirePoint, time: wireTime)))
        #expect(
            EmbeddedInputSink.wire(
                .mouse(
                    InputCore.MouseEvent(
                        action: .hoverExit, position: corePoint, buttons: [], time: coreTime)))
                == .mouse(
                    RuntimeAPI.WireMouseEvent(action: .hoverExit, position: wirePoint, buttons: 0, time: wireTime)))
        #expect(
            EmbeddedInputSink.wire(
                .scroll(
                    InputCore.ScrollEvent(position: corePoint, vertical: -1.5, horizontal: 0.25, time: coreTime)))
                == .scroll(
                    RuntimeAPI.WireScrollEvent(
                        position: wirePoint, vertical: -1.5, horizontal: 0.25, time: wireTime)))
        #expect(
            EmbeddedInputSink.wire(
                .key(
                    InputCore.KeyEvent(
                        action: .up, androidKeyCode: 66, metaState: .ctrlOn, repeatCount: 2, time: coreTime)))
                == .key(
                    RuntimeAPI.WireKeyEvent(
                        action: .up, androidKeyCode: 66, metaState: 0x1000, repeatCount: 2, time: wireTime)))
        #expect(
            EmbeddedInputSink.wire(.longPress(corePoint, coreTime))
                == .longPress(wirePoint, wireTime))
        #expect(EmbeddedInputSink.wire(.cancelAll(coreTime)) == .cancelAll(wireTime))
    }

    @Test func everyTouchPhaseAndMouseActionConverts() {
        #expect(EmbeddedInputSink.touchPhase(.down) == .down)
        #expect(EmbeddedInputSink.touchPhase(.move) == .move)
        #expect(EmbeddedInputSink.touchPhase(.up) == .up)
        #expect(EmbeddedInputSink.touchPhase(.cancel) == .cancel)
        #expect(EmbeddedInputSink.mouseAction(.hoverEnter) == .hoverEnter)
        #expect(EmbeddedInputSink.mouseAction(.hoverMove) == .hoverMove)
        #expect(EmbeddedInputSink.mouseAction(.hoverExit) == .hoverExit)
        #expect(EmbeddedInputSink.mouseAction(.press(.secondary)) == .press(.secondary))
        #expect(EmbeddedInputSink.mouseAction(.release(.primary)) == .release(.primary))
        #expect(EmbeddedInputSink.mouseButton(.primary) == .primary)
        #expect(EmbeddedInputSink.mouseButton(.secondary) == .secondary)
        #expect(EmbeddedInputSink.mouseButton(.tertiary) == .tertiary)
        #expect(EmbeddedInputSink.mouseButton(.back) == .back)
        #expect(EmbeddedInputSink.mouseButton(.forward) == .forward)
        #expect(EmbeddedInputSink.keyAction(.down) == .down)
        #expect(EmbeddedInputSink.keyAction(.up) == .up)
    }

    @Test func aLongListIsCutInOrderAtTheRoutesBatchSize() {
        let events = (0..<600).map { index in
            InputCore.InputEvent.touch(
                InputCore.TouchEvent(
                    phase: .move, pointerID: 0,
                    position: InputCore.DisplayPoint(x: Double(index), y: 0), time: coreTime))
        }
        let batches = EmbeddedInputSink.batches(events)
        #expect(batches.map { $0.events.count } == [512, 88])
        let xs = batches.flatMap(\.events).map { event -> Double in
            if case .touch(let touch) = event {
                return touch.position.x
            }
            return -1
        }
        #expect(xs == (0..<600).map(Double.init))
    }

    @Test func anEmptyListGivesNoBatch() {
        #expect(EmbeddedInputSink.batches([]).isEmpty)
    }
#endif
