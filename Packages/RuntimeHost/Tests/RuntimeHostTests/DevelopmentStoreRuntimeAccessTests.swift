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
            return FakeAccessStoreAgentChannel()
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

private actor StoreRuntimeAccessProbe {
    private(set) var channelRequestCount = 0

    func channelRequested() {
        channelRequestCount += 1
    }
}

private struct FakeAccessStoreAgentChannel: StoreAgentChannel {
    let capabilities: StoreCapabilities = [.install, .metadata]

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
