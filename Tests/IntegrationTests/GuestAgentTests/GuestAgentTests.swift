import DiagnosticsCore
import Foundation
import GuestProtocol
import RuntimeCore
import XCTest

/// The development Guest Agent on a real Android guest (#072 T2; guest-components.md §3, §12; guest-protocol.md
/// §15). The suite runs in the `AndroidGuestAgent` configuration of IntegrationTests.xctestplan. It needs the Android
/// bundle of `scripts/build-test-android-bundle.sh` and the Guest Agent bundle of `scripts/build-guest.sh`.
final class GuestAgentTests: XCTestCase {
    private static let agentPackage = "io.apkrun.guest"
    private static let processName = "apkrun_guestd"
    private static let helloText = "io.apkrun.fixture.hellotext"

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["APKRUN_INTEGRATION_SUITE"] == "android-guest-agent" else {
            throw XCTSkip("The Guest Agent checks run in the AndroidGuestAgent test-plan configuration.")
        }
    }

    /// `apkrun dev boot` installs and starts the agent, and the agent answers the handshake and Ping (guest-protocol.md
    /// §5, guest-components.md §3.2). The boot itself waits at most 5 s for the connection.
    func testDevelopmentBootConnectsAndAnswersPing() async throws {
        let bundle = try Self.bundle()
        try await AndroidBootSession.withBoot(developerMode: true, guestAgentBundle: bundle) { session in
            guard let agent = await session.supervisor.developmentGuestAgent else {
                return XCTFail("the boot did not start the development Guest Agent")
            }
            let state = await agent.supervisor.state
            XCTAssertEqual(state, .ready)
            let info = await agent.supervisor.session
            XCTAssertEqual(info?.agentProtocolVersion, ProtocolVersion(major: 1, minor: 0))
            XCTAssertEqual(info?.agentVersionCode, Int64(bundle.versionCode))
            XCTAssertTrue(info?.enabledCapabilities.contains("core.v1") ?? false)
            let pong = try await agent.supervisor.send(GuestPing(nonce: 9))
            XCTAssertEqual(pong.nonce, 9)
            let displays = await agent.supervisor.snapshot.displays.keys
            XCTAssertTrue(displays.contains(0), "the snapshot does not list display 0")
        }
    }

    /// Every SystemServices wrapper resolves on the stock image (guest-components.md §6.2, #072 acceptance). The check
    /// runs the daemon's own classes through app_process.
    func testEveryServiceWrapperResolvesOnTheStockImage() async throws {
        let bundle = try Self.bundle()
        try await AndroidBootSession.withBoot(developerMode: true, guestAgentBundle: bundle) { _ in
            let adb = try await Self.connectedClient()
            let reply = try await adb.shell(
                "CLASSPATH=$(pm path \(Self.agentPackage) | sed \"s/^package://\") app_process / io.apkrun.guest.daemon.ServiceCheck"
            )
            let lines = reply.output.split(separator: "\n").map(String.init)
            XCTAssertEqual(lines.count, 5, "the check reported \(lines)")
            for line in lines {
                XCTAssertTrue(line.contains("available=true"), "a wrapper does not resolve: \(line)")
                XCTAssertTrue(line.hasSuffix("missing="), "a method is missing: \(line)")
            }
        }
    }

    /// `apkrun dev launch` starts HelloText on display 0 through `LaunchApplication`, and the agent reports its task
    /// (#072 acceptance, guest-protocol.md §7.1 #14).
    func testLaunchPutsHelloTextOnDisplayZero() async throws {
        let apk = try Self.fixtureAPK()
        let bundle = try Self.bundle()
        try await AndroidBootSession.withBoot(developerMode: true, guestAgentBundle: bundle) { session in
            let adb = try await Self.connectedClient()
            try await adb.install(apk: apk)
            guard let agent = await session.supervisor.developmentGuestAgent else {
                return XCTFail("the boot did not start the development Guest Agent")
            }
            let report = try await agent.launch(package: Self.helloText, displayID: 0)
            XCTAssertGreaterThan(report.taskID, 0)
            XCTAssertEqual(report.outcome, "started")
            let appeared = await Self.waitUntil {
                await agent.supervisor.snapshot.tasks.values.contains {
                    $0.package == Self.helloText && $0.displayID == 0
                }
            }
            XCTAssertTrue(appeared, "no task of \(Self.helloText) appeared on display 0")
        }
    }

    /// A killed agent is restarted by the host, and the supervisor reconnects and resynchronises (#072 acceptance,
    /// guest-components.md §3.3). The new session has a new token.
    func testKilledAgentIsRestartedAndTheSupervisorResynchronises() async throws {
        let bundle = try Self.bundle()
        try await AndroidBootSession.withBoot(developerMode: true, guestAgentBundle: bundle) { session in
            guard let agent = await session.supervisor.developmentGuestAgent else {
                return XCTFail("the boot did not start the development Guest Agent")
            }
            let adb = try await Self.connectedClient()
            let pidBefore = try await adb.processID(named: Self.processName)
            let tokenBefore = await agent.supervisor.session?.sessionToken
            try await adb.terminateProcess(named: Self.processName)
            let resynchronised = await Self.waitUntil(seconds: 60) {
                let state = await agent.supervisor.state
                let token = await agent.supervisor.session?.sessionToken
                return state == .ready && token != nil && token != tokenBefore
            }
            XCTAssertTrue(resynchronised, "the supervisor did not reconnect after the agent was killed")
            let pidAfter = try await adb.processID(named: Self.processName)
            XCTAssertNotNil(pidAfter)
            XCTAssertNotEqual(pidBefore, pidAfter)
            let pong = try await agent.supervisor.send(GuestPing(nonce: 3))
            XCTAssertEqual(pong.nonce, 3)
        }
    }

    /// A fourth death within a minute is not restarted, and the host reports `requiredAgentUnavailable` (#072
    /// acceptance, guest-components.md §3.3).
    func testAFourthDeathWithinAMinuteIsRequiredAgentUnavailable() async throws {
        let bundle = try Self.bundle()
        try await AndroidBootSession.withBoot(developerMode: true, guestAgentBundle: bundle) { session in
            guard let agent = await session.supervisor.developmentGuestAgent else {
                return XCTFail("the boot did not start the development Guest Agent")
            }
            let adb = try await Self.connectedClient()
            for death in 1...3 {
                let before = await agent.supervisor.session?.sessionToken
                try await adb.terminateProcess(named: Self.processName)
                let back = await Self.waitUntil(seconds: 60) {
                    let token = await agent.supervisor.session?.sessionToken
                    return token != nil && token != before
                }
                XCTAssertTrue(back, "restart \(death) did not reconnect")
            }
            try await adb.terminateProcess(named: Self.processName)
            let unavailable = await Self.waitUntil(seconds: 60) { await agent.supervisor.state == .unavailable }
            XCTAssertTrue(unavailable, "the fourth death did not end the supervisor")
            do {
                try await agent.requireAvailable()
                XCTFail("the unavailable agent was reported as available")
            } catch let failure as GuestAgentFailure {
                XCTAssertEqual(failure, .requiredAgentUnavailable)
            }
        }
    }

    /// An installed agent with another version is replaced by the bundled one (#072 acceptance, guest-components.md
    /// §3.1). The second version is built by `scripts/build-guest.sh --version-code`.
    func testAnotherInstalledVersionIsReplacedByTheBundle() async throws {
        let bundle = try Self.bundle()
        let other = try Self.otherBundle()
        try await AndroidBootSession.withBoot(developerMode: true, guestAgentBundle: bundle) { _ in
            let adb = try await Self.connectedClient()
            try await GuestAgentProvisioner(adb: adb, bundle: other).install()
            let installed = try await adb.listPackages(matching: Self.agentPackage).first?.versionCode
            XCTAssertEqual(installed, other.versionCode)
            try await GuestAgentProvisioner(adb: adb, bundle: bundle).install()
            let restored = try await adb.listPackages(matching: Self.agentPackage).first?.versionCode
            XCTAssertEqual(restored, bundle.versionCode)
        }
    }

    /// The ADB forward listens on the host's loopback address only (NFR-SEC-06, guest-protocol.md §13.2).
    func testTheAgentForwardListensOnTheLoopbackAddressOnly() async throws {
        let bundle = try Self.bundle()
        try await AndroidBootSession.withBoot(developerMode: true, guestAgentBundle: bundle) { _ in
            let adb = try await Self.connectedClient()
            let port = try await adb.forward(remote: "localabstract:apkrun-guestd-control")
            defer {
                Task { try? await adb.forwardRemove(port: port) }
            }
            XCTAssertEqual(try AndroidADBTests.listeningAddresses(port: port), ["127.0.0.1:\(port)"])
        }
    }

    /// The device setup of guest-components.md §3.4: the screen stays on, and there is no keyguard.
    func testTheDeviceStaysAwakeWithoutKeyguard() async throws {
        let bundle = try Self.bundle()
        try await AndroidBootSession.withBoot(developerMode: true, guestAgentBundle: bundle) { _ in
            let adb = try await Self.connectedClient()
            let stayOn = try await adb.shell("settings get global stay_on_while_plugged_in").output
            XCTAssertEqual(stayOn.trimmingCharacters(in: .whitespacesAndNewlines), "7")
            let timeout = try await adb.shell("settings get system screen_off_timeout").output
            XCTAssertEqual(timeout.trimmingCharacters(in: .whitespacesAndNewlines), "\(Int32.max)")
            let disabled = try await adb.shell("cmd lock_settings get-disabled").output
            XCTAssertEqual(disabled.trimmingCharacters(in: .whitespacesAndNewlines), "true")
        }
    }

    // MARK: - Helpers

    /// The Guest Agent bundle of `APKRUN_GUEST_DIR`. The test process cannot read the repository's `Documents` folder
    /// (macOS privacy), so the bundle is built into `/tmp` before the run (see the test plan's environment).
    private static func bundle() throws -> GuestAgentBundle {
        try loadBundle(environmentKey: "APKRUN_GUEST_DIR")
    }

    /// The Guest Agent bundle with another versionCode, of `APKRUN_GUEST_OTHER_DIR` (guest-components.md §3.1).
    private static func otherBundle() throws -> GuestAgentBundle {
        try loadBundle(environmentKey: "APKRUN_GUEST_OTHER_DIR")
    }

    private static func loadBundle(environmentKey: String) throws -> GuestAgentBundle {
        guard let path = ProcessInfo.processInfo.environment[environmentKey], !path.isEmpty else {
            throw XCTSkip(
                "\(environmentKey) is not set. Build the bundle with scripts/build-guest.sh --out, then set it.")
        }
        do {
            return try GuestAgentBundle.load(directory: URL(fileURLWithPath: path, isDirectory: true))
        } catch {
            throw XCTSkip("The Guest Agent bundle in \(path) could not be read: \(error.qualifiedCode)")
        }
    }

    /// The HelloText fixture APK, copied to `APKRUN_FIXTURE_APK` before the run.
    private static func fixtureAPK() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["APKRUN_FIXTURE_APK"], !path.isEmpty,
            FileManager.default.fileExists(atPath: path)
        else {
            throw XCTSkip(
                "APKRUN_FIXTURE_APK is not set. Copy the HelloText fixture of scripts/build-fixtures.sh to /tmp.")
        }
        return URL(fileURLWithPath: path)
    }

    /// An ADB client connected to the development endpoint.
    private static func connectedClient() async throws -> AdbClient {
        let adb = AdbClient(executable: try AndroidTestEnvironment.adbExecutable())
        try await adb.connect(timeout: .seconds(30))
        return adb
    }

    /// Polls `condition` every 200 ms until it holds, or `seconds` have passed.
    private static func waitUntil(seconds: Double = 30, _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return await condition()
    }
}
