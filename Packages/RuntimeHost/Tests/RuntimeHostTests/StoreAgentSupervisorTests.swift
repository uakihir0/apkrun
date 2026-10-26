import APKStoreCore
import Foundation
import GuestProtocol
import RuntimeCore
import Testing

@testable import RuntimeHost

@Test(.timeLimit(.minutes(1)))
func storeSupervisorNegotiatesCapabilitiesAndBindsArtifactSessionToControlToken() async throws {
    let transport = StoreTestTransport()
    let channel = StoreAgentSupervisor(transport: transport)
    let package = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))

    #expect(!channel.isConnected)
    #expect(channel.capabilities.isEmpty)

    let info = try await channel.packageInfo(package)
    #expect(info?.packageID == package)
    #expect(info?.versionCode == 7)
    #expect(info?.displayName == "Hello Text")
    #expect(info?.launchableComponent == "io.apkrun.fixture.hellotext/.MainActivity")
    #expect(info?.installerPackage == PackageID(rawValue: "io.apkrun.store"))
    #expect(info?.updateOwner == PackageID(rawValue: "io.apkrun.store"))
    #expect(info?.initiatingPackage == package)
    #expect(info?.signingLineage == [rawDigest(0xCD)])
    #expect(info?.signingSchemeVersion == 3)
    #expect(info?.splitNames == ["base", "config.arm64_v8a"])
    #expect(info?.nativeABIs == ["arm64-v8a"])
    #expect(info?.suspended == true)
    #expect(info?.requestedPermissionsCount == 4)
    #expect(channel.isConnected)
    #expect(channel.capabilities == [.install, .metadata, .inspect])
    let managedPackages = try await channel.listManagedPackages()
    #expect(managedPackages.map(\.packageID) == [package])
    let managedSnapshot = await transport.agent.snapshot()
    #expect(managedSnapshot.lastListFilter == .allUserInstalled)
    let packages = try await channel.listPackages(.launchable)
    #expect(packages.map(\.packageID) == [package])
    #expect(packages.allSatisfy { $0.launchable })

    let snapshot = managedSnapshot
    #expect(snapshot.endpoints == [.storeControl, .storeArtifacts])
    #expect(snapshot.artifactTokenMatched)

    await channel.close()
    #expect(!channel.isConnected)
}

@Test(.timeLimit(.minutes(1)))
func storeSupervisorKeepsControlConnectionAliveAndStopsPingsOnClose() async throws {
    let transport = StoreTestTransport()
    let channel = StoreAgentSupervisor(
        transport: transport,
        keepaliveInterval: .milliseconds(20)
    )
    let package = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))

    _ = try await channel.packageInfo(package)
    await transport.agent.waitForPingCount(1)
    #expect(await transport.agent.snapshot().pingRequests >= 1)

    await channel.close()
    await transport.agent.waitForControlClose()
    #expect(!channel.isConnected)
}

@Test(.timeLimit(.minutes(1)))
func storeSupervisorDisconnectsAndFailsInstallWaitersAfterThreeMissedPongs() async throws {
    let payload = Data("verified apk bytes".utf8)
    let file = try temporaryAPK(payload)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    let transport = StoreTestTransport(missedPongs: 3, sendInstallFinished: false)
    let channel = StoreAgentSupervisor(
        transport: transport,
        installOutcomeTimeout: .seconds(2),
        keepaliveInterval: .milliseconds(15)
    )
    let disconnection = Task {
        for await _ in channel.disconnectionEvents {
            return true
        }
        return false
    }
    let package = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let spec = StoreArtifactSpec(name: "base", size: UInt64(payload.count), sha256: SHA256Digest(data: payload))
    let install = Task {
        try await channel.install(
            StoreInstallRequest(
                packageID: package,
                versionCode: 7,
                expectedSignerDigests: [rawDigest(0xAB)],
                artifacts: [spec]
            ),
            files: [file]
        )
    }

    await transport.agent.waitForPingCount(3)
    await transport.agent.waitForControlClose()
    #expect(!channel.isConnected)
    #expect(await disconnection.value)
    await #expect(throws: StoreAgentSupervisorFailure.disconnected) {
        try await install.value
    }
    #expect(await transport.agent.snapshot().commitRequests == 1)
}

