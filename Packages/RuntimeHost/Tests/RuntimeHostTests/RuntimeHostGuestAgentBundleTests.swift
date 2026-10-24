import DiagnosticsCore
import Foundation
import RuntimeCore
import Testing

@testable import RuntimeHost

@Test func releaseHostDoesNotLoadDevelopmentGuestAgentBundle() throws {
    let missingDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MissingGuestAgent-\(UUID().uuidString)", isDirectory: true)

    let bundle = try RuntimeHost.loadGuestAgentBundle(
        configuration: .release,
        directory: missingDirectory
    )

    #expect(bundle == nil)
}

@Test func debugHostRequiresDevelopmentGuestAgentBundle() throws {
    let missingDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MissingGuestAgent-\(UUID().uuidString)", isDirectory: true)

    #expect(throws: GuestAgentFailure.bundleMissing) {
        try RuntimeHost.loadGuestAgentBundle(
            configuration: .debug,
            directory: missingDirectory
        )
    }
}
