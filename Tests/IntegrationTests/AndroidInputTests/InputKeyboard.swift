import AppKit
import Foundation
import WindowingCore

/// A key of the US keyboard: its macOS virtual key code (`kVK_*`), and whether Shift is held to type it (#025, T2).
struct MacKey: Equatable, Sendable {
    let code: UInt16
    let shift: Bool

    static let tab = MacKey(code: 0x30, shift: false)
    static let returnKey = MacKey(code: 0x24, shift: false)
    static let escape = MacKey(code: 0x35, shift: false)
    static let delete = MacKey(code: 0x33, shift: false)
    static let leftArrow = MacKey(code: 0x7B, shift: false)
    static let rightArrow = MacKey(code: 0x7C, shift: false)
    static let leftBracket = MacKey(code: 0x21, shift: false)
    static let a = MacKey(code: 0x00, shift: false)
    static let c = MacKey(code: 0x08, shift: false)
    static let v = MacKey(code: 0x09, shift: false)
    static let x = MacKey(code: 0x07, shift: false)
    static let z = MacKey(code: 0x06, shift: false)

    /// The key that types `character` on the US layout, or nil for a character that the suite does not type.
    static func typing(_ character: Character) -> MacKey? {
        if let code = unshifted[character] {
            return MacKey(code: code, shift: false)
        }
        if let code = shifted[character] {
            return MacKey(code: code, shift: true)
        }
        if character.isUppercase, let code = unshifted[Character(character.lowercased())] {
            return MacKey(code: code, shift: true)
        }
        return nil
    }

    /// The keys of the US ANSI layout without Shift, by the character they type.
    private static let unshifted: [Character: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08,
        "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12,
        "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "9": 0x19, "7": 0x1A, "8": 0x1C, "0": 0x1D,
        "]": 0x1E, "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28,
        ",": 0x2B, "n": 0x2D, "m": 0x2E, ".": 0x2F, " ": 0x31,
    ]

    /// The keys that need Shift on the US layout, by the character they type.
    private static let shifted: [Character: UInt16] = ["!": 0x12]
}

enum InputKeyboardFailure: Error, Equatable {
    /// The suite has no key for this character, so it cannot type it.
    case unmappedCharacter(Character)
}

/// Posts AppKit key events into the window's content view, as AppKit delivers them (#025, T2). Shift and Command are
/// pressed and released as their own `flagsChanged` events, as a physical keyboard sends them. A ⌘ shortcut goes to
/// `performKeyEquivalent` first, and the other keys go to `keyDown` and `keyUp`.
@MainActor
struct InputKeyboard {
    static let shiftKeyCode: UInt16 = 0x38
    static let commandKeyCode: UInt16 = 0x37

    let window: NSWindow
    let view: IOSurfaceLayerView

    /// Types `text` one character at a time, with Shift held for the characters that need it.
    func type(_ text: String) async throws {
        for character in text {
            guard let key = MacKey.typing(character) else {
                throw InputKeyboardFailure.unmappedCharacter(character)
            }
            try await tap(key)
        }
    }

    /// A key down and up. Shift is held around the key when the key needs it.
    func tap(_ key: MacKey) async throws {
        let flags: NSEvent.ModifierFlags = key.shift ? .shift : []
        if key.shift {
            try await flagsChanged(Self.shiftKeyCode, flags)
        }
        try await send(.keyDown, key.code, flags)
        try await send(.keyUp, key.code, flags)
        if key.shift {
            try await flagsChanged(Self.shiftKeyCode, [])
        }
    }

    /// A ⌘ shortcut: Command goes down, the key goes to the window as AppKit sends it (a key equivalent first), and
    /// Command goes up. macOS sends no key up while Command is held, so none is sent (IR-1273).
    func commandShortcut(_ key: MacKey) async throws {
        try await flagsChanged(Self.commandKeyCode, .command)
        if let event = Self.event(.keyDown, key.code, .command, window: window), !view.performKeyEquivalent(with: event)
        {
            view.keyDown(with: event)
        }
        try await Task.sleep(for: .milliseconds(15))
        try await flagsChanged(Self.commandKeyCode, [])
    }

    /// A modifier key goes down (with its flag) or up (with no flag).
    private func flagsChanged(_ code: UInt16, _ flags: NSEvent.ModifierFlags) async throws {
        if let event = Self.event(.flagsChanged, code, flags, window: window) {
            view.flagsChanged(with: event)
        }
        try await Task.sleep(for: .milliseconds(15))
    }

    private func send(_ type: NSEvent.EventType, _ code: UInt16, _ flags: NSEvent.ModifierFlags) async throws {
        if let event = Self.event(type, code, flags, window: window) {
            switch type {
            case .keyDown: view.keyDown(with: event)
            case .keyUp: view.keyUp(with: event)
            default: break
            }
        }
        try await Task.sleep(for: .milliseconds(15))
    }

    private static func event(
        _ type: NSEvent.EventType, _ code: UInt16, _ flags: NSEvent.ModifierFlags, window: NSWindow
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: code)
    }
}