@Test(.timeLimit(.minutes(1)))
func storeSupervisorStreamsInspectionInOneMiBChunksAndAbortsOnDigestMismatch() async throws {
    let payload = Data(repeating: 0x6A, count: StoreAgentSupervisor.maximumChunkSize + 1)
    let file = try temporaryAPK(payload)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    let transport = StoreTestTransport()
    let channel = StoreAgentSupervisor(transport: transport)
    let goodSpec = StoreArtifactSpec(
        name: "base",
        size: UInt64(payload.count),
        sha256: SHA256Digest(data: payload)
    )
    let inspected = try await channel.inspect([goodSpec], files: [file])
    #expect(inspected.packageID.rawValue == "io.apkrun.fixture.hellotext")
    #expect(inspected.versionCode == 7)

    var wrongDigestBytes = Data(repeating: 0x11, count: 32)
    wrongDigestBytes[0] = 0x12
    let wrongSpec = StoreArtifactSpec(
        name: "base",
        size: UInt64(payload.count),
        sha256: SHA256Digest(data: wrongDigestBytes)
    )
    await #expect(throws: StoreAgentSupervisorFailure.artifactDigestMismatch("base")) {
        try await channel.inspect([wrongSpec], files: [file])
    }

    let snapshot = await transport.agent.snapshot()
    #expect(snapshot.transfers.count == 2)
    #expect(snapshot.transfers[0].context == "inspect")
    #expect(snapshot.transfers[0].chunkSizes == [StoreAgentSupervisor.maximumChunkSize, 1])
    #expect(snapshot.transfers[0].transferID.isMultiple(of: 2))
    #expect(snapshot.transfers[0].acknowledged)
    #expect(snapshot.transfers[1].context == "inspect")
    #expect(snapshot.transfers[1].aborted)
    #expect(snapshot.inspectRequests == 1)

    await channel.close()
}

@Test(.timeLimit(.minutes(1)))
func storeSupervisorInstallUsesInspectedIdentityAndRequiresSuccessfulMatchingOutcome() async throws {
    let payload = Data("verified apk bytes".utf8)
    let file = try temporaryAPK(payload)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    let transport = StoreTestTransport()
    let channel = StoreAgentSupervisor(transport: transport, installOutcomeTimeout: .milliseconds(250))
    let package = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let signer = rawDigest(0xAB)
    let spec = StoreArtifactSpec(name: "base", size: UInt64(payload.count), sha256: SHA256Digest(data: payload))
    let commitBoundary = InstallCommitBoundaryProbe()

    let installed = try await channel.install(
        StoreInstallRequest(
            packageID: package,
            versionCode: 7,
            mode: .update,
            expectedSignerDigests: [signer],
            artifacts: [spec]
        ),
        files: [file],
        beforeCommit: {
            await commitBoundary.record(await transport.agent.snapshot())
        }
    )

    #expect(installed.packageID == package)
    #expect(installed.versionCode == 7)
    #expect(installed.signingDigests == [signer])
    let boundarySnapshot = await commitBoundary.snapshot()
    #expect(boundarySnapshot?.commitRequests == 0)
    #expect(boundarySnapshot?.transfers.last?.context == "install-1")
    #expect(boundarySnapshot?.transfers.last?.acknowledged == true)
    let snapshot = await transport.agent.snapshot()
    #expect(snapshot.beginInstall?.expectedPackage == package.rawValue)
    #expect(snapshot.beginInstall?.expectedVersionCode == 7)
    #expect(snapshot.beginInstall?.expectedSignerSha256 == [Data(repeating: 0xAB, count: 32)])
    #expect(snapshot.beginInstall?.mode == .update)
    #expect(snapshot.beginInstall?.allowDowngrade == false)
    #expect(snapshot.beginInstall?.requestUpdateOwnership == false)
    #expect(snapshot.beginInstall?.enableRollback == false)
    #expect(snapshot.beginInstall?.installReason == 4)
    #expect(snapshot.beginInstall?.packageSource == 1)
    #expect(snapshot.beginInstall?.artifacts.map(\.name) == ["base"])
    #expect(snapshot.commitRequests == 1)
    #expect(snapshot.abandonRequests == 0)
    #expect(snapshot.transfers.map(\.context) == ["inspect", "install-1"])
    #expect(snapshot.transfers.map(\.acknowledged) == [true, true])

    await channel.close()
}

