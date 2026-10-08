import Testing

@testable import GraphicsCore

private let bgra: UInt32 = 1
private let rgba: UInt32 = 67

@Test func createsA2DResourceWithItsHostMemoryEstimate() throws {
    var table = ResourceTable()
    try table.createHost2D(id: 7, format: bgra, width: 1024, height: 768)

    let resource = try #require(table.resource(id: 7))
    #expect(resource.byteEstimate == 1024 * 768 * 4)
    #expect(resource.backing.isEmpty)
    #expect(table.count == 1)
    #expect(table.estimatedByteCount == 1024 * 768 * 4)
}

@Test func resourceIDsMustBeNonZeroAndUnused() throws {
    var table = ResourceTable()
    #expect(throws: ResourceTableFailure.invalidResourceID(0)) {
        try table.createHost2D(id: 0, format: bgra, width: 4, height: 4)
    }
    try table.createHost2D(id: 1, format: bgra, width: 4, height: 4)
    #expect(throws: ResourceTableFailure.invalidResourceID(1)) {
        try table.createHost2D(id: 1, format: bgra, width: 4, height: 4)
    }
    #expect(table.count == 1)
}

@Test func unsupportedFormatsAndDimensionsAreRejected() {
    var table = ResourceTable()
    #expect(throws: ResourceTableFailure.invalidParameter(field: "format")) {
        try table.createHost2D(id: 1, format: 999, width: 4, height: 4)
    }
    #expect(throws: ResourceTableFailure.invalidParameter(field: "width")) {
        try table.createHost2D(id: 1, format: bgra, width: 0, height: 4)
    }
    #expect(throws: ResourceTableFailure.invalidParameter(field: "height")) {
        try table.createHost2D(id: 1, format: bgra, width: 4, height: 8193)
    }
    #expect(table.count == 0)
    #expect(table.estimatedByteCount == 0)
}

@Test func theLargestAllowedResourceFitsTheSingleResourceLimit() throws {
    var table = ResourceTable()
    try table.createHost2D(id: 1, format: rgba, width: 8192, height: 8192)
    #expect(table.estimatedByteCount == 256 * 1024 * 1024)
}

@Test func memoryAndCountLimitsRejectNewResources() throws {
    var limits = ResourceTableLimits()
    limits.totalBytes = 1024 * 1024
    limits.liveResourceCount = 2
    var table = ResourceTable(limits: limits)

    try table.createHost2D(id: 1, format: bgra, width: 512, height: 512)
    #expect(throws: ResourceTableFailure.outOfMemory(limit: "totalBytes")) {
        try table.createHost2D(id: 2, format: bgra, width: 1, height: 1)
    }

    var smallCount = ResourceTableLimits()
    smallCount.liveResourceCount = 1
    var counted = ResourceTable(limits: smallCount)
    try counted.createHost2D(id: 1, format: bgra, width: 1, height: 1)
    #expect(throws: ResourceTableFailure.outOfMemory(limit: "liveResources")) {
        try counted.createHost2D(id: 2, format: bgra, width: 1, height: 1)
    }
}

@Test func aSingleResourceAboveItsLimitIsRejected() {
    var limits = ResourceTableLimits()
    limits.singleResourceBytes = 1024
    var table = ResourceTable(limits: limits)
    #expect(throws: ResourceTableFailure.outOfMemory(limit: "singleResource")) {
        try table.createHost2D(id: 1, format: bgra, width: 64, height: 64)
    }
}

@Test func unrefReleasesTheEstimateAndTheID() throws {
    var table = ResourceTable()
    try table.createHost2D(id: 3, format: bgra, width: 8, height: 8)
    try table.unref(id: 3)
    #expect(table.resource(id: 3) == nil)
    #expect(table.estimatedByteCount == 0)
    #expect(throws: ResourceTableFailure.invalidResourceID(3)) {
        try table.unref(id: 3)
    }
    try table.createHost2D(id: 3, format: bgra, width: 8, height: 8)
    #expect(table.count == 1)
}

