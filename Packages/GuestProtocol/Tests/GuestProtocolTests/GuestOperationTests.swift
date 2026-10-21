import Foundation
import Testing

@testable import GuestProtocol

/// The paired GuestOperation of guest-protocol.md §4.1 and §13.1, checked against the schema (#73). Each typed
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
        ("clear_display", GuestClearDisplay.number),
        ("launch_application", GuestLaunchApplication.number),
        ("stop_application", GuestStopApplication.number),
        ("stop_application", GuestForceStopApplication.number),
        ("move_task_to_display", GuestMoveTaskToDisplay.number),
        ("list_tasks", GuestListTasks.number),
        ("focus_display", GuestFocusDisplay.number),
        ("query_package", GuestQueryPackage.number),
        ("list_packages", GuestListPackages.number),
        ("get_health", GuestGetHealth.number),
        ("shutdown", GuestShutdown.number),
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
    let launchRequest: GPRequest.OneOf_Op? = GuestLaunchApplication(
        package: "io.apkrun.fixture.hellotext", displayID: 0
    ).request()
    if case .launchApplication(let launch)? = launchRequest {
        #expect(launch.package == "io.apkrun.fixture.hellotext")
    } else {
        Issue.record("GuestLaunchApplication does not build the launch request")
    }
    let clearRequest: GPRequest.OneOf_Op? = GuestClearDisplay(displayID: 4).request()
    #expect(GuestClearDisplay(displayID: 4).timeout == .seconds(5))
    if case .clearDisplay_p(let clear)? = clearRequest {
        #expect(clear.displayID == 4)
        #expect(clear.policy == .finishTasks)
    } else {
        Issue.record("GuestClearDisplay does not build the clear-display request")
    }
    let stopRequest: GPRequest.OneOf_Op? = GuestStopApplication(package: "io.apkrun.fixture.hellotext").request()
    if case .stopApplication(let stop)? = stopRequest {
        #expect(stop.package == "io.apkrun.fixture.hellotext")
        #expect(stop.mode == .finishTasks)
    } else {
        Issue.record("GuestStopApplication does not build the finish-tasks request")
    }
    let forceStopRequest: GPRequest.OneOf_Op? = GuestForceStopApplication(
        package: "io.apkrun.fixture.hellotext"
    ).request()
    #expect(GuestForceStopApplication(package: "io.apkrun.fixture.hellotext").timeout == .seconds(5))
    #expect(GuestForceStopApplication(package: "io.apkrun.fixture.hellotext").capability == .launch)
    if case .stopApplication(let stop)? = forceStopRequest {
        #expect(stop.package == "io.apkrun.fixture.hellotext")
        #expect(stop.mode == .forceStop)
    } else {
        Issue.record("GuestForceStopApplication does not build the force-stop request")
    }

    let packageRequest: GPRequest.OneOf_Op? = GuestQueryPackage(package: "io.apkrun.fixture.hellotext").request()
    #expect(GuestQueryPackage(package: "io.apkrun.fixture.hellotext").timeout == .seconds(5))
    if case .queryPackage(let query)? = packageRequest {
        #expect(query.package == "io.apkrun.fixture.hellotext")
    } else {
        Issue.record("GuestQueryPackage does not build a query request")
    }

    let packagesRequest: GPRequest.OneOf_Op? = GuestListPackages(filter: .userInstalled).request()
    #expect(GuestListPackages(filter: .userInstalled).timeout == .seconds(5))
    if case .listPackages(let list)? = packagesRequest {
        #expect(list.filter == .userInstalled)
    } else {
        Issue.record("GuestListPackages does not build a list request")
    }

    let moveOperation = GuestMoveTaskToDisplay(taskID: 8, displayID: 4, toBack: true)
    let moveRequest: GPRequest.OneOf_Op? = moveOperation.request()
    #expect(moveOperation.timeout == .seconds(5))
    #expect(moveOperation.capability == .launch)
    #expect(moveOperation.operationName == "MoveTaskToDisplay")
    if case .moveTaskToDisplay(let move)? = moveRequest {
        #expect(move.taskID == 8)
        #expect(move.displayID == 4)
        #expect(move.toBack)
    } else {
        Issue.record("GuestMoveTaskToDisplay does not build the move request")
    }
    #expect(GuestMoveTaskToDisplay.decode(.moveTaskToDisplay(GPEmpty())) != nil)
    #expect(GuestMoveTaskToDisplay.decode(.getHealth(GPHealth())) == nil)

    let allTasksOperation = GuestListTasks()
    let allTasksRequest: GPRequest.OneOf_Op? = allTasksOperation.request()
    #expect(allTasksOperation.timeout == .seconds(5))
    #expect(allTasksOperation.capability == .launch)
    #expect(allTasksOperation.operationName == "ListTasks")
    if case .listTasks(let list)? = allTasksRequest {
        #expect(!list.hasDisplayID)
    } else {
        Issue.record("GuestListTasks does not build the all-displays request")
    }
    let displayTasksRequest: GPRequest.OneOf_Op? = GuestListTasks(displayID: 4).request()
    if case .listTasks(let list)? = displayTasksRequest {
        #expect(list.hasDisplayID)
        #expect(list.displayID == 4)
    } else {
        Issue.record("GuestListTasks does not build the display-filtered request")
    }
    #expect(GuestListTasks.decode(.listTasks(GPTaskList())) != nil)
    #expect(GuestListTasks.decode(.getHealth(GPHealth())) == nil)

    let healthOperation = GuestGetHealth()
    let healthRequest: GPRequest.OneOf_Op? = healthOperation.request()
    #expect(healthOperation.timeout == .seconds(5))
    #expect(healthOperation.capability == .health)
    #expect(healthOperation.operationName == "GetHealth")
    if case .getHealth? = healthRequest {
        #expect(GuestGetHealth.decode(.getHealth(GPHealth())) != nil)
    } else {
        Issue.record("GuestGetHealth does not build the health request")
    }
    #expect(GuestGetHealth.decode(.shutdown(GPEmpty())) == nil)

    let shutdownOperation = GuestShutdown(reason: "test complete")
    let shutdownRequest: GPRequest.OneOf_Op? = shutdownOperation.request()
    #expect(shutdownOperation.timeout == .seconds(20))
    #expect(shutdownOperation.capability == .system)
    #expect(shutdownOperation.operationName == "Shutdown")
    if case .shutdown(let shutdown)? = shutdownRequest {
        #expect(shutdown.reason == "test complete")
    } else {
        Issue.record("GuestShutdown does not build the shutdown request")
    }
    #expect(GuestShutdown.decode(.shutdown(GPEmpty())) != nil)
    #expect(GuestShutdown.decode(.getHealth(GPHealth())) == nil)
}