@Test(.timeLimit(.minutes(1)))
func storeSupervisorRefusesSignerMismatchBeforeBeginInstall() async throws {
    let payload = Data("verified apk bytes".utf8)
    let file = try temporaryAPK(payload)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    let transport = StoreTestTransport()
    let channel = StoreAgentSupervisor(transport: transport)
    let package = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let wrongSigner = rawDigest(0xEE)
    let spec = StoreArtifactSpec(name: "base", size: UInt64(payload.count), sha256: SHA256Digest(data: payload))

    await #expect(throws: StoreAgentSupervisorFailure.signerMismatch) {
        try await channel.install(
            StoreInstallRequest(
                packageID: package,
                versionCode: 7,
                expectedSignerDigests: [wrongSigner],
                artifacts: [spec]
            ),
            files: [file]
        )
    }
    let snapshot = await transport.agent.snapshot()
    #expect(snapshot.inspectRequests == 1)
    #expect(snapshot.beginInstall == nil)
    #expect(snapshot.commitRequests == 0)
    #expect(snapshot.abandonRequests == 0)
    await channel.close()
}

@Test(.timeLimit(.minutes(1)))
func storeSupervisorAbandonsInstallWhenArtifactAcknowledgementIsRejected() async throws {
    let payload = Data("verified apk bytes".utf8)
    let file = try temporaryAPK(payload)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    let transport = StoreTestTransport(rejectedBulkContext: "install-1")
    let channel = StoreAgentSupervisor(transport: transport)
    let package = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let spec = StoreArtifactSpec(name: "base", size: UInt64(payload.count), sha256: SHA256Digest(data: payload))

    await #expect(
        throws: StoreAgentSupervisorFailure.bulkTransferRejected(status: Int32(GPBulkAckStatus.rejected.rawValue))
    ) {
        try await channel.install(
            StoreInstallRequest(
                packageID: package,
                versionCode: 7,
                expectedSignerDigests: [rawDigest(0xAB)],
                artifacts: [spec]
            ),
            files: [file]
        )
    }

    let snapshot = await transport.agent.snapshot()
    #expect(snapshot.beginInstall != nil)
    #expect(snapshot.commitRequests == 0)
    #expect(snapshot.abandonRequests == 1)
    #expect(snapshot.transfers.map(\.context) == ["inspect", "install-1"])
    await channel.close()
}

@Test(.timeLimit(.minutes(1)))
func storeSupervisorUninstallsThroughPackageInstaller() async throws {
    let transport = StoreTestTransport()
    let channel = StoreAgentSupervisor(transport: transport)
    let package = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))

    try await channel.uninstall(package, keepData: true)

    let snapshot = await transport.agent.snapshot()
    #expect(snapshot.uninstallRequests == 1)
    #expect(snapshot.uninstallPackage == package.rawValue)
    #expect(snapshot.uninstallKeptData == true)
    await channel.close()
}

