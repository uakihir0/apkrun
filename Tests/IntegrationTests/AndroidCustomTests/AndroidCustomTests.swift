import Darwin
import DiagnosticsCore
import Foundation
import GuestProtocol
import RuntimeCore
import XCTest

/// T2 checks of the composed APKRun image (#36).
class AndroidCustomTestCase: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["APKRUN_INTEGRATION_SUITE"] == "android-custom" else {
            throw XCTSkip("Composed image checks run in the AndroidCustom test-plan configuration.")
        }
    }

    static func android(_ session: AndroidBootSession) async throws -> AndroidShellConsole {
        guard let shell = await session.supervisor.shell else {
            throw XCTSkip("The composed-image check needs the developer serial shell.")
        }
        return AndroidShellConsole(shell: shell)
    }

    static func adb(_ session: AndroidBootSession) async throws -> AdbClient {
        guard let port = await session.supervisor.developmentADBHostPort else {
            throw XCTSkip("The composed-image check needs developer-mode ADB.")
        }
        let client = AdbClient(
            executable: try AndroidTestEnvironment.adbExecutable(),
            endpoint: AdbClient.loopbackEndpoint(port: port)
        )
        try await client.connect(timeout: .seconds(30))
        return client
    }

    static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Boots the selected composed image and verifies its init marker and SELinux mode.
final class CustomImageBootTests: AndroidCustomTestCase {
    func testProductImageBootsWithEnforcingPolicy() async throws {
        try await AndroidBootSession.withBoot(developerMode: true) { session in
            let android = try await Self.android(session)
            let state = await session.supervisor.state
            XCTAssertEqual(state, .ready)
            let bootCompleted = try await android.value("getprop sys.boot_completed")
            let productMarker = try await android.value("getprop ro.apkrun.product")
            let enforcing = try await android.value("getenforce")
            let privilegedPermissionMode = try await android.value("getprop ro.control_privapp_permissions")
            XCTAssertEqual(Self.trimmed(bootCompleted), "1")
            XCTAssertEqual(Self.trimmed(privilegedPermissionMode), "enforce")
            XCTAssertEqual(Self.trimmed(enforcing), "Enforcing")
            if Self.trimmed(productMarker) != "1" {
                let productProperties = try await android.run("getprop | grep apkrun").output
                let initFile = try await android.run("ls -lZ /system_ext/etc/init/apkrun.rc").output
                let initTrace = try await android.run("dmesg | grep -E 'apkrun(_|[.]rc)'").output
                let propertyContext = try await android.run("getprop -Z ro.apkrun.product").output
                let propertyFiles = try await android.run(
                    "grep -n 'ro.apkrun.product' /system/build.prop /system_ext/build.prop "
                        + "/system_ext/etc/prop.default 2>/dev/null || true"
                ).output
                let initErrors = try await android.run("logcat -b all -d -s init:E").output
                XCTFail(
                    """
                    The product init marker is missing.
                    APKRun properties: \(productProperties)
                    Property context: \(propertyContext)
                    Property files: \(propertyFiles)
                    Init file: \(initFile)
                    Init trace: \(initTrace)
                    init errors: \(initErrors)
                    """
                )
            }
        }
    }
}

/// The composed image's agent is a persistent platform-signed privileged application.
final class SystemServicesTest: AndroidCustomTestCase {
    private static let package = "io.apkrun.guest"

