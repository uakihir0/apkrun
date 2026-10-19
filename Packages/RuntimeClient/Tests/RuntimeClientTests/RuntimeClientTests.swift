import Foundation
import RuntimeAPI
import Testing

@testable import RuntimeClient

@Test func controlClientAuthenticatesBrokerAndUsesOneControlEndpoint() async throws {
    let configuration = try RuntimeControlClientConfiguration(
        clientKind: .cli,
        claimedIdentity: "io.apkrun.cli.dev",
        buildIdentity: .development,
        clientVersion: "0.1.0",
        clientBuild: 1
    )
    let hello = RuntimeHelloReply(
        runtimeVersion: "0.1.0",
        runtimeBuild: 1,
        apiVersion: APIVersion.current,
        hostState: "running"
    )
    let status = RuntimeHostStatus(
        hostState: "running",
        runtimeState: "ready",
        bootProgress: nil,
        startupFailureStep: nil,
        startupFailureCode: nil,
        crashLoopActive: false,
        daemonPID: 42,
        imageVersion: "test-image"
    )
    let transport = try MockRuntimeTransport(hello: hello, status: status)
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)

    #expect(try await client.connect() == hello)
    #expect(try await client.runtimeStatus() == status)
    #expect(try await client.startRuntime() == status)
    #expect(try await client.stopRuntime() == status)
    #expect(try await client.resetRuntime() == status)

    let snapshot = transport.snapshot()
    #expect(snapshot.serviceName == "io.apkrun.apkrund.dev.xpc")
    #expect(snapshot.brokerRequirement == "identifier \"io.apkrun.apkrund.dev\"")
    #expect(snapshot.controlRequirement == snapshot.brokerRequirement)
    #expect(snapshot.controlConnections == 1)
    #expect(snapshot.brokerInvalidations == 1)

    let helloRequest = try JSONDecoder().decode(RuntimeHelloRequest.self, from: snapshot.helloRequests[0])
    #expect(helloRequest.clientKind == RuntimeClientKind.cli)
    #expect(helloRequest.claimedIdentity == "io.apkrun.cli.dev")
    #expect(helloRequest.apiVersion == APIVersion.current)
    #expect(helloRequest.clientVersion == "0.1.0")
    #expect(helloRequest.clientBuild == 1)

    let endpointRequest = try JSONDecoder().decode(RuntimeEndpointRequest.self, from: snapshot.endpointRequests[0])
    #expect(endpointRequest.kind == .control)
    #expect(endpointRequest.clientKind == RuntimeClientKind.cli)
    #expect(endpointRequest.claimedIdentity == "io.apkrun.cli.dev")

    #expect(snapshot.statusRequests.count == 2)
    #expect(snapshot.startRequests.count == 1)
    #expect(snapshot.stopRequests.count == 1)
    #expect(snapshot.resetRequests.count == 1)
    let resetRequest = try JSONDecoder().decode(
        RuntimeResetControlRequest.self,
        from: snapshot.resetRequests[0]
    )
    #expect(resetRequest.header.apiVersion == APIVersion.current)
    #expect(resetRequest.header.clientKind == RuntimeClientKind.cli)
    for data in snapshot.statusRequests + snapshot.startRequests + snapshot.stopRequests + snapshot.resetRequests {
        let request = try JSONDecoder().decode(ControlRequestHeader.self, from: data)
        #expect(request.header.apiVersion == APIVersion.current)
        #expect(request.header.clientKind == RuntimeClientKind.cli)
    }
}

