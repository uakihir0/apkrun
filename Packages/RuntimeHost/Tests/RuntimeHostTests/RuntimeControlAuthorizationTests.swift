import RuntimeAPI
import Testing

@testable import RuntimeHost

@Test func runtimeControlOperationsMatchDocumentedClientPermissions() {
    let fullControlClients: [RuntimeClientKind] = [.app, .menuBar, .cli]
    let launcherOperations: [RuntimeControlOperation] = [.runtimeStatus]
    let launcherPackageOperations: [RuntimeControlOperation] = [.packageInfo]
    let allOperations: [RuntimeControlOperation] = [
        .runtimeStatus,
        .startRuntime,
        .stopRuntime,
        .listPackages,
        .packageInfo,
        .launch,
        .terminate,
    ]

    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.runtimeStatus.allows($0) })
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.startRuntime.allows($0) })
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.stopRuntime.allows($0) })
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.listPackages.allows($0) })
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.packageInfo.allows($0) })
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.launch.allows($0) })
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.terminate.allows($0) })

    #expect(launcherOperations.allSatisfy { $0.allows(.launcher) })
    #expect(launcherPackageOperations.allSatisfy { $0.allows(.launcher) })
    #expect(!RuntimeControlOperation.listPackages.allows(.launcher))
    #expect(!RuntimeControlOperation.startRuntime.allows(.launcher))
    #expect(!RuntimeControlOperation.stopRuntime.allows(.launcher))
    #expect(!RuntimeControlOperation.launch.allows(.launcher))
    #expect(!RuntimeControlOperation.terminate.allows(.launcher))
    #expect(allOperations.allSatisfy { !$0.allows(.wrapper) })
}
