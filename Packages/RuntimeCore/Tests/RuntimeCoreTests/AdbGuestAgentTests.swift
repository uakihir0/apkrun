import DiagnosticsCore
import Foundation
import GuestProtocol
import Testing

@testable import RuntimeCore

/// The ADB helpers of the Guest Agent and the provisioner's decisions, run against a fake adb (guest-components.md
/// §3.1, §3.2; #73 T0).

/// A fake `adb` that records each call and answers the ones the Guest Agent uses. The state of the fake (the installed
/// version, whether the agent runs, and whether the next install is refused) lives in files in its directory.
private final class FakeGuestADB: @unchecked Sendable {
    let directory: URL
    let executable: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-072-adb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("adb")
        let script = """
            #!/bin/sh
            dir='\(directory.path)'
            printf '%s\\n' "$*" >> "$dir/calls.log"
            case "$*" in
              "-s 127.0.0.1:6520 forward tcp:0 localabstract:apkrun-guestd-control") echo 43001; exit 0 ;;
              "-s 127.0.0.1:6520 forward --remove tcp:43001") exit 0 ;;
              "-s 127.0.0.1:6520 forward --list")
                printf '127.0.0.1:6520 tcp:43001 localabstract:apkrun-guestd-control\\n'
                printf '127.0.0.1:6520 tcp:5555 localabstract:other\\n'
                exit 0 ;;
              "-s 127.0.0.1:6520 get-state") echo device; exit 0 ;;
              "-s 127.0.0.1:6520 shell pm list packages --show-versioncode io.apkrun.guest")
                v=$(cat "$dir/version" 2>/dev/null || echo 1000)
                echo "package:io.apkrun.guest versionCode:$v"
                exit 0 ;;
              "-s 127.0.0.1:6520 install -r -t "*)
                if [ -f "$dir/slow-install" ]; then sleep 2; fi
                if [ -f "$dir/refuse-all-installs" ]; then
                  echo "adb: failed to install: Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: Existing package io.apkrun.guest signatures do not match newer version; ignoring !allowDowngrade]"
                  exit 1
                fi
                if [ -f "$dir/refuse-install" ]; then
                  rm -f "$dir/refuse-install"
                  echo "adb: failed to install: Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: Existing package io.apkrun.guest signatures do not match newer version; ignoring !allowDowngrade]"
                  exit 1
                fi
                echo "Performing Streamed Install"; echo "Success"; exit 0 ;;
              "-s 127.0.0.1:6520 uninstall io.apkrun.guest") echo "Success"; exit 0 ;;
              "-s 127.0.0.1:6520 shell pidof apkrun_guestd")
                if [ -f "$dir/running" ]; then echo 2121; exit 0; fi
                exit 1 ;;
              "-s 127.0.0.1:6520 shell kill 2121")
                rm -f "$dir/running"; exit 0 ;;
              *"app_process"*)
                if [ -f "$dir/block-start" ]; then
                  touch "$dir/start-entered"
                  while [ -f "$dir/block-start" ]; do sleep 0.01; done
                fi
                if [ -f "$dir/refuse-start" ]; then exit 1; fi
                touch "$dir/running"; exit 0 ;;
              *) exit 0 ;;
            esac
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    var calls: [String] {
        let text = (try? String(contentsOf: directory.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    func setInstalledVersion(_ version: Int) throws {
        try String(version).write(to: directory.appendingPathComponent("version"), atomically: true, encoding: .utf8)
    }

    func setRunning(_ running: Bool) throws {
        let flag = directory.appendingPathComponent("running")
        if running {
            try Data().write(to: flag)
        } else {
            try? FileManager.default.removeItem(at: flag)
        }
    }

    /// Makes every start of the agent process fail, as `app_process` would when the device refuses it.
    func refuseEveryStart() throws {
        try Data().write(to: directory.appendingPathComponent("refuse-start"))
    }

    /// Makes every install refused, so that the reinstall after the removal is refused too.
    func refuseEveryInstall() throws {
        try Data().write(to: directory.appendingPathComponent("refuse-all-installs"))
    }

    func refuseNextInstall() throws {
        try Data().write(to: directory.appendingPathComponent("refuse-install"))
    }

    func blockAgentStart() throws {
        try Data().write(to: directory.appendingPathComponent("block-start"))
    }

    func slowInstall() throws {
        try Data().write(to: directory.appendingPathComponent("slow-install"))
    }

    var agentStartEntered: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("start-entered").path)
    }

    func allowAgentStart() {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("block-start"))
    }

    var agentIsRunning: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("running").path)
    }
}

private func bundle(version: Int) -> GuestAgentBundle {
    GuestAgentBundle(
        apk: URL(fileURLWithPath: "/tmp/apkrun-072-missing/apkrun-guest.apk"),
        packageName: "io.apkrun.guest",
        versionCode: version,
        versionName: "test"
    )
}

@Test(.timeLimit(.minutes(1)))
func developmentGuestAgentRelaysAndResolvesSaveToMacOffers() async throws {
    let fake = try FakeGuestADB()
    let transport = InMemoryTransport { _, agent, _ in
        agent.sendHello(capabilities: GuestCapability.allCases.map(\.rawValue))
        agent.answer = { request in
            switch request.op {
            case .getSnapshot?:
                .getSnapshot(GPSnapshot())
            case .resolveExport(let operation)?:
                #expect(operation.decision == .decline)
                var result = GPExportStart()
                result.transferID = 41
                return .resolveExport(result)
            default:
                nil
            }
        }
    }
    let guest = DevelopmentGuestAgent(
        adb: AdbClient(executable: fake.executable),
        bundle: bundle(version: 1000),
        transport: transport
    )
    try await guest.start(connectTimeout: .seconds(5))

    var offered = GPExportFileOffered()
    offered.offerID = 7
    offered.name = "report.pdf"
    offered.mimeType = "application/pdf"
    offered.size = 4096
    offered.sourcePackage = "io.apkrun.fixture.reader"
    offered.displayID = 3
    transport.agents[0].sendEvent(.exportFileOffered(offered))

    var iterator = guest.exportOffers.makeAsyncIterator()
    let received = try #require(await iterator.next())
    #expect(received.name == "report.pdf")
    #expect(received.mimeType == "application/pdf")
    #expect(received.size == 4096)
    #expect(received.sourcePackage == "io.apkrun.fixture.reader")
    #expect(received.displayID == 3)

    try await waitForDeclinedExport(offerID: 7, agent: transport.agents[0])
    await guest.stop()
}

@Test(.timeLimit(.minutes(1)))
func staleExportOfferCannotResolveAReusedGuestIDAfterReconnect() async throws {
    let fake = try FakeGuestADB()
    let transport = InMemoryTransport { _, agent, _ in
        agent.sendHello(capabilities: GuestCapability.allCases.map(\.rawValue))
        agent.answer = { request in
            switch request.op {
            case .getSnapshot?:
                .getSnapshot(GPSnapshot())
            case .resolveExport(let operation)?:
                guard operation.decision == .accept else { return nil }
                var result = GPExportStart()
                result.transferID = 41
                return .resolveExport(result)
            default:
                nil
            }
        }
    }
    let guest = DevelopmentGuestAgent(
        adb: AdbClient(executable: fake.executable),
        bundle: bundle(version: 1000),
        transport: transport
    )
    await guest.setExportOfferHandler { _ in }
    try await guest.start(connectTimeout: .seconds(5))

    var iterator = guest.exportOffers.makeAsyncIterator()
    transport.agents[0].sendEvent(.exportFileOffered(exportOffer(offerID: 7)))
    let staleOffer = try #require(await iterator.next())

    await guest.supervisor.stop()
    try await guest.start(connectTimeout: .seconds(5))
    transport.agents[1].sendEvent(.exportFileOffered(exportOffer(offerID: 7)))
    let currentOffer = try #require(await iterator.next())
    #expect(staleOffer.offerID != currentOffer.offerID)

    do {
        _ = try await guest.resolveExport(offerID: staleOffer.offerID, decision: .accept)
        Issue.record("An offer from an earlier connection resolved on the replacement session.")
    } catch {
        // The stale opaque handle must not be replayed against a replacement session.
    }
    #expect(
        !transport.agents[1].requests.contains { request in
            guard case .resolveExport(let operation)? = request.op else { return false }
            return operation.offerID == 7
        })

    let result = try await guest.resolveExport(offerID: currentOffer.offerID, decision: .accept)
    #expect(result.transferID == 41)
    #expect(
        transport.agents[1].requests.contains { request in
            guard case .resolveExport(let operation)? = request.op else { return false }
            return operation.offerID == 7 && operation.decision == .accept
        })
    await guest.stop()
}

@Test(.timeLimit(.minutes(1)))
func developmentGuestAgentDeclinesExportOffersPastThePendingLimit() async throws {
    let fake = try FakeGuestADB()
    let transport = InMemoryTransport { _, agent, _ in
        agent.sendHello(capabilities: GuestCapability.allCases.map(\.rawValue))
        agent.answer = { request in
            switch request.op {
            case .getSnapshot?:
                .getSnapshot(GPSnapshot())
            case .resolveExport?:
                .resolveExport(GPExportStart())
            default:
                nil
            }
        }
    }
    let guest = DevelopmentGuestAgent(
        adb: AdbClient(executable: fake.executable),
        bundle: bundle(version: 1000),
        transport: transport
    )
    await guest.setExportOfferHandler { _ in }
    try await guest.start(connectTimeout: .seconds(5))

    var iterator = guest.exportOffers.makeAsyncIterator()
    for offerID in UInt64(1)...UInt64(DevelopmentGuestAgent.maximumPendingExportOffers) {
        transport.agents[0].sendEvent(.exportFileOffered(exportOffer(offerID: offerID)))
        #expect(await iterator.next() != nil)
    }

    let overflowOfferID = UInt64(DevelopmentGuestAgent.maximumPendingExportOffers + 1)
    transport.agents[0].sendEvent(.exportFileOffered(exportOffer(offerID: overflowOfferID)))
    try await waitForDeclinedExport(offerID: overflowOfferID, agent: transport.agents[0])
    #expect(
        transport.agents[0].requests.filter { request in
            guard case .resolveExport(let operation)? = request.op else { return false }
            return operation.decision == .decline
        }.count == 1
    )

    await guest.stop()
}

@Test(.timeLimit(.minutes(1)))
func developmentGuestAgentExpiresAndDeclinesUnresolvedExportOffers() async throws {
    let fake = try FakeGuestADB()
    let transport = InMemoryTransport { _, agent, _ in
        agent.sendHello(capabilities: GuestCapability.allCases.map(\.rawValue))
        agent.answer = { request in
            switch request.op {
            case .getSnapshot?:
                .getSnapshot(GPSnapshot())
            case .resolveExport?:
                .resolveExport(GPExportStart())
            default:
                nil
            }
        }
    }
    let guest = DevelopmentGuestAgent(
        adb: AdbClient(executable: fake.executable),
        bundle: bundle(version: 1000),
        transport: transport,
        exportOfferLifetime: .milliseconds(25)
    )
    await guest.setExportOfferHandler { _ in }
    try await guest.start(connectTimeout: .seconds(5))

    var iterator = guest.exportOffers.makeAsyncIterator()
    let guestOfferID: UInt64 = 41
    transport.agents[0].sendEvent(.exportFileOffered(exportOffer(offerID: guestOfferID)))
    let offered = try #require(await iterator.next())
    try await waitForDeclinedExport(offerID: guestOfferID, agent: transport.agents[0])

    do {
        _ = try await guest.resolveExport(offerID: offered.offerID, decision: .accept)
        Issue.record("An expired export offer remained acceptable.")
    } catch {
        // Expired opaque handles are no longer resolvable.
    }
    #expect(
        !transport.agents[0].requests.contains { request in
            guard case .resolveExport(let operation)? = request.op else { return false }
            return operation.offerID == guestOfferID && operation.decision == .accept
        })

    await guest.stop()
}

private func exportOffer(offerID: UInt64) -> GPExportFileOffered {
    var offer = GPExportFileOffered()
    offer.offerID = offerID
    offer.name = "report.pdf"
    offer.mimeType = "application/pdf"
    offer.size = 4096
    offer.sourcePackage = "io.apkrun.fixture.reader"
    offer.displayID = 3
    return offer
}

private func waitForDeclinedExport(offerID: UInt64, agent: InMemoryAgent) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !agent.requests.contains(where: { request in
        guard case .resolveExport(let operation)? = request.op else { return false }
        return operation.offerID == offerID && operation.decision == .decline
    }), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(
        agent.requests.contains { request in
            guard case .resolveExport(let operation)? = request.op else { return false }
            return operation.offerID == offerID && operation.decision == .decline
        }
    )
}

@Test(.timeLimit(.minutes(1)))
func forwardReturnsThePortAdbChoseAndRemovesItAgain() async throws {
    let fake = try FakeGuestADB()
    let client = AdbClient(executable: fake.executable)
    let port = try await client.forward(remote: "localabstract:apkrun-guestd-control")
    #expect(port == 43001)
    let forwards = try await client.forwardList()
    #expect(forwards.contains(AdbForward(local: "tcp:43001", remote: "localabstract:apkrun-guestd-control")))
    try await client.forwardRemove(port: port)
    #expect(fake.calls.contains("-s 127.0.0.1:6520 forward --remove tcp:43001"))
}

@Test(.timeLimit(.minutes(1)))
func aForwardToAnythingButAGuestSocketIsRefused() async throws {
    let fake = try FakeGuestADB()
    let client = AdbClient(executable: fake.executable)
    do {
        _ = try await client.forward(remote: "tcp:8080")
        Issue.record("a forward to a non-socket target was started")
    } catch let failure as AdbFailure {
        #expect(failure == .invalidArgument(command: "forward"))
    }
}

@Test(.timeLimit(.minutes(1)))
func startGuestAgentRunsTheDocumentedAppProcessCommand() async throws {
    let fake = try FakeGuestADB()
    let client = AdbClient(executable: fake.executable)
    try await client.startGuestAgent(packageName: "io.apkrun.guest")
    let started = fake.calls.first { $0.contains("app_process") } ?? ""
    #expect(started.contains("setsid nohup app_process -Dapkrun.mode=development / --nice-name=apkrun_guestd"))
    #expect(started.contains("io.apkrun.guest.daemon.Main"))
}

@Test(.timeLimit(.minutes(1)))
func aMatchingVersionIsInstalledAgainOnEveryStart() async throws {
    let fake = try FakeGuestADB()
    try fake.setInstalledVersion(1000)
    let provisioner = GuestAgentProvisioner(
        adb: AdbClient(executable: fake.executable),
        bundle: bundle(version: 1000)
    )
    try await provisioner.install()
    #expect(fake.calls.contains { $0.hasPrefix("-s 127.0.0.1:6520 install -r -t ") })
    #expect(!fake.calls.contains("-s 127.0.0.1:6520 uninstall io.apkrun.guest"))
}

@Test(.timeLimit(.minutes(1)))
func aDifferentVersionIsInstalledWithTheTestOnlyFlag() async throws {
    let fake = try FakeGuestADB()
    try fake.setInstalledVersion(999)
    let provisioner = GuestAgentProvisioner(
        adb: AdbClient(executable: fake.executable),
        bundle: bundle(version: 1000)
    )
    try await provisioner.install()
    #expect(fake.calls.contains { $0.hasPrefix("-s 127.0.0.1:6520 install -r -t ") })
}

@Test(.timeLimit(.minutes(1)))
func anOlderBundleReplacesANewerInstalledAgentByRemovingIt() async throws {
    let fake = try FakeGuestADB()
    try fake.setInstalledVersion(1001)
    let provisioner = GuestAgentProvisioner(
        adb: AdbClient(executable: fake.executable),
        bundle: bundle(version: 1000)
    )
    try await provisioner.install()
    let calls = fake.calls
    let uninstall = calls.firstIndex(of: "-s 127.0.0.1:6520 uninstall io.apkrun.guest")
    let install = calls.firstIndex { $0.hasPrefix("-s 127.0.0.1:6520 install -r -t ") }
    #expect(uninstall != nil && install != nil)
    if let uninstall, let install {
        #expect(uninstall < install)
    }
}

@Test(.timeLimit(.minutes(1)))
func aSignerMismatchUninstallsBetweenTheRefusedInstallAndTheRetry() async throws {
    let fake = try FakeGuestADB()
    try fake.setInstalledVersion(999)
    try fake.refuseNextInstall()
    let provisioner = GuestAgentProvisioner(
        adb: AdbClient(executable: fake.executable),
        bundle: bundle(version: 1000)
    )
    try await provisioner.install()
    let calls = fake.calls
    let installs = calls.indices.filter { calls[$0].contains(" install -r -t ") }
    let uninstall = calls.firstIndex(of: "-s 127.0.0.1:6520 uninstall io.apkrun.guest")
    #expect(installs.count == 2)
    #expect(uninstall != nil)
    if let uninstall, installs.count == 2 {
        #expect(installs[0] < uninstall)
        #expect(uninstall < installs[1])
    }
}

@Test(.timeLimit(.minutes(1)))
func aRefusalThatTheRetryDoesNotClearIsInstallFailedWithAndroidsReason() async throws {
    let fake = try FakeGuestADB()
    try fake.setInstalledVersion(999)
    try fake.refuseEveryInstall()
    let provisioner = GuestAgentProvisioner(
        adb: AdbClient(executable: fake.executable),
        bundle: bundle(version: 1000)
    )
    do {
        try await provisioner.install()
        Issue.record("the install succeeded although Android refused it")
    } catch {
        #expect(error == .installFailed(reason: "INSTALL_FAILED_UPDATE_INCOMPATIBLE"))
    }
}

@Test(.timeLimit(.minutes(1)))
func startingReplacesARunningAgentFirst() async throws {
    let fake = try FakeGuestADB()
    try fake.setRunning(true)
    let provisioner = GuestAgentProvisioner(
        adb: AdbClient(executable: fake.executable),
        bundle: bundle(version: 1000)
    )
    try await provisioner.startAgent()
    let calls = fake.calls
    let kill = calls.firstIndex(of: "-s 127.0.0.1:6520 shell kill 2121")
    let start = calls.firstIndex { $0.contains("app_process") }
    #expect(kill != nil && start != nil)
    if let kill, let start {
        #expect(kill < start)
    }
}

/// Keeps the entries that a logger writes, so that a test can read the error codes it logged.
private final class EntryRecorder: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LogEntry] = []

    var entries: [LogEntry] {
        lock.withLock { stored }
    }

    func isEnabled(for level: LogLevel) -> Bool {
        true
    }

    func write(_ entry: LogEntry) {
        lock.withLock { stored.append(entry) }
    }
}

@Test(.timeLimit(.minutes(1)))
func aRestartThatFailsIsLoggedWithTheCodeOfItsOwnFailure() async throws {
    let fake = try FakeGuestADB()
    try fake.setRunning(false)
    try fake.refuseEveryStart()
    let recorder = EntryRecorder()
    let agent = DevelopmentGuestAgent(
        adb: AdbClient(executable: fake.executable),
        bundle: bundle(version: 1000),
        logSink: recorder
    )
    let restarted = await agent.handleLoss(.disconnected)
    #expect(!restarted)
    let codes = recorder.entries.compactMap(\.errorCode)
    #expect(codes.contains("runtime.adb"), "the logged codes are \(codes)")
    #expect(!codes.contains("runtime.guestAgentStartFailed"))
}

@Test(.timeLimit(.minutes(1)))
func aFourthDeathWithinAMinuteIsRequiredAgentUnavailable() async throws {
    // Three deaths are restarted, and the fourth within the minute is refused. The refusal is the code that the
    // host reports (guest-components.md §3.3, #73 acceptance).
    let fake = try FakeGuestADB()
    let agent = DevelopmentGuestAgent(
        adb: AdbClient(executable: fake.executable),
        bundle: bundle(version: 1000)
    )
    // A loss counts as a death only when the process is gone, so each death first stops the fake agent.
    for death in 1...3 {
        try fake.setRunning(false)
        #expect(await agent.handleLoss(.disconnected), "death \(death) should be restarted")
    }
    try fake.setRunning(false)
    #expect(await agent.handleLoss(.disconnected) == false)
    do throws(GuestAgentFailure) {
        try await agent.requireAvailable()
        Issue.record("the agent after its fourth death was reported as available")
    } catch {
        #expect(error == .requiredAgentUnavailable)
        // The catalog code is the one that the host reports (error-catalog.md).
        #expect(error.qualifiedCode == "runtime.requiredAgentUnavailable")
    }
}

@Test(.timeLimit(.minutes(1)))
func theRequiredAgentDeadlineIncludesProvisioning() async throws {
    let fake = try FakeGuestADB()
    try fake.slowInstall()
    let agent = DevelopmentGuestAgent(
        adb: AdbClient(executable: fake.executable),
        bundle: bundle(version: 1000)
    )
    let started = ContinuousClock.now
    do {
        try await agent.start(connectTimeout: .milliseconds(1_500))
        Issue.record("the Guest Agent installed after its connection deadline")
    } catch {
        #expect(error == .connectTimedOut)
    }
    #expect(ContinuousClock.now - started < .seconds(5))
    #expect(
        fake.calls.contains { $0.hasPrefix("-s 127.0.0.1:6520 install -r -t ") },
        "ADB calls were \(fake.calls)"
    )
}

@Test(.timeLimit(.minutes(1)))
func aRestartFinishingAfterStopDoesNotLeaveTheAgentRunning() async throws {
    let fake = try FakeGuestADB()
    try fake.blockAgentStart()
    let agent = DevelopmentGuestAgent(
        adb: AdbClient(executable: fake.executable),
        bundle: bundle(version: 1000)
    )
    let restart = Task { await agent.handleLoss(.unresponsive) }
    let deadline = ContinuousClock.now + .seconds(5)
    while !fake.agentStartEntered, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(fake.agentStartEntered, "the fake ADB did not reach the blocked start command")

    await agent.stop()
    fake.allowAgentStart()

    #expect(await restart.value == false)
    #expect(!fake.agentIsRunning)
    #expect(fake.calls.contains("-s 127.0.0.1:6520 shell kill 2121"))
}