@Test func controlClientRestartsWithOneVersionedRequestAndDoesNotReplayFailures() async throws {
    let configuration = try RuntimeControlClientConfiguration(
        clientKind: .cli,
        claimedIdentity: "io.apkrun.cli.dev",
        buildIdentity: .development,
        restartRequestTimeout: .milliseconds(10)
    )
    let hello = RuntimeHelloReply(
        runtimeVersion: "0.1.0",
        runtimeBuild: 1,
        apiVersion: APIVersion.current,
        hostState: "running"
    )
    let status = RuntimeHostStatus(
        hostState: "running",
        runtimeState: "ready",
        bootProgress: nil,
        startupFailureStep: nil,
        startupFailureCode: nil,
        crashLoopActive: false,
        daemonPID: 42,
        imageVersion: "test-image"
    )
    let transport = try MockRuntimeTransport(hello: hello, status: status)
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)

    #expect(try await client.restartRuntime() == status)

    let snapshot = transport.snapshot()
    #expect(snapshot.restartRequests.count == 1)
    #expect(snapshot.stopRequests.isEmpty)
    #expect(snapshot.startRequests.isEmpty)
    let request = try JSONDecoder().decode(RestartRuntimeRequest.self, from: snapshot.restartRequests[0])
    #expect(request.header.apiVersion == APIVersion.current)
    #expect(request.header.clientKind == .cli)

    transport.failNextRestart()
    do {
        _ = try await client.restartRuntime()
        Issue.record("The mock restart transport failure was not returned to the caller.")
    } catch {
        #expect(error == .transportFailure(domain: "NSCocoaErrorDomain", code: 4099))
    }
    let failedSnapshot = transport.snapshot()
    #expect(failedSnapshot.restartRequests.count == 2)
    #expect(failedSnapshot.controlConnections == 1)

    transport.delayNextRestart(for: .seconds(1))
    do {
        _ = try await client.restartRuntime()
        Issue.record("The delayed restart did not time out.")
    } catch {
        #expect(error == .requestTimedOut(operation: "runtimeRestart"))
    }
    let timedOutSnapshot = transport.snapshot()
    #expect(timedOutSnapshot.restartRequests.count == 3)
    #expect(timedOutSnapshot.startRequests.isEmpty)
    #expect(timedOutSnapshot.stopRequests.isEmpty)
    #expect(timedOutSnapshot.controlConnections == 2)

    _ = try await client.runtimeStatus()
    #expect(transport.snapshot().controlConnections == 3)
}

@Test func controlClientLaunchesAndTerminatesWithVersionedRequests() async throws {
    let configuration = try RuntimeControlClientConfiguration(
        clientKind: .cli,
        claimedIdentity: "io.apkrun.cli.dev",
        buildIdentity: .development
    )
    let hello = RuntimeHelloReply(
        runtimeVersion: "0.1.0",
        runtimeBuild: 1,
        apiVersion: APIVersion.current,
        hostState: "running"
    )
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let launchResult = RuntimeLaunchResult(
        sessionID: UUID(uuidString: "CF9204EA-C7B5-4C34-A8D9-6D7CD6742501")!,
        packageID: packageID,
        state: .running
    )
    let terminateResult = RuntimeTerminateResult(packageID: packageID, hadSession: true)
    let transport = try MockRuntimeTransport(
        hello: hello,
        status: nil,
        launchReply: RuntimeLaunchControlReply(result: launchResult),
        terminateReply: RuntimeTerminateControlReply(result: terminateResult)
    )
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)

    #expect(try await client.launch(RuntimeLaunchRequest(packageID: packageID)) == launchResult)
    #expect(try await client.terminate(RuntimeTerminateRequest(packageID: packageID)) == terminateResult)

    let snapshot = transport.snapshot()
    #expect(snapshot.launchRequests.count == 1)
    #expect(snapshot.terminateRequests.count == 1)
    let launchRequest = try JSONDecoder().decode(RuntimeLaunchControlRequest.self, from: snapshot.launchRequests[0])
    let terminateRequest = try JSONDecoder().decode(
        RuntimeTerminateControlRequest.self,
        from: snapshot.terminateRequests[0]
    )
    #expect(launchRequest.packageID == packageID)
    #expect(terminateRequest.packageID == packageID)
    for header in [launchRequest.header, terminateRequest.header] {
        #expect(header.apiVersion == APIVersion.current)
        #expect(header.clientKind == RuntimeClientKind.cli)
    }
}

