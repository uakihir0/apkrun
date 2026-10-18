import APKStoreCore
import Foundation
import GuestProtocol
import RuntimeCore
import Testing

@testable import RuntimeHost

@Test(.timeLimit(.minutes(1)))
func adbStoreChannelInstallsAndVerifiesPackageManagerFacts() async throws {
    let package = try #require(PackageID(rawValue: "io.apkrun.fixture.hellosplit"))
    let guest = FakeStoreGuestAgent(packageInfo: packageInfo(package: package.rawValue, versionCode: 7))
    let adb = FakeStoreADBClient()
    let channel = ADBStoreAgentChannel(
        agent: guest,
        adb: adb,
        capabilities: [.install, .metadata, .downgradeReinstall]
    )
    let files = [
        URL(fileURLWithPath: "/tmp/base.apk"),
        URL(fileURLWithPath: "/tmp/split_config.arm64_v8a.apk"),
    ]

    let result = try await channel.install(
        StoreInstallRequest(packageID: package, versionCode: 7, allowDowngrade: true),
        files: files
    )

    #expect(result.packageID == package)
    #expect(result.versionCode == 7)
    #expect(result.displayName == "Hello Split")
    #expect(result.installerPackage == PackageID(rawValue: "io.apkrun.store"))
    #expect(result.signingDigests == [SHA256Digest(data: Data(repeating: 0xAB, count: 32))])
    let installCall = await guest.installCalls.first
    #expect(installCall?.0 == files)
    #expect(installCall?.1 == true)
    #expect(await guest.queryPackages == [package.rawValue])
    #expect(await adb.uninstallCalls.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func adbStoreChannelRejectsPackageManagerPackageAndVersionMismatches() async throws {
    let requested = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let other = try #require(PackageID(rawValue: "io.apkrun.fixture.hellocompose"))
    let files = [URL(fileURLWithPath: "/tmp/base.apk")]

    let packageMismatch = ADBStoreAgentChannel(
        agent: FakeStoreGuestAgent(packageInfo: packageInfo(package: other.rawValue, versionCode: 3)),
        adb: FakeStoreADBClient(),
        capabilities: [.install, .metadata]
    )
    await #expect(throws: ADBStoreAgentChannelFailure.packageMismatch(expected: requested, actual: other)) {
        try await packageMismatch.install(StoreInstallRequest(packageID: requested, versionCode: 3), files: files)
    }

    let versionMismatch = ADBStoreAgentChannel(
        agent: FakeStoreGuestAgent(packageInfo: packageInfo(package: requested.rawValue, versionCode: 4)),
        adb: FakeStoreADBClient(),
        capabilities: [.install, .metadata]
    )
    await #expect(
        throws: ADBStoreAgentChannelFailure.versionMismatch(package: requested, expected: 3, actual: 4)
    ) {
        try await versionMismatch.install(StoreInstallRequest(packageID: requested, versionCode: 3), files: files)
    }
}

@Test(.timeLimit(.minutes(1)))
func adbStoreChannelUsesGuestAgentForPackageQueriesAndMapsFilters() async throws {
    let package = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let guest = FakeStoreGuestAgent(
        packageInfo: packageInfo(package: package.rawValue, versionCode: 9),
        summaries: [
            packageSummary(package: package.rawValue, versionCode: 9)
        ]
    )
    let channel = ADBStoreAgentChannel(agent: guest, adb: FakeStoreADBClient(), capabilities: [.metadata])

    let queried = try await channel.packageInfo(package)
    let launchable = try await channel.listPackages(.launchable)
    let userInstalled = try await channel.listPackages(.userInstalled)
    let all = try await channel.listPackages(.all)

    #expect(queried?.packageID == package)
    #expect(queried?.versionCode == 9)
    #expect(launchable.first?.packageID == package)
    #expect(userInstalled.first?.userInstalled == true)
    #expect(all.first?.launchable == true)
    #expect(await guest.queryPackages == [package.rawValue])
    #expect(await guest.listFilters == [.launchable, .userInstalled, .all])
}

@Test(.timeLimit(.minutes(1)))
func adbStoreChannelRejectsPackageQueryIdentityMismatch() async throws {
    let requested = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let returned = try #require(PackageID(rawValue: "io.apkrun.fixture.hellocompose"))
    let channel = ADBStoreAgentChannel(
        agent: FakeStoreGuestAgent(packageInfo: packageInfo(package: returned.rawValue, versionCode: 9)),
        adb: FakeStoreADBClient(),
        capabilities: [.metadata]
    )

    await #expect(
        throws: ADBStoreAgentChannelFailure.packageMismatch(expected: requested, actual: returned)
    ) {
        try await channel.packageInfo(requested)
    }
}

@Test(.timeLimit(.minutes(1)))
func adbStoreChannelPassesKeepDataThroughTheNamedADBHelper() async throws {
    let package = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let adb = FakeStoreADBClient()
    let channel = ADBStoreAgentChannel(
        agent: FakeStoreGuestAgent(),
        adb: adb,
        capabilities: [.install, .metadata]
    )

    try await channel.uninstall(package, keepData: true)

    let uninstallCall = await adb.uninstallCalls.first
    #expect(uninstallCall?.0 == package.rawValue)
    #expect(uninstallCall?.1 == true)
}