    func testPersistentPrivilegedAgentHasItsAllowlistedPermissions() async throws {
        try await AndroidBootSession.withBoot(developerMode: true) { session in
            let android = try await Self.android(session)
            let path = try await android.value("pm path \(Self.package)")
            XCTAssertTrue(
                path.contains("/system_ext/priv-app/ApkRunGuest/ApkRunGuest.apk"),
                "Guest Agent was not loaded from system_ext: \(path)"
            )

            let package = try await android.output("dumpsys package \(Self.package)")
            XCTAssertTrue(package.contains("SYSTEM"), "the package is not a system app")
            XCTAssertTrue(package.contains("PRIVILEGED"), "the package is not privileged")

            for permission in [
                "android.permission.FORCE_STOP_PACKAGES",
                "android.permission.INJECT_EVENTS",
                "android.permission.INTERNAL_SYSTEM_WINDOW",
                "android.permission.MANAGE_ACTIVITY_TASKS",
                "android.permission.REMOVE_TASKS",
                "android.permission.SET_ACTIVITY_WATCHER",
                "android.permission.QUERY_ALL_PACKAGES",
                "android.permission.WRITE_SECURE_SETTINGS",
                "android.permission.REBOOT",
                "android.permission.WRITE_SETTINGS",
                "android.permission.ACCESS_KEYGUARD_SECURE_STORAGE",
            ] {
                let result = try await android.value(
                    "dumpsys package check-permission \(permission) \(Self.package) 0"
                )
                XCTAssertEqual(Self.trimmed(result), "0", "\(permission) was not granted")
            }

            let processID = try await android.value("pidof \(Self.package)")
            XCTAssertFalse(processID.isEmpty, "the persistent Guest Agent process is not running")
            let processContext = try await android.value(
                "ps -A -Z | grep \(Self.package) | head -n 1"
            )
            XCTAssertTrue(
                processContext.contains("u:r:apkrun_guest_app:s0"),
                """
                the APKRun platform-signed priv-app did not receive its seapp_contexts domain \
                (which requires seinfo=platform): \(processContext)
                """
            )
            let bridgeProcess = try await android.value("pidof apkrun_vsockd")
            XCTAssertFalse(bridgeProcess.isEmpty, "apkrun_vsockd is not running")
            let bridgeContext = try await android.value(
                "ps -A -Z | grep apkrun_vsockd | head -n 1"
            )
            XCTAssertTrue(
                bridgeContext.contains("u:r:apkrun_vsockd:s0"),
                "apkrun_vsockd did not receive its product domain: \(bridgeContext)"
            )
            try await Self.verifySystemServiceInstrumentation(session: session)
        }
    }

    func testPersistentAgentRestartsAfterProcessKill() async throws {
        try await AndroidBootSession.withBoot(developerMode: true) { session in
            let android = try await Self.android(session)
            guard let originalPID = try await Self.agentProcessID(using: android) else {
                return XCTFail("the persistent Guest Agent process is not running before the kill")
            }
            _ = try await android.output("kill -9 \(originalPID)", root: true)

            let deadline = ContinuousClock.now + .seconds(60)
            var restartedPID: Int?
            while ContinuousClock.now < deadline {
                if let currentPID = try await Self.agentProcessID(using: android),
                    currentPID != originalPID
                {
                    restartedPID = currentPID
                    break
                }
                try await Task.sleep(for: .milliseconds(200))
            }

            guard let restartedPID else {
                let processState = try await android.run(
                    "ps -A -Z | grep \(Self.package) || true"
                ).output
                let activityState = try await android.run(
                    "dumpsys activity processes | grep -A 3 -B 2 \(Self.package) || true"
                ).output
                XCTFail(
                    """
                    ActivityManager did not restart the persistent Guest Agent with a new PID \
                    within 60 seconds (original PID: \(originalPID)).
                    Processes: \(processState)
                    ActivityManager state: \(activityState)
                    """
                )
                return
            }
            XCTAssertNotEqual(restartedPID, originalPID)

            let agent = try await VsockAgentTests.connectPersistentAgent(session)
            do {
                let pong = try await agent.send(GuestPing(nonce: 36))
                XCTAssertEqual(pong.nonce, 36)
            } catch {
                await agent.stop()
                throw error
            }
            await agent.stop()
        }
    }

    private struct SystemServiceOutcome {
        var available = true
        var servicePresent = true
        var missingMethods = Set<String>()
    }