@Test func controlClientListsPackagesAndReadsDetailsWithVersionedRequests() async throws {
    let configuration = try RuntimeControlClientConfiguration(
        clientKind: .cli,
        claimedIdentity: "io.apkrun.cli.dev",
        buildIdentity: .development
    )
    let hello = RuntimeHelloReply(
        runtimeVersion: "0.1.0",
        runtimeBuild: 1,
        apiVersion: APIVersion.current,
        hostState: "running"
    )
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let summary = RuntimePackageSummary(
        packageID: packageID,
        displayName: "Hello Text",
        versionCode: 7,
        versionName: "1.2.3",
        state: .installed,
        managed: true,
        updateAuthority: .apkrun
    )
    let listResult = RuntimePackageListResult(
        packages: [summary],
        source: .cachedAndroid,
        observedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let details = RuntimePackageDetails(
        summary: summary,
        files: [
            RuntimeArtifactFile(
                name: "base.apk",
                size: 1024,
                sha256: try #require(RuntimeSHA256Digest(rawValue: "sha256:" + String(repeating: "a", count: 64)))
            )
        ],
        artifactBytes: 1024,
        androidDataBytes: 2048
    )
    let transport = try MockRuntimeTransport(
        hello: hello,
        status: nil,
        packageListReply: RuntimeListPackagesControlReply(result: listResult),
        packageInfoReply: RuntimePackageInfoControlReply(result: details)
    )
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)

    #expect(try await client.listPackages(filter: .all) == listResult)
    #expect(try await client.packageInfo(packageID: packageID) == details)

    let snapshot = transport.snapshot()
    #expect(snapshot.packageListRequests.count == 1)
    #expect(snapshot.packageInfoRequests.count == 1)
    let listRequest = try JSONDecoder().decode(
        RuntimeListPackagesControlRequest.self,
        from: snapshot.packageListRequests[0]
    )
    let infoRequest = try JSONDecoder().decode(
        RuntimePackageInfoControlRequest.self,
        from: snapshot.packageInfoRequests[0]
    )
    #expect(listRequest.filter == .all)
    #expect(infoRequest.packageID == packageID)
    for header in [listRequest.header, infoRequest.header] {
        #expect(header.apiVersion == APIVersion.current)
        #expect(header.clientKind == RuntimeClientKind.cli)
    }
}

@Test func controlClientPreservesTypedPackageQueryErrors() async throws {
    let configuration = try RuntimeControlClientConfiguration(
        clientKind: .cli,
        claimedIdentity: "io.apkrun.cli.dev",
        buildIdentity: .development
    )
    let hello = RuntimeHelloReply(
        runtimeVersion: "0.1.0",
        runtimeBuild: 1,
        apiVersion: APIVersion.current,
        hostState: "running"
    )
    let failure = RuntimeWireError.runtime(
        "packageNotFound",
        message: "APKRun has no stored details for this app.",
        remediation: "List managed apps to see the packages APKRun can inspect."
    )
    let transport = try MockRuntimeTransport(
        hello: hello,
        status: nil,
        packageInfoReply: RuntimePackageInfoControlReply(error: failure)
    )
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.unknown"))

    do {
        _ = try await client.packageInfo(packageID: packageID)
        Issue.record("The remote package-info error was not returned to the caller.")
    } catch {
        #expect(error == .remoteFailure(code: failure.code, message: failure.message))
        #expect(error.errorDescription == failure.message)
    }
}

