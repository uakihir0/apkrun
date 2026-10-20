import AppKit
import InputCore
import Testing

@testable import WindowingCore

// The adapter of input.md §5.2 (#26): NSEvent key events become KeySamples, and the side of each modifier comes from the
// device-dependent bits of NSEvent.modifierFlags.

/// The generic and device bits of the modifier flags that the tests build.
private enum Flags {
    static let shiftGeneric: UInt = 0x0002_0000
    static let shiftLeft: UInt = 0x0000_0002
    static let shiftRight: UInt = 0x0000_0004
    static let commandGeneric: UInt = 0x0010_0000
    static let commandLeft: UInt = 0x0000_0008
    static let optionGeneric: UInt = 0x0008_0000
    static let optionLeft: UInt = 0x0000_0020
    static let controlRight: UInt = 0x0000_2000
    static let capsLock: UInt = 0x0001_0000
}

private func keyEvent(_ type: NSEvent.EventType, code: UInt16, flags: UInt = 0, repeats: Bool = false) -> NSEvent {
    NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: flags), timestamp: 1.5,
        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: repeats,
        keyCode: code)!
}

@Test func aKeyDownCarriesTheCodeAndTheTimeInNanoseconds() {
    let sample = KeyEventAdapter.sample(for: keyEvent(.keyDown, code: 0x00))
    #expect(sample == KeySample(kind: .down, virtualKeyCode: 0x00, time: InputTimestamp(hostNanos: 1_500_000_000)))
}

@Test func aRepeatedKeyDownIsMarkedAsARepeat() {
    let sample = KeyEventAdapter.sample(for: keyEvent(.keyDown, code: 0x00, repeats: true))
    #expect(sample?.isRepeat == true)
    #expect(sample?.kind == .down)
}

@Test func aKeyUpIsAnUp() {
    #expect(KeyEventAdapter.sample(for: keyEvent(.keyUp, code: 0x08))?.kind == .up)
}

@Test func theLeftShiftGoesDownWithItsSide() {
    let down = KeyEventAdapter.sample(
        for: keyEvent(.flagsChanged, code: 0x38, flags: Flags.shiftGeneric | Flags.shiftLeft))
    #expect(down?.kind == .modifierChanged(pressed: true))
    #expect(down?.modifiers == [.shiftLeft])
    let up = KeyEventAdapter.sample(for: keyEvent(.flagsChanged, code: 0x38, flags: 0))
    #expect(up?.kind == .modifierChanged(pressed: false))
    #expect(up?.modifiers == [])
}

@Test func aReleaseOfOneShiftKeepsTheOtherOne() {
    // The left shift goes up while the right one is still down.
    let sample = KeyEventAdapter.sample(
        for: keyEvent(.flagsChanged, code: 0x38, flags: Flags.shiftGeneric | Flags.shiftRight))
    #expect(sample?.kind == .modifierChanged(pressed: false))
    #expect(sample?.modifiers == [.shiftRight])
}

@Test func theRightShiftIsItsOwnSide() {
    let sample = KeyEventAdapter.sample(
        for: keyEvent(.flagsChanged, code: 0x3C, flags: Flags.shiftGeneric | Flags.shiftRight))
    #expect(sample?.kind == .modifierChanged(pressed: true))
    #expect(sample?.modifiers == [.shiftRight])
}

@Test func aGenericFlagWithoutASideCountsAsTheLeftKey() {
    let sample = KeyEventAdapter.sample(for: keyEvent(.flagsChanged, code: 0x38, flags: Flags.shiftGeneric))
    #expect(sample?.kind == .modifierChanged(pressed: true))
    #expect(sample?.modifiers == [.shiftLeft])
}

@Test func theRightControlAndTheLeftOptionAreSided() {
    let control = KeyEventAdapter.sample(
        for: keyEvent(.flagsChanged, code: 0x3E, flags: 0x0004_0000 | Flags.controlRight))
    #expect(control?.kind == .modifierChanged(pressed: true))
    #expect(control?.modifiers == [.controlRight])
    let option = KeyEventAdapter.sample(
        for: keyEvent(.flagsChanged, code: 0x3A, flags: Flags.optionGeneric | Flags.optionLeft))
    #expect(option?.kind == .modifierChanged(pressed: true))
    #expect(option?.modifiers == [.optionLeft])
}

@Test func theLeftCommandIsCommandWhileItIsDown() {
    let down = KeyEventAdapter.sample(
        for: keyEvent(.flagsChanged, code: 0x37, flags: Flags.commandGeneric | Flags.commandLeft))
    #expect(down?.kind == .modifierChanged(pressed: true))
    #expect(down?.modifiers == [.command])
    let up = KeyEventAdapter.sample(for: keyEvent(.flagsChanged, code: 0x37, flags: 0))
    #expect(up?.kind == .modifierChanged(pressed: false))
    #expect(up?.modifiers == [])
}

@Test func capsLockIsOnWhileItsFlagIsSet() {
    let on = KeyEventAdapter.sample(for: keyEvent(.flagsChanged, code: 0x39, flags: Flags.capsLock))
    #expect(on?.kind == .modifierChanged(pressed: true))
    #expect(on?.modifiers == [.capsLock])
    let off = KeyEventAdapter.sample(for: keyEvent(.flagsChanged, code: 0x39, flags: 0))
    #expect(off?.kind == .modifierChanged(pressed: false))
}

@Test func aCommandShortcutKeyDownCarriesCommand() {
    let sample = KeyEventAdapter.sample(
        for: keyEvent(.keyDown, code: 0x08, flags: Flags.commandGeneric | Flags.commandLeft))
    #expect(sample?.modifiers == [.command])
    #expect(sample.map(KeyTranslator.forwardsCommandShortcut) == true)
}

@Test func aFunctionKeyChangeIsNotUsed() {
    #expect(KeyEventAdapter.sample(for: keyEvent(.flagsChanged, code: 0x3F, flags: 0x0080_0000)) == nil)
}

@Test func aMouseEventIsNotAKeyEvent() {
    let mouse = NSEvent.mouseEvent(
        with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        eventNumber: 0, clickCount: 0, pressure: 0)!
    #expect(KeyEventAdapter.sample(for: mouse) == nil)
}