    private static func systemServicesTestAPK() throws -> URL {
        let environment = AndroidTestEnvironment.current()
        let configured =
            environment["APKRUN_SYSTEM_SERVICES_TEST_APK"]
            ?? Bundle.main.object(forInfoDictionaryKey: "APKRUN_SYSTEM_SERVICES_TEST_APK") as? String
        guard let path = configured, !path.isEmpty, FileManager.default.isReadableFile(atPath: path) else {
            throw AndroidShellConsole.CheckFailure(
                command: "SystemServicesTest fixture",
                detail:
                    "build with scripts/build-fixtures.sh --app SystemServicesTest --platform-test-key "
                    + "and stage APKRUN_SYSTEM_SERVICES_TEST_APK."
            )
        }
        return URL(fileURLWithPath: path)
    }

    private static func verifySystemServiceInstrumentation(session: AndroidBootSession) async throws {
        let apk = try systemServicesTestAPK()
        let adb = try await Self.adb(session)
        let instrumentationPackage = "io.apkrun.fixture.systemservicestest"
        try await adb.install(apk: apk)

        let instrumentation: AdbShellReply
        do {
            instrumentation = try await adb.shell(
                "am instrument -w \(instrumentationPackage)/.SystemServicesInstrumentation",
                timeout: .seconds(120)
            )
        } catch {
            try? await adb.uninstall(packageName: instrumentationPackage)
            throw error
        }
        do {
            try await adb.uninstall(packageName: instrumentationPackage)
        } catch {
            XCTFail("could not remove the temporary system-services instrumentation APK: \(error)")
        }

        let output = instrumentation.output + "\n" + instrumentation.errorOutput
        XCTAssertEqual(instrumentation.status, 0, "am instrument did not complete: \(output)")
        XCTAssertTrue(output.contains("INSTRUMENTATION_CODE: -1"), "instrumentation failed: \(output)")
        XCTAssertTrue(output.contains("APKRUN_SYSTEM_SERVICES_OK"), "instrumentation checks failed: \(output)")
        XCTAssertFalse(output.contains("APKRUN_SYSTEM_SERVICES_FAILED"), output)

        var outcomes: [String: SystemServiceOutcome] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let marker = line.range(of: "APKRUN_SYSTEM_SERVICE|") else { continue }
            let fields = line[marker.lowerBound...].split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 5 else {
                XCTFail("malformed SystemServices instrumentation record: \(line)")
                continue
            }
            let service = String(fields[1])
            guard ["true", "false"].contains(String(fields[2])),
                ["true", "false"].contains(String(fields[3]))
            else {
                XCTFail("malformed availability for \(service): \(fields[2])")
                continue
            }
            var outcome = outcomes[service] ?? SystemServiceOutcome()
            outcome.available = outcome.available && fields[2] == "true"
            outcome.servicePresent = outcome.servicePresent && fields[3] == "true"
            if !fields[4].isEmpty {
                for method in fields[4].split(separator: ",") {
                    outcome.missingMethods.insert(String(method))
                }
            }
            outcomes[service] = outcome
        }
        let expectedServices: Set<String> = [
            "activity",
            "activity_task",
            "display",
            "input",
            "lock_settings",
            "power",
            "window",
        ]
        XCTAssertEqual(Set(outcomes.keys), expectedServices, "incomplete wrapper report: \(output)")