@Test func controlClientDoesNotReplaySessionMutationsAfterTransportFailure() async throws {
    let configuration = try RuntimeControlClientConfiguration(
        clientKind: .cli,
        claimedIdentity: "io.apkrun.cli.dev",
        buildIdentity: .development
    )
    let hello = RuntimeHelloReply(
        runtimeVersion: "0.1.0",
        runtimeBuild: 1,
        apiVersion: APIVersion.current,
        hostState: "running"
    )
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let transport = try MockRuntimeTransport(hello: hello, status: nil)
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)
    transport.failNextLaunch()

    do {
        _ = try await client.launch(RuntimeLaunchRequest(packageID: packageID))
        Issue.record("The mock transport failure was not returned to the caller.")
    } catch {
        #expect(error == .transportFailure(domain: "NSCocoaErrorDomain", code: 4099))
    }

    let failedSnapshot = transport.snapshot()
    #expect(failedSnapshot.launchRequests.count == 1)
    #expect(failedSnapshot.controlConnections == 1)
    #expect(failedSnapshot.brokerConnections == 1)

    // A new explicit call can open a fresh connection; the failed launch itself was sent once.
    _ = try await client.launch(RuntimeLaunchRequest(packageID: packageID))
    let retriedSnapshot = transport.snapshot()
    #expect(retriedSnapshot.launchRequests.count == 2)
    #expect(retriedSnapshot.controlConnections == 2)
    #expect(retriedSnapshot.brokerConnections == 2)

    transport.failNextTerminate()
    do {
        _ = try await client.terminate(RuntimeTerminateRequest(packageID: packageID))
        Issue.record("The mock terminate transport failure was not returned to the caller.")
    } catch {
        #expect(error == .transportFailure(domain: "NSCocoaErrorDomain", code: 4099))
    }
    let terminateSnapshot = transport.snapshot()
    #expect(terminateSnapshot.terminateRequests.count == 1)
    #expect(terminateSnapshot.controlConnections == 2)
    #expect(terminateSnapshot.brokerConnections == 2)

    transport.failNextReset()
    do {
        _ = try await client.resetRuntime()
        Issue.record("The mock reset transport failure was not returned to the caller.")
    } catch {
        #expect(error == .transportFailure(domain: "NSCocoaErrorDomain", code: 4099))
    }
    let resetSnapshot = transport.snapshot()
    #expect(resetSnapshot.resetRequests.count == 1)
    #expect(resetSnapshot.controlConnections == 3)
    #expect(resetSnapshot.brokerConnections == 3)
}

@Test func controlClientPreservesTypedSessionErrors() async throws {
    let configuration = try RuntimeControlClientConfiguration(
        clientKind: .cli,
        claimedIdentity: "io.apkrun.cli.dev",
        buildIdentity: .development
    )
    let hello = RuntimeHelloReply(
        runtimeVersion: "0.1.0",
        runtimeBuild: 1,
        apiVersion: APIVersion.current,
        hostState: "running"
    )
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let failure = RuntimeWireError.runtime(
        "packageNotInstalled",
        message: "This app is not installed.",
        remediation: "Install the app, then retry."
    )
    let transport = try MockRuntimeTransport(
        hello: hello,
        status: nil,
        launchReply: RuntimeLaunchControlReply(error: failure)
    )
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)

    do {
        _ = try await client.launch(RuntimeLaunchRequest(packageID: packageID))
        Issue.record("The remote package failure was not returned to the caller.")
    } catch {
        #expect(error == .remoteFailure(code: failure.code, message: failure.message))
        #expect(error.errorDescription == failure.message)
    }
}

@Test func controlClientRejectsAnIncompatibleBrokerBeforeRequestingAnEndpoint() async throws {
    let configuration = try RuntimeControlClientConfiguration(
        clientKind: .app,
        claimedIdentity: "io.apkrun.APKRun.dev",
        buildIdentity: .development
    )
    let hello = RuntimeHelloReply(
        runtimeVersion: "2.0.0",
        runtimeBuild: 2,
        apiVersion: APIVersion(major: APIVersion.current.major + 1, minor: 0),
        hostState: "running"
    )
    let transport = try MockRuntimeTransport(hello: hello, status: nil)
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)

    do {
        _ = try await client.connect()
        Issue.record("The client accepted an incompatible daemon API version.")
    } catch {
        #expect(error == .apiVersionMismatch(client: APIVersion.current, server: hello.apiVersion))
    }

    let snapshot = transport.snapshot()
    #expect(snapshot.endpointRequests.isEmpty)
    #expect(snapshot.controlConnections == 0)
}

