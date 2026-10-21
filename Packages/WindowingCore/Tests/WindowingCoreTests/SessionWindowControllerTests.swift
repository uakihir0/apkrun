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

@Test func appWindowKeepsPlaceholderAndInputDisabledUntilTheAppFrameIsPresented() {
    var state = SessionWindowPresentationState(holdsPlaceholderUntilAppRunning: true)

    #expect(state.showsPlaceholder)
    #expect(!state.acceptsInput)

    state.markFramePresented()

    #expect(state.hasPresentedFrame)
    #expect(state.showsPlaceholder)
    #expect(!state.acceptsInput)

    state.markAppRunning()

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
