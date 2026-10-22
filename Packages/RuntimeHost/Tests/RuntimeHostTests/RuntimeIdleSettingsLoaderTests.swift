import Foundation
import Testing

@testable import RuntimeHost

@Test func runtimeIdleSettingsLoaderUsesDefaultsWhenTheFileIsAbsent() throws {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-idle-settings-\(UUID().uuidString).json")
    let settings = try RuntimeIdleSettingsLoader.load(from: fileURL)

    #expect(settings == .default)
}

@Test func runtimeIdleSettingsLoaderReadsIdlePolicyFromGlobalSettings() throws {
    let fileURL = try writeSettings(
        """
        {
          "schemaVersion": 1,
          "runtime": {
            "idleSuspendMinutes": 1,
            "idleStopMinutes": 2,
            "startPolicy": "atLogin"
          }
        }
        """
    )
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let settings = try RuntimeIdleSettingsLoader.load(from: fileURL)

    #expect(settings.idleSuspendMinutes == 1)
    #expect(settings.idleStopMinutes == 2)
    #expect(settings.startPolicy == .atLogin)
}

@Test func runtimeIdleSettingsLoaderRejectsInvalidAndNewerSettings() throws {
    let invalidFileURL = try writeSettings(
        """
        {
          "schemaVersion": 1,
          "runtime": { "idleSuspendMinutes": true }
        }
        """
    )
    defer { try? FileManager.default.removeItem(at: invalidFileURL) }
    #expect(throws: RuntimeIdleSettingsLoader.Failure.self) {
        try RuntimeIdleSettingsLoader.load(from: invalidFileURL)
    }

    let newerFileURL = try writeSettings(#"{"schemaVersion": 2}"#)
    defer { try? FileManager.default.removeItem(at: newerFileURL) }
    #expect(throws: RuntimeIdleSettingsLoader.Failure.unsupportedSchema(2)) {
        try RuntimeIdleSettingsLoader.load(from: newerFileURL)
    }

    let missingSchemaFileURL = try writeSettings(#"{"runtime":{"idleStopMinutes":30}}"#)
    defer { try? FileManager.default.removeItem(at: missingSchemaFileURL) }
    #expect(throws: RuntimeIdleSettingsLoader.Failure.malformed) {
        try RuntimeIdleSettingsLoader.load(from: missingSchemaFileURL)
    }

    let invalidRuntimeFileURL = try writeSettings(#"{"schemaVersion":1,"runtime":false}"#)
    defer { try? FileManager.default.removeItem(at: invalidRuntimeFileURL) }
    #expect(throws: RuntimeIdleSettingsLoader.Failure.invalidSetting("runtime")) {
        try RuntimeIdleSettingsLoader.load(from: invalidRuntimeFileURL)
    }
}

private func writeSettings(_ content: String) throws -> URL {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-idle-settings-\(UUID().uuidString).json")
    try Data(content.utf8).write(to: fileURL)
    return fileURL
}
