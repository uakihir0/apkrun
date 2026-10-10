import Testing

@testable import GraphicsCore

@Test func contextsAreCreatedAndDestroyed() throws {
    var table = ContextTable()
    try table.create(id: 1)
    #expect(table.contains(1))
    try table.destroy(id: 1)
    #expect(!table.contains(1))
    #expect(table.count == 0)
}

@Test func contextZeroAndDuplicatesAreInvalidIDs() throws {
    var table = ContextTable()
    #expect(throws: ContextTableFailure.invalidContextID(0)) {
        try table.create(id: 0)
    }
    try table.create(id: 3)
    #expect(throws: ContextTableFailure.invalidContextID(3)) {
        try table.create(id: 3)
    }
    #expect(throws: ContextTableFailure.invalidContextID(8)) {
        try table.destroy(id: 8)
    }
}

@Test func atMost256ContextsAreLive() throws {
    var table = ContextTable()
    for id in 1...UInt32(ContextTable.maximumCount) {
        try table.create(id: id)
    }
    #expect(throws: ContextTableFailure.limitReached) {
        try table.create(id: 1_000)
    }
    #expect(ContextTableFailure.limitReached.errorCode == .unspec)
    #expect(table.count == 256)
}

@Test func resetForgetsEveryContext() throws {
    var table = ContextTable()
    try table.create(id: 1)
    try table.create(id: 2)
    table.reset()
    #expect(table.count == 0)
    try table.create(id: 1)
}

@Test func contextFailuresMapToVirtioErrorCodes() {
    #expect(ContextTableFailure.invalidContextID(1).errorCode == .invalidContextID)
    #expect(ContextTableFailure.limitReached.errorCode == .unspec)
}
