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

@Test func controlClientReadsRuntimeInfoSessionsAndConfiguration() async throws {
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
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let info = RuntimeInfo(
        status: status,
        sizing: RuntimeSizing(cpuCount: 4, memoryGiB: 6, userdataGiB: 32),
        displayPoolSize: 3,
        resources: ResourceUsage(daemonPhysicalFootprintBytes: 4_194_304),
        displays: []
    )
    let sessions = [
        SessionSummary(
            sessionID: UUID(uuidString: "ea9bf3b2-0520-4ed7-a5ab-13cda15bc481")!,
            packageID: packageID,
            displayName: "Hello Text",
            state: .running,
            clientKind: .wrapper,
            openedAt: Date(timeIntervalSince1970: 1_800_000_000),
            windowMode: .secondaryDisplay,
            recording: false
        )
    ]
    let resolved = ConfigurationSnapshot(
        entries: [
            ConfigurationEntry(
                key: "runtime.memoryGiB",
                value: .integer(6),
                defaultValue: .integer(6),
                isSet: false,
                applies: .nextBoot
            )
        ]
    )
    let updated = ConfigurationSnapshot(
        entries: [
            ConfigurationEntry(
                key: "runtime.memoryGiB",
                value: .integer(8),
                defaultValue: .integer(6),
                isSet: true,
                applies: .nextBoot
            )
        ]
    )
    let transport = try MockRuntimeTransport(
        hello: hello,
        status: status,
        runtimeInfoReply: RuntimeInfoControlReply(result: info),
        listSessionsReply: RuntimeListSessionsControlReply(result: sessions),
        configurationReply: RuntimeConfigurationControlReply(result: resolved),
        updateConfigurationReply: RuntimeUpdateConfigurationControlReply(result: updated)
    )
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)
    let infoRequest = RuntimeInfoRequest(resources: true, displays: false)
    let patch = ConfigurationPatch(
        patch: .object(["runtime": .object(["memoryGiB": .integer(8)])])
    )

    #expect(try await client.runtimeInfo(infoRequest) == info)
    #expect(try await client.listSessions() == sessions)
    #expect(try await client.configuration() == resolved)
    #expect(try await client.updateConfiguration(patch) == updated)

    let snapshot = transport.snapshot()
    #expect(snapshot.runtimeInfoRequests.count == 1)
    #expect(snapshot.listSessionsRequests.count == 1)
    #expect(snapshot.configurationRequests.count == 1)
    #expect(snapshot.updateConfigurationRequests.count == 1)
    let runtimeInfoRequest = try JSONDecoder().decode(
        RuntimeInfoControlRequest.self,
        from: snapshot.runtimeInfoRequests[0]
    )
    let listSessionsRequest = try JSONDecoder().decode(
        RuntimeListSessionsControlRequest.self,
        from: snapshot.listSessionsRequests[0]
    )
    let configurationRequest = try JSONDecoder().decode(
        RuntimeConfigurationControlRequest.self,
        from: snapshot.configurationRequests[0]
    )
    let updateRequest = try JSONDecoder().decode(
        RuntimeUpdateConfigurationControlRequest.self,
        from: snapshot.updateConfigurationRequests[0]
    )
    #expect(runtimeInfoRequest.header.apiVersion == APIVersion.current)
    #expect(runtimeInfoRequest.header.clientKind == .cli)
    #expect(runtimeInfoRequest.request == infoRequest)
    #expect(listSessionsRequest.header.clientKind == .cli)
    #expect(configurationRequest.header.clientKind == .cli)
    #expect(updateRequest.header.clientKind == .cli)
    #expect(updateRequest.request == patch)
}

@Test func controlClientMapsTypedErrorsAndInvalidatesAfterTransportFailure() async throws {
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
    let failure = RuntimeWireError.runtime(
        "hostUnavailable",
        message: "The runtime service is unavailable.",
        remediation: "Open APKRun and retry."
    )
    let transport = try MockRuntimeTransport(
        hello: hello,
        status: status,
        runtimeInfoReply: RuntimeInfoControlReply(error: failure),
        listSessionsReply: RuntimeListSessionsControlReply(error: failure),
        configurationReply: RuntimeConfigurationControlReply(error: failure),
        updateConfigurationReply: RuntimeUpdateConfigurationControlReply(error: failure)
    )
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)

    for operation in 0..<4 {
        do {
            switch operation {
            case 0:
                _ = try await client.runtimeInfo()
            case 1:
                _ = try await client.listSessions()
            case 2:
                _ = try await client.configuration()
            default:
                _ = try await client.updateConfiguration(ConfigurationPatch(patch: .object([:])))
            }
            Issue.record("The control endpoint's typed failure was not returned to the caller.")
        } catch {
            #expect(error == .remoteFailure(code: failure.code, message: failure.message))
        }
    }
    #expect(transport.snapshot().controlConnections == 1)

    transport.failNextRuntimeInfo()
    do {
        _ = try await client.runtimeInfo()
        Issue.record("The mock runtimeInfo transport failure was not returned to the caller.")
    } catch {
        #expect(error == .transportFailure(domain: "NSCocoaErrorDomain", code: 4099))
    }
    #expect(transport.snapshot().controlConnections == 1)

    do {
        _ = try await client.runtimeInfo()
        Issue.record("The mock typed error was not returned after reconnecting.")
    } catch {
        #expect(error == .remoteFailure(code: failure.code, message: failure.message))
    }
    #expect(transport.snapshot().controlConnections == 2)
}