@Test func controlClientExplainsWhenTheDaemonIsShuttingDown() async throws {
    let configuration = try RuntimeControlClientConfiguration(
        clientKind: .cli,
        claimedIdentity: "io.apkrun.cli.dev",
        buildIdentity: .development
    )
    let hello = RuntimeHelloReply(
        runtimeVersion: "0.1.0",
        runtimeBuild: 1,
        apiVersion: APIVersion.current,
        hostState: "shuttingDown"
    )
    let transport = try MockRuntimeTransport(
        hello: hello,
        status: nil,
        endpointRejection: .hostShuttingDown
    )
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)

    do {
        _ = try await client.connect()
        Issue.record("The client accepted an endpoint request while the daemon was shutting down.")
    } catch {
        #expect(error == .endpointRejected(.hostShuttingDown))
        #expect(error.errorDescription == "APKRun's background service is stopping. Try again in a moment.")
    }

    let snapshot = transport.snapshot()
    #expect(snapshot.endpointRequests.count == 1)
    #expect(snapshot.controlConnections == 0)
    #expect(snapshot.brokerInvalidations == 1)
}

@Test func controlClientRetriesTransientEndpointAdmissionBeforeConnecting() async throws {
    let configuration = try RuntimeControlClientConfiguration(
        clientKind: .cli,
        claimedIdentity: "io.apkrun.cli.dev",
        buildIdentity: .development
    )
    let hello = RuntimeHelloReply(
        runtimeVersion: "0.1.0",
        runtimeBuild: 1,
        apiVersion: APIVersion.current,
        hostState: "running"
    )
    let transport = try MockRuntimeTransport(
        hello: hello,
        status: nil,
        endpointBusyRejections: 2
    )
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)

    try await client.connect()

    let snapshot = transport.snapshot()
    #expect(snapshot.endpointRequests.count == 3)
    #expect(snapshot.controlConnections == 1)
}

@Test func controlClientRetriesTransportRefusedEndpointBeforeReturningConnection() async throws {
    let configuration = try RuntimeControlClientConfiguration(
        clientKind: .cli,
        claimedIdentity: "io.apkrun.cli.dev",
        buildIdentity: .development
    )
    let hello = RuntimeHelloReply(
        runtimeVersion: "0.1.0",
        runtimeBuild: 1,
        apiVersion: APIVersion.current,
        hostState: "running"
    )
    let transport = try MockRuntimeTransport(hello: hello, status: nil)
    transport.failNextStatus()
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)

    try await client.connect()

    let snapshot = transport.snapshot()
    #expect(snapshot.brokerConnections == 2)
    #expect(snapshot.controlConnections == 2)
    #expect(snapshot.endpointRequests.count == 2)
    #expect(snapshot.statusRequests.count == 2)
}

@Test func controlClientDecodesBrokerAdmissionErrors() async throws {
    let configuration = try RuntimeControlClientConfiguration(
        clientKind: .cli,
        claimedIdentity: "io.apkrun.cli.dev",
        buildIdentity: .development
    )
    let failure = RuntimeControlError(
        code: "runtime.busy",
        message: "The runtime daemon is handling the maximum number of requests."
    )
    let hello = RuntimeHelloReply(
        runtimeVersion: "0.1.0",
        runtimeBuild: 1,
        apiVersion: APIVersion.current,
        hostState: "running"
    )
    let transport = try MockRuntimeTransport(hello: hello, status: nil, helloFailure: failure)
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)

    do {
        _ = try await client.connect()
        Issue.record("The client accepted a broker admission error as a hello reply.")
    } catch {
        #expect(error == .remoteFailure(code: failure.code, message: failure.message))
    }

    let snapshot = transport.snapshot()
    #expect(snapshot.endpointRequests.isEmpty)
    #expect(snapshot.controlConnections == 0)
    #expect(snapshot.brokerInvalidations == 1)
}

