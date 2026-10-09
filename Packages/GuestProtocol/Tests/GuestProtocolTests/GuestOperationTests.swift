import Foundation
import Testing

@testable import GuestProtocol

/// The paired GuestOperation of guest-protocol.md §4.1 and §13.1, checked against the schema (#072). Each typed
/// operation has the field number and the field name of its request and of its result in `envelope.proto`.
private enum EnvelopeSchema {
    /// The text of `envelope.proto`, found from the location of this source file.
    static let text: String = {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // GuestProtocolTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // GuestProtocol
            .appendingPathComponent("proto/apkrun/guest/v1/envelope.proto")
        return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }()

    /// The `name = number` fields of the message `message` (its oneof fields), by name.
    static func fields(of message: String) -> [String: Int] {
        var inside = false
        var fields: [String: Int] = [:]
        for line in text.split(separator: "\n") {
            if line.hasPrefix("message \(message) {") {
                inside = true
                continue
            }
            guard inside else { continue }
            if line.hasPrefix("}") {
                break
            }
            if let match = line.firstMatch(of: /^\s+(?:repeated )?\w+ (\w+) = (\d+);/) {
                fields[String(match.1)] = Int(match.2)
            }
        }
        return fields
    }
}

@Test func theImplementedOperationsPairTheirRequestAndResultNumbers() {
    let requests = EnvelopeSchema.fields(of: "Request")
    let results = EnvelopeSchema.fields(of: "Response")
    let pairs: [(name: String, number: Int)] = [
        ("ping", GuestPing.number),
        ("get_snapshot", GuestGetSnapshot.number),
        ("set_display_policy", GuestSetDisplayPolicy.number),
        ("launch_application", GuestLaunchApplication.number),
        ("focus_display", GuestFocusDisplay.number),
    ]
    for pair in pairs {
        #expect(requests[pair.name] == pair.number, "Request.\(pair.name) is not \(pair.number)")
        #expect(results[pair.name] == pair.number, "Response.\(pair.name) is not \(pair.number)")
    }
}

@Test func theSchemaReadsTheRequestOperations() {
    let requests = EnvelopeSchema.fields(of: "Request")
    #expect(requests["ping"] == 10)
    #expect(requests["launch_application"] == 14)
    #expect(requests["timeout_ms"] == 1)
}

@Test func anOperationPutsItsOwnCaseInTheRequest() {
    let pingRequest: GPRequest.OneOf_Op? = GuestPing(nonce: 5).request()
    if case .ping(let ping)? = pingRequest {
        #expect(ping.nonce == 5)
    } else {
        Issue.record("GuestPing does not build the ping request")
    }
    let launchRequest: GPRequest.OneOf_Op? = GuestLaunchApplication(package: "io.apkrun.fixture.hellotext", displayID: 0).request()
    if case .launchApplication(let launch)? = launchRequest {
        #expect(launch.package == "io.apkrun.fixture.hellotext")
    } else {
        Issue.record("GuestLaunchApplication does not build the launch request")
    }
}