@Test func controlClientSubscribesToOperationEventsAndDeliversEnvelopes() async throws {
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
    let stream = try await client.subscribe(to: .operations)

    let operationID = OperationID()
    let envelope = EventEnvelope(
        topic: .operations,
        seq: 1,
        time: Date(timeIntervalSince1970: 1_800_000_001),
        operationID: operationID,
        payload: .operations(.progress(operationID, OperationProgress(stage: "installing")))
    )
    let eventTask = Task { () -> EventEnvelope? in
        for await event in stream {
            return event
        }
        return nil
    }
    try transport.deliver([envelope])
    #expect(await eventTask.value == envelope)

    let snapshot = transport.snapshot()
    #expect(snapshot.subscribeRequests.count == 1)
    let request = try JSONDecoder().decode(
        RuntimeSubscribeControlRequest.self,
        from: snapshot.subscribeRequests[0]
    )
    #expect(request.topics == [.operations])
}

@Test func controlClientReplaysEventSubscriptionsAfterConnectionInterruption() async throws {
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
    let stream = try await client.subscribe(to: .operations)
    let eventTask = Task { () -> [EventEnvelope] in
        var received: [EventEnvelope] = []
        for await event in stream {
            received.append(event)
            if received.count == 2 {
                break
            }
        }
        return received
    }

    transport.interruptControlConnection()
    for _ in 0..<100 {
        let snapshot = transport.snapshot()
        if snapshot.controlConnections >= 2 && snapshot.subscribeRequests.count >= 2 {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    let reconnected = transport.snapshot()
    #expect(reconnected.controlConnections >= 2)
    #expect(reconnected.subscribeRequests.count == 2)

    let operationID = OperationID()
    let envelope = EventEnvelope(
        topic: .operations,
        seq: 1,
        time: Date(timeIntervalSince1970: 1_800_000_002),
        operationID: operationID,
        payload: .operations(
            .started(
                OperationSnapshot(
                    operationID: operationID,
                    kind: .install,
                    startedAt: Date(timeIntervalSince1970: 1_800_000_002)
                )
            ))
    )
    try transport.deliver([envelope])
    let received = await eventTask.value
    #expect(received.count == 2)
    #expect(received[0].seq == 0)
    #expect(received[0].payload == .resyncRequired(.operations))
    #expect(received[1] == envelope)
}

@Test func eventStreamHubBoundsBuffersAndSignalsResyncAfterOverflow() async {
    let hub = RuntimeEventStreamHub()
    let stream = hub.makeStream(for: .operations, onTermination: { _ in }).stream
    let operationID = OperationID()
    let timestamp = Date(timeIntervalSince1970: 1_800_000_003)
    let events = (1...1_100).map { sequence in
        EventEnvelope(
            topic: .operations,
            seq: UInt64(sequence),
            time: timestamp,
            operationID: operationID,
            payload: .operations(
                .progress(operationID, OperationProgress(stage: "installing"))
            )
        )
    }

    hub.deliver(events)

    var iterator = stream.makeAsyncIterator()
    var received: [EventEnvelope] = []
    for _ in 0..<1_024 {
        guard let event = await iterator.next() else { break }
        received.append(event)
    }
    #expect(received.count == 1_024)
    #expect(
        received.contains {
            $0.seq == 0 && $0.payload == .resyncRequired(.operations)
        })
}

@Test func eventSinkAcknowledgesMalformedBatchesAndSignalsResync() async {
    let hub = RuntimeEventStreamHub()
    let stream = hub.makeStream(for: .operations, onTermination: { _ in }).stream
    let receiver = RuntimeEventSinkReceiver(streamHub: hub)
    await withCheckedContinuation { continuation in
        receiver.deliver(Data("not-json".utf8)) {
            continuation.resume()
        }
    }

    var iterator = stream.makeAsyncIterator()
    let marker = await iterator.next()
    #expect(marker?.seq == 0)
    #expect(marker?.payload == .resyncRequired(.operations))
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

@Test func controlClientPreservesCallerCancellationSeparatelyFromTimeout() async throws {
    let configuration = try RuntimeControlClientConfiguration(
        clientKind: .cli,
        claimedIdentity: "io.apkrun.cli.dev",
        buildIdentity: .development,
        restartRequestTimeout: .seconds(5)
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
    transport.delayNextRestart(for: .seconds(1))
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)
    let restart = Task {
        try await client.restartRuntime()
    }

    for _ in 0..<1_000 {
        if transport.snapshot().restartRequests.count == 1 {
            break
        }
        await Task.yield()
    }
    #expect(transport.snapshot().restartRequests.count == 1)
    restart.cancel()

    do {
        _ = try await restart.value
        Issue.record("The cancelled restart wait unexpectedly succeeded.")
    } catch {
        let clientError = error as? RuntimeControlClientError
        #expect(clientError == .requestCancelled(operation: "runtimeRestart"))
    }
    #expect(transport.snapshot().restartRequests.count == 1)
    #expect(transport.snapshot().controlConnections == 1)

    _ = try await client.runtimeStatus()
    #expect(transport.snapshot().controlConnections == 2)
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

@Test func controlClientImportsAndInstallsPackageThroughVersionedRequests() async throws {
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
    let ticket = try #require(RuntimeImportTicket(rawValue: "84cfd2a0-504c-4dc2-9d6f-0f579f771902"))
    let preview = RuntimeImportPreview(
        ticket: ticket,
        packageID: packageID,
        displayName: "Hello Text",
        versionCode: 7,
        files: [],
        relation: .newPackage
    )
    let summary = RuntimePackageSummary(packageID: packageID, displayName: "Hello Text", versionCode: 7)
    let transport = try MockRuntimeTransport(
        hello: hello,
        status: nil,
        importReply: RuntimeImportPackageControlReply(result: preview),
        installImportedReply: RuntimeInstallImportedControlReply(result: summary)
    )
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)
    let file = try #require(FileHandle(forReadingAtPath: "/dev/null"))
    defer { try? file.close() }
    let importRequest = RuntimeImportPackageRequest(
        files: [RuntimeImportSourceFile(fileIndex: 0, name: "hello.apk")],
        origin: .cli
    )
    let installRequest = RuntimeInstallImportedRequest(ticket: ticket)

    #expect(try await client.importPackage(importRequest, files: [file]) == preview)
    #expect(try await client.installImported(installRequest) == summary)

    let snapshot = transport.snapshot()
    #expect(snapshot.importRequests.count == 1)
    #expect(snapshot.importFileHandleIDs == [[ObjectIdentifier(file)]])
    #expect(snapshot.installImportedRequests.count == 1)
    let decodedImport = try JSONDecoder().decode(
        RuntimeImportPackageControlRequest.self,
        from: snapshot.importRequests[0]
    )
    let decodedInstall = try JSONDecoder().decode(
        RuntimeInstallImportedControlRequest.self,
        from: snapshot.installImportedRequests[0]
    )
    #expect(decodedImport.request == importRequest)
    #expect(decodedInstall.request == installRequest)
    for header in [decodedImport.header, decodedInstall.header] {
        #expect(header.apiVersion == APIVersion.current)
        #expect(header.clientKind == .cli)
    }
}

@Test func controlClientBeginsAndTracksInstallOperationsWithVersionedRequests() async throws {
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
    let operationID = try #require(OperationID(wire: "b4a90e78-5e1f-4d5a-9ba1-0b691f180032"))
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let ticket = try #require(RuntimeImportTicket(rawValue: "84cfd2a0-504c-4dc2-9d6f-0f579f771902"))
    let request = RuntimeInstallImportedRequest(ticket: ticket)
    let handle = OperationHandle(operationID: operationID, kind: .install)
    let snapshot = OperationSnapshot(
        operationID: operationID,
        kind: .install,
        packageID: packageID,
        clientKind: .cli,
        startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        progress: OperationProgress(fraction: 0.5, stage: "installing"),
        result: nil
    )
    let transport = try MockRuntimeTransport(
        hello: hello,
        status: nil,
        beginInstallImportedReply: RuntimeBeginInstallImportedControlReply(result: handle),
        operationStatusReply: RuntimeOperationStatusControlReply(result: snapshot),
        listOperationsReply: RuntimeListOperationsControlReply(result: [snapshot]),
        cancelOperationReply: RuntimeCancelOperationControlReply(result: .cancelling)
    )
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)

    #expect(try await client.beginInstallImported(request, operationID: operationID) == handle)
    #expect(try await client.operationStatus(operationID) == snapshot)
    #expect(try await client.listOperations() == [snapshot])
    #expect(try await client.cancelOperation(operationID) == .cancelling)

    let requests = transport.snapshot()
    #expect(requests.beginInstallImportedRequests.count == 1)
    #expect(requests.operationStatusRequests.count == 1)
    #expect(requests.listOperationsRequests.count == 1)
    #expect(requests.cancelOperationRequests.count == 1)
    let begin = try JSONDecoder().decode(
        RuntimeBeginInstallImportedControlRequest.self,
        from: requests.beginInstallImportedRequests[0]
    )
    #expect(begin.header.operationID == operationID.rawValue)
    #expect(begin.header.apiVersion == APIVersion.current)
    #expect(begin.header.clientKind == .cli)
    #expect(begin.request == request)

    let statusRequest = try JSONDecoder().decode(
        RuntimeOperationStatusControlRequest.self,
        from: requests.operationStatusRequests[0]
    )
    #expect(statusRequest.operationID == operationID)
    #expect(statusRequest.header.apiVersion == APIVersion.current)
    let listRequest = try JSONDecoder().decode(
        RuntimeListOperationsControlRequest.self,
        from: requests.listOperationsRequests[0]
    )
    #expect(listRequest.header.apiVersion == APIVersion.current)
    let cancelRequest = try JSONDecoder().decode(
        RuntimeCancelOperationControlRequest.self,
        from: requests.cancelOperationRequests[0]
    )
    #expect(cancelRequest.operationID == operationID)
    #expect(cancelRequest.header.apiVersion == APIVersion.current)
}

@Test func controlClientBeginsAndRecoversUninstallOperationsWithoutReplay() async throws {
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
    let operationID = try #require(OperationID(wire: "b4a90e78-5e1f-4d5a-9ba1-0b691f180032"))
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let request = RuntimeUninstallPackageRequest(
        packageID: packageID,
        options: RuntimeUninstallOptions(keepData: true)
    )
    let handle = OperationHandle(operationID: operationID, kind: .uninstall)
    let snapshot = OperationSnapshot(
        operationID: operationID,
        kind: .uninstall,
        packageID: packageID,
        requestFingerprint: try RuntimeOperationRequestFingerprint.make(for: request),
        clientKind: .cli,
        startedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let transport = try MockRuntimeTransport(
        hello: hello,
        status: nil,
        beginUninstallPackageReply: RuntimeBeginUninstallPackageControlReply(result: handle),
        operationStatusReply: RuntimeOperationStatusControlReply(result: snapshot)
    )
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)

    #expect(try await client.beginUninstallPackage(request, operationID: operationID) == handle)
    transport.failNextBeginUninstallPackage()
    #expect(try await client.beginUninstallPackage(request, operationID: operationID) == handle)

    let requests = transport.snapshot()
    #expect(requests.beginUninstallPackageRequests.count == 2)
    #expect(requests.operationStatusRequests.count == 1)
    let begin = try JSONDecoder().decode(
        RuntimeBeginUninstallPackageControlRequest.self,
        from: requests.beginUninstallPackageRequests[0]
    )
    #expect(begin.header.operationID == operationID.rawValue)
    #expect(begin.header.apiVersion == APIVersion.current)
    #expect(begin.header.clientKind == .cli)
    #expect(begin.request == request)
    let statusRequest = try JSONDecoder().decode(
        RuntimeOperationStatusControlRequest.self,
        from: requests.operationStatusRequests[0]
    )
    #expect(statusRequest.operationID == operationID)
}

@Test func controlClientReconcilesAmbiguousBeginWithoutReplayingIt() async throws {
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
    let operationID = try #require(OperationID(wire: "b4a90e78-5e1f-4d5a-9ba1-0b691f180032"))
    let ticket = try #require(RuntimeImportTicket(rawValue: "84cfd2a0-504c-4dc2-9d6f-0f579f771902"))
    let request = RuntimeInstallImportedRequest(ticket: ticket)
    let snapshot = OperationSnapshot(
        operationID: operationID,
        kind: .install,
        packageID: RuntimePackageID(rawValue: "com.example.app"),
        requestFingerprint: try RuntimeOperationRequestFingerprint.make(for: request),
        startedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let transport = try MockRuntimeTransport(
        hello: hello,
        status: nil,
        operationStatusReply: RuntimeOperationStatusControlReply(result: snapshot)
    )
    transport.failNextBeginInstallImported()
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)

    let handle = try await client.beginInstallImported(request, operationID: operationID)

    #expect(handle == OperationHandle(operationID: operationID, kind: .install))
    let requests = transport.snapshot()
    #expect(requests.beginInstallImportedRequests.count == 1)
    #expect(requests.operationStatusRequests.count == 1)
    #expect(requests.controlConnections == 2)
    let statusRequest = try JSONDecoder().decode(
        RuntimeOperationStatusControlRequest.self,
        from: requests.operationStatusRequests[0]
    )
    #expect(statusRequest.operationID == operationID)
}

@Test func controlClientDoesNotRecoverAnUninstallWithDifferentOptions() async throws {
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
    let operationID = try #require(OperationID(wire: "b4a90e78-5e1f-4d5a-9ba1-0b691f180032"))
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let requested = RuntimeUninstallPackageRequest(
        packageID: packageID,
        options: RuntimeUninstallOptions(keepData: false)
    )
    let existing = RuntimeUninstallPackageRequest(
        packageID: packageID,
        options: RuntimeUninstallOptions(keepData: true)
    )
    let snapshot = OperationSnapshot(
        operationID: operationID,
        kind: .uninstall,
        packageID: packageID,
        requestFingerprint: try RuntimeOperationRequestFingerprint.make(for: existing),
        startedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let transport = try MockRuntimeTransport(
        hello: hello,
        status: nil,
        operationStatusReply: RuntimeOperationStatusControlReply(result: snapshot)
    )
    transport.failNextBeginUninstallPackage()
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)

    do {
        _ = try await client.beginUninstallPackage(requested, operationID: operationID)
        Issue.record("A status for a different keep-data policy was accepted as the requested operation.")
    } catch {
        #expect(error == .operationResultUnknown(operation: "beginUninstallPackage"))
    }

    let requests = transport.snapshot()
    #expect(requests.beginUninstallPackageRequests.count == 1)
    #expect(requests.operationStatusRequests.count == 1)
}

@Test func controlClientReconcilesMalformedBeginReplyWithoutReplayingIt() async throws {
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
    let operationID = try #require(OperationID(wire: "b4a90e78-5e1f-4d5a-9ba1-0b691f180032"))
    let ticket = try #require(RuntimeImportTicket(rawValue: "84cfd2a0-504c-4dc2-9d6f-0f579f771902"))
    let request = RuntimeInstallImportedRequest(ticket: ticket)
    let snapshot = OperationSnapshot(
        operationID: operationID,
        kind: .install,
        packageID: RuntimePackageID(rawValue: "com.example.app"),
        requestFingerprint: try RuntimeOperationRequestFingerprint.make(for: request),
        startedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let transport = try MockRuntimeTransport(
        hello: hello,
        status: nil,
        operationStatusReply: RuntimeOperationStatusControlReply(result: snapshot),
        beginInstallImportedReplyData: Data("not-json".utf8)
    )
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)

    let handle = try await client.beginInstallImported(request, operationID: operationID)

    #expect(handle.operationID == operationID)
    let requests = transport.snapshot()
    #expect(requests.beginInstallImportedRequests.count == 1)
    #expect(requests.operationStatusRequests.count == 1)
    #expect(requests.controlConnections == 2)
}

@Test func controlClientReportsUnknownWhenAmbiguousBeginCannotBeFound() async throws {
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
    let operationID = try #require(OperationID(wire: "b4a90e78-5e1f-4d5a-9ba1-0b691f180032"))
    let notFound = RuntimeWireError.runtime("operationNotFound", message: "Operation not found.")
    let transport = try MockRuntimeTransport(
        hello: hello,
        status: nil,
        operationStatusReply: RuntimeOperationStatusControlReply(error: notFound)
    )
    transport.failNextBeginInstallImported()
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)
    let ticket = try #require(RuntimeImportTicket(rawValue: "84cfd2a0-504c-4dc2-9d6f-0f579f771902"))

    do {
        _ = try await client.beginInstallImported(
            RuntimeInstallImportedRequest(ticket: ticket),
            operationID: operationID
        )
        Issue.record("The missing operation was treated as a confirmed begin result.")
    } catch {
        #expect(error == .operationResultUnknown(operation: "beginInstallImported"))
    }

    let requests = transport.snapshot()
    #expect(requests.beginInstallImportedRequests.count == 1)
    #expect(requests.operationStatusRequests.count == 1)
    #expect(requests.controlConnections == 2)
}

