import Foundation
import XCTest

/// The Android network check of #095 step 5 (FR-VM-04): an address, a vmnet default route, DNS, and a validated
/// Wi-Fi network.
///
/// It is #095's open check, not a condition of gate G2 (#014; IR-374), so it runs in its own `AndroidNetwork`
/// test-plan configuration of `IntegrationTests`. CI and the gate do not select that configuration. Run it by hand
/// with `-only-test-configuration AndroidNetwork -only-testing:IntegrationTests/AndroidNetworkTests`: the LinuxGuest
/// classes do not check the suite variable, so the configuration alone would also boot Linux test guests (IR-545).
final class AndroidNetworkTests: XCTestCase {
    /// One stage of the network check, in the order the guest reaches it.
    private struct Stage {
        let name: String
        let command: String
        let expectation: String
        let passes: (String) -> Bool
    }

    /// The outcome of polling one stage: its last reply, and whether that reply passed within the bound.
    private struct Poll {
        let stage: Stage
        let lastValue: String
        let passed: Bool
        let polls: Int
        let elapsed: Duration
    }

    /// Each stage may take this long to pass. DHCP and the first Wi-Fi join finish after `ready`, and the
    /// captive-portal probe can take longer than the rest (IR-374).
    private static let stageBound: Duration = .seconds(120)
    private static let pollInterval: Duration = .seconds(2)
    private static let replyTimeout: Duration = .seconds(30)

    /// The four stages, in the order the guest reaches them (android-image.md §7.4).
    private var stages: [Stage] {
        [
            Stage(
                name: "address",
                // The design (android-image.md §7.4) puts the guest on wlan0 (virt_wifi on eth2) with vmnet's DHCP.
                command: "ip addr show wlan0 | grep 'inet '",
                expectation: "wlan0 has the vmnet IPv4 address",
                passes: { $0.contains("inet 192.168.") }
            ),
            Stage(
                name: "route",
                // IPv4 only: the router advertisement also gives an IPv6 default route on wlan0.
                command: "ip route show table all | grep 'default via 192'",
                expectation: "the default route goes through vmnet",
                passes: { $0.contains("default via 192.168.") }
            ),
            Stage(
                name: "dns",
                // ICMP gets no reply through vmnet, so name resolution is checked with getent, not ping.
                command: "getent hosts connectivitycheck.gstatic.com",
                expectation: "connectivitycheck.gstatic.com resolves to an address",
                passes: isResolvedAddress
            ),
            Stage(
                name: "validated",
                // NetworkMonitor's generate_204 probe passed when the line says VALIDATED. The command spells the
                // words in brackets, so the echo of the command cannot match the search (IR-370).
                command: "dumpsys connectivity | grep NetworkAgentInfo | grep 'WIF[I]' "
                    + "| grep 'VALID[A]TED' | tail -n 1",
                expectation: "the WIFI NetworkAgentInfo line is VALIDATED",
                passes: isValidatedWifiLine
            ),
        ]
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["APKRUN_INTEGRATION_SUITE"] == "android-network" else {
            throw XCTSkip("The Android network check runs in the AndroidNetwork test-plan configuration.")
        }
    }

