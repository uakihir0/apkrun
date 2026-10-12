import Foundation
import Testing

@testable import InputCore

// The key map of input.md §5.2 (#025). The table is a literal, so these tests keep it equal to the CSV, and check every
// Android name and value against the API 37 list of `android.view.KeyEvent`.

/// The directory of the module's resources: `Packages/InputCore/Resources`, found from this file's path.
private let resourceDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // InputCoreTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // InputCore
    .appendingPathComponent("Resources")

/// The data rows of the CSV: the header and the `#` comments are skipped.
private func csvRows() throws -> [[String]] {
    let text = try String(
        contentsOf: resourceDirectory.appendingPathComponent("keymap-mac-android.csv"), encoding: .utf8)
    return text.split(separator: "\n", omittingEmptySubsequences: true)
        .map(String.init)
        .filter { !$0.hasPrefix("#") && !$0.hasPrefix("kvk_name,") }
        .map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
}

/// The API 37 constants, by name.
private func apiConstants() throws -> [String: Int32] {
    let text = try String(
        contentsOf: resourceDirectory.appendingPathComponent("android-api37-keycodes.txt"), encoding: .utf8)
    var values: [String: Int32] = [:]
    for line in text.split(separator: "\n") where !line.hasPrefix("#") {
        let parts = line.split(separator: " ")
        if parts.count == 2, let value = Int32(parts[1]) {
            values[String(parts[0])] = value
        }
    }
    return values
}

@Test func theTableHasTheRowsOfTheCSVInOrder() throws {
    let rows = try csvRows()
    #expect(rows.count == KeyCodeMap.entries.count)
    for (row, entry) in zip(rows, KeyCodeMap.entries) {
        #expect(row.count == 4, "a CSV row has four fields: \(row)")
        #expect(row[0] == entry.macName)
        #expect(UInt16(row[1].dropFirst(2), radix: 16) == entry.virtualKeyCode)
        #expect(row[2] == entry.androidName)
        #expect(Int32(row[3]) == entry.androidKeyCode)
    }
}

@Test func everyVirtualKeyCodeIsUnique() {
    let codes = KeyCodeMap.entries.map(\.virtualKeyCode)
    #expect(Set(codes).count == codes.count)
}

@Test func everyAndroidKeyCodeIsUsedOnce() {
    let names = KeyCodeMap.entries.map(\.androidName)
    #expect(Set(names).count == names.count)
    let values = KeyCodeMap.entries.map(\.androidKeyCode)
    #expect(Set(values).count == values.count)
}

@Test func everyAndroidNameExistsInTheAPI37ListWithTheSameValue() throws {
    let constants = try apiConstants()
    #expect(constants.count > 300, "the API 37 list is read")
    for entry in KeyCodeMap.entries {
        #expect(
            constants[entry.androidName] == entry.androidKeyCode,
            "\(entry.androidName) is in the API 37 list with its value")
    }
}

@Test func theMetaStateConstantsMatchTheAPI37List() throws {
    let constants = try apiConstants()
    let expected: [(AndroidMetaState, String)] = [
        (.shiftOn, "META_SHIFT_ON"), (.shiftLeftOn, "META_SHIFT_LEFT_ON"), (.shiftRightOn, "META_SHIFT_RIGHT_ON"),
        (.altOn, "META_ALT_ON"), (.altLeftOn, "META_ALT_LEFT_ON"), (.altRightOn, "META_ALT_RIGHT_ON"),
        (.ctrlOn, "META_CTRL_ON"), (.ctrlLeftOn, "META_CTRL_LEFT_ON"), (.ctrlRightOn, "META_CTRL_RIGHT_ON"),
        (.capsLockOn, "META_CAPS_LOCK_ON"),
    ]
    for (state, name) in expected {
        #expect(constants[name] == state.rawValue, "\(name) matches AndroidMetaState")
    }
}

@Test func theSpotChecksOfTheMapHold() {
    #expect(KeyCodeMap.androidKeyCode(forVirtualKeyCode: 0x00) == 29)  // A
    #expect(KeyCodeMap.androidKeyCode(forVirtualKeyCode: 0x08) == 31)  // C
    #expect(KeyCodeMap.androidKeyCode(forVirtualKeyCode: 0x24) == 66)  // Return to ENTER
    #expect(KeyCodeMap.androidKeyCode(forVirtualKeyCode: 0x33) == 67)  // Delete to DEL
    #expect(KeyCodeMap.androidKeyCode(forVirtualKeyCode: 0x35) == 4)  // Escape to BACK
    #expect(KeyCodeMap.androidKeyCode(forVirtualKeyCode: 0x7B) == 21)  // Left arrow to DPAD_LEFT
    #expect(KeyCodeMap.androidKeyCode(forVirtualKeyCode: 0x7A) == 131)  // F1
    #expect(KeyCodeMap.androidKeyCode(forVirtualKeyCode: 0x5D) == 216)  // JIS Yen to YEN
}

@Test func keysOutsideKeyModeAreNotInTheMap() {
    // Command (both sides), Function, the keypad clear, Eisu, Kana, and F13 are not forwarded (input.md §5.2).
    for code: UInt16 in [0x37, 0x36, 0x3F, 0x47, 0x66, 0x68, 0x69] {
        #expect(KeyCodeMap.androidKeyCode(forVirtualKeyCode: code) == nil, "virtual key \(code) is not forwarded")
    }
}
