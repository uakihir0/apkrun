import Testing

@testable import GraphicsCore

private func geometryBox(x: UInt32 = 0, y: UInt32 = 0, z: UInt32 = 0, width: UInt32, height: UInt32, depth: UInt32 = 1)
    -> VirtioGPUBox
{
    VirtioGPUBox(x: x, y: y, z: z, width: width, height: height, depth: depth)
}

private func texture(
    width: UInt32 = 64,
    height: UInt32 = 32,
    depth: UInt32 = 1,
    lastLevel: UInt32 = 0,
    format: UInt32 = 1
) throws -> GPUResource {
    var table = ResourceTable()
    try table.create3D(
        VirtioGPUResourceCreate3D(
            resourceID: 1,
            target: depth > 1 ? 3 : 2,
            format: format,
            bind: 0,
            width: width,
            height: height,
            depth: depth,
            arraySize: 1,
            lastLevel: lastLevel,
            sampleCount: 0,
            flags: 0
        )
    )
    return try #require(table.resource(id: 1))
}

@Test func zeroStridesResolveToTightRowsAndLayers() throws {
    let resource = try texture()
    let geometry = try TransferGeometry(
        resource: resource,
        level: 0,
        stride: 0,
        layerStride: 0,
        box: geometryBox(width: 64, height: 32),
        offset: 0
    )
    #expect(geometry.stride == 64 * 4)
    #expect(geometry.layerStride == 64 * 4 * 32)
}

@Test func levelsShrinkTheBoxBounds() throws {
    let resource = try texture(lastLevel: 3)
    let geometry = try TransferGeometry(
        resource: resource,
        level: 2,
        stride: 0,
        layerStride: 0,
        box: geometryBox(width: 16, height: 8),
        offset: 0
    )
    #expect(geometry.levelWidth == 16)
    #expect(geometry.levelHeight == 8)
    #expect(geometry.stride == 16 * 4)
    #expect(throws: ResourceTableFailure.invalidParameter(field: "box")) {
        _ = try TransferGeometry(
            resource: resource,
            level: 2,
            stride: 0,
            layerStride: 0,
            box: geometryBox(width: 17, height: 8),
            offset: 0
        )
    }
}

@Test func aLevelAboveTheLastLevelIsRejected() throws {
    let resource = try texture(lastLevel: 0)
    #expect(throws: ResourceTableFailure.invalidParameter(field: "level")) {
        _ = try TransferGeometry(
            resource: resource,
            level: 1,
            stride: 0,
            layerStride: 0,
            box: geometryBox(width: 1, height: 1),
            offset: 0
        )
    }
}

@Test func aBoxOutsideTheTextureIsRejected() throws {
    let resource = try texture()
    for box in [
        geometryBox(x: 60, width: 5, height: 1), geometryBox(y: 31, width: 1, height: 2),
        geometryBox(width: 0, height: 1),
    ] {
        #expect(throws: ResourceTableFailure.invalidParameter(field: "box")) {
            _ = try TransferGeometry(
                resource: resource,
                level: 0,
                stride: 0,
                layerStride: 0,
                box: box,
                offset: 0
            )
        }
    }
}

@Test func theExtentCoversTheLastRowAndColumnOfTheBox() throws {
    let resource = try texture()
    let geometry = try TransferGeometry(
        resource: resource,
        level: 0,
        stride: 0,
        layerStride: 0,
        box: geometryBox(x: 2, y: 1, width: 3, height: 2),
        offset: 0
    )
    // The last pixel is at x = 4, y = 2: row 2 starts at 512, and its column ends at byte 20 of the row.
    #expect(try geometry.extent() == 2 * 256 + 5 * 4)
}

@Test func theBoxRunsCoverOnlyTheBoxInEachRow() throws {
    let resource = try texture()
    let geometry = try TransferGeometry(
        resource: resource,
        level: 0,
        stride: 0,
        layerStride: 0,
        box: geometryBox(x: 2, y: 1, width: 3, height: 2),
        offset: 0
    )
    #expect(
        geometry.boxRuns() == [
            TransferRun(offset: 256 + 8, length: 12),
            TransferRun(offset: 512 + 8, length: 12),
        ]
    )
}

@Test func layersAddTheirOwnRunsAndExtent() throws {
    let resource = try texture(width: 4, height: 2, depth: 2)
    let geometry = try TransferGeometry(
        resource: resource,
        level: 0,
        stride: 16,
        layerStride: 40,
        box: geometryBox(width: 4, height: 1, depth: 2),
        offset: 0
    )
    #expect(
        geometry.boxRuns() == [
            TransferRun(offset: 0, length: 16),
            TransferRun(offset: 40, length: 16),
        ]
    )
    #expect(try geometry.extent() == 40 + 16)
}

@Test func blockFormatsRoundTheBoxToWholeBlocks() throws {
    let resource = try texture(width: 8, height: 8, format: 105)
    let geometry = try TransferGeometry(
        resource: resource,
        level: 0,
        stride: 0,
        layerStride: 0,
        box: geometryBox(x: 1, y: 1, width: 2, height: 2),
        offset: 0
    )
    // The box is inside one 4 × 4 block, so it covers one block row of one 8-byte block.
    #expect(geometry.boxRuns() == [TransferRun(offset: 0, length: 8)])
    #expect(try geometry.extent() == 8)
}

@Test func anExtentThatOverflowsIsRejected() throws {
    let resource = try texture()
    let geometry = try TransferGeometry(
        resource: resource,
        level: 0,
        stride: UInt32.max,
        layerStride: UInt32.max,
        box: geometryBox(width: 1, height: 32, depth: 1),
        offset: UInt64.max - 4
    )
    #expect(throws: ResourceTableFailure.invalidParameter(field: "box")) {
        _ = try geometry.extent()
    }
}