@Test func controlClientReportsUnknownWhenAmbiguousBeginStatusTransportFails() async throws {
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
    let operationID = try #require(OperationID(wire: "b4a90e78-5e1f-4d5a-9ba1-0b691f180032"))
    let snapshot = OperationSnapshot(
        operationID: operationID,
        kind: .install,
        startedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let transport = try MockRuntimeTransport(
        hello: hello,
        status: nil,
        operationStatusReply: RuntimeOperationStatusControlReply(result: snapshot)
    )
    transport.failNextBeginInstallImported()
    transport.failNextOperationStatus()
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)
    let ticket = try #require(RuntimeImportTicket(rawValue: "84cfd2a0-504c-4dc2-9d6f-0f579f771902"))

    do {
        _ = try await client.beginInstallImported(
            RuntimeInstallImportedRequest(ticket: ticket),
            operationID: operationID
        )
        Issue.record("A failed status query was treated as a confirmed begin result.")
    } catch {
        #expect(error == .operationResultUnknown(operation: "beginInstallImported"))
    }

    let requests = transport.snapshot()
    #expect(requests.beginInstallImportedRequests.count == 1)
    #expect(requests.operationStatusRequests.count == 1)
    #expect(requests.controlConnections == 2)
}

@Test func controlClientPreservesTypedInstallErrorsAndDoesNotReplay() async throws {
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
    let ticket = try #require(RuntimeImportTicket(rawValue: "84cfd2a0-504c-4dc2-9d6f-0f579f771902"))
    let failure = RuntimeWireError.store(
        "installFailed",
        message: "Android could not install this package.",
        remediation: "Check the Android runtime and retry."
    )
    let transport = try MockRuntimeTransport(
        hello: hello,
        status: nil,
        installImportedReply: RuntimeInstallImportedControlReply(error: failure)
    )
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)

    do {
        _ = try await client.installImported(RuntimeInstallImportedRequest(ticket: ticket))
        Issue.record("The daemon install error was not returned to the caller.")
    } catch {
        #expect(error == .remoteFailure(code: failure.code, message: failure.message))
    }
    #expect(transport.snapshot().installImportedRequests.count == 1)

    transport.failNextInstallImported()
    do {
        _ = try await client.installImported(RuntimeInstallImportedRequest(ticket: ticket))
        Issue.record("The simulated install transport failure was not returned to the caller.")
    } catch {
        #expect(error == .operationResultUnknown(operation: "installImported"))
    }
    let snapshot = transport.snapshot()
    #expect(snapshot.installImportedRequests.count == 2)
}

