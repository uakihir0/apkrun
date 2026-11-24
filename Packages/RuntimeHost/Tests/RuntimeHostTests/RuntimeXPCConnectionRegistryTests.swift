import Foundation
import RuntimeCore
import Testing

@testable import RuntimeHost

@Test func cliActivityHoldFollowsItsControlConnectionLifetime() async throws {
    let registry = RuntimeXPCConnectionRegistry(eventHub: RuntimeEventHub())
    let idleController = IdleController()
    let connection = NSXPCConnection(serviceName: "io.apkrun.RuntimeHostTests.activity")
    let connectionID = ObjectIdentifier(connection)
    #expect(registry.register(connection, kind: .broker))

    let firstAssertion = await idleController.assertActivity(.cli)
    let firstHoldToken = try #require(registry.holdActivity(firstAssertion, for: connectionID))
    #expect(await idleController.activeActivityKinds == [.cli])

    let duplicateAssertion = await idleController.assertActivity(.cli)
    let secondHoldToken = try #require(registry.holdActivity(duplicateAssertion, for: connectionID))
    registry.releaseActivityHold(firstHoldToken, for: connectionID)
    #expect(await waitForAssertionCount(1, controller: idleController))

    registry.remove(connectionID)
    #expect(await waitForAssertionCount(0, controller: idleController))

    let staleAssertion = await idleController.assertActivity(.cli)
    #expect(registry.holdActivity(staleAssertion, for: connectionID) == nil)
    #expect(await waitForAssertionCount(0, controller: idleController))
    registry.releaseActivityHold(secondHoldToken, for: connectionID)

    connection.invalidate()
    registry.close()
}

private func waitForAssertionCount(_ expectedCount: Int, controller: IdleController) async -> Bool {
    for _ in 0..<1_000 {
        if await controller.activeAssertionCount == expectedCount {
            return true
        }
        await Task.yield()
    }
    return await controller.activeAssertionCount == expectedCount
}
