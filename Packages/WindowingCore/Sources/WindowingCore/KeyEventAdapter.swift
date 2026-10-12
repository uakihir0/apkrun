import AppKit
import InputCore

/// Converts AppKit key events into `KeySample`s (input.md §5.2, #025, decision D1).
///
/// This is the only place that reads the key events of `NSEvent`. A modifier key's side comes from the device-dependent
/// bits of `NSEvent.modifierFlags`. When a side is unknown and no side bit is set, the generic flag stands for the key.
/// The adapter returns nil for the events that key mode does not use.
public enum KeyEventAdapter {
    /// Returns the sample of `event`, or nil when key mode does not use the event.
    public static func sample(for event: NSEvent) -> KeySample? {
        let time = PointerEventAdapter.timestamp(seconds: event.timestamp)
        let code = event.keyCode
        switch event.type {
        case .keyDown:
            return KeySample(
                kind: .down, virtualKeyCode: code, modifiers: modifiers(of: event.modifierFlags),
                isRepeat: event.isARepeat, time: time)
        case .keyUp:
            return KeySample(kind: .up, virtualKeyCode: code, modifiers: modifiers(of: event.modifierFlags), time: time)
        case .flagsChanged:
            guard let pressed = modifierKeyIsDown(code, event.modifierFlags) else {
                return nil
            }
            return KeySample(
                kind: .modifierChanged(pressed: pressed), virtualKeyCode: code,
                modifiers: modifiers(of: event.modifierFlags), time: time)
        default:
            return nil
        }
    }

    /// The modifier keys that are down, with the side of each (`NX_DEVICE*KEYMASK` bits in `IOLLEvent.h`).
    static func modifiers(of flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var result: KeyModifiers = []
        if isDown(flags, generic: .shift, side: DeviceBits.leftShift, otherSide: DeviceBits.rightShift, isLeft: true) {
            result.insert(.shiftLeft)
        }
        if isDown(flags, generic: .shift, side: DeviceBits.rightShift, otherSide: DeviceBits.leftShift, isLeft: false) {
            result.insert(.shiftRight)
        }
        if isDown(
            flags, generic: .control, side: DeviceBits.leftControl, otherSide: DeviceBits.rightControl, isLeft: true)
        {
            result.insert(.controlLeft)
        }
        if isDown(
            flags, generic: .control, side: DeviceBits.rightControl, otherSide: DeviceBits.leftControl, isLeft: false)
        {
            result.insert(.controlRight)
        }
        if isDown(flags, generic: .option, side: DeviceBits.leftOption, otherSide: DeviceBits.rightOption, isLeft: true)
        {
            result.insert(.optionLeft)
        }
        if isDown(
            flags, generic: .option, side: DeviceBits.rightOption, otherSide: DeviceBits.leftOption, isLeft: false)
        {
            result.insert(.optionRight)
        }
        if flags.contains(.command) {
            result.insert(.command)
        }
        if flags.contains(.capsLock) {
            result.insert(.capsLock)
        }
        return result
    }

    /// Whether the modifier key with `code` is down after a `flagsChanged`, or nil when `code` is not a modifier that key
    /// mode uses. Caps Lock is on while its lock flag is set.
    static func modifierKeyIsDown(_ code: UInt16, _ flags: NSEvent.ModifierFlags) -> Bool? {
        switch code {
        case MacVirtualKey.shift:
            isDown(flags, generic: .shift, side: DeviceBits.leftShift, otherSide: DeviceBits.rightShift, isLeft: true)
        case MacVirtualKey.rightShift:
            isDown(flags, generic: .shift, side: DeviceBits.rightShift, otherSide: DeviceBits.leftShift, isLeft: false)
        case MacVirtualKey.control:
            isDown(
                flags, generic: .control, side: DeviceBits.leftControl, otherSide: DeviceBits.rightControl, isLeft: true
            )
        case MacVirtualKey.rightControl:
            isDown(
                flags, generic: .control, side: DeviceBits.rightControl, otherSide: DeviceBits.leftControl,
                isLeft: false)
        case MacVirtualKey.option:
            isDown(
                flags, generic: .option, side: DeviceBits.leftOption, otherSide: DeviceBits.rightOption, isLeft: true)
        case MacVirtualKey.rightOption:
            isDown(
                flags, generic: .option, side: DeviceBits.rightOption, otherSide: DeviceBits.leftOption, isLeft: false)
        case MacVirtualKey.command:
            isDown(
                flags, generic: .command, side: DeviceBits.leftCommand, otherSide: DeviceBits.rightCommand, isLeft: true
            )
        case MacVirtualKey.rightCommand:
            isDown(
                flags, generic: .command, side: DeviceBits.rightCommand, otherSide: DeviceBits.leftCommand,
                isLeft: false)
        case MacVirtualKey.capsLock:
            flags.contains(.capsLock)
        default:
            nil
        }
    }

    /// Whether the key of `side` is down. Its side bit decides. The left side also counts the generic flag when neither
    /// side has a bit, because some events carry no side bits, and the generic flag of another key does not count
    /// for this one. The right side never falls back to the generic flag, so the one fallback names the left key.
    private static func isDown(
        _ flags: NSEvent.ModifierFlags, generic: NSEvent.ModifierFlags, side: UInt, otherSide: UInt, isLeft: Bool
    ) -> Bool {
        let bits = flags.rawValue
        if bits & side != 0 {
            return true
        }
        return isLeft && bits & otherSide == 0 && flags.contains(generic)
    }

    /// The device-dependent modifier bits of `NSEvent.ModifierFlags`.
    private enum DeviceBits {
        static let leftControl: UInt = 0x0000_0001
        static let leftShift: UInt = 0x0000_0002
        static let rightShift: UInt = 0x0000_0004
        static let leftCommand: UInt = 0x0000_0008
        static let rightCommand: UInt = 0x0000_0010
        static let leftOption: UInt = 0x0000_0020
        static let rightOption: UInt = 0x0000_0040
        static let rightControl: UInt = 0x0000_2000
    }
}