    /// #095 step 5: the guest has an address, a default route, DNS, and a validated network (FR-VM-04).
    ///
    /// The checks run inside Android over the serial shell. `connectivitycheck` is the name NetworkMonitor
    /// probes, and `VALIDATED` in `dumpsys connectivity` means its `generate_204` probe passed.
    func testNetwork() async throws {
        let home = try AndroidBootFixture.makeHome()
        defer { removeTestHome(home) }
        let fixture = try await AndroidBootFixture(home: home, bundle: AndroidBootFixture.bundleDirectory())
        try await fixture.resetInstance()
        let supervisor = fixture.supervisor(developerMode: true)
        let collector = Task {
            for await _ in supervisor.events {}
        }
        var failure: Error?
        do {
            try await supervisor.ensureReady(.cli)
            let shellOrNil = await supervisor.shell
            let android = AndroidShellConsole(shell: try XCTUnwrap(shellOrNil))
            // Each stage has its own bound. The stages depend on each other, so the walk stops at the first stage
            // that does not pass, and the later stages are not polled.
            var polls: [Poll] = []
            for stage in stages {
                let outcome = try await poll(stage, on: android)
                polls.append(outcome)
                if !outcome.passed {
                    break
                }
            }
            for outcome in polls {
                XCTAssertTrue(
                    outcome.passed,
                    "\(outcome.stage.name): \(outcome.stage.expectation); last value: \(outcome.lastValue)"
                )
            }
            // The record names the stage that stopped the walk, so a failure is read without the test source.
            var lines = polls.map { outcome in
                "\(outcome.stage.name): \(outcome.passed ? "passed" : "not passed") after \(outcome.polls) polls, "
                    + "\(outcome.elapsed); last value: \(outcome.lastValue)"
            }
            let notPolled = stages.dropFirst(polls.count).map(\.name)
            lines.append("stopped at: \(polls.first { !$0.passed }?.stage.name ?? "none")")
            lines.append("not polled: \(notPolled.isEmpty ? "none" : notPolled.joined(separator: ", "))")
            // Diagnostics for the record: the Wi-Fi state, the links, the connectivity service's network agents,
            // and the join's log lines. Each command is read on its own, so one failed reply keeps the others.
            let diagnostics = [
                ("wifi agent", "dumpsys connectivity | grep NetworkAgentInfo | grep WIFI | tail -n 1"),
                ("wifi", "cmd wifi status | head -n 8"),
                ("links", "ip -o link | cut -c1-90"),
                ("wifi log", "logcat -d | grep -i virtwifi | tail -n 8"),
            ]
            for (label, command) in diagnostics {
                let text = (try? await android.run(command).output) ?? "unavailable"
                lines.append("\(label):\n\(text)")
            }
            let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
            attachment.lifetime = .keepAlways
            add(attachment)
        } catch {
            failure = error
        }
        let stopped = await ConsoleBuffer.completes(within: .seconds(90)) {
            await supervisor.stop()
        }
        collector.cancel()
        XCTAssertTrue(stopped, "the developer-mode stop returns within 90 s")
        if let failure {
            throw failure
        }
    }

    /// Polls `stage` until its reply passes or `stageBound` runs out. The outcome keeps the last reply, so a failure
    /// shows what the guest last said, not only that the stage did not pass.
    private func poll(_ stage: Stage, on android: AndroidShellConsole) async throws -> Poll {
        let start = ContinuousClock.now
        let deadline = start + Self.stageBound
        var polls = 0
        var lastValue = ""
        repeat {
            polls += 1
            do {
                lastValue = try await android.value(stage.command, timeout: Self.replyTimeout)
            } catch {
                lastValue = "no reply (\(error))"
            }
            if stage.passes(lastValue) {
                return Poll(
                    stage: stage,
                    lastValue: lastValue,
                    passed: true,
                    polls: polls,
                    elapsed: start.duration(to: ContinuousClock.now)
                )
            }
            try await Task.sleep(for: Self.pollInterval)
        } while ContinuousClock.now < deadline
        return Poll(
            stage: stage,
            lastValue: lastValue,
            passed: false,
            polls: polls,
            elapsed: start.duration(to: ContinuousClock.now)
        )
    }
}

/// Whether `text` is a `getent hosts` line for `connectivitycheck.gstatic.com`: an address first, then the name.
/// The address must lead, because the echo of the command also contains the name.
private func isResolvedAddress(_ text: String) -> Bool {
    text.range(of: #"^[0-9a-fA-F:.]+\s+connectivitycheck\.gstatic\.com$"#, options: .regularExpression) != nil
}

/// Whether `text` names WIFI and VALIDATED as whole words. `NOT_VALIDATED` does not count as VALIDATED.
private func isValidatedWifiLine(_ text: String) -> Bool {
    let words = Set(text.split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init))
    return words.contains("WIFI") && words.contains("VALIDATED")
}
