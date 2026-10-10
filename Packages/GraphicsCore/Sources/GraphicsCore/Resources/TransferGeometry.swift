/// A box transfer between a resource and the guest backing (graphics.md §4.2, §4.4).
///
/// It resolves the strides the way virglrenderer does for a zero stride, checks the box
/// against the mip level, and gives the byte extent of the guest backing that the box can
/// touch. All arithmetic is checked, because the request values come from the guest.
struct TransferGeometry: Equatable, Sendable {
    let layout: PixelLayout
    /// The width, height, and depth of the mip level, in pixels.
    let levelWidth: UInt32
    let levelHeight: UInt32
    let levelDepth: UInt32
    /// The row stride in bytes, resolved from the request (zero means tight rows).
    let stride: UInt32
    /// The layer stride in bytes, resolved from the request (zero means whole rows).
    let layerStride: UInt32
    let x: UInt32
    let y: UInt32
    let z: UInt32
    let width: UInt32
    let height: UInt32
    let depth: UInt32
    /// The byte offset of the resource origin in the guest backing.
    let offset: UInt64

    /// Checks a transfer against its resource. Throws `ResourceTableFailure.invalidParameter` when the level or the box is out of range.
    init(
        resource: GPUResource,
        level: UInt32,
        stride requestedStride: UInt32,
        layerStride requestedLayerStride: UInt32,
        box: VirtioGPUBox,
        offset: UInt64
    ) throws(ResourceTableFailure) {
        guard level <= resource.lastLevel else {
            throw .invalidParameter(field: "level")
        }
        let layout = resource.layout
        levelWidth = max(1, resource.width >> level)
        levelHeight = max(1, resource.height >> level)
        levelDepth = max(1, resource.depth >> level)
        guard
            box.width >= 1, box.height >= 1, box.depth >= 1,
            !box.x.addingReportingOverflow(box.width).overflow,
            box.x + box.width <= levelWidth,
            !box.y.addingReportingOverflow(box.height).overflow,
            box.y + box.height <= levelHeight,
            !box.z.addingReportingOverflow(box.depth).overflow,
            box.z + box.depth <= levelDepth
        else {
            throw .invalidParameter(field: "box")
        }
        self.layout = layout
        let rowBytes = layout.rowBytes(pixels: levelWidth)
        guard rowBytes <= UInt64(UInt32.max) else {
            throw .invalidParameter(field: "box")
        }
        let tightStride = UInt32(rowBytes)
        stride = requestedStride == 0 ? tightStride : requestedStride
        let rowsPerLayer = layout.rowCount(levelHeight)
        let tightLayerStride = UInt64(stride) * rowsPerLayer
        guard requestedLayerStride != 0 || tightLayerStride <= UInt64(UInt32.max) else {
            throw .invalidParameter(field: "layerStride")
        }
        layerStride = requestedLayerStride == 0 ? UInt32(tightLayerStride) : requestedLayerStride
        x = box.x
        y = box.y
        z = box.z
        width = box.width
        height = box.height
        depth = box.depth
        self.offset = offset
    }

    /// The byte count from the origin that the box can read or write: the last byte of the last box row, plus one.
    /// Checked arithmetic. Throws on overflow.
    func extent() throws(ResourceTableFailure) -> UInt64 {
        let rowCount = layout.rowCount(y + height)
        let lastRow = rowCount - 1
        let lastLayer = UInt64(z + depth - 1)
        let (layerBytes, layerOverflow) = lastLayer.multipliedReportingOverflow(by: UInt64(layerStride))
        let (rowBytes, rowOverflow) = lastRow.multipliedReportingOverflow(by: UInt64(stride))
        guard !layerOverflow, !rowOverflow else {
            throw .invalidParameter(field: "box")
        }
        let lastColumnBytes = layout.rowBytes(pixels: x + width)
        let (total1, overflow1) = offset.addingReportingOverflow(layerBytes)
        let (total2, overflow2) = total1.addingReportingOverflow(rowBytes)
        let (total3, overflow3) = total2.addingReportingOverflow(lastColumnBytes)
        guard !overflow1, !overflow2, !overflow3 else {
            throw .invalidParameter(field: "box")
        }
        return total3 - offset
    }

    /// The byte runs of the box inside the extent, in order: each run is the box's part of one row of one layer.
    ///
    /// Scatter writes only these runs, so bytes outside the box keep their guest values.
    func boxRuns() -> [TransferRun] {
        let columnStart = UInt64(x / layout.blockWidth) * UInt64(layout.bytesPerBlock)
        let columnEnd = layout.rowBytes(pixels: x + width)
        let runLength = Int(columnEnd - columnStart)
        var runs: [TransferRun] = []
        let firstRow = y / layout.blockHeight
        let endRow = layout.rowCount(y + height)
        for layer in z..<(z + depth) {
            for row in firstRow..<UInt32(endRow) {
                let relative = UInt64(layer) * UInt64(layerStride)
                    + UInt64(row) * UInt64(stride)
                    + columnStart
                runs.append(TransferRun(offset: relative, length: runLength))
            }
        }
        return runs
    }
}

/// One contiguous byte run of a box, relative to the resource origin.
struct TransferRun: Equatable, Sendable {
    let offset: UInt64
    let length: Int
}
