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
        .restartRuntime,
        .resetRuntime,
        .configuration,
        .updateConfiguration,
        .listPackages,
        .packageInfo,
        .launch,
        .terminate,
        .importPackage,
        .installImported,
        .beginUninstallPackage,
        .subscribe,
        .unsubscribe,
    ]

    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.runtimeStatus.allows($0) })
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.startRuntime.allows($0) })
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.stopRuntime.allows($0) })
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.restartRuntime.allows($0) })
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.resetRuntime.allows($0) })
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.configuration.allows($0) })
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.updateConfiguration.allows($0) })
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.listPackages.allows($0) })
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.packageInfo.allows($0) })
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.launch.allows($0) })
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.terminate.allows($0) })
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.importPackage.allows($0) })
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.installImported.allows($0) })
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.beginUninstallPackage.allows($0) })
    #expect(RuntimeControlOperation.subscribe.allows(.launcher))
    #expect(RuntimeControlOperation.unsubscribe.allows(.launcher))

    #expect(launcherOperations.allSatisfy { $0.allows(.launcher) })
    #expect(launcherPackageOperations.allSatisfy { $0.allows(.launcher) })
    #expect(!RuntimeControlOperation.listPackages.allows(.launcher))
    #expect(!RuntimeControlOperation.startRuntime.allows(.launcher))
    #expect(!RuntimeControlOperation.stopRuntime.allows(.launcher))
    #expect(!RuntimeControlOperation.restartRuntime.allows(.launcher))
    #expect(!RuntimeControlOperation.resetRuntime.allows(.launcher))
    #expect(!RuntimeControlOperation.launch.allows(.launcher))
    #expect(!RuntimeControlOperation.terminate.allows(.launcher))
    #expect(!RuntimeControlOperation.importPackage.allows(.launcher))
    #expect(!RuntimeControlOperation.installImported.allows(.launcher))
    #expect(!RuntimeControlOperation.beginUninstallPackage.allows(.launcher))
    #expect(!RuntimeControlOperation.configuration.allows(.launcher))
    #expect(!RuntimeControlOperation.updateConfiguration.allows(.launcher))
    #expect(allOperations.allSatisfy { !$0.allows(.wrapper) })
}