@Test(.timeLimit(.minutes(1)))
func storeSupervisorSelectsOperationsOnlyFromNegotiatedCapabilities() async throws {
    let payload = Data([0x42])
    let file = try temporaryAPK(payload)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    let transport = StoreTestTransport(capabilities: [GuestCapability.storeMetadata.rawValue])
    let channel = StoreAgentSupervisor(transport: transport)
    let package = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let spec = StoreArtifactSpec(name: "base", size: 1, sha256: SHA256Digest(data: payload))

    #expect(try await channel.packageInfo(package)?.packageID == package)
    #expect(channel.capabilities == [.metadata, .inspect])
    await #expect(
        throws: GuestProtocolFailure.capabilityMissing(capability: GuestCapability.storeInstall.rawValue)
    ) {
        try await channel.install(
            StoreInstallRequest(
                packageID: package,
                versionCode: 7,
                expectedSignerDigests: [rawDigest(0xAB)],
                artifacts: [spec]
            ),
            files: [file]
        )
    }
    let snapshot = await transport.agent.snapshot()
    #expect(snapshot.beginInstall == nil)
    #expect(snapshot.transfers.isEmpty)
    await channel.close()
}

@Test(.timeLimit(.minutes(1)))
func storeSupervisorAbandonsInstallWhenCommitBoundaryIsCancelled() async throws {
    let payload = Data("verified apk bytes".utf8)
    let file = try temporaryAPK(payload)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    let transport = StoreTestTransport()
    let channel = StoreAgentSupervisor(transport: transport)
    let package = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let spec = StoreArtifactSpec(name: "base", size: UInt64(payload.count), sha256: SHA256Digest(data: payload))

    await #expect(throws: InstallBoundaryTestFailure.cancelled) {
        try await channel.install(
            StoreInstallRequest(
                packageID: package,
                versionCode: 7,
                expectedSignerDigests: [rawDigest(0xAB)],
                artifacts: [spec]
            ),
            files: [file],
            beforeCommit: {
                throw InstallBoundaryTestFailure.cancelled
            }
        )
    }

    let snapshot = await transport.agent.snapshot()
    #expect(snapshot.transfers.map(\.context) == ["inspect", "install-1"])
    #expect(snapshot.transfers.filter { !$0.acknowledged }.isEmpty)
    #expect(snapshot.commitRequests == 0)
    #expect(snapshot.abandonRequests == 1)
    await channel.close()
}

@Test(.timeLimit(.minutes(1)))
func storeSupervisorRejectsAnInstallFinishedFailureAndSupportsLaunchableFilter() async throws {
    let payload = Data([0x43])
    let file = try temporaryAPK(payload)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    let transport = StoreTestTransport(finishedStatus: .conflict, finishedMessage: "signature conflict")
    let channel = StoreAgentSupervisor(transport: transport, installOutcomeTimeout: .milliseconds(250))
    let package = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let spec = StoreArtifactSpec(name: "base", size: 1, sha256: SHA256Digest(data: payload))

    await #expect(
        throws: StoreAgentSupervisorFailure.installFailed(
            status: Int32(GPInstallStatus.conflict.rawValue),
            legacyStatus: "INSTALL_FAILED_UPDATE_INCOMPATIBLE",
            message: "signature conflict"
        )
    ) {
        try await channel.install(
            StoreInstallRequest(
                packageID: package,
                versionCode: 7,
                expectedSignerDigests: [rawDigest(0xAB)],
                artifacts: [spec]
            ),
            files: [file]
        )
    }

    let launchablePackages = try await channel.listPackages(.launchable)
    #expect(launchablePackages.count == 1)
    #expect(launchablePackages[0].launchable)
    let snapshot = await transport.agent.snapshot()
    #expect(snapshot.commitRequests == 1)
    #expect(snapshot.metadataRequests == 0)
    await channel.close()
}

private func temporaryAPK(_ data: Data) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("base.apk")
    try data.write(to: file)
    return file
}

