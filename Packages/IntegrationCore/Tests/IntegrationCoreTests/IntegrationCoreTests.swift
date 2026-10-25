import Testing

@testable import IntegrationCore

@Test func fileNameSanitizerAppliesWrapperFileNameRules() {
    let name = "...\u{0001}e\u{0301} /: \u{202E}👩‍💻"

    #expect(FileNameSanitizer.sanitize(name, packageID: "com.example.saved") == "é -- 👩‍💻")
}

@Test func fileNameSanitizerTruncatesAtGraphemeBoundaries() {
    let name = String(repeating: "a", count: 199) + "😀"

    #expect(FileNameSanitizer.sanitize(name, packageID: "com.example.saved") == String(repeating: "a", count: 199))
    #expect(
        FileNameSanitizer.sanitize(String(repeating: "a", count: 200), packageID: "com.example.saved").utf8.count == 200
    )
}

@Test func fileNameSanitizerFallsBackToPackageSegmentWhenNameIsEmpty() {
    #expect(FileNameSanitizer.sanitize("...\u{0000}\u{202E}", packageID: "com.example.saved") == "saved")
    #expect(FileNameSanitizer.sanitize("...", packageID: "invalid") == "invalid")
}
