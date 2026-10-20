import Testing

@testable import InputCore

// Key mode (input.md §5.2, §6; #26): the key codes, the meta state, the repeat count, the shortcuts, and the rule that
// every release matches its press.

private let time = InputTimestamp(hostNanos: 1_000)

private func down(_ code: UInt16, _ modifiers: KeyModifiers = [], repeat isRepeat: Bool = false) -> KeySample {
    KeySample(kind: .down, virtualKeyCode: code, modifiers: modifiers, isRepeat: isRepeat, time: time)
}

private func up(_ code: UInt16, _ modifiers: KeyModifiers = []) -> KeySample {
    KeySample(kind: .up, virtualKeyCode: code, modifiers: modifiers, time: time)
}

private func changed(_ code: UInt16, pressed: Bool, _ modifiers: KeyModifiers) -> KeySample {
    KeySample(kind: .modifierChanged(pressed: pressed), virtualKeyCode: code, modifiers: modifiers, time: time)
}

private func keyDown(_ code: Int32, _ meta: AndroidMetaState = [], repeat count: Int32 = 0) -> InputEvent {
    .key(KeyEvent(action: .down, androidKeyCode: code, metaState: meta, repeatCount: count, time: time))
}

private func keyUp(_ code: Int32, _ meta: AndroidMetaState = []) -> InputEvent {
    .key(KeyEvent(action: .up, androidKeyCode: code, metaState: meta, repeatCount: 0, time: time))
}

private let shiftLeftState: AndroidMetaState = [.shiftOn, .shiftLeftOn]
private let ctrlLeftState: AndroidMetaState = [.ctrlOn, .ctrlLeftOn]

@Test func aPlainKeyGoesDownAndUpWithoutMetaState() {
    var translator = KeyTranslator()
    #expect(translator.translate(down(MacVirtualKey.a)) == [keyDown(29)])
    #expect(translator.translate(up(MacVirtualKey.a)) == [keyUp(29)])
}

@Test func shiftAndALetterCarryTheShiftMetaStateOfTheSide() {
    var translator = KeyTranslator()
    #expect(
        translator.translate(changed(MacVirtualKey.shift, pressed: true, [.shiftLeft])) == [keyDown(59, shiftLeftState)]
    )
    #expect(translator.translate(down(MacVirtualKey.a, [.shiftLeft])) == [keyDown(29, shiftLeftState)])
    #expect(translator.translate(up(MacVirtualKey.a, [.shiftLeft])) == [keyUp(29, shiftLeftState)])
    #expect(translator.translate(changed(MacVirtualKey.shift, pressed: false, [])) == [keyUp(59)])
}

@Test func theRightShiftIsSentAsSHIFTRIGHTWithItsOwnBit() {
    var translator = KeyTranslator()
    let state: AndroidMetaState = [.shiftOn, .shiftRightOn]
    #expect(
        translator.translate(changed(MacVirtualKey.rightShift, pressed: true, [.shiftRight])) == [keyDown(60, state)])
    #expect(translator.translate(changed(MacVirtualKey.rightShift, pressed: false, [])) == [keyUp(60)])
}

@Test func aHeldKeySendsRepeatsWithTheCountAndNoUpBetweenThem() {
    var translator = KeyTranslator()
    #expect(translator.translate(down(MacVirtualKey.a)) == [keyDown(29)])
    #expect(translator.translate(down(MacVirtualKey.a, repeat: true)) == [keyDown(29, repeat: 1)])
    #expect(translator.translate(down(MacVirtualKey.a, repeat: true)) == [keyDown(29, repeat: 2)])
    #expect(translator.translate(up(MacVirtualKey.a)) == [keyUp(29)])
}

@Test func aRepeatWithoutAPressStartsAtRepeatZero() {
    // The window became key while the key was held, so the first event the translator sees is a repeat.
    var translator = KeyTranslator()
    #expect(translator.translate(down(MacVirtualKey.a, repeat: true)) == [keyDown(29)])
    #expect(translator.translate(up(MacVirtualKey.a)) == [keyUp(29)])
}

@Test func controlPassesThroughWithTheControlMetaState() {
    var translator = KeyTranslator()
    #expect(
        translator.translate(changed(MacVirtualKey.control, pressed: true, [.controlLeft])) == [
            keyDown(113, ctrlLeftState)
        ])
    #expect(translator.translate(down(MacVirtualKey.c, [.controlLeft])) == [keyDown(31, ctrlLeftState)])
    #expect(translator.translate(up(MacVirtualKey.c, [.controlLeft])) == [keyUp(31, ctrlLeftState)])
    #expect(translator.translate(changed(MacVirtualKey.control, pressed: false, [])) == [keyUp(113)])
}

