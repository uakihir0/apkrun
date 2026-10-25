import Foundation
import GuestProtocol
import RuntimeAPI
import Testing

@testable import RuntimeCore

@Test(.timeLimit(.minutes(1)))
func storeAgentRetriesTransientControlDisconnectsBeforeOpeningArtifactChannel() async throws {
    let transport = InMemoryTransport { endpoint, agent, connectionNumber in
        switch endpoint {
        case .storeControl:
            if connectionNumber == 1 {
                agent.hangUp()
            } else {
                agent.sendHello(
                    channel: .storeControl,
                    capabilities: ["store.install.v1", "store.metadata.v1", "store.inspect.v1"]
                )
            }
        case .storeArtifacts:
            if connectionNumber == 3 {
                agent.hangUp()
            } else {
                agent.sendHello(channel: .storeArtifacts, capabilities: ["bulk.v1"])
            }
        default:
            Issue.record("Store Agent requested an unsupported endpoint")
        }
    }
    let client = try await GuestStoreAgentClient.connect(
        transport: RuntimeStoreTestTransport(inner: transport),
        keepaliveInterval: .seconds(60)
    )

    #expect(transport.agents.count == 5)
    #expect(client.isConnected)
    await client.close()
}

@Test
func storeAgentAcceptsAndroidInspectedSignerWhenHostHasNotVerifiedIt() throws {
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let signer = String(repeating: "a", count: 64)
    let archive = RuntimeStoreArchiveInfo(
        packageID: packageID,
        versionCode: 1,
        splitNames: [],
        nativeABIs: [],
        minSDK: 23,
        targetSDK: 37,
        signingDigests: [signer],
        signingSchemeVersion: 2
    )
    let request = RuntimeStoreInstallRequest(packageID: packageID, versionCode: 1)

    try GuestStoreAgentClient.validate(archive, against: request)
    #expect(try GuestStoreAgentClient.protocolSignerDigests(for: request).isEmpty)
}

@Test
func storeAgentStillChecksHostVerifiedSignerDigests() throws {
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let signer = String(repeating: "a", count: 64)
    let archive = RuntimeStoreArchiveInfo(
        packageID: packageID,
        versionCode: 1,
        splitNames: [],
        nativeABIs: [],
        minSDK: 23,
        targetSDK: 37,
        signingDigests: [signer],
        signingSchemeVersion: 2
    )
    let matching = RuntimeStoreInstallRequest(
        packageID: packageID,
        versionCode: 1,
        expectedSignerDigests: [signer]
    )
    let mismatching = RuntimeStoreInstallRequest(
        packageID: packageID,
        versionCode: 1,
        expectedSignerDigests: [String(repeating: "b", count: 64)]
    )

    try GuestStoreAgentClient.validate(archive, against: matching)
    #expect(
        try GuestStoreAgentClient.protocolSignerDigests(for: matching)
            == [Data(repeating: 0xaa, count: 32)]
    )
    #expect(throws: RuntimeStoreAgentFailure.signerMismatch) {
        try GuestStoreAgentClient.validate(archive, against: mismatching)
    }
}

private struct RuntimeStoreTestTransport: RuntimeGuestTransport {
    let inner: InMemoryTransport

    func open(_ endpoint: RuntimeGuestEndpoint) async throws -> any RuntimeGuestByteStream {
        let guestEndpoint: GuestEndpoint
        switch endpoint {
        case .storeControl: guestEndpoint = .storeControl
        case .storeArtifacts: guestEndpoint = .storeArtifacts
        }
        return RuntimeStoreTestStream(base: try await inner.open(guestEndpoint))
    }
}

private struct RuntimeStoreTestStream: RuntimeGuestByteStream {
    let base: any GuestByteStream

    func read() async throws -> Data? {
        try await base.read()
    }

    func write(_ bytes: Data) async throws {
        try await base.write(bytes)
    }

    func close() async {
        await base.close()
    }
}
