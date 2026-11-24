import DiagnosticsCore
import Foundation
import RuntimeAPI
import Testing

@testable import RuntimeHost

@Test func sharedFolderHealthCheckReportsAvailableRootsAsPass() async {
    let root = sharedFolder(availability: .available)
    let check = SharedFolderHealthCheck(sharedFolders: { [root] })

    let result = await check.run(healthContext())

    #expect(result.id == "integrations.sharedFolders")
    #expect(result.group == .integrations)
    #expect(check.requirement == .daemon)
    #expect(result.state == .pass)
    #expect(result.error == nil)
    #expect(result.detail == "All configured shared folders are available.")
}

@Test func sharedFolderHealthCheckWarnsForUnavailableRootStatesWithoutLeakingNamesOrPaths() async {
    let unavailableStates: [RuntimeAPI.SharedFolderAvailability] = [
        .missing,
        .privacyDenied,
        .offline,
        .unknown,
    ]

    for availability in unavailableStates {
        let root = sharedFolder(
            name: "Private folder name",
            path: "/Users/private/Private folder name",
            availability: availability
        )
        let check = SharedFolderHealthCheck(sharedFolders: { [root] })
        let result = await check.run(healthContext())

        #expect(result.state == .warning)
        #expect(result.error?.code == "integration.folderUnavailable")
        #expect(result.error?.remediation != nil)
        #expect(result.detail?.contains("Private folder name") == false)
        #expect(result.detail?.contains("/Users/private") == false)
        #expect(result.error?.message.parameters["file"] == .fileName("shared folder"))
        #expect(result.detail?.contains(availability.rawValue) == true)
    }
}

@Test func sharedFolderHealthCheckWarnsSafelyWhenSettingsCannotBeRead() async {
    let check = SharedFolderHealthCheck(sharedFolders: {
        throw SharedFolderProviderFailure.privateDiagnostic
    })

    let result = await check.run(healthContext())

    #expect(result.state == .warning)
    #expect(result.detail == "Shared-folder settings are unavailable.")
    #expect(result.error == nil)
    #expect(result.detail?.contains("/Users/private") == false)
    #expect(result.detail?.contains("secret setting contents") == false)
}

@Test func sharedFolderHealthCheckPassesWhenNoRootsAreConfigured() async {
    let check = SharedFolderHealthCheck(sharedFolders: { [] })

    let result = await check.run(healthContext())

    #expect(result.state == .pass)
    #expect(result.detail == "No shared folders are configured.")
}

private func sharedFolder(
    name: String = "Shared",
    path: String = "/Users/example/Shared",
    availability: RuntimeAPI.SharedFolderAvailability
) -> RuntimeAPI.SharedFolder {
    RuntimeAPI.SharedFolder(
        id: "test-root",
        name: name,
        path: path,
        access: .readOnly,
        builtIn: false,
        availability: availability
    )
}

private func healthContext() -> HealthContext {
    HealthContext(
        daemonAvailable: true,
        runtimeRunning: false,
        paths: APKRunPaths(
            allowingHomeOverride: true,
            environment: ["APKRUN_HOME": "/tmp/apkrun-shared-folder-health-tests"]
        )
    )
}

private enum SharedFolderProviderFailure: Error {
    case privateDiagnostic

    var localizedDescription: String {
        "/Users/private secret setting contents"
    }
}