@Test func validBackingIsStoredAndDetachedWithoutRemovingTheResource() throws {
    var table = ResourceTable()
    try table.createHost2D(id: 7, format: bgra, width: 16, height: 16)
    let entries = [VirtioGPUMemoryEntry(address: 0x8000_0000, length: 1024)]
    try table.attachBacking(id: 7, entries: entries) { _ in true }
    #expect(table.resource(id: 7)?.backing == entries)

    try table.detachBacking(id: 7)
    #expect(table.resource(id: 7)?.backing.isEmpty == true)
    #expect(table.count == 1)
}

@Test func backingValidationRejectsEachBadEntryWithoutKeepingPartialState() throws {
    var table = ResourceTable()
    try table.createHost2D(id: 7, format: bgra, width: 16, height: 16)
    let needed = VirtioGPUMemoryEntry(address: 0x8000_0000, length: 1024)

    #expect(throws: ResourceTableFailure.invalidResourceID(8)) {
        try table.attachBacking(id: 8, entries: [needed]) { _ in true }
    }
    #expect(throws: ResourceTableFailure.invalidParameter(field: "entries")) {
        try table.attachBacking(id: 7, entries: []) { _ in true }
    }
    #expect(throws: ResourceTableFailure.invalidParameter(field: "entry.length")) {
        try table.attachBacking(id: 7, entries: [VirtioGPUMemoryEntry(address: 0x8000_0000, length: 0)]) {
            _ in true
        }
    }
    #expect(throws: ResourceTableFailure.invalidParameter(field: "entry.address")) {
        try table.attachBacking(id: 7, entries: [VirtioGPUMemoryEntry(address: UInt64.max - 1, length: 4)]) {
            _ in true
        }
    }
    #expect(throws: ResourceTableFailure.invalidParameter(field: "entry.address")) {
        try table.attachBacking(id: 7, entries: [needed]) { _ in false }
    }
    #expect(throws: ResourceTableFailure.invalidParameter(field: "entry.length")) {
        try table.attachBacking(id: 7, entries: [VirtioGPUMemoryEntry(address: 0x8000_0000, length: 512)]) {
            _ in true
        }
    }
    #expect(table.resource(id: 7)?.backing.isEmpty == true)

    try table.attachBacking(id: 7, entries: [needed]) { _ in true }
    #expect(throws: ResourceTableFailure.invalidParameter(field: "backing")) {
        try table.attachBacking(id: 7, entries: [needed]) { _ in true }
    }
}

@Test func backingEntryCountIsLimitedTo16384() throws {
    var table = ResourceTable()
    try table.createHost2D(id: 1, format: bgra, width: 1, height: 1)
    let entries = Array(
        repeating: VirtioGPUMemoryEntry(address: 0x8000_0000, length: 4),
        count: VirtioGPUProtocol.Limits.maximumBackingEntries + 1
    )
    #expect(throws: ResourceTableFailure.invalidParameter(field: "entries")) {
        try table.attachBacking(id: 1, entries: entries) { _ in true }
    }
}

@Test func resetClearsEveryResourceAndTheEstimate() throws {
    var table = ResourceTable()
    try table.createHost2D(id: 1, format: bgra, width: 8, height: 8)
    try table.createHost2D(id: 2, format: rgba, width: 8, height: 8)
    table.reset()
    #expect(table.count == 0)
    #expect(table.estimatedByteCount == 0)
    #expect(table.resource(id: 1) == nil)
}

@Test func failuresMapToVirtioErrorCodes() {
    #expect(ResourceTableFailure.invalidResourceID(1).errorCode == .invalidResourceID)
    #expect(ResourceTableFailure.invalidParameter(field: "format").errorCode == .invalidParameter)
    #expect(ResourceTableFailure.outOfMemory(limit: "totalBytes").errorCode == .outOfMemory)
}
