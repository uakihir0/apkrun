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
