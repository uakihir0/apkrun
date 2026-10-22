import RuntimeAPI
import Testing

@testable import RuntimeHost

@Test func runtimeControlOperationsMatchDocumentedClientPermissions() {
    let fullControlClients: [RuntimeClientKind] = [.app, .menuBar, .cli]
    let launcherOperations: [RuntimeControlOperation] = [.runtimeStatus]
    let launcherPackageOperations: [RuntimeControlOperation] = [.packageInfo]
    let wrapperOperations: [RuntimeControlOperation] = [.runtimeStatus, .packageInfo]
    let allOperations: [RuntimeControlOperation] = [
        .runtimeStatus,
        .runtimeInfo,
        .listSessions,
        .configuration,
        .updateConfiguration,
        .startRuntime,
        .stopRuntime,
        .restartRuntime,
        .resetRuntime,
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
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.runtimeInfo.allows($0) })
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.listSessions.allows($0) })
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.configuration.allows($0) })
    #expect(fullControlClients.allSatisfy { RuntimeControlOperation.updateConfiguration.allows($0) })
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

    #expect(launcherOperations.allSatisfy { $0.allows(.launcher) })
    #expect(launcherPackageOperations.allSatisfy { $0.allows(.launcher) })
    #expect(!RuntimeControlOperation.listPackages.allows(.launcher))
    #expect(!RuntimeControlOperation.runtimeInfo.allows(.launcher))
    #expect(!RuntimeControlOperation.listSessions.allows(.launcher))
    #expect(!RuntimeControlOperation.configuration.allows(.launcher))
    #expect(!RuntimeControlOperation.updateConfiguration.allows(.launcher))
    #expect(!RuntimeControlOperation.startRuntime.allows(.launcher))
    #expect(!RuntimeControlOperation.stopRuntime.allows(.launcher))
    #expect(!RuntimeControlOperation.restartRuntime.allows(.launcher))
    #expect(!RuntimeControlOperation.resetRuntime.allows(.launcher))
    #expect(!RuntimeControlOperation.launch.allows(.launcher))
    #expect(!RuntimeControlOperation.terminate.allows(.launcher))
    #expect(!RuntimeControlOperation.importPackage.allows(.launcher))
    #expect(!RuntimeControlOperation.installImported.allows(.launcher))
    #expect(!RuntimeControlOperation.beginUninstallPackage.allows(.launcher))
    #expect(wrapperOperations.allSatisfy { $0.allows(.wrapper) })
    #expect(allOperations.filter { !wrapperOperations.contains($0) }.allSatisfy { !$0.allows(.wrapper) })
}

@Test func wrapperAuthorizerBindsEachBundleToOnePackageAndSigningRequirement() throws {
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let otherPackageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.other"))
    let authorizer = WrapperAuthorizer(registrations: [
        WrapperRegistration(
            bundleID: "io.apkrun.android.io.apkrun.fixture.hellotext",
            packageID: packageID,
            codeSigningRequirement: "identifier \"io.apkrun.android.io.apkrun.fixture.hellotext\""
        )
    ])
    let endpointRequest = RuntimeEndpointRequest(
        kind: .wrapper,
        clientKind: .wrapper,
        claimedIdentity: "io.apkrun.android.io.apkrun.fixture.hellotext",
        apiVersion: .current
    )

    #expect(authorizer.authorizesPackage(packageID, for: "io.apkrun.android.io.apkrun.fixture.hellotext"))
    #expect(!authorizer.authorizesPackage(otherPackageID, for: "io.apkrun.android.io.apkrun.fixture.hellotext"))
    #expect(authorizer.registration(for: "io.apkrun.android.io.apkrun.fixture.other") == nil)
    #expect(authorizer.registration(for: endpointRequest)?.packageID == packageID)
    #expect(
        authorizer.registration(for: endpointRequest)?.codeSigningRequirement
            == "identifier \"io.apkrun.android.io.apkrun.fixture.hellotext\"")
    #expect(
        authorizer.registration(
            for: RuntimeEndpointRequest(
                kind: .control,
                clientKind: .wrapper,
                claimedIdentity: endpointRequest.claimedIdentity,
                apiVersion: .current
            )
        ) == nil
    )
    #expect(
        authorizer.registration(
            for: RuntimeEndpointRequest(
                kind: .wrapper,
                clientKind: .cli,
                claimedIdentity: endpointRequest.claimedIdentity,
                apiVersion: .current
            )
        ) == nil
    )
    #expect(RuntimeWrapperAuthorization.allowsPackageInfo(packageID, authorizedPackageID: packageID))
    #expect(!RuntimeWrapperAuthorization.allowsPackageInfo(otherPackageID, authorizedPackageID: packageID))
    #expect(!RuntimeWrapperAuthorization.allowsPackageInfo(packageID, authorizedPackageID: nil))
}
