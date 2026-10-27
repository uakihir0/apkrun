import AppKit
import IOSurface
import Testing

@testable import WindowingCore

@MainActor
@Test func sessionWindowDelegatesUserCloseToItsOwner() {
    let controller = SessionWindowController(
        source: EmptyFrameSource(),
        title: "HelloText",
        backingScale: 1
    )
    var closeRequests = 0
    controller.onShouldClose = {
        closeRequests += 1
        return false
    }

    controller.performClose()
    #expect(closeRequests == 1)
}

@Test func sessionWindowKeepsPlaceholderUntilTheFirstFrameIsPresented() {
    var state = SessionWindowPresentationState()

    #expect(state.showsPlaceholder)
    #expect(!state.shouldOrderWindowFront)
    #expect(!state.acceptsInput)

    state.markFramePresented()

    #expect(!state.showsPlaceholder)
    #expect(state.shouldOrderWindowFront)
    #expect(state.acceptsInput)
}

@Test func startupFallbackRevealsTheSessionSurfaceWithoutEnablingInput() {
    var state = SessionWindowPresentationState()

    state.markStartupFallbackElapsed()

    #expect(state.showsPlaceholder)
    #expect(state.shouldOrderWindowFront)
    #expect(!state.acceptsInput)
}

@Test func fastFirstFrameRemainsVisibleWhenTheStartupFallbackWouldExpireLater() {
    var state = SessionWindowPresentationState()
    state.markFramePresented()

    state.markStartupFallbackElapsed()

    #expect(!state.showsPlaceholder)
    #expect(state.shouldOrderWindowFront)
    #expect(state.acceptsInput)
}

@Test func firstFrameAfterStartupFallbackEnablesInputWithoutRestoringPlaceholder() {
    var state = SessionWindowPresentationState()
    state.markStartupFallbackElapsed()

    state.markFramePresented()

    #expect(!state.showsPlaceholder)
    #expect(state.shouldOrderWindowFront)
    #expect(state.acceptsInput)
}

@Test func bootingSessionRequestsImmediatePresentationWithThePlaceholder() {
    var state = SessionWindowPresentationState()

    state.requestImmediatePresentation()

    #expect(state.shouldOrderWindowFront)
    #expect(state.showsPlaceholder)
    #expect(!state.acceptsInput)
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

@Test func uncertainResizeOutcomeKeepsInputDisabledUntilANewerGenerationCommits() {
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

private final class EmptyFrameSource: FrameSource, @unchecked Sendable {
    private let surfaceSet = FrameSurfaceSet(
        generation: 1,
        surfaces: [],
        pixelWidth: 320,
        pixelHeight: 400,
        contentSize: CGSize(width: 320, height: 400),
        contentsScale: 1,
        zoom: 1
    )
    let frames = AsyncStream<FrameSourceEvent> { $0.finish() }

    var currentSurfaceSet: FrameSurfaceSet { surfaceSet }
    var surfaces: [IOSurface] { surfaceSet.surfaces }
    var generation: UInt64 { surfaceSet.generation }
    var pixelWidth: Int { surfaceSet.pixelWidth }
    var pixelHeight: Int { surfaceSet.pixelHeight }

    func surfaceSet(generation: UInt64) -> FrameSurfaceSet? {
        generation == surfaceSet.generation ? surfaceSet : nil
    }

    func frameDisplayed(generation: UInt64, sequence: UInt64) {}
}