@Test func controlClientReconnectsAfterAControlTransportFailureWithoutReplayingIt() async throws {
    let configuration = try RuntimeControlClientConfiguration(
        clientKind: .cli,
        claimedIdentity: "io.apkrun.cli.dev",
        buildIdentity: .development
    )
    let hello = RuntimeHelloReply(
        runtimeVersion: "0.1.0",
        runtimeBuild: 1,
        apiVersion: APIVersion.current,
        hostState: "running"
    )
    let status = RuntimeHostStatus(
        hostState: "running",
        runtimeState: "ready",
        bootProgress: nil,
        startupFailureStep: nil,
        startupFailureCode: nil,
        crashLoopActive: false,
        daemonPID: 42,
        imageVersion: "test-image"
    )
    let transport = try MockRuntimeTransport(hello: hello, status: status)
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)

    #expect(try await client.runtimeStatus() == status)
    transport.failNextStatus()
    do {
        _ = try await client.runtimeStatus()
        Issue.record("The mock transport failure was not returned to the caller.")
    } catch {
        #expect(error == .transportFailure(domain: "NSCocoaErrorDomain", code: 4099))
    }
    #expect(try await client.runtimeStatus() == status)

    let snapshot = transport.snapshot()
    #expect(snapshot.brokerConnections == 2)
    #expect(snapshot.controlConnections == 2)
    #expect(snapshot.brokerInvalidations == 3)
    #expect(snapshot.statusRequests.count == 5)
}

@Test func clientConfigurationsBindReleaseDaemonToTeamAndIdentifier() throws {
    let release = try RuntimeControlClientConfiguration(
        clientKind: .app,
        claimedIdentity: "io.apkrun.APKRun",
        buildIdentity: .release(teamIdentifier: "ABCDE12345")
    )
    let updateTest = try RuntimeControlClientConfiguration(
        clientKind: .app,
        claimedIdentity: "io.apkrun.APKRun.updatetest",
        buildIdentity: .releaseUpdateTest(teamIdentifier: "ABCDE12345")
    )

    #expect(release.serviceName == "io.apkrun.apkrund.xpc")
    #expect(
        release.daemonCodeSigningRequirement
            == "anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\" and identifier \"io.apkrun.apkrund\""
    )
    #expect(updateTest.serviceName == "io.apkrun.apkrund.updatetest.xpc")
    #expect(
        updateTest.daemonCodeSigningRequirement
            == "anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\" and identifier \"io.apkrun.apkrund.updatetest\""
    )
}

private struct ControlRequestHeader: Decodable {
    let header: APIRequestHeader
}

private struct BrokerErrorEnvelope: Encodable {
    let error: RuntimeControlError
}

