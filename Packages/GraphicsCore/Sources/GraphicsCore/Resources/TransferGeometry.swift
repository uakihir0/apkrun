/// A box transfer between a resource and the guest backing (graphics.md §4.2, §4.4).
///
/// It resolves the strides the way virglrenderer does for a zero stride, checks the box
/// against the mip level, and gives the byte extent of the guest backing that the box can
/// touch. All arithmetic is checked, because the request values come from the guest.
struct TransferGeometry: Equatable, Sendable {
    /// The most bytes one transfer may gather, scatter, or hand to the renderer: one resource's limit (§5.4).
    static let maximumExtent: UInt64 = 256 * 1024 * 1024
    /// The most row runs one transfer may write back. Beyond it the transfer is refused, so one request cannot
    /// cost the device queue unbounded time.
    static let maximumRuns: UInt64 = 4 * 1024 * 1024

    let layout: PixelLayout
    /// The width, height, and number of layers of the mip level, in pixels.
    let levelWidth: UInt32
    let levelHeight: UInt32
    let levelLayers: UInt32
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

    /// Checks a transfer against its resource. Throws `ResourceTableFailure.invalidParameter` when the level, the box,
    /// or a stride is out of range.
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
        levelLayers = resource.isArrayLike ? max(1, resource.arraySize) : max(1, resource.depth >> level)
        guard
            box.width >= 1, box.height >= 1, box.depth >= 1,
            !box.x.addingReportingOverflow(box.width).overflow,
            box.x + box.width <= levelWidth,
            !box.y.addingReportingOverflow(box.height).overflow,
            box.y + box.height <= levelHeight,
            !box.z.addingReportingOverflow(box.depth).overflow,
            box.z + box.depth <= levelLayers
        else {
            throw .invalidParameter(field: "box")
        }
        self.layout = layout
        let rowBytes = layout.rowBytes(pixels: levelWidth)
        guard rowBytes <= UInt64(UInt32.max) else {
            throw .invalidParameter(field: "box")
        }
        let tightStride = UInt32(rowBytes)
        guard requestedStride == 0 || UInt64(requestedStride) >= rowBytes else {
            throw .invalidParameter(field: "stride")
        }
        stride = requestedStride == 0 ? tightStride : requestedStride
        let rowsPerLayer = layout.rowCount(levelHeight)
        let minimumLayerStride = UInt64(stride) * rowsPerLayer
        guard requestedLayerStride == 0 || UInt64(requestedLayerStride) >= minimumLayerStride,
            minimumLayerStride <= UInt64(UInt32.max)
        else {
            throw .invalidParameter(field: "layerStride")
        }
        layerStride = requestedLayerStride == 0 ? UInt32(minimumLayerStride) : requestedLayerStride
        x = box.x
        y = box.y
        z = box.z
        width = box.width
        height = box.height
        depth = box.depth
        self.offset = offset
    }

    /// The byte count from the origin that the box can read or write: the last byte of the last box row, plus one.
    /// Throws when the count overflows, or when it exceeds the one-resource limit.
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
        let (total1, overflow1) = layerBytes.addingReportingOverflow(rowBytes)
        let (total2, overflow2) = total1.addingReportingOverflow(lastColumnBytes)
        guard !overflow1, !overflow2, total2 <= Self.maximumExtent else {
            throw .invalidParameter(field: "box")
        }
        return total2
    }

    /// The number of row runs the box has.
    var runCount: UInt64 {
        UInt64(depth) * (UInt64(layout.rowCount(y + height)) - UInt64(y / layout.blockHeight))
    }

    /// Calls `body` for each byte run of the box inside the extent, in increasing order, without building a list.
    ///
    /// Each run is the box's part of one row of one layer. Scatter writes only these runs, so bytes outside the box keep
    /// their guest values.
    func forEachRun(_ body: (TransferRun) -> Void) {
        let columnStart = UInt64(x / layout.blockWidth) * UInt64(layout.bytesPerBlock)
        let columnEnd = layout.rowBytes(pixels: x + width)
        let runLength = Int(columnEnd - columnStart)
        let firstRow = UInt64(y / layout.blockHeight)
        let endRow = layout.rowCount(y + height)
        for layer in UInt64(z)..<UInt64(z + depth) {
            for row in firstRow..<endRow {
                let relative = layer * UInt64(layerStride) + row * UInt64(stride) + columnStart
                body(TransferRun(offset: relative, length: runLength))
            }
        }
    }

    /// The runs of the box, as a list. Tests use it; the device queue uses ``forEachRun(_:)``.
    func boxRuns() -> [TransferRun] {
        var runs: [TransferRun] = []
        forEachRun { runs.append($0) }
        return runs
    }
}

/// One contiguous byte run of a box, relative to the resource origin.
struct TransferRun: Equatable, Sendable {
    let offset: UInt64
    let length: Int
}
