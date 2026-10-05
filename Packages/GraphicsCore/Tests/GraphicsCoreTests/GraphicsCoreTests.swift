import Testing

@testable import GraphicsCore

@Test func graphicsFailureHasStableCatalogIdentity() {
    let failure = GraphicsFailure.rendererInitFailed(
        stage: .egl,
        detail: "ANGLE EGL Metal initialization failed"
    )

    #expect(GraphicsFailure.domain.rawValue == "graphics")
    #expect(failure.code == "rendererInitFailed")
    #expect(failure.parameters["stage"] != nil)
    #expect(failure.parameters["detail"] != nil)
    #expect(failure.parameters.count == 2)
}

@Test func missingRuntimeLibraryUsesTheLibraryFailureCode() {
    let failure = GraphicsFailure.libraryMissing(name: "libEGL.dylib")

    #expect(failure.code == "libraryMissing")
    #expect(failure.parameters["name"] != nil)
    #expect(failure.parameters.count == 1)
}

@Test func graphicsOperationFailureHasStableCatalogIdentity() {
    let failure = GraphicsFailure.rendererOperationFailed(
        operation: "reset",
        detail: "graphics renderer called from a thread other than its owner"
    )

    #expect(failure.code == "rendererOperationFailed")
    #expect(failure.parameters["operation"] != nil)
    #expect(failure.parameters["detail"] != nil)
    #expect(failure.parameters.count == 2)
}
