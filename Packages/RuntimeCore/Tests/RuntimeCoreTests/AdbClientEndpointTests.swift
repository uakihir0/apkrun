import Foundation
import Testing

@testable import RuntimeCore

/// The `host:port` that `adb -s` addresses for one developer ADB port (test-strategy §3.10). The product endpoint
/// keeps port 6520, and a boot with another port addresses that port.
@Test func developmentEndpointKeepsTheProductPort() {
    #expect(AdbClient.developmentEndpoint == "127.0.0.1:6520")
    #expect(AdbClient.loopbackEndpoint(port: 6520) == AdbClient.developmentEndpoint)
}

@Test func loopbackEndpointNamesTheGivenPortOnLoopbackOnly() {
    #expect(AdbClient.loopbackEndpoint(port: 49_321) == "127.0.0.1:49321")
    #expect(AdbClient.loopbackEndpoint(port: 0) == "127.0.0.1:0")
    #expect(AdbClient.loopbackEndpoint(port: UInt16.max) == "127.0.0.1:65535")
}

@Test func clientsAddressTheEndpointTheyAreGiven() {
    let executable = URL(fileURLWithPath: "/usr/bin/false")
    let runClient = AdbClient(executable: executable, endpoint: AdbClient.loopbackEndpoint(port: 49_321))
    #expect(runClient.endpoint == "127.0.0.1:49321")
    let productClient = AdbClient(executable: executable)
    #expect(productClient.endpoint == AdbClient.developmentEndpoint)
}