private func rawDigest(_ byte: UInt8) -> SHA256Digest {
    let hexByte = String(format: "%02x", byte)
    return SHA256Digest(hex: String(repeating: hexByte, count: 32))!
}

private enum InstallBoundaryTestFailure: Error, Equatable {
    case cancelled
}

private struct TransferObservation: Sendable {
    let transferID: UInt64
    let name: String
    let context: String
    let chunkSizes: [Int]
    let acknowledged: Bool
    let aborted: Bool
}

private struct StoreTestSnapshot: Sendable {
    let endpoints: [GuestEndpoint]
    let artifactTokenMatched: Bool
    let transfers: [TransferObservation]
    let inspectRequests: Int
    let beginInstall: GPInstallRequest?
    let commitRequests: Int
    let abandonRequests: Int
    let metadataRequests: Int
    let uninstallRequests: Int
    let uninstallPackage: String?
    let uninstallKeptData: Bool?
    let lastListFilter: GPManagedPackageFilter?
    let pingRequests: Int
}

private actor InstallCommitBoundaryProbe {
    private var recordedSnapshot: StoreTestSnapshot?

    func record(_ snapshot: StoreTestSnapshot) {
        recordedSnapshot = snapshot
    }

    func snapshot() -> StoreTestSnapshot? {
        recordedSnapshot
    }
}

private final class StoreTestTransport: RuntimeGuestTransport, @unchecked Sendable {
    let agent: StoreTestAgent

    init(
        capabilities: [String] = [
            GuestCapability.storeInstall.rawValue,
            GuestCapability.storeMetadata.rawValue,
        ],
        finishedStatus: GPInstallStatus = .success,
        finishedMessage: String = "",
        rejectedBulkContext: String? = nil,
        missedPongs: Int = 0,
        sendInstallFinished: Bool = true
    ) {
        var advertisedCapabilities = capabilities
        if !advertisedCapabilities.contains(GuestCapability.core.rawValue) {
            advertisedCapabilities.append(GuestCapability.core.rawValue)
        }
        agent = StoreTestAgent(
            capabilities: advertisedCapabilities,
            finishedStatus: finishedStatus,
            finishedMessage: finishedMessage,
            rejectedBulkContext: rejectedBulkContext,
            missedPongs: missedPongs,
            sendInstallFinished: sendInstallFinished
        )
    }

    func open(_ endpoint: RuntimeGuestEndpoint) async throws -> any RuntimeGuestByteStream {
        let guestEndpoint: GuestEndpoint
        switch endpoint {
        case .storeControl: guestEndpoint = .storeControl
        case .storeArtifacts: guestEndpoint = .storeArtifacts
        }
        return RuntimeTestByteStreamAdapter(stream: await agent.open(guestEndpoint))
    }
}

private struct RuntimeTestByteStreamAdapter: RuntimeGuestByteStream {
    let stream: any GuestByteStream

    func read() async throws -> Data? {
        try await stream.read()
    }

    func write(_ bytes: Data) async throws {
        try await stream.write(bytes)
    }

    func close() async {
        await stream.close()
    }
}

