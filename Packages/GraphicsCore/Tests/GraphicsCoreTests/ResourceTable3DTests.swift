import Testing

@testable import GraphicsCore

private let bgra8: UInt32 = 1
private let rgba8: UInt32 = 67
private let dxt1: UInt32 = 105

private func create(
    id: UInt32 = 1,
    target: UInt32 = 2,
    format: UInt32 = bgra8,
    width: UInt32 = 16,
    height: UInt32 = 16,
    depth: UInt32 = 1,
    arraySize: UInt32 = 1,
    lastLevel: UInt32 = 0,
    sampleCount: UInt32 = 0
) -> VirtioGPUResourceCreate3D {
    VirtioGPUResourceCreate3D(
        resourceID: id,
        target: target,
        format: format,
        bind: 0,
        width: width,
        height: height,
        depth: depth,
        arraySize: arraySize,
        lastLevel: lastLevel,
        sampleCount: sampleCount,
        flags: 0
    )
}

@Test func aBufferIsSizedInBytesAndIsNotLimitedToTheTextureDimension() throws {
    var table = ResourceTable()
    try table.create3D(create(target: 0, format: 64, width: 1_000_000, height: 1))
    let resource = try #require(table.resource(id: 1))
    #expect(resource.byteEstimate == 1_000_000)
    #expect(resource.kind == .virgl(target: 0))
}

@Test func aBufferMustHaveOneRow() {
    var table = ResourceTable()
    #expect(throws: ResourceTableFailure.invalidParameter(field: "size")) {
        try table.create3D(create(target: 0, format: 64, width: 64, height: 2))
    }
}

@Test func aTextureDimensionAboveTheLimitIsRejected() {
    var table = ResourceTable()
    #expect(throws: ResourceTableFailure.invalidParameter(field: "width")) {
        try table.create3D(create(width: 8_193))
    }
    #expect(throws: ResourceTableFailure.invalidParameter(field: "height")) {
        try table.create3D(create(height: 0))
    }
}

@Test func theByteEstimateMultipliesDepthAndLayers() throws {
    var table = ResourceTable()
    try table.create3D(create(target: 3, width: 16, height: 8, depth: 4, arraySize: 2))
    #expect(try #require(table.resource(id: 1)).byteEstimate == 16 * 8 * 4 * 2 * 4)
}

@Test func blockFormatsAreSizedInWholeBlocks() throws {
    var table = ResourceTable()
    try table.create3D(create(format: dxt1, width: 10, height: 10))
    // 10 × 10 pixels are 3 × 3 blocks of 8 bytes.
    #expect(try #require(table.resource(id: 1)).byteEstimate == 3 * 3 * 8)
}

@Test func unknownFormatsAndTargetsAreRejected() {
    var table = ResourceTable()
    #expect(throws: ResourceTableFailure.invalidParameter(field: "format")) {
        try table.create3D(create(format: 14))
    }
    #expect(throws: ResourceTableFailure.invalidParameter(field: "target")) {
        try table.create3D(create(target: 9))
    }
}

@Test func levelAndSampleLimitsApplyToTextures() {
    var table = ResourceTable()
    #expect(throws: ResourceTableFailure.invalidParameter(field: "lastLevel")) {
        try table.create3D(create(lastLevel: 14))
    }
    #expect(throws: ResourceTableFailure.invalidParameter(field: "nrSamples")) {
        try table.create3D(create(sampleCount: 32))
    }
}

@Test func theSingleResourceLimitIsExact() throws {
    var table = ResourceTable()
    try table.create3D(create(id: 1, target: 0, format: 64, width: 256 * 1024 * 1024, height: 1))
    #expect(throws: ResourceTableFailure.outOfMemory(limit: "singleResource")) {
        try table.create3D(create(id: 2, target: 0, format: 64, width: 256 * 1024 * 1024 + 1, height: 1))
    }
}

@Test func theTotalLimitRejectsTheResourceThatWouldExceedIt() throws {
    var limits = ResourceTableLimits()
    limits.totalBytes = 3_000
    var table = ResourceTable(limits: limits)
    try table.create3D(create(id: 1, target: 0, format: 64, width: 2_000, height: 1))
    #expect(throws: ResourceTableFailure.outOfMemory(limit: "totalBytes")) {
        try table.create3D(create(id: 2, target: 0, format: 64, width: 1_001, height: 1))
    }
    #expect(table.estimatedByteCount == 2_000)
}

@Test func theEstimateOverflowIsAnInvalidSize() {
    #expect(throws: ResourceTableFailure.invalidParameter(field: "size")) {
        _ = try ResourceTable.textureBytes(
            width: UInt32.max,
            height: UInt32.max,
            depth: 1,
            arraySize: 1,
            layout: PixelLayout(blockWidth: 1, blockHeight: 1, bytesPerBlock: 4)
        )
    }
}

@Test func createdResourcesCanBeUnreferencedAndTheTableReset() throws {
    var table = ResourceTable()
    try table.create3D(create(id: 1))
    try table.create3D(create(id: 2))
    #expect(throws: ResourceTableFailure.invalidResourceID(1)) {
        try table.create3D(create(id: 1))
    }
    try table.unref(id: 1)
    #expect(table.count == 1)
    table.reset()
    #expect(table.count == 0)
    #expect(table.estimatedByteCount == 0)
}

@Test func aVirGL2DResourceIsOwnedByTheRenderer() throws {
    var table = ResourceTable()
    try table.createVirgl2D(id: 4, format: rgba8, width: 8, height: 8)
    let resource = try #require(table.resource(id: 4))
    #expect(resource.kind == .virgl(target: 2))
    #expect(resource.byteEstimate == 8 * 8 * 4)
}