@Test func optionIsTheAltMetaStateOfItsSide() {
    var translator = KeyTranslator()
    let state: AndroidMetaState = [.altOn, .altRightOn]
    #expect(translator.translate(down(0x0E, [.optionRight])) == [keyDown(33, state)])
    #expect(translator.translate(up(0x0E, [.optionRight])) == [keyUp(33, state)])
}

@Test func capsLockIsATapWithTheLockInTheMetaState() {
    var translator = KeyTranslator()
    let lockOn: AndroidMetaState = [.capsLockOn]
    #expect(
        translator.translate(changed(MacVirtualKey.capsLock, pressed: true, [.capsLock])) == [
            keyDown(115, lockOn), keyUp(115, lockOn),
        ])
    #expect(translator.translate(changed(MacVirtualKey.capsLock, pressed: false, [])) == [keyDown(115), keyUp(115)])
}

@Test func commandCIsAControlTapAndCommandReleaseSendsNothing() {
    // macOS sends no keyUp for C while Command is down, so the shortcut is a tap: DOWN and UP at once.
    var translator = KeyTranslator()
    #expect(translator.translate(changed(MacVirtualKey.command, pressed: true, [.command])) == [])
    #expect(
        translator.translate(down(MacVirtualKey.c, [.command])) == [
            keyDown(31, ctrlLeftState), keyUp(31, ctrlLeftState),
        ])
    #expect(translator.translate(changed(MacVirtualKey.command, pressed: false, [])) == [])
    // A later release of C, if one arrives, has no press to end.
    #expect(translator.translate(up(MacVirtualKey.c)) == [])
}

@Test func theOtherShortcutLettersAreControlTaps() {
    var translator = KeyTranslator()
    #expect(
        translator.translate(down(MacVirtualKey.x, [.command])) == [
            keyDown(52, ctrlLeftState), keyUp(52, ctrlLeftState),
        ])
    #expect(
        translator.translate(down(MacVirtualKey.v, [.command])) == [
            keyDown(50, ctrlLeftState), keyUp(50, ctrlLeftState),
        ])
    #expect(
        translator.translate(down(MacVirtualKey.a, [.command])) == [
            keyDown(29, ctrlLeftState), keyUp(29, ctrlLeftState),
        ])
}

@Test func commandShiftZIsAControlShiftTap() {
    var translator = KeyTranslator()
    let state: AndroidMetaState = [.ctrlOn, .ctrlLeftOn, .shiftOn, .shiftLeftOn]
    #expect(
        translator.translate(down(MacVirtualKey.z, [.command, .shiftLeft])) == [keyDown(54, state), keyUp(54, state)])
}

@Test func commandLeftBracketIsABackTap() {
    var translator = KeyTranslator()
    #expect(translator.translate(down(MacVirtualKey.leftBracket, [.command])) == [keyDown(4), keyUp(4)])
}

@Test func commandDownEndsTheKeysThatAreHeld() {
    // The A is held when Command goes down. Its keyUp is not delivered while Command is down, so the UP is sent here.
    var translator = KeyTranslator()
    #expect(translator.translate(down(MacVirtualKey.a)) == [keyDown(29)])
    #expect(translator.translate(changed(MacVirtualKey.command, pressed: true, [.command])) == [keyUp(29)])
    #expect(translator.translate(up(MacVirtualKey.a)) == [])
}

@Test func commandDownKeepsTheModifiersThatAreHeld() {
    // Shift stays held: its release arrives as flagsChanged, so only the other keys end.
    var translator = KeyTranslator()
    #expect(
        translator.translate(changed(MacVirtualKey.shift, pressed: true, [.shiftLeft])) == [keyDown(59, shiftLeftState)]
    )
    #expect(translator.translate(down(MacVirtualKey.a, [.shiftLeft])) == [keyDown(29, shiftLeftState)])
    #expect(
        translator.translate(changed(MacVirtualKey.command, pressed: true, [.shiftLeft, .command]))
            == [keyUp(29, shiftLeftState)])
    #expect(translator.translate(changed(MacVirtualKey.shift, pressed: false, [.command])) == [keyUp(59)])
}

@Test func otherCommandCombinationsAreNotForwardedAndTheirReleasesAreDropped() {
    var translator = KeyTranslator()
    // ⌘Q, ⌘⇧[, and ⌘1 are not in key mode. Neither press nor release reaches the guest.
    #expect(translator.translate(down(0x0C, [.command])) == [])
    #expect(translator.translate(up(0x0C, [.command])) == [])
    #expect(translator.translate(down(MacVirtualKey.leftBracket, [.command, .shiftLeft])) == [])
    #expect(translator.translate(up(MacVirtualKey.leftBracket, [.command, .shiftLeft])) == [])
    #expect(translator.translate(down(0x12, [.command])) == [])
    #expect(translator.translate(up(0x12)) == [])
    #expect(translator.translate(changed(MacVirtualKey.command, pressed: false, [])) == [])
}

