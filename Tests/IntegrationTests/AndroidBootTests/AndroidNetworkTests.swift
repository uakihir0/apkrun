import Foundation
import XCTest

/// The Android network check of #095 step 5 (FR-VM-04): an address, a vmnet default route, DNS, and a validated
/// Wi-Fi network.
///
/// It is #095's open check, not a condition of gate G2 (#014; IR-374), so it runs in its own `AndroidNetwork`
/// test-plan configuration of `IntegrationTests`. CI and the gate do not select that configuration; run it by hand
/// with `-only-test-configuration AndroidNetwork`.
final class AndroidNetworkTests: XCTestCase {
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
        let supervisor = try fixture.supervisor(developerMode: true)
        let collector = Task {
            for await _ in supervisor.events {}
        }
        var failure: Error?
        do {
            try await supervisor.ensureReady(.cli)
            let shellOrNil = await supervisor.shell
            let android = AndroidShellConsole(shell: try XCTUnwrap(shellOrNil))
            // The design (android-image.md §7.4) puts the guest on wlan0 (virt_wifi on eth2) with vmnet's DHCP.
            // ICMP gets no reply through vmnet, but `ping` prints the resolved address before it waits for a reply,
            // and prints `unknown host` when the name does not resolve. The stock image has no getent or nslookup
            // (IR-548), so name resolution is checked with the first line of `ping -c 1`.
            // DHCP and the first Wi-Fi join finish after `ready`, so the stages are polled for a bounded time.
            // Each stage is judged by its last value: the reply the poll stopped on.
            var address = ""
            var route = ""
            var resolved = ""
            var validated = ""
            let resolvedPrefix = "PING connectivitycheck.gstatic.com ("
            let deadline = ContinuousClock.now + .seconds(120)
            repeat {
                address = (try? await android.value("ip addr show wlan0 | grep 'inet '")) ?? ""
                // IPv4 only: the router advertisement also gives an IPv6 default route on wlan0.
                route = (try? await android.value("ip route show table all | grep 'default via 192'")) ?? ""
                // The first line only: the banner when the name resolves, or the error line, not the statistics.
                resolved =
                    (try? await android.value(
                        "ping -c 1 -W 2 connectivitycheck.gstatic.com 2>&1 | head -n 1"
                    )) ?? ""
                validated =
                    (try? await android.value(
                        "dumpsys connectivity | grep NetworkAgentInfo | grep WIFI | grep VALIDATED | tail -n 1"
                    )) ?? ""
                if address.contains("inet 192.168."), route.contains("default via 192.168."),
                    resolved.hasPrefix(resolvedPrefix), validated.contains("VALIDATED"),
                    !validated.contains("NOT_VALIDATED")
                {
                    break
                }
                try await Task.sleep(for: .seconds(2))
            } while ContinuousClock.now < deadline
            XCTAssertTrue(address.contains("inet 192.168."), "wlan0 has the vmnet IPv4 address: \(address)")
            XCTAssertTrue(route.contains("default via 192.168."), "the default route goes through vmnet: \(route)")
            XCTAssertTrue(resolved.hasPrefix(resolvedPrefix), "connectivitycheck.gstatic.com resolves: \(resolved)")
            XCTAssertTrue(
                validated.contains("WIFI") && validated.contains("VALIDATED") && !validated.contains("NOT_VALIDATED"),
                "the WIFI NetworkAgentInfo line is VALIDATED: \(validated)"
            )
            // Diagnostics for the record: the Wi-Fi state, the links, the connectivity service's network
            // agents, the join's log lines, the resolver's first line, a loopback ping (its banner shows the
            // format of a reply line without DNS), and the DNS addresses the connectivity service reports.
            let record = [
                "wlan0:\n\(address)",
                "routes:\n\(route)",
                "resolved: \(resolved)",
                "validated: \(validated)",
                "loopback ping:\n\(try await android.run("ping -c 1 -W 2 127.0.0.1 2>&1 | head -n 1").output)",
                "dns:\n\(try await android.run("dumpsys connectivity | grep -i dns | head -n 4 | cut -c1-200").output)",
                "wifi agent:\n\(try await android.run("dumpsys connectivity | grep NetworkAgentInfo | grep WIFI | tail -n 1").output)",
                "wifi:\n\(try await android.run("cmd wifi status | head -n 8").output)",
                "links:\n\(try await android.run("ip -o link | cut -c1-90").output)",
                "wifi log:\n\(try await android.run("logcat -d | grep -i virtwifi | tail -n 8").output)",
            ].joined(separator: "\n")
            let attachment = XCTAttachment(string: record)
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
}