@Test(.timeLimit(.minutes(1)))
func adbStoreChannelPropagatesAnAmbiguousUninstallFailureForAnAbsentPackage() async throws {
    let package = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let guest = FakeStoreGuestAgent()
    let adb = FakeStoreADBClient(
        uninstallFailure: .packageRejected(command: "uninstall", reason: "DELETE_FAILED_INTERNAL_ERROR")
    )
    let channel = ADBStoreAgentChannel(agent: guest, adb: adb, capabilities: [.metadata])

    await #expect(
        throws: AdbFailure.packageRejected(command: "uninstall", reason: "DELETE_FAILED_INTERNAL_ERROR")
    ) {
        try await channel.uninstall(package, keepData: false)
    }

    let uninstallCalls = await adb.uninstallCalls
    #expect(uninstallCalls.count == 1)
    #expect(uninstallCalls.first?.0 == package.rawValue)
    #expect(uninstallCalls.first?.1 == false)
    #expect(await guest.queryPackages.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func adbStoreChannelPropagatesAnAmbiguousKeepDataUninstallFailure() async throws {
    let package = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let guest = FakeStoreGuestAgent()
    let adb = FakeStoreADBClient(
        uninstallFailure: .packageRejected(command: "uninstall", reason: "DELETE_FAILED_INTERNAL_ERROR")
    )
    let channel = ADBStoreAgentChannel(agent: guest, adb: adb, capabilities: [.metadata])

    await #expect(
        throws: AdbFailure.packageRejected(command: "uninstall", reason: "DELETE_FAILED_INTERNAL_ERROR")
    ) {
        try await channel.uninstall(package, keepData: true)
    }
    #expect(await guest.queryPackages.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func adbStoreChannelPreservesAnUninstallFailureWhenPackageManagerStillFindsThePackage() async throws {
    let package = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let guest = FakeStoreGuestAgent(packageInfo: packageInfo(package: package.rawValue, versionCode: 9))
    let failure = AdbFailure.packageRejected(command: "uninstall", reason: "DELETE_FAILED_INTERNAL_ERROR")
    let adb = FakeStoreADBClient(uninstallFailure: failure)
    let channel = ADBStoreAgentChannel(agent: guest, adb: adb, capabilities: [.metadata])

    await #expect(throws: failure) {
        try await channel.uninstall(package, keepData: true)
    }
    #expect(await guest.queryPackages.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func adbStoreChannelDoesNotPassUnsupportedDowngradeRequestsToAndroid() async throws {
    let package = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let guest = FakeStoreGuestAgent(packageInfo: packageInfo(package: package.rawValue, versionCode: 2))
    let channel = ADBStoreAgentChannel(agent: guest, adb: FakeStoreADBClient(), capabilities: [.install, .metadata])

    await #expect(throws: ADBStoreAgentChannelFailure.downgradeNotSupported) {
        try await channel.install(
            StoreInstallRequest(packageID: package, versionCode: 2, allowDowngrade: true),
            files: [URL(fileURLWithPath: "/tmp/base.apk")]
        )
    }
    #expect(await guest.installCalls.isEmpty)
}

private func packageInfo(package: String, versionCode: Int64) -> GPPackageInfo {
    var info = GPPackageInfo()
    info.package = package
    info.versionCode = versionCode
    info.versionName = "1.2.3"
    info.label = "Hello Split"
    info.enabled = true
    info.launchableComponent = "\(package)/.MainActivity"
    info.installerPackage = "io.apkrun.store"
    info.firstInstallTimeMs = 1_700_000_000_000
    info.lastUpdateTimeMs = 1_700_000_001_000
    info.targetSdk = 35
    info.minSdk = 23
    info.signingSha256 = [Data(repeating: 0xAB, count: 32)]
    return info
}

private func packageSummary(package: String, versionCode: Int64) -> GPPackageSummary {
    var summary = GPPackageSummary()
    summary.package = package
    summary.label = "Hello Text"
    summary.versionCode = versionCode
    summary.launchable = true
    summary.userInstalled = true
    return summary
}

private actor FakeStoreGuestAgent: ADBStoreGuestAgent {
    private let info: GPPackageInfo?
    private let summaries: [GPPackageSummary]
    private(set) var installCalls: [([URL], Bool)] = []
    private(set) var queryPackages: [String] = []
    private(set) var listFilters: [GPPackageFilter] = []

    init(packageInfo: GPPackageInfo? = nil, summaries: [GPPackageSummary] = []) {
        info = packageInfo
        self.summaries = summaries
    }

    func installMultiple(apks: [URL], allowDowngrade: Bool) async throws(AdbFailure) {
        installCalls.append((apks, allowDowngrade))
    }

    func queryPackage(_ package: String) async throws(GuestAgentFailure) -> GPPackageInfo? {
        queryPackages.append(package)
        return info
    }

    func listPackages(filter: GPPackageFilter) async throws(GuestAgentFailure) -> [GPPackageSummary] {
        listFilters.append(filter)
        return summaries
    }
}

private actor FakeStoreADBClient: ADBStoreADBClient {
    private let uninstallFailure: AdbFailure?
    private(set) var uninstallCalls: [(String, Bool)] = []

    init(uninstallFailure: AdbFailure? = nil) {
        self.uninstallFailure = uninstallFailure
    }

    func uninstall(packageName: String, keepData: Bool) async throws(AdbFailure) {
        uninstallCalls.append((packageName, keepData))
        if let uninstallFailure {
            throw uninstallFailure
        }
    }
}
