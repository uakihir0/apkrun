import Testing

@testable import RuntimeHost

@Test func adbClientActivityTrackerIgnoresCallbacksFromStoppedForwarders() {
    var tracker = ADBClientActivityTracker()
    let acceptedInitialConnection = tracker.receive(generation: 1, revision: 1, connectionCount: 1)
    #expect(acceptedInitialConnection)
    #expect(tracker.connectionCount == 1)

    tracker.invalidate(afterGeneration: 1)
    #expect(tracker.generation == 2)
    #expect(tracker.connectionCount == 0)
    let acceptedStaleConnection = tracker.receive(generation: 1, revision: 2, connectionCount: 1)
    #expect(!acceptedStaleConnection)
    #expect(tracker.connectionCount == 0)

    let acceptedNewConnection = tracker.receive(generation: 2, revision: 1, connectionCount: 1)
    #expect(acceptedNewConnection)
    #expect(tracker.connectionCount == 1)
}

@Test func adbClientActivityTrackerKeepsTheNextForwarderEligibleAfterRepeatedNoOpStops() {
    var tracker = ADBClientActivityTracker()
    tracker.invalidate(afterGeneration: 0)
    tracker.invalidate(afterGeneration: 0)

    let acceptedFirstForwarder = tracker.receive(generation: 1, revision: 1, connectionCount: 1)
    #expect(acceptedFirstForwarder)
    #expect(tracker.connectionCount == 1)
}

@Test func adbClientActivityTrackerRejectsOutOfOrderRevisions() {
    var tracker = ADBClientActivityTracker()
    let acceptedFirstRevision = tracker.receive(generation: 4, revision: 2, connectionCount: 1)
    #expect(acceptedFirstRevision)
    let acceptedOutOfOrderRevision = tracker.receive(generation: 4, revision: 1, connectionCount: 0)
    #expect(!acceptedOutOfOrderRevision)
    #expect(tracker.connectionCount == 1)
    let acceptedLatestRevision = tracker.receive(generation: 4, revision: 3, connectionCount: 0)
    #expect(acceptedLatestRevision)
    #expect(tracker.connectionCount == 0)
}