private actor StoreTestAgent {
    private struct ActiveTransfer {
        let transferID: UInt64
        let name: String
        let context: String
        var chunkSizes: [Int] = []
    }

    private let capabilities: [String]
    private let finishedStatus: GPInstallStatus
    private let finishedMessage: String
    private let rejectedBulkContext: String?
    private let missedPongs: Int
    private let sendInstallFinished: Bool
    private var controlToken: Data?
    private var artifactTokenMatched = false
    private var endpoints: [GuestEndpoint] = []
    private var transfers: [TransferObservation] = []
    private var activeTransfers: [UInt64: ActiveTransfer] = [:]
    private var inspectRequests = 0
    private var beginInstall: GPInstallRequest?
    private var commitRequests = 0
    private var abandonRequests = 0
    private var metadataRequests = 0
    private var uninstallRequests = 0
    private var uninstallPackage: String?
    private var uninstallKeptData: Bool?
    private var lastListFilter: GPManagedPackageFilter?
    private var pingRequests = 0
    private var pingWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var controlClosed = false
    private var controlCloseWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        capabilities: [String],
        finishedStatus: GPInstallStatus,
        finishedMessage: String,
        rejectedBulkContext: String?,
        missedPongs: Int,
        sendInstallFinished: Bool
    ) {
        self.capabilities = capabilities
        self.finishedStatus = finishedStatus
        self.finishedMessage = finishedMessage
        self.rejectedBulkContext = rejectedBulkContext
        self.missedPongs = missedPongs
        self.sendInstallFinished = sendInstallFinished
    }

    func open(_ endpoint: GuestEndpoint) -> any GuestByteStream {
        endpoints.append(endpoint)
        let (host, guest) = TestByteStream.pair()
        Task { await serve(endpoint, stream: guest) }
        return host
    }

    func snapshot() -> StoreTestSnapshot {
        StoreTestSnapshot(
            endpoints: endpoints,
            artifactTokenMatched: artifactTokenMatched,
            transfers: transfers,
            inspectRequests: inspectRequests,
            beginInstall: beginInstall,
            commitRequests: commitRequests,
            abandonRequests: abandonRequests,
            metadataRequests: metadataRequests,
            uninstallRequests: uninstallRequests,
            uninstallPackage: uninstallPackage,
            uninstallKeptData: uninstallKeptData,
            lastListFilter: lastListFilter,
            pingRequests: pingRequests
        )
    }

    func waitForPingCount(_ count: Int) async {
        guard pingRequests < count else {
            return
        }
        await withCheckedContinuation { continuation in
            pingWaiters.append((count, continuation))
        }
    }

    func waitForControlClose() async {
        guard !controlClosed else {
            return
        }
        await withCheckedContinuation { continuation in
            controlCloseWaiters.append(continuation)
        }
    }

    private func serve(_ endpoint: GuestEndpoint, stream: TestByteStream) async {
        var nextEnvelopeID: UInt64 = 1
        var nextEventSequence: UInt64 = 1
        await sendHello(endpoint, stream: stream, id: &nextEnvelopeID)
        while let bytes = try? await stream.read() {
            guard let envelope = try? FrameCodec.decode(bytes), let body = envelope.body else {
                return
            }
            switch body {
            case .helloAck(let ack):
                if endpoint == .storeControl {
                    controlToken = ack.sessionToken
                } else if endpoint == .storeArtifacts {
                    artifactTokenMatched = ack.sessionToken == controlToken
                }
            case .bulk(let frame):
                guard endpoint == .storeArtifacts else { return }
                await receive(frame, stream: stream, nextEnvelopeID: &nextEnvelopeID)
            case .request(let request):
                guard endpoint == .storeControl else { return }
                await receive(
                    request,
                    id: envelope.id,
                    stream: stream,
                    nextEnvelopeID: &nextEnvelopeID,
                    nextEventSequence: &nextEventSequence
                )
            default:
                break
            }
        }
        if endpoint == .storeControl {
            controlClosed = true
            for waiter in controlCloseWaiters {
                waiter.resume()
            }
            controlCloseWaiters.removeAll()
        }
    }

    private func sendHello(_ endpoint: GuestEndpoint, stream: TestByteStream, id: inout UInt64) async {
        var version = GPProtocolVersion()
        version.major = 1
        version.minor = 1
        var info = GPAgentInfo()
        info.kind = .storeAgent
        info.versionCode = 37
        info.versionName = "test"
        var android = GPAndroidInfo()
        android.sdkInt = 37
        var hello = GPHello()
        hello.protocolVersion = version
        hello.agent = info
        hello.android = android
        hello.capabilities = capabilities
        hello.channel = endpoint.channel
        hello.runtimeImageVersion = "test-image"
        await send(.hello(hello), stream: stream, id: &id)
    }

    private func receive(
        _ frame: GPBulkFrame,
        stream: TestByteStream,
        nextEnvelopeID: inout UInt64
    ) async {
        switch frame.kind {
        case .begin(let begin):
            activeTransfers[frame.transferID] = ActiveTransfer(
                transferID: frame.transferID,
                name: begin.name,
                context: begin.context
            )
        case .chunk(let data):
            guard var transfer = activeTransfers[frame.transferID] else { return }
            transfer.chunkSizes.append(data.count)
            activeTransfers[frame.transferID] = transfer
        case .end:
            guard let transfer = activeTransfers.removeValue(forKey: frame.transferID) else { return }
            transfers.append(
                TransferObservation(
                    transferID: transfer.transferID,
                    name: transfer.name,
                    context: transfer.context,
                    chunkSizes: transfer.chunkSizes,
                    acknowledged: true,
                    aborted: false
                )
            )
            var ack = GPBulkAck()
            ack.status = transfer.context == rejectedBulkContext ? .rejected : .ok
            var response = GPBulkFrame()
            response.transferID = frame.transferID
            response.kind = .ack(ack)
            await send(.bulk(response), stream: stream, id: &nextEnvelopeID)
        case .abort:
            guard let transfer = activeTransfers.removeValue(forKey: frame.transferID) else { return }
            transfers.append(
                TransferObservation(
                    transferID: transfer.transferID,
                    name: transfer.name,
                    context: transfer.context,
                    chunkSizes: transfer.chunkSizes,
                    acknowledged: false,
                    aborted: true
                )
            )
        case .ack, .none:
            break
        }
    }

    private func receive(
        _ request: GPRequest,
        id: UInt64,
        stream: TestByteStream,
        nextEnvelopeID: inout UInt64,
        nextEventSequence: inout UInt64
    ) async {
        guard let op = request.op else { return }
        let result: GPResponse.OneOf_Result
        switch op {
        case .ping(let ping):
            pingRequests += 1
            let ready = pingWaiters.filter { $0.0 <= pingRequests }
            pingWaiters.removeAll { $0.0 <= pingRequests }
            for (_, waiter) in ready {
                waiter.resume()
            }
            guard pingRequests > missedPongs else {
                return
            }
            var pong = GPPong()
            pong.nonce = ping.nonce
            result = .ping(pong)
        case .inspectArchive:
            inspectRequests += 1
            var archive = GPArchiveInfo()
            archive.package = "io.apkrun.fixture.hellotext"
            archive.versionCode = 7
            archive.versionName = "1.2.3"
            archive.splitNames = ["base"]
            archive.nativeAbis = ["arm64-v8a"]
            archive.minSdk = 23
            archive.targetSdk = 37
            archive.signerSha256 = [Data(repeating: 0xAB, count: 32)]
            archive.signingSchemeVersion = 3
            result = .inspectArchive(archive)
        case .beginInstall(let install):
            beginInstall = install
            var started = GPBeginInstallResult()
            started.installID = "install-1"
            started.androidSessionID = 42
            result = .beginInstall(started)
        case .commitInstall:
            commitRequests += 1
            var finished = GPInstallFinished()
            finished.installID = "install-1"
            finished.status = finishedStatus
            finished.androidStatus = 1
            finished.legacyStatus = finishedStatus == .conflict ? "INSTALL_FAILED_UPDATE_INCOMPATIBLE" : ""
            finished.message = finishedMessage
            finished.installedVersionCode = 7
            if sendInstallFinished {
                var event = GPEvent()
                event.seq = nextEventSequence
                nextEventSequence += 1
                event.kind = .installFinished(finished)
                await send(.event(event), stream: stream, id: &nextEnvelopeID)
            }
            result = .commitInstall(GPEmpty())
        case .abandonInstall:
            abandonRequests += 1
            result = .abandonInstall(GPEmpty())
        case .uninstall:
            uninstallRequests += 1
            if case .uninstall(let uninstall) = op {
                uninstallPackage = uninstall.package
                uninstallKeptData = uninstall.keepData
            }
            var uninstall = GPUninstallResult()
            uninstall.status = .success
            result = .uninstall(uninstall)
        case .getPackageMetadata:
            metadataRequests += 1
            result = .getPackageMetadata(packageMetadata())
        case .listManagedPackages(let list):
            lastListFilter = list.filter
            var packages = GPStorePackageList()
            packages.packages = [packageMetadata()]
            result = .listManagedPackages(packages)
        default:
            return
        }
        var response = GPResponse()
        response.result = result
        var envelope = GPEnvelope()
        envelope.id = nextEnvelopeID
        nextEnvelopeID += 1
        envelope.replyTo = id
        envelope.body = .response(response)
        if let frame = try? FrameCodec.encode(envelope) {
            try? await stream.write(frame)
        }
    }

    private func packageMetadata() -> GPStorePackageInfo {
        var signing = GPSigningInfo()
        signing.currentSha256 = [Data(repeating: 0xAB, count: 32)]
        signing.pastSha256 = [Data(repeating: 0xCD, count: 32)]
        signing.schemeVersion = 3
        var info = GPStorePackageInfo()
        info.package = "io.apkrun.fixture.hellotext"
        info.versionCode = 7
        info.versionName = "1.2.3"
        info.label = "Hello Text"
        info.launchableComponent = "io.apkrun.fixture.hellotext/.MainActivity"
        info.installerOfRecord = "io.apkrun.store"
        info.updateOwner = "io.apkrun.store"
        info.initiatingPackage = "io.apkrun.fixture.hellotext"
        info.firstInstallTimeMs = 1_700_000_000_000
        info.lastUpdateTimeMs = 1_700_000_001_000
        info.minSdk = 23
        info.targetSdk = 37
        info.splits = ["base", "config.arm64_v8a"]
        info.nativeAbis = ["arm64-v8a"]
        info.signing = signing
        info.enabled = true
        info.suspended = true
        info.requestedPermissionsCount = 4
        return info
    }

    private func send(
        _ body: GPEnvelope.OneOf_Body,
        stream: TestByteStream,
        id: inout UInt64
    ) async {
        var envelope = GPEnvelope()
        envelope.id = id
        id += 1
        envelope.body = body
        if let frame = try? FrameCodec.encode(envelope) {
            try? await stream.write(frame)
        }
    }
}