@Test func controlClientReportsMalformedInstallReplyAsUnknownOutcome() async throws {
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
    let malformedReply = try JSONDecoder().decode(
        RuntimeInstallImportedControlReply.self,
        from: Data("{}".utf8)
    )
    let transport = try MockRuntimeTransport(
        hello: hello,
        status: nil,
        installImportedReply: malformedReply
    )
    let client = RuntimeControlClient(configuration: configuration, connectionFactory: transport)
    let ticket = try #require(RuntimeImportTicket(rawValue: "84cfd2a0-504c-4dc2-9d6f-0f579f771902"))

    do {
        _ = try await client.installImported(RuntimeInstallImportedRequest(ticket: ticket))
        Issue.record("A reply without a result or error must not look successful.")
    } catch {
        #expect(error == .operationResultUnknown(operation: "installImported"))
    }
    #expect(transport.snapshot().installImportedRequests.count == 1)
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
    private let runtimeInfoData: Data
    private let listSessionsData: Data
    private let configurationData: Data
    private let updateConfigurationData: Data
    private let packageListData: Data
    private let packageInfoData: Data
    private let importPackageData: Data
    private let installImportedData: Data
    private let beginInstallImportedData: Data
    private let beginUninstallPackageData: Data
    private let operationStatusData: Data
    private let listOperationsData: Data
    private let cancelOperationData: Data
    private let launchData: Data
    private let terminateData: Data
    private let lock = NSLock()
    private var serviceNameValue: String?
    private var brokerRequirementValue: String?
    private var controlRequirementValue: String?
    private var helloRequestsValue: [Data] = []
    private var endpointRequestsValue: [Data] = []
    private var statusRequestsValue: [Data] = []
    private var runtimeInfoRequestsValue: [Data] = []
    private var listSessionsRequestsValue: [Data] = []
    private var configurationRequestsValue: [Data] = []
    private var updateConfigurationRequestsValue: [Data] = []
    private var startRequestsValue: [Data] = []
    private var stopRequestsValue: [Data] = []
    private var restartRequestsValue: [Data] = []
    private var packageListRequestsValue: [Data] = []
    private var packageInfoRequestsValue: [Data] = []
    private var importPackageRequestsValue: [Data] = []
    private var importFileHandleIDsValue: [[ObjectIdentifier]] = []
    private var installImportedRequestsValue: [Data] = []
    private var beginInstallImportedRequestsValue: [Data] = []
    private var beginUninstallPackageRequestsValue: [Data] = []
    private var operationStatusRequestsValue: [Data] = []
    private var listOperationsRequestsValue: [Data] = []
    private var cancelOperationRequestsValue: [Data] = []
    private var subscribeRequestsValue: [Data] = []
    private var unsubscribeRequestsValue: [Data] = []
    private var launchRequestsValue: [Data] = []
    private var terminateRequestsValue: [Data] = []
    private var resetRequestsValue: [Data] = []
    private var brokerConnectionsValue = 0
    private var controlConnectionsValue = 0
    private var brokerInvalidationsValue = 0
    private var failNextStatusValue = false
    private var failNextRuntimeInfoValue = false
    private var failNextLaunchValue = false
    private var failNextTerminateValue = false
    private var failNextRestartValue = false
    private var restartDelayValue: Duration?
    private var failNextResetValue = false
    private var failNextInstallImportedValue = false
    private var failNextBeginInstallImportedValue = false
    private var failNextBeginUninstallPackageValue = false
    private var failNextOperationStatusValue = false
    private var endpointBusyRejectionsValue: Int
    private var eventSinkValue: RuntimeEventSinkReceiver?
    private var connectionEventHandlerValue: (@Sendable () -> Void)?

    init(
        hello: RuntimeHelloReply,
        status: RuntimeHostStatus?,
        endpointRejection: RuntimeEndpointRejection? = nil,
        endpointBusyRejections: Int = 0,
        helloFailure: RuntimeControlError? = nil,
        packageListReply: RuntimeListPackagesControlReply? = nil,
        packageInfoReply: RuntimePackageInfoControlReply? = nil,
        importReply: RuntimeImportPackageControlReply? = nil,
        installImportedReply: RuntimeInstallImportedControlReply? = nil,
        beginInstallImportedReply: RuntimeBeginInstallImportedControlReply? = nil,
        beginUninstallPackageReply: RuntimeBeginUninstallPackageControlReply? = nil,
        operationStatusReply: RuntimeOperationStatusControlReply? = nil,
        listOperationsReply: RuntimeListOperationsControlReply? = nil,
        cancelOperationReply: RuntimeCancelOperationControlReply? = nil,
        beginInstallImportedReplyData: Data? = nil,
        launchReply: RuntimeLaunchControlReply? = nil,
        terminateReply: RuntimeTerminateControlReply? = nil,
        runtimeInfoReply: RuntimeInfoControlReply? = nil,
        listSessionsReply: RuntimeListSessionsControlReply? = nil,
        configurationReply: RuntimeConfigurationControlReply? = nil,
        updateConfigurationReply: RuntimeUpdateConfigurationControlReply? = nil
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
        let defaultStatus =
            status
            ?? RuntimeHostStatus(
                hostState: "running",
                runtimeState: "ready",
                bootProgress: nil,
                startupFailureStep: nil,
                startupFailureCode: nil,
                crashLoopActive: false,
                daemonPID: 42,
                imageVersion: "test-image"
            )
        if let status {
            statusData = try JSONEncoder().encode(RuntimeControlReply(status: status))
        } else {
            statusData = try JSONEncoder().encode(
                RuntimeControlReply(error: RuntimeControlError(code: "runtime.test", message: "test failure"))
            )
        }
        let defaultRuntimeInfo = RuntimeInfo(
            status: defaultStatus,
            sizing: RuntimeSizing(cpuCount: 4, memoryGiB: 6, userdataGiB: 32),
            displayPoolSize: 3
        )
        runtimeInfoData = try JSONEncoder().encode(
            runtimeInfoReply ?? RuntimeInfoControlReply(result: defaultRuntimeInfo)
        )
        listSessionsData = try JSONEncoder().encode(
            listSessionsReply ?? RuntimeListSessionsControlReply(result: [])
        )
        let defaultConfiguration = ConfigurationSnapshot(entries: [])
        configurationData = try JSONEncoder().encode(
            configurationReply ?? RuntimeConfigurationControlReply(result: defaultConfiguration)
        )
        updateConfigurationData = try JSONEncoder().encode(
            updateConfigurationReply ?? RuntimeUpdateConfigurationControlReply(result: defaultConfiguration)
        )
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
        let defaultImportReply = RuntimeImportPackageControlReply(
            result: RuntimeImportPreview(
                ticket: RuntimeImportTicket(rawValue: "84cfd2a0-504c-4dc2-9d6f-0f579f771902")!,
                packageID: packageID,
                displayName: "Example",
                versionCode: 1,
                files: [],
                relation: .newPackage
            )
        )
        let defaultInstallImportedReply = RuntimeInstallImportedControlReply(result: defaultSummary)
        let defaultOperationID = try #require(OperationID(wire: "b4a90e78-5e1f-4d5a-9ba1-0b691f180032"))
        let defaultOperationHandle = OperationHandle(operationID: defaultOperationID, kind: .install)
        let defaultUninstallOperationHandle = OperationHandle(operationID: defaultOperationID, kind: .uninstall)
        let defaultOperationSnapshot = OperationSnapshot(
            operationID: defaultOperationID,
            kind: .install,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000)
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
        importPackageData = try JSONEncoder().encode(importReply ?? defaultImportReply)
        installImportedData = try JSONEncoder().encode(installImportedReply ?? defaultInstallImportedReply)
        beginInstallImportedData =
            try beginInstallImportedReplyData
            ?? JSONEncoder().encode(
                beginInstallImportedReply
                    ?? RuntimeBeginInstallImportedControlReply(
                        result: defaultOperationHandle
                    ))
        beginUninstallPackageData = try JSONEncoder().encode(
            beginUninstallPackageReply
                ?? RuntimeBeginUninstallPackageControlReply(result: defaultUninstallOperationHandle)
        )
        operationStatusData = try JSONEncoder().encode(
            operationStatusReply ?? RuntimeOperationStatusControlReply(result: defaultOperationSnapshot)
        )
        listOperationsData = try JSONEncoder().encode(
            listOperationsReply ?? RuntimeListOperationsControlReply(result: [])
        )
        cancelOperationData = try JSONEncoder().encode(
            cancelOperationReply ?? RuntimeCancelOperationControlReply(result: .cancelling)
        )
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
        signingRequirement: String,
        eventSink: RuntimeEventSinkReceiver
    ) throws(RuntimeControlClientError) -> any RuntimeControlChannel {
        guard endpoint.value is NSObject else {
            throw .malformedReply
        }
        lock.withLock {
            controlRequirementValue = signingRequirement
            controlConnectionsValue += 1
            eventSinkValue = eventSink
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

    func runtimeInfo(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        let shouldFail = lock.withLock {
            runtimeInfoRequestsValue.append(request)
            defer { failNextRuntimeInfoValue = false }
            return failNextRuntimeInfoValue
        }
        if shouldFail {
            throw .transportFailure(domain: "NSCocoaErrorDomain", code: 4099)
        }
        return runtimeInfoData
    }

    func listSessions(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        lock.withLock { listSessionsRequestsValue.append(request) }
        return listSessionsData
    }

    func configuration(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        lock.withLock { configurationRequestsValue.append(request) }
        return configurationData
    }

    func updateConfiguration(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        lock.withLock { updateConfigurationRequestsValue.append(request) }
        return updateConfigurationData
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

    func importPackage(
        _ request: Data,
        files: [FileHandle]
    ) async throws(RuntimeControlClientError) -> Data {
        lock.withLock {
            importPackageRequestsValue.append(request)
            importFileHandleIDsValue.append(files.map(ObjectIdentifier.init))
        }
        return importPackageData
    }

    func installImported(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        let shouldFail = lock.withLock {
            installImportedRequestsValue.append(request)
            defer { failNextInstallImportedValue = false }
            return failNextInstallImportedValue
        }
        if shouldFail {
            throw .transportFailure(domain: "NSCocoaErrorDomain", code: 4099)
        }
        return installImportedData
    }

    func beginInstallImported(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        let shouldFail = lock.withLock {
            beginInstallImportedRequestsValue.append(request)
            defer { failNextBeginInstallImportedValue = false }
            return failNextBeginInstallImportedValue
        }
        if shouldFail {
            throw .transportFailure(domain: "NSCocoaErrorDomain", code: 4099)
        }
        return beginInstallImportedData
    }

    func beginUninstallPackage(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        let shouldFail = lock.withLock {
            beginUninstallPackageRequestsValue.append(request)
            defer { failNextBeginUninstallPackageValue = false }
            return failNextBeginUninstallPackageValue
        }
        if shouldFail {
            throw .transportFailure(domain: "NSCocoaErrorDomain", code: 4099)
        }
        return beginUninstallPackageData
    }

    func operationStatus(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        let shouldFail = lock.withLock {
            operationStatusRequestsValue.append(request)
            defer { failNextOperationStatusValue = false }
            return failNextOperationStatusValue
        }
        if shouldFail {
            throw .transportFailure(domain: "NSCocoaErrorDomain", code: 4099)
        }
        return operationStatusData
    }

    func subscribe(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        lock.withLock { subscribeRequestsValue.append(request) }
        guard
            let subscription = try? JSONDecoder().decode(
                RuntimeSubscribeControlRequest.self,
                from: request
            )
        else {
            throw .malformedReply
        }
        do {
            return try JSONEncoder().encode(RuntimeSubscribeControlReply(result: subscription.topics))
        } catch {
            throw .encodingFailure
        }
    }

    func unsubscribe(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        lock.withLock { unsubscribeRequestsValue.append(request) }
        guard (try? JSONDecoder().decode(RuntimeUnsubscribeControlRequest.self, from: request)) != nil else {
            throw .malformedReply
        }
        do {
            return try JSONEncoder().encode(RuntimeUnsubscribeControlReply())
        } catch {
            throw .encodingFailure
        }
    }

    func setConnectionEventHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { connectionEventHandlerValue = handler }
    }

    func listOperations(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        lock.withLock { listOperationsRequestsValue.append(request) }
        return listOperationsData
    }

    func cancelOperation(_ request: Data) async throws(RuntimeControlClientError) -> Data {
        lock.withLock { cancelOperationRequestsValue.append(request) }
        return cancelOperationData
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
                runtimeInfoRequests: runtimeInfoRequestsValue,
                listSessionsRequests: listSessionsRequestsValue,
                configurationRequests: configurationRequestsValue,
                updateConfigurationRequests: updateConfigurationRequestsValue,
                startRequests: startRequestsValue,
                stopRequests: stopRequestsValue,
                restartRequests: restartRequestsValue,
                packageListRequests: packageListRequestsValue,
                packageInfoRequests: packageInfoRequestsValue,
                importRequests: importPackageRequestsValue,
                importFileHandleIDs: importFileHandleIDsValue,
                installImportedRequests: installImportedRequestsValue,
                beginInstallImportedRequests: beginInstallImportedRequestsValue,
                beginUninstallPackageRequests: beginUninstallPackageRequestsValue,
                operationStatusRequests: operationStatusRequestsValue,
                listOperationsRequests: listOperationsRequestsValue,
                cancelOperationRequests: cancelOperationRequestsValue,
                subscribeRequests: subscribeRequestsValue,
                unsubscribeRequests: unsubscribeRequestsValue,
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

    func failNextRuntimeInfo() {
        lock.withLock { failNextRuntimeInfoValue = true }
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

    func failNextInstallImported() {
        lock.withLock { failNextInstallImportedValue = true }
    }

    func failNextBeginInstallImported() {
        lock.withLock { failNextBeginInstallImportedValue = true }
    }

    func failNextBeginUninstallPackage() {
        lock.withLock { failNextBeginUninstallPackageValue = true }
    }

    func failNextOperationStatus() {
        lock.withLock { failNextOperationStatusValue = true }
    }

    func interruptControlConnection() {
        let handler = lock.withLock { connectionEventHandlerValue }
        handler?()
    }

    func deliver(_ envelopes: [EventEnvelope]) throws {
        let data = try JSONEncoder().encode(envelopes)
        let eventSink = lock.withLock { eventSinkValue }
        eventSink?.deliver(data) {}
    }

    struct Snapshot {
        let serviceName: String?
        let brokerRequirement: String?
        let controlRequirement: String?
        let helloRequests: [Data]
        let endpointRequests: [Data]
        let statusRequests: [Data]
        let runtimeInfoRequests: [Data]
        let listSessionsRequests: [Data]
        let configurationRequests: [Data]
        let updateConfigurationRequests: [Data]
        let startRequests: [Data]
        let stopRequests: [Data]
        let restartRequests: [Data]
        let packageListRequests: [Data]
        let packageInfoRequests: [Data]
        let importRequests: [Data]
        let importFileHandleIDs: [[ObjectIdentifier]]
        let installImportedRequests: [Data]
        let beginInstallImportedRequests: [Data]
        let beginUninstallPackageRequests: [Data]
        let operationStatusRequests: [Data]
        let listOperationsRequests: [Data]
        let cancelOperationRequests: [Data]
        let subscribeRequests: [Data]
        let unsubscribeRequests: [Data]
        let launchRequests: [Data]
        let terminateRequests: [Data]
        let resetRequests: [Data]
        let brokerConnections: Int
        let controlConnections: Int
        let brokerInvalidations: Int
    }
}
