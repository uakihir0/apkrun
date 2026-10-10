import Testing

@testable import GraphicsCore

@Test func anElementCompletesOnlyAfterItHasExecuted() {
    let queue = ControlCompletionQueue<String>()
    let first = queue.append("first", executed: false)
    let second = queue.append("second", executed: false)
    #expect(queue.markExecuted(second, fence: nil).isEmpty)
    #expect(queue.markExecuted(first, fence: nil) == ["first", "second"])
    #expect(queue.isEmpty)
}

@Test func aFencedElementWaitsForItsFence() {
    let queue = ControlCompletionQueue<String>()
    let ticket = queue.append("fenced", executed: false)
    #expect(queue.markExecuted(ticket, fence: 5).isEmpty)
    #expect(queue.isWaitingForFence)
    queue.recordCompletedFence(4)
    #expect(queue.drainReady().isEmpty)
    queue.recordCompletedFence(5)
    #expect(queue.drainReady() == ["fenced"])
    #expect(!queue.isWaitingForFence)
}

@Test func anUnfencedElementWaitsBehindAnEarlierFence() {
    let queue = ControlCompletionQueue<String>()
    let fenced = queue.append("fenced", executed: false)
    let later = queue.append("later", executed: false)
    _ = queue.markExecuted(fenced, fence: 9)
    #expect(queue.markExecuted(later, fence: nil).isEmpty)
    queue.recordCompletedFence(9)
    #expect(queue.drainReady() == ["fenced", "later"])
}

@Test func aFenceThatCompletedBeforeTheElementExecutedCompletesAtOnce() {
    let queue = ControlCompletionQueue<String>()
    queue.recordCompletedFence(3)
    let ticket = queue.append("early", executed: false)
    #expect(queue.markExecuted(ticket, fence: 3) == ["early"])
}

@Test func theCompletedFenceNeverGoesBackwards() {
    let queue = ControlCompletionQueue<String>()
    queue.recordCompletedFence(7)
    queue.recordCompletedFence(3)
    let ticket = queue.append("five", executed: false)
    #expect(queue.markExecuted(ticket, fence: 5) == ["five"])
}

@Test func anElementAppendedAsExecutedWaitsItsTurn() {
    let queue = ControlCompletionQueue<String>()
    let fenced = queue.append("fenced", executed: false)
    _ = queue.markExecuted(fenced, fence: 2)
    _ = queue.append("answered", executed: true)
    #expect(queue.count == 2)
    queue.recordCompletedFence(2)
    #expect(queue.drainReady() == ["fenced", "answered"])
}

@Test func removeAllReturnsEveryElementWhetherReadyOrNot() {
    let queue = ControlCompletionQueue<String>()
    _ = queue.append("pending", executed: false)
    let fenced = queue.append("fenced", executed: false)
    _ = queue.markExecuted(fenced, fence: 100)
    #expect(queue.removeAll() == ["pending", "fenced"])
    #expect(queue.isEmpty)
}