private final class MockRuntimeTransport: RuntimeXPCConnectionFactory, RuntimeBrokerChannel, RuntimeControlChannel,
    @unchecked Sendable
{
    private let helloData: Data
    private let endpointData: Data
    private let endpointBusyData: Data
    private let endpoint: RuntimeXPCListenerEndpoint?
    private let statusData: Data
    private let packageListData: Data
    private let packageInfoData: Data
    private let launchData: Data
    private let terminateData: Data
    private let lock = NSLock()
    private var serviceNameValue: String?
    private var brokerRequirementValue: String?
    private var controlRequirementValue: String?
    private var helloRequestsValue: [Data] = []
    private var endpointRequestsValue: [Data] = []
    private var statusRequestsValue: [Data] = []
    private var startRequestsValue: [Data] = []
    private var stopRequestsValue: [Data] = []
    private var restartRequestsValue: [Data] = []
    private var packageListRequestsValue: [Data] = []
    private var packageInfoRequestsValue: [Data] = []
    private var launchRequestsValue: [Data] = []
    private var terminateRequestsValue: [Data] = []
    private var resetRequestsValue: [Data] = []
    private var brokerConnectionsValue = 0
    private var controlConnectionsValue = 0
    private var brokerInvalidationsValue = 0
    private var failNextStatusValue = false
    private var failNextLaunchValue = false
    private var failNextTerminateValue = false
    private var failNextRestartValue = false
    private var restartDelayValue: Duration?
    private var failNextResetValue = false
    private var endpointBusyRejectionsValue: Int

    init(
        hello: RuntimeHelloReply,
        status: RuntimeHostStatus?,
        endpointRejection: RuntimeEndpointRejection? = nil,
        endpointBusyRejections: Int = 0,
        helloFailure: RuntimeControlError? = nil,
        packageListReply: RuntimeListPackagesControlReply? = nil,
        packageInfoReply: RuntimePackageInfoControlReply? = nil,
        launchReply: RuntimeLaunchControlReply? = nil,
        terminateReply: RuntimeTerminateControlReply? = nil
    ) throws {
        if let helloFailure {
            helloData = try JSONEncoder().encode(BrokerErrorEnvelope(error: helloFailure))
        } else {
            helloData = try JSONEncoder().encode(hello)
        }
        if let endpointRejection {
            endpointData = try JSONEncoder().encode(RuntimeEndpointReply.rejected(endpointRejection))
            endpoint = nil
        } else {
            endpointData = try JSONEncoder().encode(RuntimeEndpointReply.granted)
            endpoint = RuntimeXPCListenerEndpoint(value: NSObject())
        }
        endpointBusyData = try JSONEncoder().encode(RuntimeEndpointReply.rejected(.busy))
        endpointBusyRejectionsValue = endpointBusyRejections
        if let status {
            statusData = try JSONEncoder().encode(RuntimeControlReply(status: status))
        } else {
            statusData = try JSONEncoder().encode(
                RuntimeControlReply(error: RuntimeControlError(code: "runtime.test", message: "test failure"))
            )
        }
        let packageID = RuntimePackageID(rawValue: "com.example.app")!
        let defaultSummary = RuntimePackageSummary(
            packageID: packageID,
            displayName: "Example",
            versionCode: 1
        )
        let defaultListReply = RuntimeListPackagesControlReply(
            result: RuntimePackageListResult(packages: [defaultSummary], source: .managedRecords)
        )
        let defaultPackageInfoReply = RuntimePackageInfoControlReply(
            result: RuntimePackageDetails(summary: defaultSummary, files: [], artifactBytes: 0)
        )
        let defaultLaunchReply = RuntimeLaunchControlReply(
            result: RuntimeLaunchResult(
                sessionID: UUID(uuidString: "B1D9C07C-E76A-446F-B849-0C9E5FC7B1C7")!,
                packageID: packageID,
                state: .running
            )
        )
        let defaultTerminateReply = RuntimeTerminateControlReply(
            result: RuntimeTerminateResult(packageID: packageID, hadSession: true)
        )
        packageListData = try JSONEncoder().encode(packageListReply ?? defaultListReply)
        packageInfoData = try JSONEncoder().encode(packageInfoReply ?? defaultPackageInfoReply)
        launchData = try JSONEncoder().encode(launchReply ?? defaultLaunchReply)
        terminateData = try JSONEncoder().encode(terminateReply ?? defaultTerminateReply)
    }

    func makeBroker(
        serviceName: String,
        signingRequirement: String
    ) throws(RuntimeControlClientError) -> any RuntimeBrokerChannel {
        lock.withLock {
            brokerConnectionsValue += 1
            serviceNameValue = serviceName
            brokerRequirementValue = signingRequirement
        }
        return self
    }

    func makeControl(
        endpoint: RuntimeXPCListenerEndpoint,
        signingRequirement: String
    ) throws(RuntimeControlClientError) -> any RuntimeControlChannel {
        guard endpoint.value is NSObject else {
            throw .malformedReply
        }
        lock.withLock {
            controlRequirementValue = signingRequirement
            controlConnectionsValue += 1
        }
        return self
    }

    func hello(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        lock.withLock { helloRequestsValue.append(request) }
        return helloData
    }

    func requestEndpoint(_ request: Data) async throws(RuntimeControlClientError) -> RuntimeBrokerEndpointReply {
        let (data, endpoint) = lock.withLock {
            endpointRequestsValue.append(request)
            guard endpointBusyRejectionsValue > 0 else {
                return (endpointData, endpoint)
            }
            endpointBusyRejectionsValue -= 1
            return (endpointBusyData, nil)
        }
        return RuntimeBrokerEndpointReply(
            data: data,
            endpoint: endpoint
        )
    }

    func invalidate() {
        lock.withLock { brokerInvalidationsValue += 1 }
    }

    func runtimeStatus(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        let shouldFail = lock.withLock {
            statusRequestsValue.append(request)
            defer { failNextStatusValue = false }
            return failNextStatusValue
        }
        if shouldFail {
            throw .transportFailure(domain: "NSCocoaErrorDomain", code: 4099)
        }
        return statusData
    }

    func startRuntime(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        lock.withLock { startRequestsValue.append(request) }
        return statusData
    }

    func stopRuntime(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        lock.withLock { stopRequestsValue.append(request) }
        return statusData
    }

    func restartRuntime(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        let (shouldFail, delay) = lock.withLock {
            restartRequestsValue.append(request)
            defer { failNextRestartValue = false }
            let delay = restartDelayValue
            restartDelayValue = nil
            return (failNextRestartValue, delay)
        }
        if let delay {
            do {
                try await Task.sleep(for: delay)
            } catch {
                throw .requestTimedOut(operation: "runtimeRestart")
            }
        }
        if shouldFail {
            throw .transportFailure(domain: "NSCocoaErrorDomain", code: 4099)
        }
        return statusData
    }

    func resetRuntime(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        let shouldFail = lock.withLock {
            resetRequestsValue.append(request)
            defer { failNextResetValue = false }
            return failNextResetValue
        }
        if shouldFail {
            throw .transportFailure(domain: "NSCocoaErrorDomain", code: 4099)
        }
        return statusData
    }

    func listPackages(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        lock.withLock { packageListRequestsValue.append(request) }
        return packageListData
    }

    func packageInfo(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        lock.withLock { packageInfoRequestsValue.append(request) }
        return packageInfoData
    }

    func launch(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        let shouldFail = lock.withLock {
            launchRequestsValue.append(request)
            defer { failNextLaunchValue = false }
            return failNextLaunchValue
        }
        if shouldFail {
            throw .transportFailure(domain: "NSCocoaErrorDomain", code: 4099)
        }
        return launchData
    }

    func terminate(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        let shouldFail = lock.withLock {
            terminateRequestsValue.append(request)
            defer { failNextTerminateValue = false }
            return failNextTerminateValue
        }
        if shouldFail {
            throw .transportFailure(domain: "NSCocoaErrorDomain", code: 4099)
        }
        return terminateData
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                serviceName: serviceNameValue,
                brokerRequirement: brokerRequirementValue,
                controlRequirement: controlRequirementValue,
                helloRequests: helloRequestsValue,
                endpointRequests: endpointRequestsValue,
                statusRequests: statusRequestsValue,
                startRequests: startRequestsValue,
                stopRequests: stopRequestsValue,
                restartRequests: restartRequestsValue,
                packageListRequests: packageListRequestsValue,
                packageInfoRequests: packageInfoRequestsValue,
                launchRequests: launchRequestsValue,
                terminateRequests: terminateRequestsValue,
                resetRequests: resetRequestsValue,
                brokerConnections: brokerConnectionsValue,
                controlConnections: controlConnectionsValue,
                brokerInvalidations: brokerInvalidationsValue
            )
        }
    }

    func failNextStatus() {
        lock.withLock { failNextStatusValue = true }
    }

    func failNextLaunch() {
        lock.withLock { failNextLaunchValue = true }
    }

    func failNextTerminate() {
        lock.withLock { failNextTerminateValue = true }
    }

    func failNextRestart() {
        lock.withLock { failNextRestartValue = true }
    }

    func delayNextRestart(for duration: Duration) {
        lock.withLock { restartDelayValue = duration }
    }

    func failNextReset() {
        lock.withLock { failNextResetValue = true }
    }

    struct Snapshot {
        let serviceName: String?
        let brokerRequirement: String?
        let controlRequirement: String?
        let helloRequests: [Data]
        let endpointRequests: [Data]
        let statusRequests: [Data]
        let startRequests: [Data]
        let stopRequests: [Data]
        let restartRequests: [Data]
        let packageListRequests: [Data]
        let packageInfoRequests: [Data]
        let launchRequests: [Data]
        let terminateRequests: [Data]
        let resetRequests: [Data]
        let brokerConnections: Int
        let controlConnections: Int
        let brokerInvalidations: Int
    }
}
