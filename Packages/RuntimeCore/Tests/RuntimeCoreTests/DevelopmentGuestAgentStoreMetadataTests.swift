import Foundation
import GuestProtocol
import RuntimeAPI
import Testing

@testable import RuntimeCore

@Test(.timeLimit(.minutes(1)))
func developmentGuestAgentProjectsPackageMetadataAndListsIntoRuntimeOwnedTypes() async throws {
    let transport = InMemoryTransport { endpoint, agent, _ in
        guard endpoint == .guestControl else { return }
        agent.sendHello(capabilities: [
            GuestCapability.core.rawValue,
            GuestCapability.display.rawValue,
            GuestCapability.launch.rawValue,
            GuestCapability.input.rawValue,
            GuestCapability.packages.rawValue,
        ])
        agent.answer = { request in
            switch request.op {
            case .getSnapshot?:
                return .getSnapshot(GPSnapshot())
            case .ping(let ping)?:
                var pong = GPPong()
                pong.nonce = ping.nonce
                return .ping(pong)
            case .queryPackage?:
                return .queryPackage(packageMetadata())
            case .listPackages(let list)?:
                var packages = GPPackageList()
                packages.packages = [packageSummary()]
                #expect(list.filter == .launchable)
                return .listPackages(packages)
            default:
                return nil
            }
        }
    }
    let agent = DevelopmentGuestAgent(
        adb: AdbClient(executable: URL(fileURLWithPath: "/usr/bin/true")),
        bundle: GuestAgentBundle(
            apk: URL(fileURLWithPath: "/tmp/unused-guest-agent.apk"),
            packageName: "io.apkrun.guest",
            versionCode: 1,
            versionName: "test"
        ),
        transport: transport
    )
    try await agent.supervisor.start(connectTimeout: .seconds(2))
    defer { Task { await agent.supervisor.stop() } }

    let info = try #require(await agent.storePackageInfo("io.apkrun.fixture.hellotext"))
    #expect(info.package == "io.apkrun.fixture.hellotext")
    #expect(info.label == "Hello Text")
    #expect(info.versionCode == 17)
    #expect(info.versionName == "2.0")
    #expect(info.launchableComponent == "io.apkrun.fixture.hellotext/.MainActivity")
    #expect(info.installerPackage == "io.apkrun.store")
    #expect(info.signingSHA256 == [Data(repeating: 0xAB, count: 32)])
    #expect(info.targetSDK == 37)
    #expect(info.minSDK == 23)

    let packages = try await agent.listStorePackages(filter: .launchable)
    #expect(
        packages == [
            GuestPackageSummary(
                package: "io.apkrun.fixture.hellotext",
                label: "Hello Text",
                versionCode: 17,
                launchable: true,
                userInstalled: true
            )
        ]
    )
    await agent.supervisor.stop()
}

@Test(.timeLimit(.minutes(1)))
func developmentGuestAgentRelaysPackageChangedEventsAsRuntimeOwnedEvents() async throws {
    let transport = InMemoryTransport { endpoint, agent, _ in
        guard endpoint == .guestControl else { return }
        agent.sendHello(capabilities: [
            GuestCapability.core.rawValue,
            GuestCapability.display.rawValue,
            GuestCapability.launch.rawValue,
            GuestCapability.input.rawValue,
            GuestCapability.packages.rawValue,
        ])
        agent.answer = { request in
            switch request.op {
            case .getSnapshot?:
                var changed = GPPackageChanged()
                changed.package = "io.apkrun.fixture.hellotext"
                changed.kind = .replaced
                changed.versionCode = 23
                agent.sendEvent(.packageChanged(changed))
                return .getSnapshot(GPSnapshot())
            case .ping(let ping)?:
                var pong = GPPong()
                pong.nonce = ping.nonce
                return .ping(pong)
            default:
                return nil
            }
        }
    }
    let guestAgent = DevelopmentGuestAgent(
        adb: AdbClient(executable: URL(fileURLWithPath: "/usr/bin/true")),
        bundle: GuestAgentBundle(
            apk: URL(fileURLWithPath: "/tmp/unused-guest-agent.apk"),
            packageName: "io.apkrun.guest",
            versionCode: 1,
            versionName: "test"
        ),
        transport: transport
    )
    await guestAgent.startEventRelay()
    try await guestAgent.supervisor.start(connectTimeout: .seconds(2))

    var events = guestAgent.packageEvents.makeAsyncIterator()
    let event = try #require(await events.next())
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    #expect(
        event
            == RuntimeStorePackageEvent(packageID: packageID, kind: .replaced, versionCode: 23)
    )
    await guestAgent.supervisor.stop()
}

private func packageMetadata() -> GPPackageInfo {
    var info = GPPackageInfo()
    info.package = "io.apkrun.fixture.hellotext"
    info.label = "Hello Text"
    info.versionCode = 17
    info.versionName = "2.0"
    info.enabled = true
    info.launchableComponent = "io.apkrun.fixture.hellotext/.MainActivity"
    info.installerPackage = "io.apkrun.store"
    info.firstInstallTimeMs = 1_700_000_000_000
    info.lastUpdateTimeMs = 1_700_000_001_000
    info.targetSdk = 37
    info.minSdk = 23
    info.signingSha256 = [Data(repeating: 0xAB, count: 32)]
    return info
}

private func packageSummary() -> GPPackageSummary {
    var summary = GPPackageSummary()
    summary.package = "io.apkrun.fixture.hellotext"
    summary.label = "Hello Text"
    summary.versionCode = 17
    summary.launchable = true
    summary.userInstalled = true
    return summary
}