        let agent = try await VsockAgentTests.connectPersistentAgent(session)
        let enabledCapabilities = await agent.session?.enabledCapabilities ?? []
        let enabled = Set(enabledCapabilities)
        func resolves(_ methods: [(service: String, method: String)]) -> Bool {
            methods.allSatisfy { requirement in
                guard let outcome = outcomes[requirement.service] else { return false }
                return outcome.servicePresent && !outcome.missingMethods.contains(requirement.method)
            }
        }
        let capabilityRequirements: [(String, [(service: String, method: String)])] = [
            (
                "display.v1",
                [
                    ("display", "getDisplayIds"),
                    ("display", "getDisplayInfo"),
                    ("display", "registerCallback"),
                    ("window", "setForcedDisplayDensityForUser"),
                    ("window", "setDisplayImePolicy"),
                ]
            ),
            (
                "launch.v1",
                [
                    ("activity_task", "getTasks"),
                    ("activity_task", "registerTaskStackListener"),
                    ("activity_task", "startActivityAsUser"),
                    ("activity_task", "moveRootTaskToDisplay"),
                    ("activity_task", "removeTask"),
                    ("activity_task", "setFocusedTask"),
                    ("activity", "forceStopPackage"),
                ]
            ),
            (
                "input.v1",
                [
                    ("activity_task", "getTasks"),
                    ("activity_task", "setFocusedTask"),
                    ("input", "injectInputEvent"),
                ]
            ),
            ("system.v1", [("power", "shutdown")]),
        ]
        for (capability, requirements) in capabilityRequirements {
            XCTAssertEqual(
                enabled.contains(capability),
                resolves(requirements),
                "\(capability) handshake does not match the on-image SystemServices wrappers; "
                    + "enabled=\(enabled), records=\(outcomes)"
            )
        }
        let agentState = await agent.state
        XCTAssertEqual(agentState, .ready)
        await agent.stop()
    }

    private static func agentProcessID(using android: AndroidShellConsole) async throws -> Int? {
        let output = try await android.value("pidof \(package) || echo 0")
        guard let token = output.split(whereSeparator: \.isWhitespace).first,
            let processID = Int(token),
            processID > 0
        else {
            return nil
        }
        return processID
    }
}

/// ADB is reachable only while the runtime has developer mode enabled.
final class DeveloperModeAdbTests: AndroidCustomTestCase {
    func testAdbUsesLoopbackInDeveloperModeAndVsockPortIsClosedOtherwise() async throws {
        try await AndroidBootSession.withBoot(developerMode: true) { session in
            let adb = try await Self.adb(session)
            let mode = try await adb.shell("getprop ro.boot.apkrun.devmode")
            XCTAssertEqual(Self.trimmed(mode.output), "1")
            let daemon = try await adb.shell("getprop init.svc.adbd")
            XCTAssertEqual(Self.trimmed(daemon.output), "running")
            let hostPort = await session.supervisor.developmentADBHostPort
            XCTAssertEqual(hostPort, 6520)
            XCTAssertEqual(adb.endpoint, AdbClient.developmentEndpoint)
        }

        try await AndroidBootSession.withBoot(developerMode: false) { session in
            let state = await session.supervisor.state
            XCTAssertEqual(state, .ready)
            let adbdStopped = await session.capture.wait(
                for: "APKRUN-TEST-ADBD-STOPPED",
                within: .seconds(5)
            )
            XCTAssertTrue(
                adbdStopped,
                """
                init did not report adbd stopped at boot completion with developer mode off:
                \(session.capture.console().suffix(500))
                """
            )
            let hostPort = await session.supervisor.developmentADBHostPort
            XCTAssertNil(hostPort)
            let serialShell = await session.supervisor.shell
            XCTAssertNil(serialShell, "developer serial shell was exposed without developer mode")
            do {
                let connection = try await session.supervisor.connect(
                    vsockPort: 5555,
                    timeout: .seconds(2)
                )
                connection.close()
                XCTFail("vsock port 5555 accepted a connection without developer mode")
            } catch let failure as RuntimeBootFailure {
                switch failure {
                case .vm(.vsockPortNotListening(port: 5555)):
                    break
                case .vm(.vsockConnectFailed(port: 5555, underlying: let error))
                where error.domain == NSPOSIXErrorDomain && error.code == Int(ECONNRESET):
                    // Virtualization.framework reports a closed guest vsock listener as a reset on macOS 27.
                    break
                default:
                    XCTFail("unexpected vsock failure while checking disabled adbd: \(failure)")
                    return
                }
            }
        }
    }
}

