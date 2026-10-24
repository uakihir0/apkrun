import Testing

@testable import WindowingCore

@Test func sessionWindowKeepsPlaceholderUntilTheFirstFrameIsPresented() {
    var state = SessionWindowPresentationState()

    #expect(state.showsPlaceholder)
    #expect(!state.acceptsInput)

    state.markFramePresented()

    #expect(!state.showsPlaceholder)
    #expect(state.acceptsInput)
}

@Test func presentingAnotherFrameKeepsThePlaceholderHidden() {
    var state = SessionWindowPresentationState()
    state.markFramePresented()

    state.markFramePresented()

    #expect(state.hasPresentedFrame)
    #expect(!state.showsPlaceholder)
}

@Test func aLaunchFailureKeepsInputDisabledAfterFurtherFrames() {
    var state = SessionWindowPresentationState()
    state.markFramePresented()
    #expect(state.acceptsInput)

    state.markFailed()
    state.markFramePresented()

    #expect(state.hasFailed)
    #expect(!state.acceptsInput)
}

@Test func failedModeRestorationKeepsInputDisabledUntilANewerGenerationCommits() {
    var state = SessionWindowPresentationState()
    state.markFramePresented()
    state.markGeometryUncertain(after: 2)

    #expect(!state.acceptsInput)

    state.markGeometrySynchronized(generation: 2)
    #expect(!state.acceptsInput)

    state.markGeometrySynchronized(generation: 3)
    #expect(state.acceptsInput)
}

@Test func resizeRPCQueueKeepsOnlyTheNewestGeometryBehindOneInFlightRequest() {
    var requests = SessionWindowGeometryRequests()
    let firstGeometry = SessionWindowGeometry(width: 640, height: 480, backingScale: 2, zoom: 1)
    let secondGeometry = SessionWindowGeometry(width: 700, height: 500, backingScale: 2, zoom: 1)
    let newestGeometry = SessionWindowGeometry(width: 800, height: 600, backingScale: 2, zoom: 1.1)

    guard let first = requests.enqueue(firstGeometry) else {
        Issue.record("The idle resize queue should start its first request.")
        return
    }
    #expect(requests.inFlight == first)
    let second = requests.enqueue(secondGeometry)
    let newest = requests.enqueue(newestGeometry)
    #expect(second == nil)
    #expect(newest == nil)
    #expect(requests.inFlight == first)
    #expect(requests.pending?.geometry == newestGeometry)

    let staleCompletion = requests.complete(first.id + 1)
    #expect(staleCompletion == nil)
    #expect(requests.inFlight == first)
    #expect(requests.pending?.geometry == newestGeometry)

    let completion = requests.complete(first.id)
    #expect(completion?.completed == first)
    #expect(completion?.next?.geometry == newestGeometry)
    #expect(requests.inFlight == completion?.next)
    #expect(requests.pending == nil)
    let duplicateCompletion = requests.complete(first.id)
    #expect(duplicateCompletion == nil)
    #expect(requests.inFlight?.geometry == newestGeometry)
}

@Test func inputWaitsForTheRequiredGenerationToCommitEvenWhenRPCReplyArrivesLate() {
    var commits = SessionWindowGenerationCommits()
    commits.commit(4)
    commits.require(4)
    #expect(!commits.isAwaitingCommit)
    #expect(commits.hasCommitted(4))

    commits.require(5)
    #expect(commits.isAwaitingCommit)
    commits.commit(4)
    #expect(commits.isAwaitingCommit)
    #expect(!commits.hasCommitted(5))
    commits.commit(5)
    #expect(!commits.isAwaitingCommit)
    #expect(commits.hasCommitted(5))
}
