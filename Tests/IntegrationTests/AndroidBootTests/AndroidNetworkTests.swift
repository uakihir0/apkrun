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
            // ICMP gets no reply through vmnet, so name resolution is checked with getent, not ping.
            // DHCP and the first Wi-Fi join finish after `ready`, so the stages are polled for a bounded time.
            // Each stage is judged by its last value: the reply the poll stopped on.
            var address = ""
            var route = ""
            var resolved = ""
            var validated = ""
            let deadline = ContinuousClock.now + .seconds(120)
            repeat {
                address = (try? await android.value("ip addr show wlan0 | grep 'inet '")) ?? ""
                // IPv4 only: the router advertisement also gives an IPv6 default route on wlan0.
                route = (try? await android.value("ip route show table all | grep 'default via 192'")) ?? ""
                resolved = (try? await android.value("getent hosts connectivitycheck.gstatic.com")) ?? ""
                validated =
                    (try? await android.value(
                        "dumpsys connectivity | grep NetworkAgentInfo | grep WIFI | grep VALIDATED | tail -n 1"
                    )) ?? ""
                if address.contains("inet 192.168."), route.contains("default via 192.168."),
                    !resolved.isEmpty, validated.contains("VALIDATED")
                {
                    break
                }
                try await Task.sleep(for: .seconds(2))
            } while ContinuousClock.now < deadline
            XCTAssertTrue(address.contains("inet 192.168."), "wlan0 has the vmnet IPv4 address: \(address)")
            XCTAssertTrue(route.contains("default via 192.168."), "the default route goes through vmnet: \(route)")
            XCTAssertFalse(resolved.isEmpty, "connectivitycheck.gstatic.com resolves")
            XCTAssertTrue(
                validated.contains("WIFI") && validated.contains("VALIDATED"),
                "the WIFI NetworkAgentInfo line is VALIDATED: \(validated)"
            )
            // Diagnostics for the record: the Wi-Fi state, the links, the connectivity service's network
            // agents, and the join's log lines.
            let record = [
                "wlan0:\n\(address)",
                "routes:\n\(route)",
                "validated: \(validated)",
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