/// The preinstalled Guest Agent completes its handshake over the production vsock bridge.
final class VsockAgentTests: AndroidCustomTestCase {
    func testPersistentAgentAnswersPingOverVsockWithoutAdb() async throws {
        try await AndroidBootSession.withBoot(developerMode: false) { session in
            let hostPort = await session.supervisor.developmentADBHostPort
            XCTAssertNil(hostPort)
            let transport = VsockGuestTransport { port, timeout in
                try await session.supervisor.connect(vsockPort: port, timeout: timeout)
            }
            let agent = GuestAgentSupervisor(
                transport: transport,
                restartAgent: { _ in false }
            )
            do {
                try await agent.start(connectTimeout: .seconds(30))
                let pong = try await agent.send(GuestPing(nonce: 36))
                XCTAssertEqual(pong.nonce, 36)
                let health = try await agent.send(GuestGetHealth())
                XCTAssertEqual(health.mode, .privilegedApp)
                XCTAssertGreaterThan(health.agentUptimeMs, 0)
                let enabledCapabilities = await agent.session?.enabledCapabilities ?? []
                XCTAssertEqual(
                    Set(enabledCapabilities),
                    Set([
                        "core.v1",
                        "display.v1",
                        "launch.v1",
                        "input.v1",
                        "input.ack_trace.v1",
                        "packages.v1",
                        "health.v1",
                        "system.v1",
                    ]),
                    "the privileged agent did not advertise every implemented capability through Guest Protocol operation 21"
                )
                let state = await agent.state
                XCTAssertEqual(state, .ready)
            } catch {
                await agent.stop()
                throw error
            }
            await agent.stop()
        }
    }
}

/// An ordinary app cannot connect to the Guest Agent's abstract sockets or create a vsock socket.
final class AgentSocketIsolationTests: AndroidCustomTestCase {
    private static let package = "io.apkrun.fixture.helloprobe"

    func testHelloProbeIsDeniedByTheEnforcingGuestPolicy() async throws {
        let apk = try Self.probeAPK()
        try await AndroidBootSession.withBoot(developerMode: true) { session in
            let agent = try await VsockAgentTests.connectPersistentAgent(session)
            do {
                let android = try await Self.android(session)
                let adb = try await Self.adb(session)
                try await adb.install(apk: apk)
                let launch = try await adb.shell("am start -n \(Self.package)/.MainActivity")
                XCTAssertEqual(launch.status, 0, launch.errorOutput)

                let deadline = ContinuousClock.now + .seconds(30)
                var output = ""
                while ContinuousClock.now < deadline {
                    output = try await adb.shell("logcat -d -t 200 -s HelloProbe:I").output
                    if output.contains("probe-complete") {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(200))
                }
                if !output.contains("probe-complete") {
                    let packageState = try await adb.shell(
                        "dumpsys package \(Self.package) | grep -E 'codePath=|userId=|enabled=' || true"
                    ).output
                    let activityState = try await adb.shell(
                        "dumpsys activity activities | grep -E 'ResumedActivity|topResumedActivity|helloprobe' || true"
                    ).output
                    let appProcesses = try await adb.shell(
                        "ps -A -Z | grep \(Self.package) || true"
                    ).output
                    let relevantLogs = try await adb.shell(
                        "logcat -b all -d -t 500 | grep -E 'HelloProbe|helloprobe|AndroidRuntime|ActivityTaskManager|FATAL EXCEPTION|avc:' || true"
                    ).output
                    output = """
                        filtered HelloProbe logcat:
                        \(output)
                        package state:
                        \(packageState)
                        activity state:
                        \(activityState)
                        app processes:
                        \(appProcesses)
                        relevant system logs:
                        \(relevantLogs)
                        launch output:
                        \(launch.output)
                        launch error:
                        \(launch.errorOutput)
                        """
                }
                XCTAssertTrue(output.contains("unix-control=denied"), output)
                XCTAssertTrue(output.contains("unix-input=denied"), output)
                XCTAssertTrue(output.contains("unix-bulk=denied"), output)
                XCTAssertFalse(output.contains("unix-control=connected"), output)
                XCTAssertFalse(output.contains("unix-input=connected"), output)
                XCTAssertFalse(output.contains("unix-bulk=connected"), output)
                XCTAssertTrue(output.contains("vsock=denied"), output)
                XCTAssertTrue(output.contains("probe-complete"), "HelloProbe did not finish: \(output)")
                let probeContext = try await android.run(
                    "ps -A -Z | grep \(Self.package) | head -n 1"
                ).output
                XCTAssertTrue(
                    probeContext.contains("u:r:untrusted_app:s0"),
                    "HelloProbe did not run in the untrusted_app domain: \(probeContext)"
                )
            } catch {
                await agent.stop()
                throw error
            }
            await agent.stop()
        }
    }

