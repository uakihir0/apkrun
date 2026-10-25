import APKStoreCore
import Foundation
import Testing

@testable import RuntimeHost

@Test(.timeLimit(.minutes(1)))
func developmentStoreRuntimeAccessProvidesChannelAndUserdataGeneration() async throws {
    let generation = UUID()
    let probe = StoreRuntimeAccessProbe()
    let access = DevelopmentStoreRuntimeAccess(
        makeChannel: {
            await probe.channelRequested()
            return FakeAccessStoreAgentChannel(probe: probe)
        },
        readUserdataGeneration: { generation }
    )

    let capabilities = try await access.withStoreAgent(UUID()) { channel in
        channel.capabilities
    }

    #expect(capabilities == [.install, .metadata])
    #expect(await probe.channelRequestCount == 1)
    #expect(await access.userdataGeneration() == generation)
}

@Test(.timeLimit(.minutes(1)))
func developmentStoreRuntimeAccessReusesAndClosesPersistentChannel() async throws {
    let probe = StoreRuntimeAccessProbe()
    let access = DevelopmentStoreRuntimeAccess(
        makeChannel: {
            await probe.channelRequested()
            return FakeAccessStoreAgentChannel(probe: probe)
        },
        readUserdataGeneration: { nil }
    )

    _ = try await access.withStoreAgent(UUID()) { $0.capabilities }
    _ = try await access.withStoreAgent(UUID()) { $0.capabilities }
    #expect(await probe.channelRequestCount == 1)
    #expect(await probe.channelCloseCount == 0)

    await access.close()
    #expect(await probe.channelCloseCount == 1)

    _ = try await access.withStoreAgent(UUID()) { $0.capabilities }
    #expect(await probe.channelRequestCount == 2)
}

@Test(.timeLimit(.minutes(1)))
func developmentStoreRuntimeAccessCoalescesConcurrentChannelCreation() async throws {
    let probe = StoreRuntimeAccessProbe()
    let access = DevelopmentStoreRuntimeAccess(
        makeChannel: {
            await probe.channelRequested()
            await probe.waitForChannelCreationRelease()
            return FakeAccessStoreAgentChannel(probe: probe)
        },
        readUserdataGeneration: { nil }
    )

    let first = Task {
        try await access.withStoreAgent(UUID()) { $0.capabilities }
    }
    await probe.waitForChannelRequests(1)

    let second = Task {
        try await access.withStoreAgent(UUID()) { $0.capabilities }
    }
    await access.waitForChannelCreationWaitersForTesting(1)
    await probe.releaseChannelCreation()

    #expect(try await first.value == [.install, .metadata])
    #expect(try await second.value == [.install, .metadata])
    #expect(await probe.channelRequestCount == 1)
    #expect(await probe.channelCloseCount == 0)

    await access.close()
    #expect(await probe.channelCloseCount == 1)
}

private actor StoreRuntimeAccessProbe {
    private(set) var channelRequestCount = 0
    private(set) var channelCloseCount = 0
    private var isChannelCreationReleased = false
    private var channelCreationReleaseContinuation: CheckedContinuation<Void, Never>?
    private var channelRequestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func channelRequested() {
        channelRequestCount += 1
        let ready = channelRequestWaiters.filter { $0.0 <= channelRequestCount }
        channelRequestWaiters.removeAll { $0.0 <= channelRequestCount }
        for waiter in ready {
            waiter.1.resume()
        }
    }

    func waitForChannelRequests(_ count: Int) async {
        guard channelRequestCount < count else { return }
        await withCheckedContinuation { continuation in
            channelRequestWaiters.append((count, continuation))
        }
    }

    func waitForChannelCreationRelease() async {
        guard !isChannelCreationReleased else { return }
        await withCheckedContinuation { continuation in
            channelCreationReleaseContinuation = continuation
        }
    }

    func releaseChannelCreation() {
        isChannelCreationReleased = true
        channelCreationReleaseContinuation?.resume()
        channelCreationReleaseContinuation = nil
    }

    func channelClosed() {
        channelCloseCount += 1
    }
}

private struct FakeAccessStoreAgentChannel: StoreAgentChannel {
    let capabilities: StoreCapabilities = [.install, .metadata]
    let probe: StoreRuntimeAccessProbe

    func close() async {
        await probe.channelClosed()
    }

    func install(_ request: StoreInstallRequest, files: [URL]) async throws -> StorePackageInfo {
        throw FakeAccessChannelFailure.unexpectedCall
    }

    func uninstall(_ package: PackageID, keepData: Bool) async throws {
        throw FakeAccessChannelFailure.unexpectedCall
    }

    func packageInfo(_ package: PackageID) async throws -> StorePackageInfo? {
        throw FakeAccessChannelFailure.unexpectedCall
    }

    func listPackages(_ filter: StorePackageFilter) async throws -> [StorePackageSummary] {
        throw FakeAccessChannelFailure.unexpectedCall
    }
}

private enum FakeAccessChannelFailure: Error {
    case unexpectedCall
}