private final class TestByteStream: GuestByteStream, @unchecked Sendable {
    private var iterator: AsyncStream<Data>.AsyncIterator
    private let inboundContinuation: AsyncStream<Data>.Continuation
    private let outboundContinuation: AsyncStream<Data>.Continuation

    private init(
        inbound: AsyncStream<Data>,
        inboundContinuation: AsyncStream<Data>.Continuation,
        outboundContinuation: AsyncStream<Data>.Continuation
    ) {
        iterator = inbound.makeAsyncIterator()
        self.inboundContinuation = inboundContinuation
        self.outboundContinuation = outboundContinuation
    }

    static func pair() -> (TestByteStream, TestByteStream) {
        let first = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        let second = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        let lhs = TestByteStream(
            inbound: first.stream,
            inboundContinuation: first.continuation,
            outboundContinuation: second.continuation
        )
        let rhs = TestByteStream(
            inbound: second.stream,
            inboundContinuation: second.continuation,
            outboundContinuation: first.continuation
        )
        return (lhs, rhs)
    }

    func read() async throws -> Data? {
        await iterator.next()
    }

    func write(_ bytes: Data) async throws {
        outboundContinuation.yield(bytes)
    }

    func close() async {
        inboundContinuation.finish()
        outboundContinuation.finish()
    }
}
