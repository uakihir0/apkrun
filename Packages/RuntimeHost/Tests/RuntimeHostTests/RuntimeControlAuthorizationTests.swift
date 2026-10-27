import RuntimeAPI
import Testing

@testable import RuntimeHost

@Test func runtimeControlOperationsMatchDocumentedClientPermissions() {
    let fullControlClients: [RuntimeClientKind] = [.app, .menuBar, .cli]
    let launcherOperations: [RuntimeControlOperation] = [.runtimeStatus]
    let launcherPackageOperations: [RuntimeControlOperation] = [.packageInfo]
    let wrapperSessionOperations: [RuntimeControlOperation] = [
        .packageInfo,
        .openSession,
        .resizeSession,
        .restartApp,
        .closeSession,
        .frameDisplayed,
        .visibilityChanged,
    ]
    let allOperations: [RuntimeControlOperation] = [
        .runtimeStatus,
        .startRuntime,
        .stopRuntime,
        .restartRuntime,
        .resetRuntime,
        .listPackages,
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
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.listPackages.allows($0) })
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.packageInfo.allows($0) })
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.launch.allows($0) })
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.terminate.allows($0) })
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.importPackage.allows($0) })
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.installImported.allows($0) })
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.beginUninstallPackage.allows($0) })
    #expect(RuntimeControlOperation.subscribe.allows(.launcher))
    #expect(RuntimeControlOperation.unsubscribe.allows(.launcher))
    #expect(RuntimeControlOperation.approveWrapper.allows(.cli))
    #expect(RuntimeControlOperation.approveWrapper.allows(.app))
    #expect(!RuntimeControlOperation.approveWrapper.allows(.menuBar))
    #expect(RuntimeControlOperation.decideApproval.allows(.cli))
    #expect(RuntimeControlOperation.decideApproval.allows(.app))
    #expect(!RuntimeControlOperation.decideApproval.allows(.wrapper))

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
    #expect(allOperations.allSatisfy { !$0.allows(.wrapper) })
    #expect(wrapperSessionOperations.allSatisfy { $0.allows(.wrapper) })
    #expect(!RuntimeControlOperation.runtimeStatus.allows(.wrapper))
    #expect(!RuntimeControlOperation.subscribe.allows(.wrapper))
    #expect(!RuntimeControlOperation.launch.allows(.wrapper))
}

@Test func wrapperPackageQueriesAreScopedToTheAuthenticatedRegistryPackage() {
    let ownPackage = RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext")!
    let anotherPackage = RuntimePackageID(rawValue: "com.example.other")!

    #expect(
        wrapperPackageAccessAllowed(
            clientKind: .wrapper,
            authorizedPackageID: ownPackage,
            requestedPackageID: ownPackage
        )
    )
    #expect(
        !wrapperPackageAccessAllowed(
            clientKind: .wrapper,
            authorizedPackageID: ownPackage,
            requestedPackageID: anotherPackage
        )
    )
    #expect(
        !wrapperPackageAccessAllowed(
            clientKind: .wrapper,
            authorizedPackageID: nil,
            requestedPackageID: ownPackage
        )
    )
    #expect(
        wrapperPackageAccessAllowed(
            clientKind: .cli,
            authorizedPackageID: nil,
            requestedPackageID: anotherPackage
        )
    )
}

@Test func wrapperEndpointCodeHashMustMatchTheActiveOrPendingRegistryEntry() {
    #expect(wrapperCodeHashIsRegistered("active-hash", active: "active-hash", pending: nil))
    #expect(wrapperCodeHashIsRegistered("pending-hash", active: "active-hash", pending: "pending-hash"))
    #expect(!wrapperCodeHashIsRegistered("changed-hash", active: "active-hash", pending: nil))
    #expect(!wrapperCodeHashIsRegistered("changed-hash", active: "active-hash", pending: "pending-hash"))
}