@Test func escapeIsBackAndCanBeEscape() {
    var back = KeyTranslator()
    #expect(back.translate(down(MacVirtualKey.escape)) == [keyDown(4)])
    #expect(back.translate(up(MacVirtualKey.escape)) == [keyUp(4)])

    var escape = KeyTranslator(escapeKey: .escape)
    #expect(escape.translate(down(MacVirtualKey.escape)) == [keyDown(111)])
    #expect(escape.translate(up(MacVirtualKey.escape)) == [keyUp(111)])
}

@Test func escapeWithCommandIsNotForwarded() {
    var translator = KeyTranslator()
    #expect(translator.translate(down(MacVirtualKey.escape, [.command])) == [])
}

@Test func editingKeysAndArrowsHaveTheirAndroidCodes() {
    var translator = KeyTranslator()
    #expect(translator.translate(down(0x24)) == [keyDown(66)])  // Return
    #expect(translator.translate(up(0x24)) == [keyUp(66)])
    #expect(translator.translate(down(0x33)) == [keyDown(67)])  // Delete
    #expect(translator.translate(up(0x33)) == [keyUp(67)])
    #expect(translator.translate(down(0x7B)) == [keyDown(21)])  // Left arrow
    #expect(translator.translate(up(0x7B)) == [keyUp(21)])
}

@Test func aKeyOutsideTheMapIsNotForwarded() {
    var translator = KeyTranslator()
    // Function (0x3F) is not in the map.
    #expect(translator.translate(down(0x3F)) == [])
    #expect(translator.translate(up(0x3F)) == [])
}

@Test func aReleaseWithoutAPressIsDropped() {
    var translator = KeyTranslator()
    #expect(translator.translate(up(MacVirtualKey.a)) == [])
}

@Test func resetForgetsTheKeysThatAreDown() {
    var translator = KeyTranslator()
    #expect(translator.translate(down(MacVirtualKey.a)) == [keyDown(29)])
    translator.reset()
    #expect(translator.translate(up(MacVirtualKey.a)) == [])
    #expect(translator.translate(down(MacVirtualKey.a)) == [keyDown(29)])
}

@Test func aModifierChangeThatRepeatsTheHeldStateIsNotANewPress() {
    var translator = KeyTranslator()
    #expect(
        translator.translate(changed(MacVirtualKey.shift, pressed: true, [.shiftLeft])) == [keyDown(59, shiftLeftState)]
    )
    #expect(translator.translate(changed(MacVirtualKey.shift, pressed: true, [.shiftLeft])) == [])
    #expect(translator.translate(changed(MacVirtualKey.shift, pressed: false, [])) == [keyUp(59)])
}

@Test func theMetaStateHasEachSideOfEachModifier() {
    let both = KeyTranslator.metaState([.shiftLeft, .shiftRight, .controlRight, .optionLeft, .capsLock], extra: [])
    #expect(both.contains([.shiftOn, .shiftLeftOn, .shiftRightOn]))
    #expect(both.contains([.ctrlOn, .ctrlRightOn]))
    #expect(!both.contains(.ctrlLeftOn))
    #expect(both.contains([.altOn, .altLeftOn]))
    #expect(!both.contains(.altRightOn))
    #expect(both.contains(.capsLockOn))
    #expect(KeyTranslator.metaState([.command], extra: []) == [], "Command adds no bit")
}

@Test func onlyTheForwardedCommandShortcutsAreReportedToTheMenus() {
    #expect(KeyTranslator.forwardsCommandShortcut(down(MacVirtualKey.c, [.command])))
    #expect(KeyTranslator.forwardsCommandShortcut(down(MacVirtualKey.z, [.command, .shiftLeft])))
    #expect(KeyTranslator.forwardsCommandShortcut(down(MacVirtualKey.leftBracket, [.command])))
    #expect(!KeyTranslator.forwardsCommandShortcut(down(MacVirtualKey.leftBracket, [.command, .shiftLeft])))
    #expect(!KeyTranslator.forwardsCommandShortcut(down(0x0C, [.command])))
    #expect(!KeyTranslator.forwardsCommandShortcut(down(MacVirtualKey.c)))
    #expect(!KeyTranslator.forwardsCommandShortcut(up(MacVirtualKey.c, [.command])))
}