    private static func probeAPK() throws -> URL {
        let configured =
            ProcessInfo.processInfo.environment["APKRUN_FIXTURE_PROBE_APK"]
            ?? Bundle.main.object(forInfoDictionaryKey: "APKRUN_FIXTURE_PROBE_APK") as? String
        guard let path = configured, !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            throw AndroidShellConsole.CheckFailure(
                command: "HelloProbe fixture",
                detail: "APKRUN_FIXTURE_PROBE_APK must point to the staged signed APK."
            )
        }
        return URL(fileURLWithPath: path)
    }
}

extension VsockAgentTests {
    fileprivate static func connectPersistentAgent(_ session: AndroidBootSession) async throws
        -> GuestAgentSupervisor
    {
        let transport = VsockGuestTransport { port, timeout in
            try await session.supervisor.connect(vsockPort: port, timeout: timeout)
        }
        let agent = GuestAgentSupervisor(transport: transport, restartAgent: { _ in false })
        try await agent.start(connectTimeout: .seconds(30))
        return agent
    }
}

/// The new privileged domains remain enforcing cleanly while their services are exercised.
final class SelinuxDenialTests: AndroidCustomTestCase {
    func testAgentAndBridgeDomainsHaveNoAvcDenials() async throws {
        try await AndroidBootSession.withBoot(developerMode: true) { session in
            let agent = try await VsockAgentTests.connectPersistentAgent(session)
            do {
                let pong = try await agent.send(GuestPing(nonce: 36))
                XCTAssertEqual(pong.nonce, 36)
                let health = try await agent.send(GuestGetHealth())
                XCTAssertEqual(health.mode, .privilegedApp)
                let android = try await Self.android(session)
                let adb = try await Self.adb(session)
                let enforcing = try await android.value("getenforce", root: true)
                XCTAssertEqual(Self.trimmed(enforcing), "Enforcing")

                _ = try await android.output("sh -c 'dmesg > /dev/apkrun-dmesg.txt'", root: true)
                let kernelLog = try await android.run(
                    "grep 'apkrun_' /dev/apkrun-dmesg.txt",
                    root: true
                ).output
                let denials = kernelLog.split(separator: "\n").filter {
                    Self.isAvcDenial($0)
                        && ($0.contains("scontext=u:r:apkrun_guest_app:")
                            || $0.contains("scontext=u:r:apkrun_vsockd:"))
                }
                XCTAssertTrue(denials.isEmpty, "new APKRun domains emitted SELinux denials: \(denials)")

                let logcat = try await adb.shell(
                    "logcat -b all -d -t 200 | grep -E 'apkrun_guest_app|apkrun_vsockd' || true"
                ).output
                let serviceDenials = logcat.split(separator: "\n").filter {
                    Self.isAvcDenial($0)
                        && ($0.contains("apkrun_guest_app") || $0.contains("apkrun_vsockd"))
                }
                XCTAssertTrue(
                    serviceDenials.isEmpty,
                    "new APKRun domains emitted SELinux denials in logcat: \(serviceDenials)"
                )
            } catch {
                await agent.stop()
                throw error
            }
            await agent.stop()
        }
    }

    private static func isAvcDenial(_ line: Substring) -> Bool {
        String(line).range(of: #"avc:\s+denied"#, options: .regularExpression) != nil
    }
}
